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
            "このアプリで最初にやること",
            "家にある食べ物や日用品を、ひとつずつメモしていくアプリです。",
            "使い方を見る",
            "まずは右下の + を押します",
            "登録画面では、名前を入れて保存すれば使い始められます。",
            "+ボタンを開く",
            "今は説明だけ見る",
            "通知は必要になってから設定できます",
            "通知を開くと、いつお知らせするかを決められます。",
            "通知を開く",
            "今は設定しない",
            "家族共有の準備もできます",
            "家族と使うときは共有を設定できます",
            "家族設定から、家族に共有リンクを送れる状態です。",
            "家族共有を開くと、家族で同じ一覧を見るための設定画面が開きます。",
            "家族共有を開く",
            "これで使い始められます",
            "分からなくなっても、設定から「はじめての使い方」を見直せます。",
            "使い始める",
            "あとで見る",
            "はじめての使い方",
            "ここで共有を始めます",
            "キッチン棚",
            "非常袋",
            "車載ボックス",
            "アルファ米",
            "カセットボンベ",
            "わが家",
            "自分",
            "家族A",
            "家族名",
            "家族を作成",
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

final class FirstLaunchTutorialPresentationPolicyTests: XCTestCase {
    func testPresentsOnceAfterInitialLanguageSelection() {
        XCTAssertTrue(
            FirstLaunchTutorialPresentationPolicy.shouldPresentAutomatically(
                hasCompletedTutorial: false,
                hasCompletedInitialLanguageSelection: true,
                hasPresentedTutorial: false,
                isLanguageSelectionPresented: false,
                isTutorialPresented: false
            )
        )
    }

    func testDoesNotPresentAgainAfterTutorialWasShownAndClosed() {
        XCTAssertFalse(
            FirstLaunchTutorialPresentationPolicy.shouldPresentAutomatically(
                hasCompletedTutorial: false,
                hasCompletedInitialLanguageSelection: true,
                hasPresentedTutorial: true,
                isLanguageSelectionPresented: false,
                isTutorialPresented: false
            )
        )
    }

    func testDoesNotPresentBeforeInitialLanguageSelectionIsComplete() {
        XCTAssertFalse(
            FirstLaunchTutorialPresentationPolicy.shouldPresentAutomatically(
                hasCompletedTutorial: false,
                hasCompletedInitialLanguageSelection: false,
                hasPresentedTutorial: false,
                isLanguageSelectionPresented: false,
                isTutorialPresented: false
            )
        )
    }
}
