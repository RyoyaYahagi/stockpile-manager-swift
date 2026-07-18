import Foundation

/// App Store提出用スクリーンショットを撮影するための起動モード。
/// `xcrun simctl launch <device> <bundleId> --screenshot-mode <screen>` の形で起動引数を渡すと有効化される。
/// Releaseビルドでは常に無効（`requestedScreen`はnil固定）で、本番配布物には機能として含まれない。
enum ScreenshotMode {
#if DEBUG
    private static let launchArgumentKey = "--screenshot-mode"

    static let requestedScreen: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgumentKey),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }()
#else
    static let requestedScreen: String? = nil
#endif

    static var isActive: Bool { requestedScreen != nil }
}
