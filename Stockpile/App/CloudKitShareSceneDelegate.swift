import UIKit
import CloudKit
import OSLog

final class CloudKitShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    private let logger = Logger(
        subsystem: "com.stockpile-manager.app",
        category: "CloudKitShareScene"
    )

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let metadata = connectionOptions.cloudKitShareMetadata else { return }
        relay(metadata, source: "connectionOptions")
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        relay(cloudKitShareMetadata, source: "activeScene")
    }

    private func relay(_ metadata: CKShare.Metadata, source: String) {
        logger.notice("Received CloudKit share metadata source=\(source, privacy: .public)")
        Task { @MainActor in
            CloudKitShareRelay.storeAndPost(metadata)
        }
    }
}
