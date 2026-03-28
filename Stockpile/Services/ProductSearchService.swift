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
        case rakuten = "楽天"
        case yahoo = "Yahoo"
        case manual = "手動入力"

        var localizedDisplayName: String {
            switch self {
            case .openFoodFacts:
                return "Open Food Facts"
            case .rakuten:
                return L10n.string("楽天")
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
    case networkError(Error)
    case parseError
    case notFound
    
    var errorDescription: String? {
        switch self {
        case .noAPIConfigured:
            return L10n.string("APIキーが設定されていません")
        case .invalidJANCode:
            return L10n.string("無効なJANコードです")
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
/// 楽天・Yahoo APIを使用してJANコードから商品情報を取得
actor ProductSearchService {
    private enum SearchAttemptFailure: Error {
        case httpStatus(source: ProductInfo.Source, statusCode: Int, detail: String?)
        case invalidResponse(source: ProductInfo.Source, detail: String)
        case parse(source: ProductInfo.Source, detail: String)
        case network(source: ProductInfo.Source, underlying: Error)

        var logMessage: String {
            switch self {
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
            case .httpStatus(_, _, let detail):
                return .networkError(NSError(domain: "ProductSearch", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: detail ?? L10n.string("APIリクエストに失敗しました")
                ]))
            case .invalidResponse(_, let detail), .parse(_, let detail):
                return .networkError(NSError(domain: "ProductSearch", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: detail
                ]))
            case .network(_, let underlying):
                return .networkError(underlying)
            }
        }
    }

    private enum SearchAttemptOutcome {
        case found(ProductInfo)
        case notFound
        case technicalFailure(SearchAttemptFailure)
    }
    
    static let shared = ProductSearchService()
    
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
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

    private func responseSnippet(from data: Data, limit: Int = 300) -> String? {
        guard let responseString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !responseString.isEmpty else {
            return nil
        }
        return String(responseString.prefix(limit))
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
        } catch {
            let failure = SearchAttemptFailure.network(source: source, underlying: error)
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

        var technicalFailures: [SearchAttemptFailure] = []
        var sawNotFound = false

        func resolve(_ outcome: SearchAttemptOutcome) -> ProductInfo? {
            switch outcome {
            case .found(let product):
                return product
            case .notFound:
                sawNotFound = true
                return nil
            case .technicalFailure(let failure):
                technicalFailures.append(failure)
                return nil
            }
        }

        // 1. 楽天APIを最優先
        if APIConfig.isRakutenConfigured {
            if let product = resolve(await runSearchAttempt(source: .rakuten) {
                try await searchRakutenProduct(janCode: cleanedCode)
            }) {
                return product
            }

            if let product = resolve(await runSearchAttempt(source: .rakuten) {
                try await searchRakuten(janCode: cleanedCode)
            }) {
                return product
            }
        } else {
            debugLog("[ProductSearch] 楽天APIは未設定です")
        }

        // 2. Open Food Facts API（無料・登録不要）
        if let product = resolve(await runSearchAttempt(source: .openFoodFacts) {
            try await searchOpenFoodFacts(janCode: cleanedCode)
        }) {
            return product
        }

        // 3. Yahoo APIにフォールバック
        if APIConfig.isYahooConfigured {
            if let product = resolve(await runSearchAttempt(source: .yahoo) {
                try await searchYahoo(janCode: cleanedCode)
            }) {
                return product
            }
        }

        if let technicalFailure = technicalFailures.last, !sawNotFound {
            throw technicalFailure.publicError
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
    private func searchOpenFoodFacts(janCode: String) async throws -> ProductInfo? {
        let languageCode = appLanguageCode()
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v0/product/\(janCode).json")!
        components.queryItems = [
            URLQueryItem(name: "lc", value: languageCode)
        ]
        let url = components.url ?? URL(string: "https://world.openfoodfacts.org/api/v0/product/\(janCode).json")!
        
        debugLog("[ProductSearch] Open Food Facts: \(url.absoluteString)")
        
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchAttemptFailure.invalidResponse(
                source: .openFoodFacts,
                detail: "HTTPレスポンスを取得できませんでした"
            )
        }

        guard httpResponse.statusCode == 200 else {
            throw SearchAttemptFailure.httpStatus(
                source: .openFoodFacts,
                statusCode: httpResponse.statusCode,
                detail: responseSnippet(from: data)
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .openFoodFacts,
                detail: "JSONを解析できませんでした"
            )
        }

        guard let status = json["status"] as? Int else {
            throw SearchAttemptFailure.parse(
                source: .openFoodFacts,
                detail: "status が含まれていません"
            )
        }

        guard status == 1 else {
            return nil
        }

        guard let product = json["product"] as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .openFoodFacts,
                detail: "product が含まれていません"
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
    
    // MARK: - 楽天API

    /// 楽天商品価格ナビ 製品検索API
    /// JANコード(productCode)で直接検索する
    private func searchRakutenProduct(janCode: String) async throws -> ProductInfo? {
        let appId = APIConfig.rakutenAppId
        let accessKey = APIConfig.rakutenAccessKey

        var components = URLComponents(string: "https://openapi.rakuten.co.jp/ichibaproduct/api/Product/Search/20250801")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatVersion", value: "2"),
            URLQueryItem(name: "applicationId", value: appId),
            URLQueryItem(name: "accessKey", value: accessKey),
            URLQueryItem(name: "productCode", value: janCode),
            URLQueryItem(
                name: "elements",
                value: "productName,productCaption,genreName,mediumImageUrl,productUrlPC,productCode"
            ),
            URLQueryItem(name: "hits", value: "1")
        ]

        guard let url = components.url else {
            throw SearchAttemptFailure.invalidResponse(
                source: .rakuten,
                detail: "商品価格ナビAPIのURLを生成できませんでした"
            )
        }

        let maskedURL = maskedURLString(from: url, sensitiveQueryNames: ["applicationid", "accesskey"])
        debugLog("[ProductSearch] Requesting Rakuten product API: \(maskedURL)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchAttemptFailure.invalidResponse(
                source: .rakuten,
                detail: "商品価格ナビAPIのHTTPレスポンスを取得できませんでした"
            )
        }

        debugLog("[ProductSearch] Rakuten product API HTTP Status: \(httpResponse.statusCode)")

        if httpResponse.statusCode == 404 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            if let responseString = responseSnippet(from: data) {
                debugLog("[ProductSearch] Rakuten product API error response: \(responseString)")
            }
            throw SearchAttemptFailure.httpStatus(
                source: .rakuten,
                statusCode: httpResponse.statusCode,
                detail: responseSnippet(from: data)
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .rakuten,
                detail: "商品価格ナビAPIのJSONを解析できませんでした"
            )
        }

        let productPayload: [String: Any]?
        if let products = json["Products"] as? [[String: Any]], let firstProduct = products.first {
            productPayload = (firstProduct["Product"] as? [String: Any]) ?? firstProduct
        } else if let items = json["items"] as? [[String: Any]], let firstItem = items.first {
            productPayload = (firstItem["Product"] as? [String: Any]) ?? firstItem
        } else if normalizedText(json["error"] as? String) == "not_found" {
            return nil
        } else {
            throw SearchAttemptFailure.parse(
                source: .rakuten,
                detail: "商品価格ナビAPIのレスポンスに Products が含まれていません"
            )
        }

        guard let productPayload,
              let rawProductName = normalizedText(productPayload["productName"]) else {
            throw SearchAttemptFailure.parse(
                source: .rakuten,
                detail: "商品価格ナビAPIの productName を取得できませんでした"
            )
        }

        let productName = mergedProductName(
            brand: normalizedText(productPayload["brandName"]),
            name: rawProductName
        )
        let description = normalizedText(productPayload["productCaption"])
        let category = normalizedText(productPayload["genreName"])
        let imageURL = normalizedText(productPayload["mediumImageUrl"]).flatMap(URL.init(string:))

        debugLog("[ProductSearch] Rakuten product API found: \(productName)")

        return ProductInfo(
            name: productName,
            description: description,
            category: category,
            imageURL: imageURL,
            janCode: janCode,
            source: .rakuten
        )
    }
    
    /// 楽天市場商品検索API
    /// https://webservice.rakuten.co.jp/documentation/ichiba-item-search
    private func searchRakuten(janCode: String) async throws -> ProductInfo? {
        let appId = APIConfig.rakutenAppId
        let accessKey = APIConfig.rakutenAccessKey
        
        // URL構築（新しい楽天OpenAPI エンドポイント）
        var components = URLComponents(string: "https://openapi.rakuten.co.jp/ichibams/api/IchibaItem/Search/20220601")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "keyword", value: janCode),
            URLQueryItem(name: "applicationId", value: appId),
            URLQueryItem(name: "accessKey", value: accessKey),
            URLQueryItem(name: "hits", value: "1")
        ]
        
        guard let url = components.url else {
            throw SearchAttemptFailure.invalidResponse(
                source: .rakuten,
                detail: "楽天市場検索APIのURLを生成できませんでした"
            )
        }
        
        let maskedURL = maskedURLString(from: url, sensitiveQueryNames: ["applicationid", "accesskey"])
        debugLog("[ProductSearch] Requesting: \(maskedURL)")
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchAttemptFailure.invalidResponse(
                source: .rakuten,
                detail: "楽天市場検索APIのHTTPレスポンスを取得できませんでした"
            )
        }
        
        debugLog("[ProductSearch] HTTP Status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 404 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            if let responseString = responseSnippet(from: data) {
                debugLog("[ProductSearch] Error response: \(responseString)")
            }
            throw SearchAttemptFailure.httpStatus(
                source: .rakuten,
                statusCode: httpResponse.statusCode,
                detail: responseSnippet(from: data)
            )
        }
        
        // JSONパース
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .rakuten,
                detail: "楽天市場検索APIのJSONを解析できませんでした"
            )
        }
        
        guard let items = json["Items"] as? [[String: Any]],
              let firstItem = items.first,
              let itemData = firstItem["Item"] as? [String: Any] else {
            return nil
        }

        guard let itemName = normalizedText(itemData["itemName"]) else {
            throw SearchAttemptFailure.parse(
                source: .rakuten,
                detail: "楽天市場検索APIの itemName を取得できませんでした"
            )
        }
        
        let description = normalizedText(itemData["itemCaption"])
        let genreName = normalizedText(itemData["genreName"])
        let imageURLString = (itemData["mediumImageUrls"] as? [[String: String]])?.first?["imageUrl"]
            ?? (itemData["smallImageUrls"] as? [[String: String]])?.first?["imageUrl"]
        let imageURL = imageURLString.flatMap { URL(string: $0) }
        
        debugLog("[ProductSearch] Found: \(itemName)")
        
        return ProductInfo(
            name: itemName,
            description: description,
            category: genreName,
            imageURL: imageURL,
            janCode: janCode,
            source: .rakuten
        )
    }
    
    // MARK: - Yahoo API
    
    /// Yahoo ショッピング商品検索API V3
    /// https://developer.yahoo.co.jp/webapi/shopping/shopping/v3/itemsearch.html
    private func searchYahoo(janCode: String) async throws -> ProductInfo? {
        let clientId = APIConfig.yahooClientId
        
        // URL構築
        var components = URLComponents(string: "https://shopping.yahooapis.jp/ShoppingWebService/V3/itemSearch")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: clientId),
            URLQueryItem(name: "jan", value: janCode),
            URLQueryItem(name: "results", value: "1")
        ]
        
        guard let url = components.url else {
            throw SearchAttemptFailure.invalidResponse(
                source: .yahoo,
                detail: "Yahoo検索APIのURLを生成できませんでした"
            )
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchAttemptFailure.invalidResponse(
                source: .yahoo,
                detail: "Yahoo検索APIのHTTPレスポンスを取得できませんでした"
            )
        }

        guard httpResponse.statusCode == 200 else {
            throw SearchAttemptFailure.httpStatus(
                source: .yahoo,
                statusCode: httpResponse.statusCode,
                detail: responseSnippet(from: data)
            )
        }
        
        // JSONパース
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchAttemptFailure.parse(
                source: .yahoo,
                detail: "Yahoo検索APIのJSONを解析できませんでした"
            )
        }

        guard let hits = json["hits"] as? [[String: Any]],
              let firstHit = hits.first else {
            return nil
        }

        guard let itemName = normalizedText(firstHit["name"]) else {
            throw SearchAttemptFailure.parse(
                source: .yahoo,
                detail: "Yahoo検索APIの name を取得できませんでした"
            )
        }
        
        let description = normalizedText(firstHit["description"])
        let category = normalizedText((firstHit["genreCategory"] as? [String: Any])?["name"])
        let imageId = firstHit["imageId"] as? String
        let imageURL = imageId.flatMap { URL(string: "https://item-shopping.c.yimg.jp/i/n/\($0)") }
        
        return ProductInfo(
            name: itemName,
            description: description,
            category: category,
            imageURL: imageURL,
            janCode: janCode,
            source: .yahoo
        )
    }
}
