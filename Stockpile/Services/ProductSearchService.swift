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
        
        // 設定されているAPIから検索
        guard APIConfig.isProductSearchAvailable else {
            throw ProductSearchError.noAPIConfigured
        }
        
        // 1. 楽天APIで検索
        if APIConfig.isRakutenConfigured {
            if let product = try? await searchRakuten(janCode: cleanedCode) {
                return product
            }
        }
        
        // 2. Yahoo APIにフォールバック
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
    
    // MARK: - 楽天API
    
    /// 楽天 商品価格ナビ製品検索API
    /// https://webservice.rakuten.co.jp/documentation/ichiba-product-search
    private func searchRakuten(janCode: String) async throws -> ProductInfo? {
        let appId = APIConfig.rakutenAppId
        
        // URL構築
        var components = URLComponents(string: "https://app.rakuten.co.jp/services/api/Product/Search/20170426")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "productCode", value: janCode),
            URLQueryItem(name: "applicationId", value: appId)
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
              let products = json["Products"] as? [[String: Any]],
              let firstProduct = products.first,
              let productData = firstProduct["Product"] as? [String: Any],
              let productName = productData["productName"] as? String else {
            return nil
        }
        
        let description = productData["catchcopy"] as? String
        let genreName = productData["genreName"] as? String
        let imageURLString = (productData["mediumImageUrl"] as? String) ?? (productData["smallImageUrl"] as? String)
        let imageURL = imageURLString.flatMap { URL(string: $0) }
        
        return ProductInfo(
            name: productName,
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
