import SwiftUI
import SwiftData
import CloudKit

extension Notification.Name {
    static let didTapNotification = Notification.Name("didTapNotification")
    static let didAcceptCloudKitShare = Notification.Name("didAcceptCloudKitShare")
    static let didDetectCloudKitConflict = Notification.Name("didDetectCloudKitConflict")
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

    /// この手順で開くタブ。シートで済む手順は nil
    var destinationTab: AppTab? {
        switch self {
        case .addItem: return nil
        case .familySharing: return .family
        case .notificationSettings: return .settings
        }
    }
}

private enum TutorialIllustrationKind {
    case welcome
    case addButton
    case attention
    case notifications
    case familySharing
    case settingsGuide
}

private let firstLaunchTutorialStepCount = 6

enum FirstLaunchTutorialPresentationPolicy {
    static func shouldPresentAutomatically(
        hasCompletedTutorial: Bool,
        hasCompletedInitialLanguageSelection: Bool,
        hasPresentedTutorial: Bool,
        isLanguageSelectionPresented: Bool,
        isTutorialPresented: Bool
    ) -> Bool {
        guard !isLanguageSelectionPresented, !isTutorialPresented else { return false }
        guard hasCompletedInitialLanguageSelection else { return false }
        return !hasCompletedTutorial && !hasPresentedTutorial
    }
}

struct ContentView: View {
    private static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @State private var router = Router()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocalizationController.self) private var localizationController
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    @Query private var items: [Item]
    @Query(sort: \NotificationSettings.createdAt, order: .forward)
    private var notificationSettingsList: [NotificationSettings]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @AppStorage("app.hasCompletedInitialLanguageSelection")
    private var hasCompletedInitialLanguageSelection = false
    @AppStorage("app.hasCompletedFirstLaunchTutorial")
    private var hasCompletedFirstLaunchTutorial = false
    @AppStorage("app.hasPresentedFirstLaunchTutorial")
    private var hasPresentedFirstLaunchTutorial = false
    @AppStorage("app.tutorial.replayRequestToken")
    private var tutorialReplayRequestToken = 0
    @State private var showInitialLanguageSelection = false
    @State private var showFirstLaunchTutorial = false
    @State private var tutorialStepIndex = 0
    @State private var shouldResumeTutorialAfterAction = false
    @State private var tutorialPendingAction: FirstLaunchAction?
    @State private var tutorialHadFamilyBeforeAction = false
    @State private var tutorialDidSetUpFamily = false
    @State private var cloudKitShareSuccessMessage: String?
    @State private var cloudKitShareSuccessToken = UUID()
    @State private var pendingSharedFamilyRefreshTask: Task<Void, Never>?
    @State private var showScreenshotAddItemFullScreen = false
    
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

        MainTabView()
        .tint(AppTheme.accent)
        .id(refreshToken)
        .localizedRefresh()
        .environment(router)
        .premiumPaywallSheet()
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

            if ScreenshotMode.isActive {
                presentScreenshotTarget()
                return
            }

            await refreshCloudKitSharedFamilies()

            presentPendingFirstLaunchFlowIfNeeded()
        }
        .onChange(of: tutorialReplayRequestToken) { _, _ in
            startTutorial(at: 0)
        }
        .task(id: currentFamily?.id) {
            guard !ScreenshotMode.isActive else { return }
            NotificationManager.shared.requestReschedule(using: modelContext)
        }
        .task(id: notificationRescheduleSignature) {
            guard !ScreenshotMode.isActive else { return }
            requestRescheduleForCurrentData()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active, !ScreenshotMode.isActive else { return }
            LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()
            premiumAccessManager.refreshUsageState()
            requestRescheduleForCurrentData()
            resumeTutorialIfNeeded()
            Task {
                await premiumAccessManager.refresh()
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
        .onReceive(NotificationCenter.default.publisher(for: .didDetectCloudKitConflict)) { _ in
            showCloudKitShareSuccess(
                L10n.string("別の端末で同じデータが更新されたため、最新状態を再同期しています。")
            )
        }
        .onDisappear {
            pendingSharedFamilyRefreshTask?.cancel()
            pendingSharedFamilyRefreshTask = nil
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
        .fullScreenCover(isPresented: $showScreenshotAddItemFullScreen) {
            sheetContent(for: .addItem())
                .environment(router)
                .id(refreshToken)
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
        case .addMethod(let bagId):
            AddMethodSheet(bagId: bagId)
        case .addItem(let bagId, let prefill):
            ItemFormSheet(mode: .add, preselectedBagId: bagId, prefill: prefill)
        case .scanBarcode(let bagId):
            BarcodeScannerView { product in
                router.presentAfterDismiss(.addItem(
                    bagId: bagId,
                    prefill: .init(
                        name: product.name,
                        janCode: product.janCode,
                        message: L10n.string("バーコードから品名を入れました")
                    )
                ))
            }
        case .scanExpiry(let bagId):
            OCRCameraView { detectedDate in
                guard let detectedDate else { return }
                router.presentAfterDismiss(.addItem(
                    bagId: bagId,
                    prefill: .init(
                        expiryDate: detectedDate,
                        message: L10n.string("パッケージから賞味期限を読み取りました")
                    )
                ))
            }
        case .renewItem(let item):
            RenewExpirySheet(item: item)
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
            QRScannerView { _ in }
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
        hasPresentedFirstLaunchTutorial = true
        tutorialStepIndex = min(max(0, index), firstLaunchTutorialStepCount - 1)
        shouldResumeTutorialAfterAction = false
        tutorialPendingAction = nil
        tutorialHadFamilyBeforeAction = currentFamily != nil
        tutorialDidSetUpFamily = currentFamily != nil
        showFirstLaunchTutorial = true
    }

    private func presentScreenshotTarget() {
        guard let screen = ScreenshotMode.requestedScreen else { return }
        switch screen {
        case "dashboard":
            break
        case "add-item":
            // 通常のシート表示だと背後の暗転が写り込むため、撮影時は全画面で提示する
            showScreenshotAddItemFullScreen = true
        case "bags":
            router.select(.stock)
        case "settings":
            router.select(.settings)
        case "family":
            if let family = currentFamily {
                router.push(.familySettings(family))
            }
        case "notifications":
            router.push(.notificationSettings)
        default:
            break
        }
    }

    private func presentPendingFirstLaunchFlowIfNeeded() {
        guard !ScreenshotMode.isActive else { return }
        guard !showInitialLanguageSelection else { return }
        guard !showFirstLaunchTutorial else { return }

        if !hasCompletedFirstLaunchTutorial && !hasCompletedInitialLanguageSelection {
            showInitialLanguageSelection = true
            return
        }

        if FirstLaunchTutorialPresentationPolicy.shouldPresentAutomatically(
            hasCompletedTutorial: hasCompletedFirstLaunchTutorial,
            hasCompletedInitialLanguageSelection: hasCompletedInitialLanguageSelection,
            hasPresentedTutorial: hasPresentedFirstLaunchTutorial,
            isLanguageSelectionPresented: showInitialLanguageSelection,
            isTutorialPresented: showFirstLaunchTutorial
        ) {
            startTutorial(at: 0)
        }
    }

    private func handleInitialLanguageSelectionContinue() {
        hasCompletedInitialLanguageSelection = true
        showInitialLanguageSelection = false

        guard !hasCompletedFirstLaunchTutorial else { return }
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
                router.present(.addMethod())
            case .familySharing:
                router.select(.family, resetPath: true)
                resumeTutorialWhenLeavingTutorialTab()
            case .notificationSettings:
                router.select(.settings, resetPath: true)
                resumeTutorialWhenLeavingTutorialTab()
            }
        }
    }

    /// タブを開く手順では、ほかのタブへ移ったところでチュートリアルの続きに戻る
    private func resumeTutorialWhenLeavingTutorialTab() {
        withObservationTracking {
            _ = router.selectedTab
        } onChange: {
            DispatchQueue.main.async {
                resumeTutorialIfNeeded()
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
        // 開いたタブにいる間は戻らない（そのタブを使い終えて、ほかのタブへ移ったら戻る）
        if let tab = tutorialPendingAction?.destinationTab, router.selectedTab == tab {
            return
        }

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

        let created = NotificationSettings.createDefault(isPremium: premiumAccessManager.hasPremiumAccess)
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
        guard !Self.isRunningUnderXCTest, !ScreenshotMode.isActive else { return }

        let sharingService = CloudKitFamilySharingService(modelContext: modelContext)

        if let metadata = CloudKitShareRelay.consumePending() {
            CloudKitSharingDiagnostics.log(
                event: "共有受理開始",
                details: [
                    "zoneName": metadata.share.recordID.zoneID.zoneName,
                    "ownerName": metadata.share.recordID.zoneID.ownerName,
                    "rootRecordID": metadata.rootRecord?.recordID.recordName ?? "nil"
                ]
            )
            do {
                #if DEBUG
                print("[CloudKitShare] 共有メタデータを検出し、受理フローを開始します。")
                #endif
                let acceptedFamily = try await sharingService.acceptShare(metadata: metadata)
                CloudKitSharingDiagnostics.log(
                    event: "共有受理成功",
                    details: [
                        "familyID": acceptedFamily.id.uuidString,
                        "familyName": acceptedFamily.name,
                        "shareState": acceptedFamily.shareState.label,
                        "scope": acceptedFamily.cloudKitDatabaseScope?.rawValue ?? "nil",
                        "zoneIdentity": acceptedFamily.cloudKitZoneIdentity ?? "-"
                    ]
                )
                #if DEBUG
                print("[CloudKitShare] 共有受理に成功しました。family=\(acceptedFamily.id.uuidString)")
                #endif
                showCloudKitShareSuccess(
                    acceptedFamily.cloudKitPendingSync
                        ? L10n.string("共有受理後の同期を再試行できます。CloudKit の共有データを同期中です。")
                        : L10n.string("データが共有されました")
                )
            } catch {
                logCloudKitShareError(error, context: "共有受理")
            }
        }

        let familiesToRefresh = cloudKitFamiliesForRefresh()
        do {
            try await sharingService.ensureAutomaticSyncSubscriptions(for: familiesToRefresh)
        } catch {
            logCloudKitShareError(error, context: "共有自動同期購読")
        }

        for family in familiesToRefresh {
            do {
                try await sharingService.syncFamilyDataToCloudKit(
                    for: family,
                    attachOrphanLocalData: false
                )
            } catch {
                logCloudKitShareError(
                    error,
                    context: "共有家族送信"
                )
            }

            do {
                try await sharingService.syncFamilyStateFromCloudKit(for: family)
            } catch {
                logCloudKitShareError(
                    error,
                    context: "共有家族同期"
                )
            }
        }

        updatePendingSharedFamilyRefreshSchedule()
    }

    private func cloudKitFamiliesForRefresh() -> [Family] {
        let storedFamilies = (try? modelContext.fetch(FetchDescriptor<Family>())) ?? families
        return storedFamilies.filter { $0.shareState != .localOnly }
    }

    private func logCloudKitShareError(_ error: Error, context: String) {
        CloudKitSharingDiagnostics.logError(context: context, error: error)
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

    private func updatePendingSharedFamilyRefreshSchedule() {
        let hasPendingSharedFamilies = cloudKitFamiliesForRefresh().contains {
            $0.cloudKitDatabaseScope == .sharedDatabase && $0.cloudKitPendingSync
        }

        guard hasPendingSharedFamilies else {
            pendingSharedFamilyRefreshTask?.cancel()
            pendingSharedFamilyRefreshTask = nil
            return
        }

        guard pendingSharedFamilyRefreshTask == nil else { return }

        pendingSharedFamilyRefreshTask = Task { @MainActor in
            defer { pendingSharedFamilyRefreshTask = nil }

            let retryIntervals: [UInt64] = [
                5_000_000_000,
                10_000_000_000,
                20_000_000_000,
                30_000_000_000
            ]

            for interval in retryIntervals {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await refreshCloudKitSharedFamilies()
                guard cloudKitFamiliesForRefresh().contains(where: {
                    $0.cloudKitDatabaseScope == .sharedDatabase && $0.cloudKitPendingSync
                }) else {
                    return
                }
            }
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
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.accent)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppTheme.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.9))
            .accessibilityLabel("共有完了メッセージを閉じる")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(AppTheme.accentInk)
                            .frame(width: 84, height: 84)
                            .background(AppTheme.accentSoft, in: Circle())
                            .accessibilityHidden(true)

                        Text("Stockpileへようこそ")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                            .multilineTextAlignment(.center)

                        Text("最初に表示する言語")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .multilineTextAlignment(.center)

                        Text("システムの言語のままでも進められます")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 28)
                    .riseIn()

                    VStack(spacing: 12) {
                        ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element.id) { index, language in
                            Button {
                                localizationController.selectLanguage(language)
                            } label: {
                                LanguageOptionCard(
                                    title: language.displayName,
                                    isSelected: localizationController.selectedLanguage == language
                                )
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.98))
                            .riseIn(index: index + 1)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("続ける") {
                onContinue()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
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
                .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.inkSecondary.opacity(0.5))

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(minHeight: 56)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.accentSoft)
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(AppTheme.accent, lineWidth: 1.5)
                    }
            } else {
                Color.clear.cardSurface(radius: 20)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                title: "家の備えを、ひと目で",
                message: "食べ物や日用品を登録すると、期限が近いものを教えてくれます。ホームでは備えの「安心度」が分かります。",
                primaryTitle: "使い方を見る",
                action: nil,
                secondaryTitle: nil,
                illustration: .welcome
            ),
            TutorialStep(
                title: "右下の ＋ で追加します",
                message: "＋ を押すと、バーコード、賞味期限の撮影、手入力から追加方法を選べます。",
                primaryTitle: "＋を押してみる",
                action: .addItem,
                secondaryTitle: "今は説明だけ見る",
                illustration: .addButton
            ),
            TutorialStep(
                title: "期限が近いものはホームで分かります",
                message: "「いま対応が必要」に、期限切れと7日以内の備蓄が並びます。使ったら「1つ使った」、買い替えたら「入れ替えた」を押します。",
                primaryTitle: "次へ進む",
                action: nil,
                secondaryTitle: nil,
                illustration: .attention
            ),
            TutorialStep(
                title: "お知らせは設定タブで決めます",
                message: "設定タブの「お知らせ」で、賞味期限のお知らせのオン・オフ、いつ知らせるか、時刻を決められます。",
                primaryTitle: "設定を開く",
                action: .notificationSettings,
                secondaryTitle: "今は設定しない",
                illustration: .notifications
            ),
            TutorialStep(
                title: didSetUpFamily ? "家族共有の準備もできます" : "家族と使うときは共有を設定できます",
                message: didSetUpFamily
                    ? "家族タブから共有リンクを送ると、家族と同じ一覧を見られます。"
                    : "家族タブで家族を作り、共有リンクで招待すると、同じ一覧を家族で共有できます。",
                primaryTitle: "家族タブを開く",
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
        let allSteps = steps
        let safeStepIndex = min(max(stepIndex, 0), allSteps.count - 1)
        let step = allSteps[safeStepIndex]
        let isLastStep = safeStepIndex == allSteps.count - 1

        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                topBar(currentIndex: safeStepIndex, count: allSteps.count)

                ScrollView {
                    VStack(spacing: 20) {
                        TutorialIllustrationCard(
                            kind: step.illustration,
                            didSetUpFamily: didSetUpFamily
                        )
                        .riseIn()

                        VStack(alignment: .leading, spacing: 10) {
                            Text(step.title)
                                .font(.system(.title, design: .rounded, weight: .bold))
                                .foregroundStyle(AppTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(step.message)
                                .font(.body)
                                .foregroundStyle(AppTheme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .cardSurface()
                        .riseIn(index: 1)
                    }
                    .id(safeStepIndex)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionArea(step: step, isLastStep: isLastStep)
        }
        .localizedRefresh()
    }

    private func topBar(currentIndex: Int, count: Int) -> some View {
        HStack {
            Color.clear
                .frame(width: 44, height: 44)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(index == currentIndex ? AppTheme.accent : AppTheme.ink.opacity(0.18))
                        .frame(width: index == currentIndex ? 22 : 7, height: 7)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .glassSurface(in: Capsule())
            .animation(AppTheme.indicatorAnimation, value: currentIndex)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(currentIndex + 1) / \(count)"))

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.92))
            .glassSurface(in: Circle(), interactive: true)
            .accessibilityLabel(Text("閉じる"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func actionArea(step: TutorialStep, isLastStep: Bool) -> some View {
        VStack(spacing: 10) {
            if let action = step.action {
                Button(step.primaryTitle) {
                    onTryStep(action)
                }
                .buttonStyle(PrimaryActionButtonStyle())

                Button(step.secondaryTitle ?? LocalizedStringKey("次へ進む")) {
                    onAdvanceStep()
                }
                .buttonStyle(SecondaryActionButtonStyle())
            } else {
                Button(step.primaryTitle) {
                    if isLastStep {
                        onFinish()
                    } else {
                        onAdvanceStep()
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }

            if !isLastStep {
                Button(action: onClose) {
                    Text("あとで見る")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// プレビュー枠の高さ
private let tutorialPreviewHeight: CGFloat = 240

private struct TutorialIllustrationCard: View {
    let kind: TutorialIllustrationKind
    let didSetUpFamily: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)

        TutorialLiveIllustrationPreview(
            kind: kind,
            didSetUpFamily: didSetUpFamily
        )
        .frame(maxWidth: .infinity)
        .frame(height: tutorialPreviewHeight)
        .background { AppTheme.background }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(AppTheme.ink.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct TutorialLiveIllustrationPreview: View {
    @Environment(LocalizationController.self) private var localizationController

    let kind: TutorialIllustrationKind
    let didSetUpFamily: Bool

    /// 画面の基準サイズ（390 x 844）での座標。プレビューの拡大率はカードの幅に合わせて決まる
    var body: some View {
        switch kind {
        case .welcome:
            // 見出し（〜y=85）と「安心度」カード（y=105〜261）を見せる
            TutorialScreenPreview(focusY: 0) {
                hostedPreview(container: TutorialPreviewFixtures.dashboardContainer(language: localizationController.selectedLanguage)) {
                    NavigationStack {
                        HomeView()
                    }
                }
            }

        case .addButton:
            // 「いま対応が必要」の上端（y=289）から見せ、下にタブバーと ＋ を重ねる
            TutorialScreenPreview(focusY: 270) {
                hostedPreview(container: TutorialPreviewFixtures.dashboardContainer(language: localizationController.selectedLanguage)) {
                    NavigationStack {
                        HomeView()
                    }
                }
            } overlay: { space in
                ZStack(alignment: .bottom) {
                    TutorialCalloutBadge(
                        text: "ここを押す",
                        symbol: "hand.tap.fill"
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, 78 * space.scale + 8)

                    // MainTabView と同じ並び: 横 16pt の余白、下 4pt の余白、＋ は 64pt の丸
                    GlassTabBar(selection: .constant(.home), onAdd: {})
                        .padding(.horizontal, 16)
                        .frame(width: TutorialPreviewSpace.referenceWidth)
                        .overlay(alignment: .trailing) {
                            // ＋ の中心は右端から 16 + 32 = 48pt。直径 78pt の輪をそこに重ねる
                            TutorialHighlightCircle()
                                .frame(width: 78, height: 78)
                                .padding(.trailing, 9)
                        }
                        .scaleEffect(space.scale, anchor: .bottom)
                        .padding(.bottom, 4 * space.scale)
                }
            }

        case .attention:
            // 「いま対応が必要」の見出し（y=289）と1枚目のカードを見せる
            TutorialScreenPreview(focusY: 270) {
                hostedPreview(container: TutorialPreviewFixtures.dashboardContainer(language: localizationController.selectedLanguage)) {
                    NavigationStack {
                        HomeView()
                    }
                }
            } overlay: { space in
                ZStack(alignment: .topLeading) {
                    // 1枚目のカードの「入れ替えた」ボタン（x=199〜354, y=397〜441）を囲む
                    TutorialHighlightFrame()
                        .tutorialPlaced(space.rect(x: 192, y: 390, width: 169, height: 58))

                    TutorialCalloutBadge(
                        text: "入れ替えたらここを押す",
                        symbol: "arrow.triangle.2.circlepath"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                }
            }

        case .notifications:
            // 見出し「お知らせ」（y=73〜95）と、カードの先頭のスイッチ行（y=107〜）を見せる
            TutorialScreenPreview(focusY: 56) {
                hostedPreview(container: TutorialPreviewFixtures.notificationContainer(language: localizationController.selectedLanguage)) {
                    NavigationStack {
                        SettingsView()
                    }
                }
            } overlay: { space in
                ZStack(alignment: .topLeading) {
                    TutorialHighlightFrame()
                        .tutorialPlaced(space.rect(x: 14, y: 102, width: 362, height: 88))

                    TutorialCalloutBadge(
                        text: "ここでお知らせを決める",
                        symbol: "bell.badge.fill"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                }
            }

        case .familySharing:
            TutorialCompactPreview {
                TutorialFamilySharingPreviewView(didSetUpFamily: didSetUpFamily)
            }

        case .settingsGuide:
            TutorialCompactPreview {
                TutorialSettingsGuidePreviewView()
            }
        }
    }

    private func hostedPreview<Content: View>(
        container: ModelContainer,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let previewLocalizationController = LocalizationController(
            initialLanguage: localizationController.selectedLanguage
        )

        return content()
            .environment(Router())
            .environment(previewLocalizationController)
            .environment(PremiumAccessManager.shared)
            .environment(\.locale, previewLocalizationController.locale)
            .environment(\.dynamicTypeSize, .large)
            .modelContainer(container)
            .scrollDisabled(true)
            .allowsHitTesting(false)
    }
}

/// 画面プレビュー内の座標（基準サイズ 390 x 844）を、枠内の座標に直す
private struct TutorialPreviewSpace {
    static let referenceWidth: CGFloat = 390
    static let referenceHeight: CGFloat = 844

    /// 基準サイズに対する拡大率
    let scale: CGFloat
    /// 枠の上端に合わせる基準サイズ上の y
    let focusY: CGFloat

    func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: x * scale,
            y: (y - focusY) * scale,
            width: width * scale,
            height: height * scale
        )
    }
}

private extension View {
    /// 枠いっぱいの重ね合わせの中で、指定した位置と大きさに置く
    func tutorialPlaced(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

/// 実際の画面を幅に合わせて縮め、focusY を上端にして見せる。強調の枠は基準座標で置ける
private struct TutorialScreenPreview<Content: View, Overlay: View>: View {
    private let content: Content
    private let focusY: CGFloat
    private let overlay: (TutorialPreviewSpace) -> Overlay

    init(
        focusY: CGFloat,
        @ViewBuilder content: () -> Content,
        @ViewBuilder overlay: @escaping (TutorialPreviewSpace) -> Overlay
    ) {
        self.focusY = focusY
        self.content = content()
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / TutorialPreviewSpace.referenceWidth
            let space = TutorialPreviewSpace(scale: scale, focusY: focusY)

            ZStack(alignment: .topLeading) {
                content
                    .frame(
                        width: TutorialPreviewSpace.referenceWidth,
                        height: TutorialPreviewSpace.referenceHeight
                    )
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: TutorialPreviewSpace.referenceWidth * scale,
                        height: TutorialPreviewSpace.referenceHeight * scale,
                        alignment: .topLeading
                    )
                    .offset(y: -focusY * scale)

                overlay(space)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

private extension TutorialScreenPreview where Overlay == EmptyView {
    init(focusY: CGFloat, @ViewBuilder content: () -> Content) {
        self.init(focusY: focusY, content: content, overlay: { _ in EmptyView() })
    }
}

/// 家族タブのプレビュー。家族がまだなら作成フォーム、作成済みなら招待ボタンを強調する
private struct TutorialFamilySharingPreviewView: View {
    let didSetUpFamily: Bool

    var body: some View {
        VStack(spacing: 14) {
            if didSetUpFamily {
                inviteCard
            } else {
                setupCard
            }

            TutorialCalloutBadge(
                text: "ここで共有を始めます",
                symbol: "person.3.fill"
            )
        }
        .padding(.horizontal, 24)
        .environment(\.dynamicTypeSize, .large)
        .localizedRefresh()
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("家族セットアップ")
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)

            Text("家族名")
                .font(.subheadline)
                .foregroundStyle(AppTheme.inkSecondary.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("家族を作成")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    TutorialHighlightFrame()
                        .padding(-5)
                }
                .padding(.top, 2)
        }
        .padding(16)
        .cardSurface()
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accentInk)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("わが家")
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Label("家族を招待する", systemImage: "person.badge.plus")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    TutorialHighlightFrame()
                        .padding(-5)
                }
        }
        .padding(16)
        .cardSurface()
    }
}

/// 最後の手順のプレビュー。設定タブの「はじめての使い方を見る」を示す
private struct TutorialSettingsGuidePreviewView: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("はじめての使い方を見る")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppTheme.inkSecondary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .cardSurface()
            .overlay {
                TutorialHighlightFrame()
                    .padding(-4)
            }
            .padding(.horizontal, 4)

            TutorialCalloutBadge(
                text: "ここから見直せます",
                symbol: "arrow.uturn.backward.circle.fill"
            )

            GlassTabBar(selection: .constant(.settings), onAdd: {})
        }
        .padding(.horizontal, 16)
        .environment(\.dynamicTypeSize, .large)
        .allowsHitTesting(false)
        .localizedRefresh()
    }
}

/// 画面全体を使わない小さなプレビューの枠
private struct TutorialCompactPreview<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            AppBackground()
            content
        }
        .allowsHitTesting(false)
    }
}

private struct TutorialHighlightFrame: View {
    var tint: Color = AppTheme.accent

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(tint.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint, lineWidth: 3)
            }
            .shadow(color: tint.opacity(0.25), radius: 8, x: 0, y: 3)
    }
}

private struct TutorialHighlightCircle: View {
    var tint: Color = AppTheme.accent

    var body: some View {
        Circle()
            .fill(tint.opacity(0.10))
            .overlay {
                Circle()
                    .strokeBorder(tint, lineWidth: 3.5)
            }
            .shadow(color: tint.opacity(0.25), radius: 8, x: 0, y: 3)
    }
}

@MainActor
private enum TutorialPreviewFixtures {
    static func dashboardContainer(language: AppLanguage) -> ModelContainer {
        makeDashboardContainer(language: language)
    }

    static func notificationContainer(language: AppLanguage) -> ModelContainer {
        makeNotificationContainer(language: language)
    }

    private static func makeDashboardContainer(language: AppLanguage) -> ModelContainer {
        let container = makeContainer()
        let context = container.mainContext
        let pantry = Bag(name: localized("キッチン棚", language: language))
        let emergency = Bag(name: localized("非常袋", language: language))
        let trunk = Bag(name: localized("車載ボックス", language: language))

        // 「いま対応が必要」に、期限切れ（缶詰）と7日以内（アルファ米）が並ぶようにする
        let items = [
            makeItem(name: localized("飲料水", language: language), quantity: 6, daysUntilExpiry: 21, bag: pantry),
            makeItem(name: localized("缶詰", language: language), quantity: 8, daysUntilExpiry: -3, bag: pantry),
            makeItem(name: localized("乾電池", language: language), quantity: 12, daysUntilExpiry: nil, bag: emergency),
            makeItem(name: localized("アルファ米", language: language), quantity: 4, daysUntilExpiry: 3, bag: trunk)
        ]

        [pantry, emergency, trunk].forEach { context.insert($0) }
        items.forEach { context.insert($0) }
        try? context.save()
        return container
    }

    private static func makeNotificationContainer(language: AppLanguage) -> ModelContainer {
        let container = makeContainer()
        let context = container.mainContext
        let settings = NotificationSettings.createDefault()
        settings.isEnabled = true
        settings.notificationHour = 9
        settings.notificationMinute = 0
        context.insert(settings)
        context.insert(
            makeItem(
                name: localized("カセットボンベ", language: language),
                quantity: 3,
                daysUntilExpiry: 14,
                bag: nil
            )
        )
        try? context.save()
        return container
    }

    private static func localized(_ key: String, language: AppLanguage) -> String {
        AppLocalization.bundle(for: language).localizedString(forKey: key, value: key, table: nil)
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

private struct TutorialCalloutBadge: View {
    let text: LocalizedStringKey
    let symbol: String
    var tint: Color = AppTheme.accentInk

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
            Text(text)
                .font(.caption.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassSurface(in: Capsule())
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Family.self, User.self, Bag.self, Item.self, NotificationSettings.self], inMemory: true)
        .environment(PremiumAccessManager.shared)
}
