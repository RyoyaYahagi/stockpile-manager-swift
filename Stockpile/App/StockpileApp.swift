import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import CloudKit
import FirebaseCore

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        configureFirebaseIfNeeded()
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

    private func configureFirebaseIfNeeded() {
        guard FirebaseApp.app() == nil else {
            return
        }

        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            print("⚠️ GoogleService-Info.plist が見つからないためFirebase初期化をスキップしました。")
            return
        }

        FirebaseApp.configure(options: options)
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
                print("⚠️ Application Support directory creation failed: \(error)")
            }
        }
        
        let configuration = ModelConfiguration(cloudKitDatabase: .none)
        
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
        }
        .modelContainer(sharedModelContainer)
    }
}
