import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import CloudKit

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        APIConfig.configureFirebaseIfNeeded()
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
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            CloudKitShareRelay.storeAndPost(cloudKitShareMetadata)
        }
    }
    
}

@main
struct StockpileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    private let sharedModelContainer: ModelContainer = {
        // 初回起動時のStore作成前にApplication Supportを保証して、
        // CoreDataの一時的な「path not found」ログを抑制する。
        if let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            do {
                try FileManager.default.createDirectory(
                    at: appSupportURL,
                    withIntermediateDirectories: true
                )
            } catch {
                #if DEBUG
                print("⚠️ Application Support directory creation failed: \(error)")
                #endif
            }
        }
        
        let configuration = ModelConfiguration(cloudKitDatabase: .automatic)
        
        do {
            return try ModelContainer(
                for: Family.self,
                User.self,
                Bag.self,
                Item.self,
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
                .task {
                    FirebaseSyncRetryCoordinator.shared.configure(
                        modelContext: sharedModelContainer.mainContext
                    )
                    FamilyRealtimeSyncCoordinator.shared.configure(
                        modelContext: sharedModelContainer.mainContext
                    )
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
