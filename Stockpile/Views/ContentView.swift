import SwiftUI
import SwiftData
import CloudKit

extension Notification.Name {
    static let didTapNotification = Notification.Name("didTapNotification")
    static let didAcceptCloudKitShare = Notification.Name("didAcceptCloudKitShare")
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

@MainActor
enum CloudKitShareRelay {
    private static var pendingMetadata: CKShare.Metadata?

    static func storeAndPost(_ metadata: CKShare.Metadata) {
        pendingMetadata = metadata
        NotificationCenter.default.post(name: .didAcceptCloudKitShare, object: nil)
    }

    static func consumePending() -> CKShare.Metadata? {
        defer { pendingMetadata = nil }
        return pendingMetadata
    }
}

private enum FirstLaunchAction {
    case addItem
    case familySharing
    case notificationSettings
}

private let firstLaunchTutorialStepCount = 7

struct ContentView: View {
    @State private var router = Router()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var items: [Item]
    @Query(sort: \NotificationSettings.createdAt, order: .forward)
    private var notificationSettingsList: [NotificationSettings]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @AppStorage("app.hasCompletedFirstLaunchTutorial")
    private var hasCompletedFirstLaunchTutorial = false
    @AppStorage("app.tutorial.replayRequestToken")
    private var tutorialReplayRequestToken = 0
    @State private var showFirstLaunchTutorial = false
    @State private var hasPresentedFirstLaunchTutorialInSession = false
    @State private var tutorialStepIndex = 0
    @State private var shouldResumeTutorialAfterAction = false
    @State private var tutorialPendingAction: FirstLaunchAction?
    @State private var tutorialItemCountBeforeAction: Int?
    @State private var tutorialDidAddItem = false
    @State private var tutorialHadFamilyBeforeAction = false
    @State private var tutorialDidSetUpFamily = false
    
    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var tutorialScopedItemCount: Int {
        guard let family = currentFamily else {
            return items.filter { $0.family == nil }.count
        }

        let familyItemsCount = items.filter { $0.family?.id == family.id }.count
        if familyItemsCount > 0 {
            return familyItemsCount
        }
        return items.filter { $0.family == nil }.count
    }

    private var notificationRescheduleSignature: String {
        let settingsSignature: String
        if let settings = notificationSettingsList.first {
            settingsSignature = [
                settings.isEnabled ? "1" : "0",
                settings.notify30DaysBefore ? "1" : "0",
                settings.notify7DaysBefore ? "1" : "0",
                settings.notifyOnDay ? "1" : "0",
                "\(settings.notificationHour)",
                "\(settings.notificationMinute)"
            ].joined(separator: ":")
        } else {
            settingsSignature = "missing"
        }

        let itemSignature = items
            .map { item in
                "\(item.id.uuidString):\(item.expiryDate?.timeIntervalSince1970 ?? -1):\(item.quantity)"
            }
            .sorted()
            .joined(separator: "|")

        return "\(settingsSignature)#\(itemSignature)"
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
            LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()

            if let pendingUserInfo = NotificationTapRelay.consumePending() {
                handleNotificationTap(
                    Notification(
                        name: .didTapNotification,
                        object: nil,
                        userInfo: pendingUserInfo
                    )
                )
            }

            await refreshCloudKitSharedFamilies()
            
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
        .task(id: notificationRescheduleSignature) {
            requestRescheduleForCurrentData()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()
            FamilyRealtimeSyncCoordinator.shared.requestImmediateSync()
            requestRescheduleForCurrentData()
            resumeTutorialIfNeeded()
            Task {
                await refreshCloudKitSharedFamilies()
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .didAcceptCloudKitShare)) { _ in
            Task {
                await refreshCloudKitSharedFamilies()
            }
        }
        .fullScreenCover(isPresented: $showFirstLaunchTutorial) {
            FirstLaunchTutorialView(
                stepIndex: $tutorialStepIndex,
                didAddItem: tutorialDidAddItem,
                didSetUpFamily: tutorialDidSetUpFamily,
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
        case .exportJSON:
            ExportJSONView()
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
        tutorialPendingAction = nil
        tutorialItemCountBeforeAction = nil
        tutorialDidAddItem = false
        tutorialHadFamilyBeforeAction = currentFamily != nil
        tutorialDidSetUpFamily = currentFamily != nil
        showFirstLaunchTutorial = true
    }

    private func handleFirstLaunchTutorialTryStep(_ action: FirstLaunchAction) {
        let nextStep = min(tutorialStepIndex + 1, firstLaunchTutorialStepCount - 1)
        tutorialStepIndex = nextStep
        shouldResumeTutorialAfterAction = true
        tutorialPendingAction = action
        if action == .addItem {
            tutorialItemCountBeforeAction = tutorialScopedItemCount
        } else {
            tutorialItemCountBeforeAction = nil
        }
        if action == .familySharing {
            tutorialHadFamilyBeforeAction = currentFamily != nil
        }
        showFirstLaunchTutorial = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            switch action {
            case .addItem:
                router.present(.addItem())
            case .familySharing:
                router.popToRoot()
                if let family = currentFamily {
                    router.push(.familySettings(family))
                } else {
                    router.push(.familySetup)
                }
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

        if tutorialPendingAction == .addItem {
            let previousCount = tutorialItemCountBeforeAction ?? 0
            tutorialDidAddItem = tutorialScopedItemCount > previousCount
        }
        if tutorialPendingAction == .familySharing {
            tutorialDidSetUpFamily = currentFamily != nil || tutorialHadFamilyBeforeAction
        }

        shouldResumeTutorialAfterAction = false
        tutorialPendingAction = nil
        tutorialItemCountBeforeAction = nil
        showFirstLaunchTutorial = true
    }

    private func requestRescheduleForCurrentData() {
        let settings = ensureNotificationSettings()
        NotificationManager.shared.requestReschedule(items: items, settings: settings)
    }

    private func ensureNotificationSettings() -> NotificationSettings {
        if let existing = notificationSettingsList.first {
            return existing
        }

        let created = NotificationSettings.createDefault()
        modelContext.insert(created)
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("通知設定の初期化保存に失敗: \(error)")
            #endif
        }
        return created
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

    private func refreshCloudKitSharedFamilies() async {
        let sharingService = CloudKitFamilySharingService(modelContext: modelContext)

        if let metadata = CloudKitShareRelay.consumePending() {
            do {
                #if DEBUG
                print("[CloudKitShare] 共有メタデータを検出し、受理フローを開始します。")
                #endif
                _ = try await sharingService.acceptShare(metadata: metadata)
                #if DEBUG
                print("[CloudKitShare] 共有受理に成功しました。")
                #endif
            } catch {
                #if DEBUG
                if let ckError = error as? CKError {
                    print("[CloudKitShare] 共有受理に失敗: CKError(\(ckError.code.rawValue)) \(ckError.localizedDescription)")
                } else {
                    print("[CloudKitShare] 共有受理に失敗: \(error.localizedDescription)")
                }
                #endif
            }
        }

        for family in families where family.cloudKitDatabaseScope == .sharedDatabase {
            do {
                try await sharingService.syncFamilyStateFromCloudKit(for: family)
            } catch {
                #if DEBUG
                if let ckError = error as? CKError {
                    print("[CloudKitShare] 共有家族同期に失敗 familyID=\(family.id.uuidString): CKError(\(ckError.code.rawValue)) \(ckError.localizedDescription)")
                } else {
                    print("[CloudKitShare] 共有家族同期に失敗 familyID=\(family.id.uuidString): \(error.localizedDescription)")
                }
                #endif
            }
        }
    }
}

private struct FirstLaunchTutorialView: View {
    @Binding var stepIndex: Int
    let didAddItem: Bool
    let didSetUpFamily: Bool
    let onTryStep: (FirstLaunchAction) -> Void
    let onAdvanceStep: () -> Void
    let onFinish: () -> Void
    let onClose: () -> Void
    
    private struct Step {
        let title: String
        let message: String
        let primaryTitle: String
        let action: FirstLaunchAction?
        let secondaryTitle: String?
    }

    private var steps: [Step] {
        [
            Step(
                title: "このアプリで最初にやること",
                message: "家にある食べ物や日用品を、ひとつずつメモしていくアプリです。",
                primaryTitle: "使い方を見る",
                action: nil,
                secondaryTitle: nil
            ),
            Step(
                title: "まずは右下の + を押します",
                message: "右下の + を押すと、登録画面が開きます。",
                primaryTitle: "+ボタンを開く",
                action: .addItem,
                secondaryTitle: "今は説明だけ見る"
            ),
            Step(
                title: didAddItem ? "登録できました" : "名前だけでも保存できます",
                message: didAddItem
                    ? "一覧に1件増えていれば、最初の登録は完了です。"
                    : "登録画面では、名前を入れて保存すれば使い始められます。",
                primaryTitle: "次へ進む",
                action: nil,
                secondaryTitle: nil
            ),
            Step(
                title: "期限は分かるときだけで大丈夫です",
                message: "賞味期限が分からない物は、あとで追加できます。",
                primaryTitle: "次へ進む",
                action: nil,
                secondaryTitle: nil
            ),
            Step(
                title: "通知は必要になってから設定できます",
                message: "通知を開くと、いつお知らせするかを決められます。",
                primaryTitle: "通知を開く",
                action: .notificationSettings,
                secondaryTitle: "今は設定しない"
            ),
            Step(
                title: didSetUpFamily ? "家族共有の準備もできます" : "家族と使うときは共有を設定できます",
                message: didSetUpFamily
                    ? "家族設定から、家族に共有リンクを送れる状態です。"
                    : "家族共有を開くと、家族で同じ一覧を見るための設定画面が開きます。",
                primaryTitle: "家族共有を開く",
                action: .familySharing,
                secondaryTitle: "今は設定しない"
            ),
            Step(
                title: "これで使い始められます",
                message: "分からなくなっても、設定から「はじめての使い方」を見直せます。",
                primaryTitle: "使い始める",
                action: nil,
                secondaryTitle: nil
            )
        ]
    }
    
    var body: some View {
        let safeStepIndex = min(max(stepIndex, 0), steps.count - 1)
        let step = steps[safeStepIndex]
        
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: "sparkles")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.blue)
                
                VStack(spacing: 10) {
                    Text("はじめての使い方")
                        .font(.title2.bold())
                    Text(step.title)
                        .font(.title3.weight(.semibold))
                    Text(step.message)
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

                        Button(step.secondaryTitle ?? "次へ進む") {
                            onAdvanceStep()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    } else {
                        Button(step.primaryTitle) {
                            if safeStepIndex == steps.count - 1 {
                                onFinish()
                            } else {
                                onAdvanceStep()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }

                    Button("あとで見る") {
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
            .navigationTitle("はじめての使い方")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Family.self, User.self, Bag.self, Item.self, NotificationSettings.self], inMemory: true)
}
