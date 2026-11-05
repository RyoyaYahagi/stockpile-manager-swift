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
    @AppStorage(AppDesign.storageKey) private var design: AppDesign = .modern
    @State private var showLegacyGuide = false
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
    @State private var tutorial = TutorialCoordinator()
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

        Group {
            if design == .legacy {
                LegacyRootView()
            } else {
                MainTabView()
                    .tint(AppTheme.accent)
            }
        }
        .id(refreshToken)
        .localizedRefresh()
        .environment(router)
        .environment(tutorial)
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
        .onChange(of: design) { _, newValue in
            tutorial.close()
            showLegacyGuide = false
            router.switchDesign(to: newValue)
        }
        .onChange(of: tutorial.finishCount) { _, _ in
            hasCompletedFirstLaunchTutorial = true
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
            Task {
                await premiumAccessManager.refresh()
                await refreshCloudKitSharedFamilies()
            }
            presentPendingFirstLaunchFlowIfNeeded()
        }
        .onChange(of: router.presentedSheet?.id) { _, newValue in
            handleSheetChangeForTutorial(isPresented: newValue != nil)
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
        .sheet(isPresented: $showLegacyGuide) {
            LegacyDesignGuide {
                hasCompletedFirstLaunchTutorial = true
                showLegacyGuide = false
            }
        }
    }
    
    @ViewBuilder
    private func sheetContent(for sheet: Router.Sheet) -> some View {
        switch sheet {
        case .addMethod(let bagId):
            AddMethodSheet(bagId: bagId)
        case .addItem(let bagId, let prefill):
            if design == .legacy {
                LegacyItemFormSheet(mode: .add, preselectedBagId: bagId)
            } else {
                ItemFormSheet(mode: .add, preselectedBagId: bagId, prefill: prefill)
            }
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
            if design == .legacy {
                LegacyItemFormSheet(mode: .edit(item))
            } else {
                ItemFormSheet(mode: .edit(item))
            }
        case .addBag:
            if design == .legacy {
                LegacyBagFormSheet()
            } else {
                BagFormSheet()
            }
        case .inviteCode(let code):
            InviteCodeView(code: code)
        case .importJSON:
            ImportJSONView()
        case .exportJSON:
            ExportJSONView()
        case .aiLink:
            AILinkSettingsView()
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
        if design == .legacy {
            router.dismissSheet()
            showLegacyGuide = true
            return
        }
        // 実際の画面の上に案内を重ねるので、開いている画面を閉じてホームから始める
        router.dismissSheet()
        router.homePath = NavigationPath()
        router.stockPath = NavigationPath()
        router.familyPath = NavigationPath()
        router.settingsPath = NavigationPath()
        tutorial.start(at: index)
    }

    /// ＋の手順で追加方法のシートを開いたら、閉じたあとに次の手順へ進む
    private func handleSheetChangeForTutorial(isPresented: Bool) {
        guard tutorial.isActive, tutorial.stepIndex == TutorialCoordinator.addStepIndex else { return }
        if isPresented {
            tutorial.awaitingAddSheet = true
            return
        }
        guard tutorial.awaitingAddSheet else { return }
        // 読み取り画面から追加フォームへ続けて出る間は、次へ進まない
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard tutorial.isActive,
                  tutorial.stepIndex == TutorialCoordinator.addStepIndex,
                  tutorial.awaitingAddSheet,
                  router.presentedSheet == nil else { return }
            withAnimation(AppTheme.indicatorAnimation) {
                tutorial.advance()
            }
        }
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
        guard !tutorial.isActive else { return }

        if !hasCompletedFirstLaunchTutorial && !hasCompletedInitialLanguageSelection {
            showInitialLanguageSelection = true
            return
        }

        if FirstLaunchTutorialPresentationPolicy.shouldPresentAutomatically(
            hasCompletedTutorial: hasCompletedFirstLaunchTutorial,
            hasCompletedInitialLanguageSelection: hasCompletedInitialLanguageSelection,
            hasPresentedTutorial: hasPresentedFirstLaunchTutorial,
            isLanguageSelectionPresented: showInitialLanguageSelection,
            isTutorialPresented: tutorial.isActive
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

#Preview {
    ContentView()
        .modelContainer(for: [Family.self, User.self, Bag.self, Item.self, NotificationSettings.self], inMemory: true)
        .environment(PremiumAccessManager.shared)
}
