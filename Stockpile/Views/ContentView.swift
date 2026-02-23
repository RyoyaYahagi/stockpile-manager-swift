import SwiftUI
import SwiftData

extension Notification.Name {
    static let didTapNotification = Notification.Name("didTapNotification")
}

@MainActor
enum NotificationTapRelay {
    private static var pendingUserInfo: [AnyHashable: Any]?
    
    static func storeAndPost(_ userInfo: [AnyHashable: Any]) {
        pendingUserInfo = userInfo
        NotificationCenter.default.post(
            name: .didTapNotification,
            object: nil,
            userInfo: userInfo
        )
    }
    
    static func consumePending() -> [AnyHashable: Any]? {
        defer { pendingUserInfo = nil }
        return pendingUserInfo
    }
}

private enum FirstLaunchAction {
    case addItem
    case notificationSettings
}

private let firstLaunchTutorialStepCount = 3

struct ContentView: View {
    @State private var router = Router()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var items: [Item]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @AppStorage("app.hasCompletedFirstLaunchTutorial")
    private var hasCompletedFirstLaunchTutorial = false
    @AppStorage("app.tutorial.replayRequestToken")
    private var tutorialReplayRequestToken = 0
    @State private var showFirstLaunchTutorial = false
    @State private var hasPresentedFirstLaunchTutorialInSession = false
    @State private var tutorialStepIndex = 0
    @State private var shouldResumeTutorialAfterAction = false
    
    private var currentFamily: Family? {
        families.first
    }
    
    var body: some View {
        NavigationStack(path: $router.path) {
            DashboardView()
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .itemDetail(let item):
                        ItemDetailView(item: item)
                    case .bagList:
                        BagListView()
                    case .settings:
                        SettingsView()
                    case .familySetup:
                        FamilySetupView()
                    case .familySettings(let family):
                        FamilySettingsView(family: family)
                    case .notificationSettings:
                        NotificationSettingsView()
                    }
                }
        }
        .environment(router)
        .sheet(item: $router.presentedSheet) { sheet in
            sheetContent(for: sheet)
                .environment(router)
        }
        .task {
            if let pendingUserInfo = NotificationTapRelay.consumePending() {
                handleNotificationTap(
                    Notification(
                        name: .didTapNotification,
                        object: nil,
                        userInfo: pendingUserInfo
                    )
                )
            }
            
            if !hasCompletedFirstLaunchTutorial,
               !hasPresentedFirstLaunchTutorialInSession {
                hasPresentedFirstLaunchTutorialInSession = true
                startTutorial(at: 0)
            }
        }
        .onChange(of: tutorialReplayRequestToken) { _, _ in
            hasPresentedFirstLaunchTutorialInSession = true
            startTutorial(at: 0)
        }
        .task(id: currentFamily?.id) {
            FamilyRealtimeSyncCoordinator.shared.activate(for: currentFamily)
            NotificationManager.shared.requestReschedule(using: modelContext)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            FamilyRealtimeSyncCoordinator.shared.requestImmediateSync()
            NotificationManager.shared.requestReschedule(using: modelContext)
            resumeTutorialIfNeeded()
        }
        .onChange(of: router.path.count) { _, _ in
            resumeTutorialIfNeeded()
        }
        .onChange(of: router.presentedSheet?.id) { _, _ in
            resumeTutorialIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapNotification)) { notification in
            _ = NotificationTapRelay.consumePending()
            handleNotificationTap(notification)
        }
        .fullScreenCover(isPresented: $showFirstLaunchTutorial) {
            FirstLaunchTutorialView(
                stepIndex: $tutorialStepIndex,
                onTryStep: handleFirstLaunchTutorialTryStep,
                onAdvanceStep: handleFirstLaunchTutorialAdvance,
                onFinish: handleFirstLaunchTutorialFinish,
                onClose: handleFirstLaunchTutorialClose
            )
        }
    }
    
    @ViewBuilder
    private func sheetContent(for sheet: Router.Sheet) -> some View {
        switch sheet {
        case .addItem(let bagId):
            ItemFormSheet(mode: .add, preselectedBagId: bagId)
        case .editItem(let item):
            ItemFormSheet(mode: .edit(item))
        case .addBag:
            BagFormSheet()
        case .inviteCode(let code):
            InviteCodeView(code: code)
        case .importJSON:
            ImportJSONView()
        case .qrScanner:
            QRScannerView { _ in
                // QRスキャン結果の処理はFamilySetupViewで行う
            }
        }
    }
    
    /// プッシュ通知タップ時のハンドリング
    private func handleNotificationTap(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        
        // シートが開いている場合は閉じる
        router.dismissSheet()
        
        // 単一アイテムの場合 → アイテム詳細へ遷移
        if let itemId = extractItemId(from: userInfo["itemId"]) {
            if let item = items.first(where: { $0.id == itemId }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    router.popToRoot()
                    router.push(.itemDetail(item))
                }
            }
        }
        // 複数アイテムの場合 → ダッシュボード（すべて表示）へ遷移
        else if userInfo["itemIds"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                router.popToRoot()
                // ルートに戻るだけでOK（DashboardViewのselectedBagIdはデフォルトでnil=すべて）
            }
        }
    }
    
    private func startTutorial(at index: Int) {
        tutorialStepIndex = min(max(0, index), firstLaunchTutorialStepCount - 1)
        shouldResumeTutorialAfterAction = false
        showFirstLaunchTutorial = true
    }

    private func handleFirstLaunchTutorialTryStep(_ action: FirstLaunchAction) {
        let nextStep = min(tutorialStepIndex + 1, firstLaunchTutorialStepCount - 1)
        tutorialStepIndex = nextStep
        shouldResumeTutorialAfterAction = true
        showFirstLaunchTutorial = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            switch action {
            case .addItem:
                router.present(.addItem())
            case .notificationSettings:
                router.popToRoot()
                router.push(.notificationSettings)
            }
        }
    }

    private func handleFirstLaunchTutorialAdvance() {
        guard tutorialStepIndex < firstLaunchTutorialStepCount - 1 else {
            handleFirstLaunchTutorialFinish()
            return
        }
        withAnimation {
            tutorialStepIndex += 1
        }
    }

    private func handleFirstLaunchTutorialFinish() {
        hasCompletedFirstLaunchTutorial = true
        shouldResumeTutorialAfterAction = false
        showFirstLaunchTutorial = false
        tutorialStepIndex = 0
    }

    private func handleFirstLaunchTutorialClose() {
        shouldResumeTutorialAfterAction = false
        showFirstLaunchTutorial = false
    }

    private func resumeTutorialIfNeeded() {
        guard shouldResumeTutorialAfterAction else { return }
        guard !showFirstLaunchTutorial else { return }
        guard router.path.isEmpty else { return }
        guard router.presentedSheet == nil else { return }

        shouldResumeTutorialAfterAction = false
        showFirstLaunchTutorial = true
    }
    
    private func extractItemId(from rawValue: Any?) -> UUID? {
        if let uuid = rawValue as? UUID {
            return uuid
        }
        
        if let uuidString = rawValue as? String {
            return UUID(uuidString: uuidString)
        }
        
        return nil
    }
}

private struct FirstLaunchTutorialView: View {
    @Binding var stepIndex: Int
    let onTryStep: (FirstLaunchAction) -> Void
    let onAdvanceStep: () -> Void
    let onFinish: () -> Void
    let onClose: () -> Void
    
    private struct Step {
        let title: String
        let description: String
        let primaryTitle: String
        let action: FirstLaunchAction?
        let helperText: String?
    }
    
    private let steps: [Step] = [
        Step(
            title: "まずは備蓄品を登録",
            description: "実際に追加画面を開いて、最初の備蓄品を登録してみましょう。",
            primaryTitle: "この操作を試す",
            action: .addItem,
            helperText: "追加画面から戻ると、このガイドの続きが自動で再表示されます。"
        ),
        Step(
            title: "通知設定を確認",
            description: "通知時刻と通知タイミングを確認して、自動通知を有効化しましょう。",
            primaryTitle: "この操作を試す",
            action: .notificationSettings,
            helperText: "設定確認後に戻ると、最終ステップに進めます。"
        ),
        Step(
            title: "準備完了です",
            description: "家族共有を使うと、備蓄品の更新が自動同期されます。すぐに使い始めましょう。",
            primaryTitle: "チュートリアル完了",
            action: nil,
            helperText: nil
        )
    ]
    
    var body: some View {
        let safeStepIndex = min(max(stepIndex, 0), steps.count - 1)
        let step = steps[safeStepIndex]
        
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: "sparkles")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.blue)
                
                VStack(spacing: 10) {
                    Text("はじめてのガイド")
                        .font(.title2.bold())
                    Text(step.title)
                        .font(.title3.weight(.semibold))
                    Text(step.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                HStack(spacing: 8) {
                    ForEach(Array(steps.indices), id: \.self) { index in
                        Capsule()
                            .fill(index == safeStepIndex ? Color.blue : Color.gray.opacity(0.25))
                            .frame(width: index == safeStepIndex ? 28 : 8, height: 8)
                    }
                }
                
                VStack(spacing: 12) {
                    if let action = step.action {
                        Button(step.primaryTitle) {
                            onTryStep(action)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        Button("この手順はあとで試す（次へ）") {
                            onAdvanceStep()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    } else {
                        Button(step.primaryTitle) {
                            onFinish()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }

                    if let helperText = step.helperText {
                        Text(helperText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("閉じる") {
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                
                Spacer()
            }
            .padding(24)
            .navigationTitle("チュートリアル")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Family.self, User.self, Bag.self, Item.self, NotificationSettings.self], inMemory: true)
}
