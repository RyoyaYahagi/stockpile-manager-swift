import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import FirebaseCore

private enum FirebaseBootstrap {
    @MainActor private static var configured = false

    @MainActor
    static func configureIfNeeded() {
        guard !configured else { return }
        guard FirebaseApp.app() == nil else {
            configured = true
            return
        }

        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            print("⚠️ GoogleService-Info.plist が見つからないためFirebase初期化をスキップしました。")
            return
        }

        FirebaseApp.configure(options: options)
        configured = true
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        FirebaseBootstrap.configureIfNeeded()
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
    
}

@main
struct StockpileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        FirebaseBootstrap.configureIfNeeded()
    }
    
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
