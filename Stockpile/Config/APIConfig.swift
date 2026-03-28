import Foundation

/// API設定を管理する構造体
struct APIConfig {
    private static func normalizedSecretValue(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let uppercased = trimmed.uppercased()
        if uppercased.hasPrefix("YOUR_") || uppercased.hasSuffix("_HERE") {
            return ""
        }

        return trimmed
    }

    // MARK: - 楽天API
    
    /// 楽天アプリID
    /// 楽天ウェブサービスで取得: https://webservice.rakuten.co.jp/
    static var rakutenAppId: String {
        // 1. 環境変数から取得を試みる
        let environmentValue = normalizedSecretValue(ProcessInfo.processInfo.environment["RAKUTEN_APP_ID"])
        if !environmentValue.isEmpty {
            return environmentValue
        }

        // 2. Secrets.plistから取得を試みる
        let secretsValue = normalizedSecretValue(secretsValue(for: "RakutenAppId"))
        if !secretsValue.isEmpty {
            return secretsValue
        }

        // 3. Info.plistから取得を試みる
        let infoValue = normalizedSecretValue(Bundle.main.infoDictionary?["RakutenAppId"] as? String)
        if !infoValue.isEmpty {
            return infoValue
        }

        return ""
    }
    
    /// 楽天アクセスキー
    static var rakutenAccessKey: String {
        let environmentValue = normalizedSecretValue(ProcessInfo.processInfo.environment["RAKUTEN_ACCESS_KEY"])
        if !environmentValue.isEmpty {
            return environmentValue
        }
        
        let secretsValue = normalizedSecretValue(secretsValue(for: "RakutenAccessKey"))
        if !secretsValue.isEmpty {
            return secretsValue
        }
        
        return ""
    }
    
    // MARK: - Yahoo API
    
    /// Yahoo Client ID
    /// Yahoo!デベロッパーネットワークで取得: https://developer.yahoo.co.jp/
    static var yahooClientId: String {
        let environmentValue = normalizedSecretValue(ProcessInfo.processInfo.environment["YAHOO_CLIENT_ID"])
        if !environmentValue.isEmpty {
            return environmentValue
        }
        
        let secretsValue = normalizedSecretValue(secretsValue(for: "YahooClientId"))
        if !secretsValue.isEmpty {
            return secretsValue
        }
        
        let infoValue = normalizedSecretValue(Bundle.main.infoDictionary?["YahooClientId"] as? String)
        if !infoValue.isEmpty {
            return infoValue
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
}
