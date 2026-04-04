import XCTest
@testable import Stockpile

final class AppLocalizationTests: XCTestCase {
    func testSupportedInAppLanguagesExcludeEULocales() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "ja", "en", "zh-Hans", "zh-Hant", "ko"]
        )
    }

    func testTutorialPreviewKeysExistForSupportedInAppLanguages() throws {
        let keys = [
            "ここで共有を始めます",
            "キッチン棚",
            "非常袋",
            "車載ボックス",
            "アルファ米",
            "カセットボンベ",
            "わが家",
            "自分",
            "家族A",
            "飲料水",
            "乾電池",
            "缶詰"
        ]

        let supportedLanguages = AppLanguage.allCases.filter { $0 != .system }

        for language in supportedLanguages {
            let bundle = AppLocalization.bundle(for: language)
            let stringsPath = try XCTUnwrap(
                bundle.path(forResource: "Localizable", ofType: "strings")
            )
            let entries = try XCTUnwrap(
                NSDictionary(contentsOfFile: stringsPath) as? [String: String]
            )

            for key in keys {
                XCTAssertNotNil(entries[key], "Missing localization for \(key) in \(language.rawValue)")
            }
        }
    }
}
