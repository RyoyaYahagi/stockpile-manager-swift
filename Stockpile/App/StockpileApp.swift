import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import GoogleSignIn

@MainActor
@Observable
final class ModelContainerStartup {
    /// バックグラウンドのサイレントプッシュからもコンテナを参照できるようにする。
    static let shared = ModelContainerStartup()

    private(set) var container: ModelContainer?
    private(set) var errorDescription: String?

    init() {
#if DEBUG
        if ScreenshotMode.isActive {
            container = ScreenshotFixtures.makeContainer()
            errorDescription = nil
            return
        }
#endif
        retry()
    }

    func retry() {
#if DEBUG
        // スクリーンショットモードでは実データのコンテナを作らない
        guard !ScreenshotMode.isActive else { return }
#endif
        StockpileApp.prepareProtectedApplicationSupportDirectory()
        let configuration = ModelConfiguration(cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(
                for: Family.self,
                User.self,
                Bag.self,
                Item.self,
                CloudKitDeletionMarker.self,
                NotificationSettings.self,
                configurations: configuration
            )
            self.container = container
            errorDescription = nil
            // バックグラウンド起動で ContentView が表示されなくても、
            // 受信箱のコマンドを実データへ適用できるようにする
            CommandInboxService.shared.configure(modelContext: container.mainContext)
        } catch {
            container = nil
            errorDescription = error.localizedDescription
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if CommandInboxWakePush.matches(userInfo) {
            // 受信箱のプッシュは CloudKit のものではないため、CloudKit へは渡さない。
            // 完了ハンドラは 1 回だけ、30 秒の制限内に呼ぶ。
            let gate = BackgroundFetchCompletionGate(handler: completionHandler)
            Task { @MainActor in
                let result = await CommandInboxPushReceiver.handle(userInfo)
                gate.complete(result)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                gate.complete(.failed)
            }
        } else {
            Task { @MainActor in
                let result = await CloudKitSyncRuntime.shared.handleRemoteNotification(userInfo)
                completionHandler(result)
            }
        }
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NotificationTapRelay.storeAndPost(response.notification.request.content.userInfo)
        }
        completionHandler()
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound]
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = CloudKitShareSceneDelegate.self
        return configuration
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "settings.appAppearance"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayName: String {
        switch self {
        case .system: return L10n.string("システム")
        case .light: return L10n.string("ライトモード")
        case .dark: return L10n.string("ダークモード")
        }
    }
}

@main
struct StockpileApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @AppStorage(AppDesign.storageKey) private var design: AppDesign = .modern
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var localizationController = LocalizationController()
    @State private var premiumAccessManager = PremiumAccessManager.shared
    @State private var googleDriveLinkManager = GoogleDriveLinkManager.shared
    @State private var modelStartup = ModelContainerStartup.shared

    var body: some Scene {
        WindowGroup {
            Group {
            if let container = modelStartup.container {
                ContentView()
                    .environment(localizationController)
                    .environment(premiumAccessManager)
                    .environment(googleDriveLinkManager)
                    .environment(\.locale, localizationController.locale)
                    .modelContainer(container)
                    .preferredColorScheme(design == .modern ? appearance.colorScheme : nil)
                    .task {
                        CloudKitSyncRuntime.shared.configure(container: container)
                    }
            } else {
                ModelContainerRecoveryView(
                    diagnostics: modelStartup.errorDescription,
                    retry: modelStartup.retry
                )
            }
            }
            .onOpenURL { url in
                _ = GIDSignIn.sharedInstance.handle(url)
            }
        }
    }

    static func prepareProtectedApplicationSupportDirectory() {
        guard let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: appSupportURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: appSupportURL.path
            )
        } catch {
            #if DEBUG
            print("⚠️ Application Support directory preparation failed: \(error)")
            #endif
        }
    }
}

private struct ModelContainerRecoveryView: View {
    let diagnostics: String?
    let retry: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("データを開けませんでした", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("端末の空き容量とiOSの状態を確認して再試行してください。アプリを削除すると端末内データも失われるため、削除せずサポートへご連絡ください。")
            } actions: {
                Button("再試行", action: retry)
                    .buttonStyle(.borderedProminent)
                if let supportURL = APIConfig.supportURL {
                    Link("サポートを開く", destination: supportURL)
                }
                if let diagnostics, !diagnostics.isEmpty {
                    Text("診断情報: \(diagnostics)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
    }
}

/// Bridges CloudKit background notifications to the SwiftData-backed sync service.
/// CloudKit may coalesce or delay silent pushes, so ContentView still performs the
/// normal launch/foreground reconciliation as a fallback.
@MainActor
final class CloudKitSyncRuntime {
    static let shared = CloudKitSyncRuntime()

    private var container: ModelContainer?
    private var isSyncing = false
    private var shouldSyncAgain = false

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard container != nil else { return .noData }
        if isSyncing {
            shouldSyncAgain = true
            return .noData
        }

        isSyncing = true
        defer {
            isSyncing = false
        }

        var didSync = false
        repeat {
            shouldSyncAgain = false
            guard let container else { break }
            let context = container.mainContext
            let families = (try? context.fetch(FetchDescriptor<Family>())) ?? []
                .filter { $0.isCloudKitSharedFamily }
            guard !families.isEmpty else { break }

            do {
                let service = CloudKitFamilySharingService(modelContext: context)
                try await service.ensureAutomaticSyncSubscriptions(for: families)
                for family in families {
                    try await service.syncFamilyStateFromCloudKit(for: family)
                }
                didSync = true
            } catch {
                CloudKitSharingDiagnostics.logError(
                    context: "リモート通知からの共有同期",
                    error: error
                )
            }
        } while shouldSyncAgain

        return didSync ? .newData : .failed
    }
}
