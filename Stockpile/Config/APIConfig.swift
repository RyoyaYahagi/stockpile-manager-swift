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

    // MARK: - Backend

    /// バックエンドのベースURL
    static var backendBaseURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if environment.keys.contains("BACKEND_BASE_URL") {
            let environmentValue = normalizedSecretValue(environment["BACKEND_BASE_URL"])
            return normalizedURL(environmentValue)
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
    
    /// Yahoo APIが利用可能かどうか
    static var isYahooConfigured: Bool {
        !yahooClientId.isEmpty
    }

    /// Backend 経由を含めて Yahoo 検索が利用可能かどうか
    static var isYahooSearchAvailable: Bool {
        isBackendConfigured || isYahooConfigured
    }
    
    /// いずれかの商品検索APIが利用可能かどうか
    static var isProductSearchAvailable: Bool {
        isBackendConfigured || isYahooConfigured
    }

    static var isBackendConfigured: Bool {
        backendBaseURL != nil
    }

    static func yahooSearchURL(for janCode: String) -> URL? {
        backendEndpointURL(pathComponents: ["v1", "yahoo", "search"], janCode: janCode, itemName: nil)
    }

    static var privacyPolicyURL: URL? {
        backendPublicPageURL(pathComponent: "privacy")
    }

    static var supportURL: URL? {
        backendPublicPageURL(pathComponent: "support")
    }

    private static func backendPublicPageURL(pathComponent: String) -> URL? {
        guard let baseURL = backendBaseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/\(pathComponent)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func backendEndpointURL(
        pathComponents: [String],
        janCode: String,
        itemName: String?
    ) -> URL? {
        guard let baseURL = backendBaseURL else { return nil }

        let trimmedJANCode = janCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJANCode.isEmpty else { return nil }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let currentPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([currentPath] + pathComponents)
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
