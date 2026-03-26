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
            let isJapanese = Locale.preferredLanguages.first?.lowercased().hasPrefix("ja") ?? true
            switch self {
            case .openFoodFacts:
                return "Open Food Facts"
            case .rakuten:
                return isJapanese ? "楽天" : "Rakuten"
            case .yahoo:
                return isJapanese ? "Yahoo" : "Yahoo Shopping"
            case .manual:
                return isJapanese ? "手動入力" : "Manual Entry"
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
            return "APIキーが設定されていません"
        case .invalidJANCode:
            return "無効なJANコードです"
        case .networkError(let error):
            return "通信エラー: \(error.localizedDescription)"
        case .parseError:
            return "データの解析に失敗しました"
        case .notFound:
            return "商品が見つかりませんでした"
        }
    }
}

/// 商品検索サービス
/// 楽天・Yahoo APIを使用してJANコードから商品情報を取得
actor ProductSearchService {
    
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

    private func preferredLanguageCandidates() -> [String] {
        var candidates: [String] = []

        for identifier in Locale.preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "-", with: "_").lowercased()
            candidates.append(normalized)
            if let primary = normalized.split(separator: "_").first {
                candidates.append(String(primary))
            }
        }

        let current = Locale.current.identifier.replacingOccurrences(of: "-", with: "_").lowercased()
        candidates.append(current)
        if let primary = current.split(separator: "_").first {
            candidates.append(String(primary))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func appLanguageCode() -> String {
        let preferred = preferredLanguageCandidates().first ?? "ja"
        return preferred.split(separator: "_").first.map(String.init) ?? "ja"
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
        
        // 1. 楽天APIを最優先
        if APIConfig.isRakutenConfigured {
            if let product = try? await searchRakutenProduct(janCode: cleanedCode) {
                return product
            }
            if let product = try? await searchRakuten(janCode: cleanedCode) {
                return product
            }
        }
        
        // 2. Open Food Facts API（無料・登録不要）
        if let product = try? await searchOpenFoodFacts(janCode: cleanedCode) {
            return product
        }
        
        // 3. Yahoo APIにフォールバック
        if APIConfig.isYahooConfigured {
            if let product = try? await searchYahoo(janCode: cleanedCode) {
                return product
            }
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
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            debugLog("[ProductSearch] Open Food Facts: HTTP error")
            return nil
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int, status == 1,
              let product = json["product"] as? [String: Any] else {
            debugLog("[ProductSearch] Open Food Facts: Product not found")
            return nil
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
        let productName = localizedProductName ?? localizedGenericName ?? "不明な商品"

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
            debugLog("[ProductSearch] Failed to create Rakuten product URL")
            return nil
        }

        let maskedURL = maskedURLString(from: url, sensitiveQueryNames: ["applicationid", "accesskey"])
        debugLog("[ProductSearch] Requesting Rakuten product API: \(maskedURL)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            debugLog("[ProductSearch] Rakuten product API: Invalid response")
            return nil
        }

        debugLog("[ProductSearch] Rakuten product API HTTP Status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            if let responseString = String(data: data, encoding: .utf8) {
                debugLog("[ProductSearch] Rakuten product API error response: \(responseString)")
            }
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            debugLog("[ProductSearch] Rakuten product API: Failed to parse JSON")
            return nil
        }

        guard let items = json["items"] as? [[String: Any]],
              let firstItem = items.first,
              let productName = normalizedText(firstItem["productName"]) else {
            debugLog("[ProductSearch] Rakuten product API: No items found")
            if let responseString = String(data: data, encoding: .utf8)?.prefix(500) {
                debugLog("[ProductSearch] Rakuten product API response: \(responseString)")
            }
            return nil
        }

        let description = normalizedText(firstItem["productCaption"])
        let category = normalizedText(firstItem["genreName"])
        let imageURL = normalizedText(firstItem["mediumImageUrl"]).flatMap(URL.init(string:))

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
            debugLog("[ProductSearch] Failed to create URL")
            return nil
        }
        
        let maskedURL = maskedURLString(from: url, sensitiveQueryNames: ["applicationid", "accesskey"])
        debugLog("[ProductSearch] Requesting: \(maskedURL)")
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            debugLog("[ProductSearch] Invalid response")
            return nil
        }
        
        debugLog("[ProductSearch] HTTP Status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            if let responseString = String(data: data, encoding: .utf8) {
                debugLog("[ProductSearch] Error response: \(responseString)")
            }
            return nil
        }
        
        // JSONパース
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            debugLog("[ProductSearch] Failed to parse JSON")
            return nil
        }
        
        guard let items = json["Items"] as? [[String: Any]],
              let firstItem = items.first,
              let itemData = firstItem["Item"] as? [String: Any],
              let itemName = itemData["itemName"] as? String else {
            debugLog("[ProductSearch] No items found in response")
            if let responseString = String(data: data, encoding: .utf8)?.prefix(500) {
                debugLog("[ProductSearch] Response: \(responseString)")
            }
            return nil
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
            return nil
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        
        // JSONパース
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]],
              let firstHit = hits.first,
              let itemName = firstHit["name"] as? String else {
            return nil
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
