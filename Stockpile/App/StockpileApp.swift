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
        return true
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
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(localizationController)
                .environment(premiumAccessManager)
                .environment(\.locale, localizationController.locale)
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
