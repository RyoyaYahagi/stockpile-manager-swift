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
        normalizedSecretValue(ProcessInfo.processInfo.environment["RAKUTEN_APP_ID"])
    }
    
    /// 楽天アクセスキー
    static var rakutenAccessKey: String {
        normalizedSecretValue(ProcessInfo.processInfo.environment["RAKUTEN_ACCESS_KEY"])
    }

    // MARK: - Backend

    /// バックエンドのベースURL
    static var backendBaseURL: URL? {
        let environmentValue = normalizedSecretValue(ProcessInfo.processInfo.environment["BACKEND_BASE_URL"])
        if let url = normalizedURL(environmentValue) {
            return url
        }

        let infoValue = normalizedSecretValue(Bundle.main.infoDictionary?["BackendBaseURL"] as? String)
        if let url = normalizedURL(infoValue) {
            return url
        }

        return nil
    }
    
    // MARK: - Yahoo API
    
    /// Yahoo Client ID
    /// Yahoo!デベロッパーネットワークで取得: https://developer.yahoo.co.jp/
    static var yahooClientId: String {
        normalizedSecretValue(ProcessInfo.processInfo.environment["YAHOO_CLIENT_ID"])
    }

    private static func normalizedURL(_ value: String?) -> URL? {
        let normalized = normalizedSecretValue(value)
        guard !normalized.isEmpty else { return nil }
        return URL(string: normalized)
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
        isRakutenBackendConfigured || isRakutenConfigured || isYahooConfigured
    }

    static var isRakutenBackendConfigured: Bool {
        backendBaseURL != nil
    }

    static func rakutenSearchURL(for janCode: String, itemName: String? = nil) -> URL? {
        rakutenEndpointURL(pathComponent: "search", janCode: janCode, itemName: itemName)
    }

    static func rakutenPurchaseURL(for janCode: String, itemName: String? = nil) -> URL? {
        rakutenEndpointURL(pathComponent: "redirect", janCode: janCode, itemName: itemName)
    }

    private static func rakutenEndpointURL(pathComponent: String, janCode: String, itemName: String?) -> URL? {
        guard let baseURL = backendBaseURL else { return nil }

        let trimmedJANCode = janCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJANCode.isEmpty else { return nil }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let currentPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [currentPath, "v1", "rakuten", pathComponent]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        var queryItems = [URLQueryItem(name: "jan", value: trimmedJANCode)]
        let trimmedItemName = itemName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedItemName, !trimmedItemName.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: trimmedItemName))
        }
        components.queryItems = queryItems
        return components.url
    }
}
