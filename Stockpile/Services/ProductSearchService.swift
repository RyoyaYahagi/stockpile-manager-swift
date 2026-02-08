import Foundation

/// 商品情報
struct ProductInfo: Sendable {
    let name: String
    let description: String?
    let category: String?
    let imageURL: URL?
    let janCode: String
    
    /// 検索ソース
    enum Source: String, Sendable {
        case rakuten = "楽天"
        case yahoo = "Yahoo"
        case manual = "手動入力"
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
        
        // 1. Open Food Facts API（無料・登録不要）
        if let product = try? await searchOpenFoodFacts(janCode: cleanedCode) {
            return product
        }
        
        // 2. 楽天APIにフォールバック
        if APIConfig.isRakutenConfigured {
            if let product = try? await searchRakuten(janCode: cleanedCode) {
                return product
            }
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
        let url = URL(string: "https://world.openfoodfacts.org/api/v0/product/\(janCode).json")!
        
        print("[ProductSearch] Open Food Facts: \(url.absoluteString)")
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            print("[ProductSearch] Open Food Facts: HTTP error")
            return nil
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int, status == 1,
              let product = json["product"] as? [String: Any] else {
            print("[ProductSearch] Open Food Facts: Product not found")
            return nil
        }
        
        // 商品名を取得（日本語優先）
        let productName = (product["product_name_ja"] as? String)
            ?? (product["product_name"] as? String)
            ?? (product["generic_name"] as? String)
            ?? "不明な商品"
        
        let brands = product["brands"] as? String
        let categories = product["categories"] as? String
        let imageURLString = product["image_url"] as? String
        let imageURL = imageURLString.flatMap { URL(string: $0) }
        
        // 商品名にブランドを追加
        let fullName = brands != nil ? "\(brands!) \(productName)" : productName
        
        print("[ProductSearch] Open Food Facts: Found \(fullName)")
        
        return ProductInfo(
            name: fullName,
            description: nil,
            category: categories,
            imageURL: imageURL,
            janCode: janCode,
            source: .rakuten  // 後でSourceにopenFoodFactsを追加可能
        )
    }
    
    // MARK: - 楽天API
    
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
            print("[ProductSearch] Failed to create URL")
            return nil
        }
        
        print("[ProductSearch] Requesting: \(url.absoluteString)")
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[ProductSearch] Invalid response")
            return nil
        }
        
        print("[ProductSearch] HTTP Status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            if let responseString = String(data: data, encoding: .utf8) {
                print("[ProductSearch] Error response: \(responseString)")
            }
            return nil
        }
        
        // JSONパース
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[ProductSearch] Failed to parse JSON")
            return nil
        }
        
        guard let items = json["Items"] as? [[String: Any]],
              let firstItem = items.first,
              let itemData = firstItem["Item"] as? [String: Any],
              let itemName = itemData["itemName"] as? String else {
            print("[ProductSearch] No items found in response")
            if let responseString = String(data: data, encoding: .utf8)?.prefix(500) {
                print("[ProductSearch] Response: \(responseString)")
            }
            return nil
        }
        
        let description = itemData["itemCaption"] as? String
        let genreName = itemData["genreName"] as? String
        let imageURLString = (itemData["mediumImageUrls"] as? [[String: String]])?.first?["imageUrl"]
            ?? (itemData["smallImageUrls"] as? [[String: String]])?.first?["imageUrl"]
        let imageURL = imageURLString.flatMap { URL(string: $0) }
        
        print("[ProductSearch] Found: \(itemName)")
        
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
        
        let description = firstHit["description"] as? String
        let category = (firstHit["genreCategory"] as? [String: Any])?["name"] as? String
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
