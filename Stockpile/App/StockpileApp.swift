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
    
    /// CloudKit共有リンク受諾時に呼ばれる
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task {
            do {
                let sharingService = CloudKitSharingService()
                try await sharingService.acceptShare(metadata: cloudKitShareMetadata)
                
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .didAcceptCloudKitShare,
                        object: nil,
                        userInfo: ["metadata": cloudKitShareMetadata]
                    )
                }
            } catch {
                print("CloudKit共有の受諾に失敗: \(error)")
            }
        }
    }
}

@main
struct StockpileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            Family.self,
            User.self,
            Bag.self,
            Item.self,
            NotificationSettings.self
        ])
    }
}
