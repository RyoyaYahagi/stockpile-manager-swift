import SwiftUI
import SwiftData
import UIKit
import UserNotifications

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
        Task { @MainActor in
            let result = await CloudKitSyncRuntime.shared.handleRemoteNotification(userInfo)
            completionHandler(result)
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

@main
struct StockpileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var localizationController = LocalizationController()
    @State private var premiumAccessManager = PremiumAccessManager.shared
    
    private let sharedModelContainer: ModelContainer = {
        prepareProtectedApplicationSupportDirectory()
        
        let configuration = ModelConfiguration(cloudKitDatabase: .none)
        
        do {
            return try ModelContainer(
                for: Family.self,
                User.self,
                Bag.self,
                Item.self,
                CloudKitDeletionMarker.self,
                NotificationSettings.self,
                configurations: configuration
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        CloudKitSyncRuntime.shared.configure(container: sharedModelContainer)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(localizationController)
                .environment(premiumAccessManager)
                .environment(\.locale, localizationController.locale)
                .task {
                    CloudKitSyncRuntime.shared.configure(container: sharedModelContainer)
                }
        }
        .modelContainer(sharedModelContainer)
    }

    private static func prepareProtectedApplicationSupportDirectory() {
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
