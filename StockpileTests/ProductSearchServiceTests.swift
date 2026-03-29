import XCTest
@testable import Stockpile

final class ProductSearchServiceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        unsetenv("BACKEND_BASE_URL")
        unsetenv("RAKUTEN_APP_ID")
        unsetenv("RAKUTEN_ACCESS_KEY")
        unsetenv("YAHOO_CLIENT_ID")
    }

    func testBackendTimeoutThenOpenFoodFactsNotFoundReturnsNotFound() async throws {
        try await withEnvironment([
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                rakutenBackendOperation: { _ in
                    throw URLError(.timedOut)
                },
                openFoodFactsOperation: { _ in
                    nil
                }
            )

            await assertThrowsAsync(
                try await service.search(janCode: "4901777300445")
            ) { error in
                guard case ProductSearchError.notFound = error else {
                    return XCTFail("Expected notFound, got \(error)")
                }
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
                rakutenBackendOperation: { _ in
                    throw URLError(.timedOut)
                },
                openFoodFactsOperation: { _ in
                    fallbackProduct
                }
            )

            let product = try await service.search(janCode: "4901777300445")
            XCTAssertEqual(product.name, fallbackProduct.name)
            XCTAssertEqual(product.source, .openFoodFacts)
        }
    }

    func testAllTechnicalFailuresSurfaceLastTechnicalError() async throws {
        try await withEnvironment([
            "BACKEND_BASE_URL": "https://example.com"
        ]) {
            let service = ProductSearchService(
                rakutenBackendOperation: { _ in
                    throw URLError(.timedOut)
                },
                openFoodFactsOperation: { _ in
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
}
