import Foundation
import FirebaseCore

/// API設定を管理する構造体
struct APIConfig {
    private static let firebaseConfigLock = NSLock()
    nonisolated(unsafe) private static var firebaseConfigured = false
    
    // MARK: - 楽天API
    
    /// 楽天アプリID
    /// 楽天ウェブサービスで取得: https://webservice.rakuten.co.jp/
    static var rakutenAppId: String {
        // 1. 環境変数から取得を試みる
        if let value = ProcessInfo.processInfo.environment["RAKUTEN_APP_ID"], !value.isEmpty {
            return value
        }
        
        // 2. Secrets.plistから取得を試みる
        if let value = secretsValue(for: "RakutenAppId"), !value.isEmpty {
            return value
        }
        
        // 3. Info.plistから取得を試みる
        if let value = Bundle.main.infoDictionary?["RakutenAppId"] as? String, !value.isEmpty {
            return value
        }
        
        return ""
    }
    
    /// 楽天アクセスキー
    static var rakutenAccessKey: String {
        if let value = ProcessInfo.processInfo.environment["RAKUTEN_ACCESS_KEY"], !value.isEmpty {
            return value
        }
        
        if let value = secretsValue(for: "RakutenAccessKey"), !value.isEmpty {
            return value
        }
        
        return ""
    }
    
    // MARK: - Yahoo API
    
    /// Yahoo Client ID
    /// Yahoo!デベロッパーネットワークで取得: https://developer.yahoo.co.jp/
    static var yahooClientId: String {
        if let value = ProcessInfo.processInfo.environment["YAHOO_CLIENT_ID"], !value.isEmpty {
            return value
        }
        
        if let value = secretsValue(for: "YahooClientId"), !value.isEmpty {
            return value
        }
        
        if let value = Bundle.main.infoDictionary?["YahooClientId"] as? String, !value.isEmpty {
            return value
        }
        
        return ""
    }
    
    // MARK: - Secrets.plist読み込み
    
    private static func secretsValue(for key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let value = dict[key] as? String else {
            return nil
        }
        return value
    }
    
    // MARK: - 設定状態の確認
    
    /// 楽天APIが利用可能かどうか
    static var isRakutenConfigured: Bool {
        !rakutenAppId.isEmpty && !rakutenAccessKey.isEmpty
    }
    
    /// Yahoo APIが利用可能かどうか
    static var isYahooConfigured: Bool {
        !yahooClientId.isEmpty
    }
    
    /// いずれかの商品検索APIが利用可能かどうか
    static var isProductSearchAvailable: Bool {
        isRakutenConfigured || isYahooConfigured
    }

    // MARK: - Firebase

    /// Firebase SDKを必要時に初期化
    static func configureFirebaseIfNeeded() {
        firebaseConfigLock.lock()
        defer { firebaseConfigLock.unlock() }

        guard !firebaseConfigured else { return }

        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
            firebaseConfigured = true
            return
        }

        // `GoogleService-Info.plist` が存在するが options 解決に失敗した場合のみ
        // 標準解決を最後に試行する。
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            print("⚠️ GoogleService-Info.plist が見つからないためFirebase初期化をスキップしました。")
            return
        }
        FirebaseApp.configure()
        firebaseConfigured = true
    }

    /// Firebase SDKが初期化済みか
    static var isFirebaseConfigured: Bool {
        firebaseConfigLock.lock()
        defer { firebaseConfigLock.unlock() }
        return firebaseConfigured
    }
}
