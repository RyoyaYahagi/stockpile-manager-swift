import Foundation
import CoreImage

/// 商品情報
struct ProductInfo: Sendable {
    let name: String
    let description: String?
    let category: String?
    let imageURL: URL?
    let janCode: String
    
    /// 検索ソース
    enum Source: String, Sendable {
        case openFoodFacts = "Open Food Facts"
        case yahoo = "Yahoo"
        case manual = "手動入力"

        var localizedDisplayName: String {
            switch self {
            case .openFoodFacts:
                return "Open Food Facts"
            case .yahoo:
                return L10n.string("Yahoo")
            case .manual:
                return L10n.string("手動入力")
            }
        }
    }
    
    let source: Source
}

/// 商品検索エラー
enum ProductSearchError: Error, LocalizedError {
    case noAPIConfigured
    case invalidJANCode
    case timeout(ProductInfo.Source)
    case rateLimited(ProductInfo.Source, retryAfterSeconds: Int?)
    case serviceUnavailable(ProductInfo.Source)
    case networkError(Error)
    case parseError
    case notFound
    
    var errorDescription: String? {
        switch self {
        case .noAPIConfigured:
            return L10n.string("APIキーが設定されていません")
        case .invalidJANCode:
            return L10n.string("無効なJANコードです")
        case .timeout(let source):
            return L10n.format("%@検索がタイムアウトしました", source.localizedDisplayName)
        case .rateLimited(let source, _):
            return L10n.format("%@検索が混み合っています。しばらくして再試行してください。", source.localizedDisplayName)
        case .serviceUnavailable(let source):
            return L10n.format("%@検索を一時的に利用できません。しばらくして再試行してください。", source.localizedDisplayName)
        case .networkError(let error):
            return L10n.format("通信エラー: %@", error.localizedDescription)
        case .parseError:
            return L10n.string("データの解析に失敗しました")
        case .notFound:
            return L10n.string("商品が見つかりませんでした")
        }
    }
}

/// 商品検索サービス
/// Yahoo API と Open Food Facts を使用してJANコードから商品情報を取得
actor ProductSearchService {
    typealias SearchOperation = @Sendable (String) async throws -> ProductInfo?

    struct SearchAttemptDeadlines: Sendable {
        let openFoodFacts: TimeInterval
        let yahoo: TimeInterval

        static let `default` = SearchAttemptDeadlines(
            openFoodFacts: 3,
            yahoo: 3
        )
    }

    private enum SearchAttemptFailure: Error {
        case timeout(source: ProductInfo.Source, deadline: TimeInterval)
        case rateLimited(source: ProductInfo.Source, retryAfterSeconds: Int?)
        case serviceUnavailable(source: ProductInfo.Source)
        case httpStatus(source: ProductInfo.Source, statusCode: Int, detail: String?)
        case invalidResponse(source: ProductInfo.Source, detail: String)
        case parse(source: ProductInfo.Source, detail: String)
        case network(source: ProductInfo.Source, underlying: Error)

        var logMessage: String {
            switch self {
            case .timeout(let source, let deadline):
                return "[ProductSearch] \(source.localizedDisplayName): Timed out after \(deadline)s"
            case .rateLimited(let source, let retryAfterSeconds):
                let suffix = retryAfterSeconds.map { " retryAfter=\($0)s" } ?? ""
                return "[ProductSearch] \(source.localizedDisplayName): Rate limited\(suffix)"
            case .serviceUnavailable(let source):
                return "[ProductSearch] \(source.localizedDisplayName): Temporarily unavailable"
            case .httpStatus(let source, let statusCode, let detail):
                let suffix = detail.map { " detail=\($0)" } ?? ""
                return "[ProductSearch] \(source.localizedDisplayName): HTTP \(statusCode)\(suffix)"
            case .invalidResponse(let source, let detail):
                return "[ProductSearch] \(source.localizedDisplayName): Invalid response \(detail)"
            case .parse(let source, let detail):
                return "[ProductSearch] \(source.localizedDisplayName): Parse failure \(detail)"
            case .network(let source, let underlying):
                return "[ProductSearch] \(source.localizedDisplayName): Network error \(underlying.localizedDescription)"
            }
        }

        var publicError: ProductSearchError {
            switch self {
            case .timeout(let source, _):
                return .timeout(source)
            case .rateLimited(let source, let retryAfterSeconds):
                return .rateLimited(source, retryAfterSeconds: retryAfterSeconds)
            case .serviceUnavailable(let source):
                return .serviceUnavailable(source)
            case .httpStatus(_, _, let detail):
                return .networkError(NSError(domain: "ProductSearch", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: detail ?? L10n.string("APIリクエストに失敗しました")
                ]))
            case .invalidResponse(_, let detail), .parse(_, let detail):
                return .networkError(NSError(domain: "ProductSearch", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: detail
                ]))
            case .network(let source, let underlying):
                if ProductSearchService.isTimeoutError(underlying) {
                    return .timeout(source)
                }
                return .networkError(underlying)
            }
        }
    }

    private enum SearchAttemptOutcome {
        case found(ProductInfo)
        case notFound
        case technicalFailure(SearchAttemptFailure)
    }

    private struct BackendErrorPayload {
        let error: String?
        let message: String?
        let retryAfterSeconds: Int?
    }
    
    static let shared = ProductSearchService()
    
    private let session: URLSession
    private let deadlines: SearchAttemptDeadlines
    private let openFoodFactsOperation: SearchOperation?
    private let yahooOperation: SearchOperation?

    init(
        session: URLSession? = nil,
        deadlines: SearchAttemptDeadlines = .default,
        openFoodFactsOperation: SearchOperation? = nil,
        yahooOperation: SearchOperation? = nil
    ) {
        self.session = session ?? ProductSearchService.makeSession()
        self.deadlines = deadlines
        self.openFoodFactsOperation = openFoodFactsOperation
        self.yahooOperation = yahooOperation
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }

    private func maskedURLString(from url: URL, sensitiveQueryNames: Set<String>) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return url.absoluteString
        }

        components.queryItems = queryItems.map { item in
            guard sensitiveQueryNames.contains(item.name.lowercased()) else {
                return item
            }
            return URLQueryItem(name: item.name, value: "***")
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func normalizedText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedInt(_ value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let stringValue as String:
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func responseSnippet(from data: Data, limit: Int = 300) -> String? {
        guard let responseString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !responseString.isEmpty else {
            return nil
        }
        return String(responseString.prefix(limit))
    }

    private func looksLikeHTML(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("<!doctype html")
            || lowered.hasPrefix("<html")
            || lowered.contains("<body")
            || lowered.contains("<head")
    }

    private func sanitizedResponseDetail(
        from data: Data,
        fallback: String = L10n.string("APIリクエストに失敗しました")
    ) -> String? {
        guard let snippet = responseSnippet(from: data) else {
            return nil
        }
        return looksLikeHTML(snippet) ? fallback : snippet
    }

    private func backendErrorPayload(from data: Data) -> BackendErrorPayload? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return BackendErrorPayload(
            error: normalizedText(json["error"]),
            message: normalizedText(json["message"]),
            retryAfterSeconds: normalizedInt(json["retryAfterSeconds"])
        )
    }

    private func retryAfterSeconds(
        from response: HTTPURLResponse,
        payload: BackendErrorPayload? = nil
    ) -> Int? {
        if let retryAfter = payload?.retryAfterSeconds {
            return retryAfter
        }

        guard let headerValue = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }

        return Int(headerValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func requestData(
        from url: URL,
        source: ProductInfo.Source,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        do {
            return try await session.data(for: request)
        } catch {
            if Self.isTimeoutError(error) {
                throw SearchAttemptFailure.timeout(source: source, deadline: timeout)
            }
            throw SearchAttemptFailure.network(source: source, underlying: error)
        }
    }

    private func runSearchAttempt(
        source: ProductInfo.Source,
        operation: () async throws -> ProductInfo?
    ) async -> SearchAttemptOutcome {
        do {
            if let product = try await operation() {
                debugLog("[ProductSearch] \(source.localizedDisplayName): Found \(product.name)")
                return .found(product)
            }
            debugLog("[ProductSearch] \(source.localizedDisplayName): Not found")
            return .notFound
        } catch let failure as SearchAttemptFailure {
            debugLog(failure.logMessage)
            return .technicalFailure(failure)
        } catch let error as ProductSearchError {
            let failure: SearchAttemptFailure
            switch error {
            case .timeout(let errorSource):
                failure = .timeout(source: errorSource, deadline: 0)
            case .rateLimited(let errorSource, let retryAfterSeconds):
                failure = .rateLimited(source: errorSource, retryAfterSeconds: retryAfterSeconds)
            case .serviceUnavailable(let errorSource):
                failure = .serviceUnavailable(source: errorSource)
            default:
                failure = .network(source: source, underlying: error)
            }
            debugLog(failure.logMessage)
            return .technicalFailure(failure)
        } catch {
            let failure: SearchAttemptFailure
            if Self.isTimeoutError(error) {
                failure = .timeout(source: source, deadline: 0)
            } else {
                failure = .network(source: source, underlying: error)
            }
            debugLog(failure.logMessage)
            return .technicalFailure(failure)
        }
    }

    private func preferredLanguageCandidates() -> [String] {
        AppLanguage.currentLanguageCandidates
            .map { $0.replacingOccurrences(of: "-", with: "_").lowercased() }
    }

    private func appLanguageCode() -> String {
        AppLanguage.currentPrimaryLanguageCode
    }

    private func localizedValue(
        baseKey: String,
        from payload: [String: Any],
        preferredLanguages: [String]
    ) -> String? {
        for language in preferredLanguages {
            let underscored = "\(baseKey)_\(language)"
            if let value = normalizedText(payload[underscored]) {
                return value
            }

            let dashed = "\(baseKey)_\(language.replacingOccurrences(of: "_", with: "-"))"
            if let value = normalizedText(payload[dashed]) {
                return value
            }

            if let primary = language.split(separator: "_").first {
                let shortKey = "\(baseKey)_\(primary)"
                if let value = normalizedText(payload[shortKey]) {
                    return value
                }
            }
        }

        return normalizedText(payload[baseKey])
    }

    private func mergedProductName(brand: String?, name: String) -> String {
        guard let brand, !name.localizedCaseInsensitiveContains(brand) else {
            return name
        }
        return "\(brand) \(name)"
    }

    private func performOpenFoodFactsSearch(janCode: String) async throws -> ProductInfo? {
        if let openFoodFactsOperation {
            return try await openFoodFactsOperation(janCode)
        }
        return try await searchOpenFoodFacts(janCode: janCode, timeout: deadlines.openFoodFacts)
    }

    private func performYahooSearch(janCode: String) async throws -> ProductInfo? {
        if let yahooOperation {
            return try await yahooOperation(janCode)
        }
        if APIConfig.isBackendConfigured {
            return try await searchYahooViaBackend(janCode: janCode, timeout: deadlines.yahoo)
        }
        return try await searchYahoo(janCode: janCode, timeout: deadlines.yahoo)
    }
    
    // MARK: - Public API
    
    /// JANコードから商品を検索
    /// - Parameter janCode: JANコード（8桁または13桁）
    /// - Returns: 商品情報
    func search(janCode: String) async throws -> ProductInfo {
        // JANコードのバリデーション
        let cleanedCode = janCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidJANCode(cleanedCode) else {
            throw ProductSearchError.invalidJANCode
        }

        let hasConfiguredCommercialAPI = APIConfig.isYahooSearchAvailable
        var technicalFailures: [SearchAttemptFailure] = []
        var sawCommercialNotFound = false
        var sawAnyNotFound = false

        func resolve(_ outcome: SearchAttemptOutcome, isCommercialSource: Bool) -> ProductInfo? {
            switch outcome {
            case .found(let product):
                return product
            case .notFound:
                sawAnyNotFound = true
                if isCommercialSource {
                    sawCommercialNotFound = true
                }
                return nil
            case .technicalFailure(let failure):
                technicalFailures.append(failure)
                return nil
            }
        }

        // 1. Yahoo が backend または direct で利用できる場合は Yahoo を優先
        if APIConfig.isYahooSearchAvailable {
            if APIConfig.isBackendConfigured {
                debugLog("[ProductSearch] Yahoo backend検索を優先します")
            } else {
                debugLog("[ProductSearch] Yahoo検索を優先します")
            }
            if let product = resolve(await runSearchAttempt(source: .yahoo) {
                try await performYahooSearch(janCode: cleanedCode)
            }, isCommercialSource: true) {
                return product
            }
            
            // 2. Open Food Facts API（無料・登録不要）
            if let product = resolve(await runSearchAttempt(source: .openFoodFacts) {
                try await performOpenFoodFactsSearch(janCode: cleanedCode)
            }, isCommercialSource: false) {
                return product
            }
        } else {
            debugLog("[ProductSearch] Yahoo検索は未設定です")

            // Yahoo 未設定時も Open Food Facts は利用する
            if let product = resolve(await runSearchAttempt(source: .openFoodFacts) {
                try await performOpenFoodFactsSearch(janCode: cleanedCode)
            }, isCommercialSource: false) {
                return product
            }
        }

        if !hasConfiguredCommercialAPI {
            throw ProductSearchError.noAPIConfigured
        }

        if let technicalFailure = technicalFailures.last, !sawCommercialNotFound {
            throw technicalFailure.publicError
        }

        if sawCommercialNotFound || sawAnyNotFound {
            throw ProductSearchError.notFound
        }

        throw ProductSearchError.notFound
    }
    
    // MARK: - Validation
    
    private func isValidJANCode(_ code: String) -> Bool {
        // 8桁（短縮）または13桁（標準）
        let isValidLength = code.count == 8 || code.count == 13
        let isNumeric = code.allSatisfy { $0.isNumber }
        return isValidLength && isNumeric
    }
    
    // MARK: - Open Food Facts API
    
    /// Open Food Facts API（無料・登録不要）
    /// https://world.openfoodfacts.org/data
    private func searchOpenFoodFacts(janCode: String, timeout: TimeInterval) async throws -> ProductInfo? {
        let languageCode = appLanguageCode()
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v0/product/\(janCode).json")!
        components.queryItems = [
            URLQueryItem(name: "lc", value: languageCode)
        ]
        let url = components.url ?? URL(string: "https://world.openfoodfacts.org/api/v0/product/\(janCode).json")!
        
        debugLog("[ProductSearch] Open Food Facts: \(url.absoluteString)")
        
        let (data, response) = try await requestData(from: url, source: .openFoodFacts, timeout: timeout)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchAttemptFailure.invalidResponse(
                source: .openFoodFacts,
                detail: L10n.string("HTTPレスポンスを取得できませんでした")
            )
        }

        guard httpResponse.statusCode == 200 else {
            throw SearchAttemptFailure.httpStatus(
                source: .openFoodFacts,
                statusCode: httpResponse.statusCode,
                detail: sanitizedResponseDetail(from: data)
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .openFoodFacts,
                detail: L10n.string("JSONを解析できませんでした")
            )
        }

        guard let status = json["status"] as? Int else {
            throw SearchAttemptFailure.parse(
                source: .openFoodFacts,
                detail: L10n.string("status が含まれていません")
            )
        }

        guard status == 1 else {
            return nil
        }

        guard let product = json["product"] as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .openFoodFacts,
                detail: L10n.string("product が含まれていません")
            )
        }
        
        let preferredLanguages = preferredLanguageCandidates()
        let localizedProductName = localizedValue(
            baseKey: "product_name",
            from: product,
            preferredLanguages: preferredLanguages
        )
        let localizedGenericName = localizedValue(
            baseKey: "generic_name",
            from: product,
            preferredLanguages: preferredLanguages
        )
        let productName = localizedProductName ?? localizedGenericName ?? L10n.string("不明な商品")

        let brands = localizedValue(baseKey: "brands", from: product, preferredLanguages: preferredLanguages)
        let categories = localizedValue(baseKey: "categories", from: product, preferredLanguages: preferredLanguages)
        let genericDescription = localizedValue(baseKey: "generic_name", from: product, preferredLanguages: preferredLanguages)
        let imageURLString = normalizedText(product["image_url"])
        let imageURL = imageURLString.flatMap { URL(string: $0) }

        let fullName = mergedProductName(brand: brands, name: productName)
        
        debugLog("[ProductSearch] Open Food Facts: Found \(fullName)")
        
        return ProductInfo(
            name: fullName,
            description: genericDescription,
            category: categories,
            imageURL: imageURL,
            janCode: janCode,
            source: .openFoodFacts
        )
    }
    
    // MARK: - Yahoo backend

    private func searchYahooViaBackend(janCode: String, timeout: TimeInterval) async throws -> ProductInfo? {
        guard let url = APIConfig.yahooSearchURL(for: janCode) else {
            throw SearchAttemptFailure.invalidResponse(
                source: .yahoo,
                detail: L10n.string("Yahoo Backend検索URLを生成できませんでした")
            )
        }

        debugLog("[ProductSearch] Requesting Yahoo backend: \(url.absoluteString)")

        let (data, response) = try await requestData(from: url, source: .yahoo, timeout: timeout)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchAttemptFailure.invalidResponse(
                source: .yahoo,
                detail: L10n.string("Yahoo Backend検索のHTTPレスポンスを取得できませんでした")
            )
        }

        let payload = backendErrorPayload(from: data)

        if httpResponse.statusCode == 404 {
            if payload?.error == "not_found" {
                return nil
            }

            throw SearchAttemptFailure.httpStatus(
                source: .yahoo,
                statusCode: httpResponse.statusCode,
                detail: payload?.message ?? sanitizedResponseDetail(from: data)
            )
        }

        if httpResponse.statusCode == 429 || payload?.error == "rate_limited" {
            throw SearchAttemptFailure.rateLimited(
                source: .yahoo,
                retryAfterSeconds: retryAfterSeconds(from: httpResponse, payload: payload)
            )
        }

        if httpResponse.statusCode == 503 {
            if payload?.error == "upstream_rate_limited" {
                throw SearchAttemptFailure.rateLimited(
                    source: .yahoo,
                    retryAfterSeconds: retryAfterSeconds(from: httpResponse, payload: payload)
                )
            }

            throw SearchAttemptFailure.serviceUnavailable(source: .yahoo)
        }

        if httpResponse.statusCode == 500, payload?.error == "server_not_configured" {
            throw SearchAttemptFailure.serviceUnavailable(source: .yahoo)
        }

        guard httpResponse.statusCode == 200 else {
            throw SearchAttemptFailure.httpStatus(
                source: .yahoo,
                statusCode: httpResponse.statusCode,
                detail: payload?.message ?? sanitizedResponseDetail(from: data)
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .yahoo,
                detail: L10n.string("Yahoo Backend検索のJSONを解析できませんでした")
            )
        }

        guard let name = normalizedText(json["name"]) else {
            throw SearchAttemptFailure.parse(
                source: .yahoo,
                detail: L10n.string("Yahoo Backend検索の name を取得できませんでした")
            )
        }

        return ProductInfo(
            name: name,
            description: normalizedText(json["description"]),
            category: normalizedText(json["category"]),
            imageURL: normalizedText(json["imageURL"]).flatMap(URL.init(string:)),
            janCode: normalizedText(json["janCode"]) ?? janCode,
            source: .yahoo
        )
    }

    // MARK: - Yahoo API
    
    /// Yahoo ショッピング商品検索API V3
    /// https://developer.yahoo.co.jp/webapi/shopping/v3/itemsearch.html
    private func searchYahoo(janCode: String, timeout: TimeInterval) async throws -> ProductInfo? {
        let clientId = APIConfig.yahooClientId
        
        // URL構築
        var components = URLComponents(string: "https://shopping.yahooapis.jp/ShoppingWebService/V3/itemSearch")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: clientId),
            URLQueryItem(name: "jan_code", value: janCode),
            URLQueryItem(name: "results", value: "1"),
            URLQueryItem(name: "image_size", value: "300")
        ]
        
        guard let url = components.url else {
            throw SearchAttemptFailure.invalidResponse(
                source: .yahoo,
                detail: L10n.string("Yahoo検索APIのURLを生成できませんでした")
            )
        }
        
        let (data, response) = try await requestData(from: url, source: .yahoo, timeout: timeout)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchAttemptFailure.invalidResponse(
                source: .yahoo,
                detail: L10n.string("Yahoo検索APIのHTTPレスポンスを取得できませんでした")
            )
        }

        if httpResponse.statusCode == 429 {
            throw SearchAttemptFailure.rateLimited(
                source: .yahoo,
                retryAfterSeconds: retryAfterSeconds(from: httpResponse)
            )
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 || httpResponse.statusCode >= 500 {
            throw SearchAttemptFailure.serviceUnavailable(source: .yahoo)
        }

        guard httpResponse.statusCode == 200 else {
            throw SearchAttemptFailure.httpStatus(
                source: .yahoo,
                statusCode: httpResponse.statusCode,
                detail: sanitizedResponseDetail(from: data)
            )
        }
        
        // JSONパース
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .yahoo,
                detail: L10n.string("Yahoo検索APIのJSONを解析できませんでした")
            )
        }

        guard let hits = json["hits"] as? [[String: Any]],
              let firstHit = hits.first else {
            return nil
        }

        func normalizedField(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let itemName = normalizedField(firstHit["name"]) else {
            throw SearchAttemptFailure.parse(
                source: .yahoo,
                detail: L10n.string("Yahoo検索APIの name を取得できませんでした")
            )
        }
        
        let descriptionValue = firstHit["description"]
        let headlineValue = firstHit["headLine"]
        let genreCategory = firstHit["genreCategory"] as? [String: Any]
        let exImage = firstHit["exImage"] as? [String: Any]
        let image = firstHit["image"] as? [String: Any]
        let returnedJANCode = firstHit["janCode"]

        let description = normalizedField(descriptionValue)
            ?? normalizedField(headlineValue)
        let category = normalizedField(genreCategory?["name"])
        let imageURLString =
            normalizedField(exImage?["url"])
            ?? normalizedField(image?["medium"])
            ?? normalizedField(image?["small"])
        let imageURL = imageURLString.flatMap { URL(string: $0) }
        let resolvedJANCode = normalizedField(returnedJANCode) ?? janCode
        
        return ProductInfo(
            name: itemName,
            description: description,
            category: category,
            imageURL: imageURL,
            janCode: resolvedJANCode,
            source: .yahoo
        )
    }
}
