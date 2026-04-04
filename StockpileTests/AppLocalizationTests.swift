import XCTest
@testable import Stockpile

final class AppLocalizationTests: XCTestCase {
    func testSupportedInAppLanguagesExcludeEULocales() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "ja", "en", "zh-Hans", "zh-Hant", "ko"]
        )
    }
}
