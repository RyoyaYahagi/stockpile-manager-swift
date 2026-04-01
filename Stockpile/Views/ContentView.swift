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

private enum TutorialIllustrationKind {
    case welcome
    case addButton
    case notifications
    case familySharing
    case settingsGuide
}

private let firstLaunchTutorialStepCount = 5

struct ContentView: View {
    private static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @State private var router = Router()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocalizationController.self) private var localizationController
    @Query private var items: [Item]
    @Query(sort: \NotificationSettings.createdAt, order: .forward)
    private var notificationSettingsList: [NotificationSettings]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @AppStorage("app.hasCompletedInitialLanguageSelection")
    private var hasCompletedInitialLanguageSelection = false
    @AppStorage("app.hasCompletedFirstLaunchTutorial")
    private var hasCompletedFirstLaunchTutorial = false
    @AppStorage("app.tutorial.replayRequestToken")
    private var tutorialReplayRequestToken = 0
    @State private var showInitialLanguageSelection = false
    @State private var showFirstLaunchTutorial = false
    @State private var hasPresentedFirstLaunchTutorialInSession = false
    @State private var tutorialStepIndex = 0
    @State private var shouldResumeTutorialAfterAction = false
    @State private var tutorialPendingAction: FirstLaunchAction?
    @State private var tutorialHadFamilyBeforeAction = false
    @State private var tutorialDidSetUpFamily = false
    @State private var cloudKitShareSuccessMessage: String?
    @State private var cloudKitShareSuccessToken = UUID()
    
    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var notificationRescheduleSignature: String {
        let settingsSignature: String
        if let settings = notificationSettingsList.first {
            settingsSignature = [
                settings.isEnabled ? "1" : "0",
                settings.notificationTimingSignature,
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
        let refreshToken = localizationController.uiRefreshToken

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
        .id(refreshToken)
        .localizedRefresh()
        .environment(router)
        .sheet(item: $router.presentedSheet) { sheet in
            sheetContent(for: sheet)
                .environment(router)
                .id(refreshToken)
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

            presentPendingFirstLaunchFlowIfNeeded()
        }
        .onChange(of: tutorialReplayRequestToken) { _, _ in
            hasPresentedFirstLaunchTutorialInSession = true
            startTutorial(at: 0)
        }
        .task(id: currentFamily?.id) {
            NotificationManager.shared.requestReschedule(using: modelContext)
        }
        .task(id: notificationRescheduleSignature) {
            requestRescheduleForCurrentData()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()
            requestRescheduleForCurrentData()
            resumeTutorialIfNeeded()
            Task {
                await refreshCloudKitSharedFamilies()
            }
            presentPendingFirstLaunchFlowIfNeeded()
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
        .overlay(alignment: .top) {
            if let cloudKitShareSuccessMessage {
                CloudKitShareSuccessBanner(
                    message: cloudKitShareSuccessMessage,
                    onDismiss: dismissCloudKitShareSuccessBanner
                )
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .task(id: cloudKitShareSuccessToken) {
            guard cloudKitShareSuccessMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            dismissCloudKitShareSuccessBanner()
        }
        .fullScreenCover(isPresented: $showInitialLanguageSelection) {
            InitialLanguageSelectionView(
                onContinue: handleInitialLanguageSelectionContinue
            )
            .id(refreshToken)
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showFirstLaunchTutorial) {
            FirstLaunchTutorialView(
                stepIndex: $tutorialStepIndex,
                didSetUpFamily: tutorialDidSetUpFamily,
                onTryStep: handleFirstLaunchTutorialTryStep,
                onAdvanceStep: handleFirstLaunchTutorialAdvance,
                onFinish: handleFirstLaunchTutorialFinish,
                onClose: handleFirstLaunchTutorialClose
            )
            .id(refreshToken)
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
        case .importJSON:
            ImportJSONView()
        case .exportJSON:
            ExportJSONView()
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
        tutorialHadFamilyBeforeAction = currentFamily != nil
        tutorialDidSetUpFamily = currentFamily != nil
        showFirstLaunchTutorial = true
    }

    private func presentPendingFirstLaunchFlowIfNeeded() {
        guard !showInitialLanguageSelection else { return }
        guard !showFirstLaunchTutorial else { return }

        if !hasCompletedFirstLaunchTutorial && !hasCompletedInitialLanguageSelection {
            showInitialLanguageSelection = true
            return
        }

        if !hasCompletedFirstLaunchTutorial,
           !hasPresentedFirstLaunchTutorialInSession {
            hasPresentedFirstLaunchTutorialInSession = true
            startTutorial(at: 0)
        }
    }

    private func handleInitialLanguageSelectionContinue() {
        hasCompletedInitialLanguageSelection = true
        showInitialLanguageSelection = false

        guard !hasCompletedFirstLaunchTutorial else { return }
        hasPresentedFirstLaunchTutorialInSession = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            startTutorial(at: 0)
        }
    }

    private func handleFirstLaunchTutorialTryStep(_ action: FirstLaunchAction) {
        let nextStep = min(tutorialStepIndex + 1, firstLaunchTutorialStepCount - 1)
        tutorialStepIndex = nextStep
        shouldResumeTutorialAfterAction = true
        tutorialPendingAction = action
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
        guard !showInitialLanguageSelection else { return }
        guard !showFirstLaunchTutorial else { return }
        guard router.path.isEmpty else { return }
        guard router.presentedSheet == nil else { return }

        if tutorialPendingAction == .familySharing {
            tutorialDidSetUpFamily = currentFamily != nil || tutorialHadFamilyBeforeAction
        }

        shouldResumeTutorialAfterAction = false
        tutorialPendingAction = nil
        showFirstLaunchTutorial = true
    }

    private func requestRescheduleForCurrentData() {
        let settings = ensureNotificationSettings()
        NotificationManager.shared.requestReschedule(items: items, settings: settings)
    }

    private func ensureNotificationSettings() -> NotificationSettings {
        if let existing = notificationSettingsList.first {
            if existing.migrateLegacyTimingRulesIfNeeded() {
                try? modelContext.save()
            }
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
        guard !Self.isRunningUnderXCTest else { return }

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
                showCloudKitShareSuccess(L10n.string("データが共有されました"))
            } catch {
                logCloudKitShareError(error, context: "共有受理")
            }
        }

        for family in families where family.cloudKitDatabaseScope == .sharedDatabase {
            do {
                try await sharingService.syncFamilyStateFromCloudKit(for: family)
            } catch {
                logCloudKitShareError(
                    error,
                    context: "共有家族同期"
                )
            }
        }
    }

    private func logCloudKitShareError(_ error: Error, context: String) {
        #if DEBUG
        if let ckError = error as? CKError {
            print(
                "[CloudKitShare] \(context) に失敗: CKError(\(ckError.code.rawValue)) \(ckError.localizedDescription)"
            )
        } else {
            print("[CloudKitShare] \(context) に失敗: \(error.localizedDescription)")
        }
        #endif
    }

    private func showCloudKitShareSuccess(_ message: String) {
        withAnimation {
            cloudKitShareSuccessMessage = message
            cloudKitShareSuccessToken = UUID()
        }
    }

    private func dismissCloudKitShareSuccessBanner() {
        guard cloudKitShareSuccessMessage != nil else { return }
        withAnimation {
            cloudKitShareSuccessMessage = nil
        }
    }
}

private struct CloudKitShareSuccessBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("共有完了メッセージを閉じる")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.green.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 6)
    }
}

private struct TutorialStep {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let primaryTitle: LocalizedStringKey
    let action: FirstLaunchAction?
    let secondaryTitle: LocalizedStringKey?
    let illustration: TutorialIllustrationKind
}

private struct InitialLanguageSelectionView: View {
    @Environment(LocalizationController.self) private var localizationController

    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.blue.opacity(0.2),
                                        Color.cyan.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 92, height: 92)

                        Image(systemName: "globe")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.blue)
                    }

                    Text("Stockpileへようこそ")
                        .font(.title2.bold())

                    Text("最初に表示する言語")
                        .font(.title3.weight(.semibold))

                    Text("システムの言語のままでも進められます")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 28)

                VStack(spacing: 12) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            localizationController.selectLanguage(language)
                        } label: {
                            LanguageOptionCard(
                                title: language.displayName,
                                isSelected: localizationController.selectedLanguage == language
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button("続ける") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
        .background(Color(.systemGroupedBackground))
        .localizedRefresh()
    }
}

private struct LanguageOptionCard: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.5))

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(isSelected ? 0.08 : 0.03), radius: 10, x: 0, y: 4)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.35) : Color.gray.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct FirstLaunchTutorialView: View {
    @Binding var stepIndex: Int
    let didSetUpFamily: Bool
    let onTryStep: (FirstLaunchAction) -> Void
    let onAdvanceStep: () -> Void
    let onFinish: () -> Void
    let onClose: () -> Void
    
    private var steps: [TutorialStep] {
        [
            TutorialStep(
                title: "このアプリで最初にやること",
                message: "家にある食べ物や日用品を、ひとつずつメモしていくアプリです。",
                primaryTitle: "使い方を見る",
                action: nil,
                secondaryTitle: nil,
                illustration: .welcome
            ),
            TutorialStep(
                title: "まずは右下の + を押します",
                message: "登録画面が開いたら、名前を入れて保存するだけで使い始められます。",
                primaryTitle: "+ボタンを開く",
                action: .addItem,
                secondaryTitle: "今は説明だけ見る",
                illustration: .addButton
            ),
            TutorialStep(
                title: "通知は必要になってから設定できます",
                message: "通知を開くと、いつお知らせするかを決められます。",
                primaryTitle: "通知を開く",
                action: .notificationSettings,
                secondaryTitle: "今は設定しない",
                illustration: .notifications
            ),
            TutorialStep(
                title: didSetUpFamily ? "家族共有の準備もできます" : "家族と使うときは共有を設定できます",
                message: didSetUpFamily
                    ? "家族設定から、家族に共有リンクを送れる状態です。"
                    : "家族共有を開くと、家族で同じ一覧を見るための設定画面が開きます。",
                primaryTitle: "家族共有を開く",
                action: .familySharing,
                secondaryTitle: "今は設定しない",
                illustration: .familySharing
            ),
            TutorialStep(
                title: "これで使い始められます",
                message: "分からなくなっても、設定から「はじめての使い方」を見直せます。",
                primaryTitle: "使い始める",
                action: nil,
                secondaryTitle: nil,
                illustration: .settingsGuide
            )
        ]
    }
    
    var body: some View {
        let safeStepIndex = min(max(stepIndex, 0), steps.count - 1)
        let step = steps[safeStepIndex]
        
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    TutorialIllustrationCard(
                        kind: step.illustration,
                        didSetUpFamily: didSetUpFamily
                    )

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
                }
                .padding(24)
                .padding(.bottom, 140)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let action = step.action {
                        Button(step.primaryTitle) {
                            onTryStep(action)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        Button(step.secondaryTitle ?? LocalizedStringKey("次へ進む")) {
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
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("はじめての使い方")
            .navigationBarTitleDisplayMode(.inline)
            .localizedRefresh()
        }
    }
}

private struct TutorialIllustrationCard: View {
    let kind: TutorialIllustrationKind
    let didSetUpFamily: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.16),
                            Color.cyan.opacity(0.08),
                            Color.white
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            TutorialLiveIllustrationPreview(
                kind: kind,
                didSetUpFamily: didSetUpFamily
            )
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 10)
    }
}

@MainActor
private struct TutorialLiveIllustrationPreview: View {
    let kind: TutorialIllustrationKind
    let didSetUpFamily: Bool

    var body: some View {
        switch kind {
        case .welcome:
            preview(offsetY: -12) {
                hostedPreview(container: TutorialPreviewFixtures.dashboardContainer) {
                    NavigationStack {
                        DashboardView()
                    }
                }
            }

        case .addButton:
            preview(offsetY: -112, scale: 0.48) {
                hostedPreview(container: TutorialPreviewFixtures.emptyDashboardContainer) {
                    NavigationStack {
                        DashboardView()
                    }
                }
            } overlay: {
                ZStack {
                    TutorialHighlightCircle(tint: .blue)
                        .frame(width: 74, height: 74)
                        .offset(x: 18, y: 18)

                    TutorialCalloutBadge(
                        text: "ここを押す",
                        symbol: "hand.tap.fill",
                        tint: .blue
                    )
                    .offset(x: -32, y: -12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

        case .notifications:
            preview(offsetY: -118) {
                hostedPreview(container: TutorialPreviewFixtures.notificationContainer) {
                    NavigationStack {
                        NotificationSettingsView()
                    }
                }
            } overlay: {
                TutorialCalloutBadge(
                    text: "通知時刻を決める",
                    symbol: "bell.badge.fill",
                    tint: .orange
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

        case .familySharing:
            if didSetUpFamily {
                preview(offsetY: -56, scale: 0.62) {
                    hostedPreview(container: TutorialPreviewFixtures.familyFixture.container) {
                        NavigationStack {
                            FamilySettingsView(family: TutorialPreviewFixtures.familyFixture.family)
                        }
                    }
                } overlay: {
                    ZStack {
                        TutorialHighlightFrame(tint: .green)
                            .frame(width: 248, height: 36)
                            .offset(x: 0, y: -14)

                        TutorialCalloutBadge(
                            text: "共有リンクを送れます",
                            symbol: "paperplane.fill",
                            tint: .green
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            } else {
                preview(offsetY: -8, scale: 0.62) {
                    hostedPreview(container: TutorialPreviewFixtures.familySetupContainer) {
                        NavigationStack {
                            FamilySetupView()
                        }
                    }
                } overlay: {
                    ZStack {
                        TutorialHighlightFrame(tint: .green)
                            .frame(width: 236, height: 42)
                            .offset(x: 0, y: -58)

                        TutorialCalloutBadge(
                            text: "ここで共有を始めます",
                            symbol: "person.3.fill",
                            tint: .green
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            }

        case .settingsGuide:
            preview(offsetY: -166, scale: 0.72) {
                hostedPreview(container: TutorialPreviewFixtures.settingsContainer) {
                    NavigationStack {
                        SettingsView()
                    }
                }
            } overlay: {
                ZStack {
                    TutorialHighlightFrame(tint: .blue)
                        .frame(width: 252, height: 44)
                        .offset(x: 0, y: -4)

                    TutorialCalloutBadge(
                        text: "ここから見直せます",
                        symbol: "arrow.uturn.backward.circle.fill",
                        tint: .blue
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
    }

    private func preview<Content: View>(
        offsetY: CGFloat,
        scale: CGFloat = 0.76,
        @ViewBuilder content: () -> Content
    ) -> some View {
        TutorialScreenPreview(offsetY: offsetY, scale: scale, content: content)
    }

    private func preview<Content: View, Overlay: View>(
        offsetY: CGFloat,
        scale: CGFloat = 0.76,
        @ViewBuilder content: () -> Content,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        TutorialScreenPreview(
            offsetY: offsetY,
            scale: scale,
            content: content,
            overlay: overlay
        )
    }

    private func hostedPreview<Content: View>(
        container: ModelContainer,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let localizationController = LocalizationController(initialLanguage: .japanese)

        return content()
            .environment(Router())
            .environment(localizationController)
            .environment(\.locale, localizationController.locale)
            .modelContainer(container)
            .scrollDisabled(true)
            .preferredColorScheme(.light)
            .allowsHitTesting(false)
    }
}

private struct TutorialScreenPreview<Content: View, Overlay: View>: View {
    private let content: Content
    private let overlay: Overlay
    private let offsetY: CGFloat
    private let previewScale: CGFloat

    private let previewSize = CGSize(width: 390, height: 844)

    init(
        offsetY: CGFloat,
        scale: CGFloat,
        @ViewBuilder content: () -> Content,
        @ViewBuilder overlay: () -> Overlay = { EmptyView() }
    ) {
        self.offsetY = offsetY
        self.previewScale = scale
        self.content = content()
        self.overlay = overlay()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.96))

            content
                .frame(width: previewSize.width, height: previewSize.height)
                .scaleEffect(previewScale, anchor: .top)
                .frame(
                    width: previewSize.width * previewScale,
                    height: previewSize.height * previewScale,
                    alignment: .top
                )
                .offset(y: offsetY)
                .clipped()

            overlay
                .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 204)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct TutorialHighlightFrame: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(tint.opacity(0.9), lineWidth: 3)
            }
            .shadow(color: tint.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

private struct TutorialHighlightCircle: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(.white.opacity(0.08))
            .overlay {
                Circle()
                    .stroke(tint.opacity(0.9), lineWidth: 4)
            }
            .shadow(color: tint.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

@MainActor
private enum TutorialPreviewFixtures {
    static let dashboardContainer = makeDashboardContainer()
    static let emptyDashboardContainer = makeEmptyDashboardContainer()
    static let notificationContainer = makeNotificationContainer()
    static let familySetupContainer = makeFamilySetupContainer()
    static let familyFixture = makeFamilyFixture()
    static let settingsContainer = makeSettingsContainer()

    private static func makeDashboardContainer() -> ModelContainer {
        let container = makeContainer()
        let context = container.mainContext
        let pantry = Bag(name: "キッチン棚")
        let emergency = Bag(name: "非常袋")
        let trunk = Bag(name: "車載ボックス")

        let items = [
            makeItem(name: "飲料水", quantity: 6, daysUntilExpiry: 21, bag: pantry),
            makeItem(name: "缶詰", quantity: 8, daysUntilExpiry: 120, bag: pantry),
            makeItem(name: "乾電池", quantity: 12, daysUntilExpiry: nil, bag: emergency),
            makeItem(name: "アルファ米", quantity: 4, daysUntilExpiry: 8, bag: trunk)
        ]

        [pantry, emergency, trunk].forEach { context.insert($0) }
        items.forEach { context.insert($0) }
        try? context.save()
        return container
    }

    private static func makeEmptyDashboardContainer() -> ModelContainer {
        makeContainer()
    }

    private static func makeNotificationContainer() -> ModelContainer {
        let container = makeContainer()
        let context = container.mainContext
        let settings = NotificationSettings.createDefault()
        settings.notificationHour = 9
        settings.notificationMinute = 0
        context.insert(settings)
        context.insert(makeItem(name: "カセットボンベ", quantity: 3, daysUntilExpiry: 14, bag: nil))
        try? context.save()
        return container
    }

    private static func makeFamilySetupContainer() -> ModelContainer {
        makeContainer()
    }

    private static func makeFamilyFixture() -> TutorialFamilyFixture {
        let container = makeContainer()
        let context = container.mainContext
        let family = Family(name: "わが家")
        family.cloudKitDatabaseScope = .privateDatabase
        family.cloudKitShareURL = URL(string: "https://icloud.com/share/stockpile-family")
        let pantry = Bag(name: "パントリー")
        pantry.family = family

        let users = [
            User(displayName: "自分", email: "me@example.com"),
            User(displayName: "家族A", email: "family-a@example.com"),
            User(displayName: "家族B", email: "family-b@example.com")
        ]
        users.forEach { $0.family = family }

        let items = [
            makeItem(name: "レトルトご飯", quantity: 5, daysUntilExpiry: 45, bag: pantry, family: family),
            makeItem(name: "保存水", quantity: 6, daysUntilExpiry: 90, bag: pantry, family: family)
        ]

        context.insert(family)
        context.insert(pantry)
        users.forEach { context.insert($0) }
        items.forEach { context.insert($0) }
        try? context.save()

        return TutorialFamilyFixture(container: container, family: family)
    }

    private static func makeSettingsContainer() -> ModelContainer {
        let container = makeContainer()
        let context = container.mainContext
        let family = Family(name: "わが家")
        let users = [
            User(displayName: "自分", email: "me@example.com"),
            User(displayName: "家族A", email: "family-a@example.com")
        ]
        users.forEach { $0.family = family }

        context.insert(family)
        users.forEach { context.insert($0) }
        try? context.save()
        return container
    }

    private static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(
            for: Family.self,
            User.self,
            Bag.self,
            Item.self,
            NotificationSettings.self,
            configurations: configuration
        )
    }

    private static func makeItem(
        name: String,
        quantity: Int,
        daysUntilExpiry: Int?,
        bag: Bag?,
        family: Family? = nil
    ) -> Item {
        let item = Item(
            name: name,
            quantity: quantity,
            expiryDate: daysUntilExpiry.map {
                Calendar.current.date(byAdding: .day, value: $0, to: Date()) ?? Date()
            }
        )
        item.bag = bag
        item.family = family
        return item
    }
}

@MainActor
private struct TutorialFamilyFixture {
    let container: ModelContainer
    let family: Family
}

private struct TutorialCalloutBadge: View {
    let text: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white, in: Capsule())
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Family.self, User.self, Bag.self, Item.self, NotificationSettings.self], inMemory: true)
}
