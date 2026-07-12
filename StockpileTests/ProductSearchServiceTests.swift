import XCTest
@testable import Stockpile

final class ProductSearchServiceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        unsetenv("BACKEND_BASE_URL")
        unsetenv("YAHOO_CLIENT_ID")
        URLProtocolStub.requestHandler = nil
    }

    func testBackendTimeoutThenOpenFoodFactsNotFoundReturnsTimeout() async throws {
        try await withEnvironment([
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                openFoodFactsOperation: { _ in
                    nil
                },
                yahooOperation: { _ in
                    throw URLError(.timedOut)
                }
            )

            await assertThrowsAsync(
                try await service.search(janCode: "4901777300445")
            ) { error in
                guard case .timeout(let source) = error as? ProductSearchError else {
                    return XCTFail("Expected timeout, got \(error)")
                }
                XCTAssertEqual(source, .yahoo)
            }
        }
    }

    func testBackendTimeoutThenOpenFoodFactsHitReturnsFallbackProduct() async throws {
        let fallbackProduct = ProductInfo(
            name: "テストウォーター",
            description: nil,
            category: "飲料",
            imageURL: nil,
            janCode: "4901777300445",
            source: .openFoodFacts
        )

        try await withEnvironment([
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                openFoodFactsOperation: { _ in
                    fallbackProduct
                },
                yahooOperation: { _ in
                    throw URLError(.timedOut)
                }
            )

            let product = try await service.search(janCode: "4901777300445")
            XCTAssertEqual(product.name, fallbackProduct.name)
            XCTAssertEqual(product.source, .openFoodFacts)
        }
    }

    func testYahooRateLimitedThenOpenFoodFactsHitReturnsFallbackProduct() async throws {
        let fallbackProduct = ProductInfo(
            name: "テストウォーター",
            description: nil,
            category: "飲料",
            imageURL: nil,
            janCode: "4901777300445",
            source: .openFoodFacts
        )

        try await withEnvironment([
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                openFoodFactsOperation: { _ in
                    fallbackProduct
                },
                yahooOperation: { _ in
                    throw ProductSearchError.rateLimited(.yahoo, retryAfterSeconds: 30)
                }
            )

            let product = try await service.search(janCode: "4901777300445")
            XCTAssertEqual(product.name, fallbackProduct.name)
            XCTAssertEqual(product.source, .openFoodFacts)
        }
    }

    func testYahooConfiguredUsesYahooBeforeOpenFoodFacts() async throws {
        let yahooProduct = ProductInfo(
            name: "ヤフーの水",
            description: nil,
            category: "飲料",
            imageURL: nil,
            janCode: "4901777300445",
            source: .yahoo
        )

        try await withEnvironment([
            "YAHOO_CLIENT_ID": "test-client-id",
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                yahooOperation: { _ in
                    yahooProduct
                }
            )

            let product = try await service.search(janCode: "4901777300445")
            XCTAssertEqual(product.name, yahooProduct.name)
            XCTAssertEqual(product.source, .yahoo)
        }
    }

    func testBackendConfiguredUsesYahooWithoutLocalYahooClientId() async throws {
        let yahooProduct = ProductInfo(
            name: "バックエンドの水",
            description: nil,
            category: "飲料",
            imageURL: nil,
            janCode: "4901777300445",
            source: .yahoo
        )

        try await withEnvironment([
            "YAHOO_CLIENT_ID": nil,
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                yahooOperation: { _ in
                    yahooProduct
                }
            )

            let product = try await service.search(janCode: "4901777300445")
            XCTAssertEqual(product.name, yahooProduct.name)
            XCTAssertEqual(product.source, .yahoo)
        }
    }

    func testYahooSearchUsesDocumentedRequestAndParsesDocumentedResponse() async throws {
        let payload = """
        {
          "totalResultsReturned": 1,
          "hits": [
            {
              "name": "ヤフーの水",
              "description": "天然水",
              "genreCategory": {
                "name": "水、ミネラルウォーター"
              },
              "janCode": "4901777300445",
              "image": {
                "small": "https://example.com/images/water-76.jpg",
                "medium": "https://example.com/images/water-146.jpg"
              },
              "exImage": {
                "url": "https://example.com/images/water-300.jpg",
                "width": 300,
                "height": 300
              }
            }
          ]
        }
        """.data(using: .utf8)!

        try await withEnvironment([
            "YAHOO_CLIENT_ID": "test-client-id",
            "BACKEND_BASE_URL": "YOUR_BACKEND_BASE_URL_HERE"
        ]) {
            let session = makeStubbedSession { request in
                guard let url = request.url,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw URLError(.badURL)
                }

                XCTAssertEqual(url.scheme, "https")
                XCTAssertEqual(url.host, "shopping.yahooapis.jp")
                XCTAssertEqual(url.path, "/ShoppingWebService/V3/itemSearch")

                let queryItems = Dictionary(
                    uniqueKeysWithValues: (components.queryItems ?? []).map { item in
                        (item.name, item.value ?? "")
                    }
                )
                XCTAssertEqual(queryItems["appid"], "test-client-id")
                XCTAssertEqual(queryItems["jan_code"], "4901777300445")
                XCTAssertEqual(queryItems["results"], "1")
                XCTAssertEqual(queryItems["image_size"], "300")

                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, payload)
            }

            let service = ProductSearchService(session: session)
            let product = try await service.search(janCode: "4901777300445")
            XCTAssertEqual(product.name, "ヤフーの水")
            XCTAssertEqual(product.description, "天然水")
            XCTAssertEqual(product.category, "水、ミネラルウォーター")
            XCTAssertEqual(product.imageURL?.absoluteString, "https://example.com/images/water-300.jpg")
            XCTAssertEqual(product.janCode, "4901777300445")
            XCTAssertEqual(product.source, .yahoo)
        }
    }

    func testYahooRateLimitedWithoutFallbackSurfacesFriendlyRateLimitError() async throws {
        try await withEnvironment([
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                openFoodFactsOperation: { _ in
                    nil
                },
                yahooOperation: { _ in
                    throw ProductSearchError.rateLimited(.yahoo, retryAfterSeconds: 30)
                }
            )

            await assertThrowsAsync(
                try await service.search(janCode: "4901777300445")
            ) { error in
                guard case .rateLimited(let source, let retryAfterSeconds) = error as? ProductSearchError else {
                    return XCTFail("Expected rateLimited, got \(error)")
                }
                XCTAssertEqual(source, .yahoo)
                XCTAssertEqual(retryAfterSeconds, 30)
            }
        }
    }

    func testNoCommercialAPIConfiguredReturnsNoAPIConfiguredBeforeOpenFoodFactsTimeout() async throws {
        try await withEnvironment([
            "BACKEND_BASE_URL": "YOUR_BACKEND_BASE_URL_HERE"
        ]) {
            let service = ProductSearchService(
                openFoodFactsOperation: { _ in
                    throw URLError(.timedOut)
                }
            )

            await assertThrowsAsync(
                try await service.search(janCode: "4901777300445")
            ) { error in
                guard case .noAPIConfigured = error as? ProductSearchError else {
                    return XCTFail("Expected noAPIConfigured, got \(error)")
                }
            }
        }
    }

    func testAllTechnicalFailuresSurfaceLastTechnicalError() async throws {
        try await withEnvironment([
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                openFoodFactsOperation: { _ in
                    throw URLError(.timedOut)
                },
                yahooOperation: { _ in
                    throw URLError(.timedOut)
                }
            )

            await assertThrowsAsync(
                try await service.search(janCode: "4901777300445")
            ) { error in
                guard case .timeout(let source) = error as? ProductSearchError else {
                    return XCTFail("Expected timeout error, got \(error)")
                }
                XCTAssertEqual(source, .openFoodFacts)
            }
        }
    }

    private func withEnvironment(
        _ overrides: [String: String?],
        perform: () async throws -> Void
    ) async rethrows {
        let previousValues = Dictionary(
            uniqueKeysWithValues: overrides.keys.map { key in
                (key, ProcessInfo.processInfo.environment[key])
            }
        )

        for (key, value) in overrides {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        defer {
            for (key, value) in previousValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        try await perform()
    }

    private func assertThrowsAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        verify: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error to be thrown", file: file, line: line)
        } catch {
            verify(error)
        }
    }

    private func makeStubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        URLProtocolStub.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
