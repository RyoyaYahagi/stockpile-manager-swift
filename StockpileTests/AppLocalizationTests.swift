import XCTest
@testable import Stockpile

final class AppLocalizationTests: XCTestCase {
    func testSupportedInAppLanguagesExcludeEULocales() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "ja", "en", "zh-Hans", "zh-Hant", "ko"]
        )
    }

    func testCoachMarkKeysExistForSupportedInAppLanguages() throws {
        let keys = [
            "家の備えを、ひと目で",
            "食べ物や日用品を登録すると、期限が近いものを教えてくれます。ホームでは備えの「安心度」が分かります。",
            "使い方を見る",
            "右下の ＋ で追加します",
            "＋ を押すと、バーコード、賞味期限の撮影、手入力から追加方法を選べます。",
            "期限が近いものはホームで分かります",
            "「いま対応が必要」に、期限切れと7日以内の備蓄が並びます。使ったら「1つ使った」、買い替えたら「入れ替えた」を押します。",
            "次へ進む",
            "お知らせは設定タブで決めます",
            "設定タブの「お知らせ」で、賞味期限のお知らせのオン・オフ、いつ知らせるか、時刻を決められます。",
            "家族共有の準備もできます",
            "家族と使うときは共有を設定できます",
            "家族タブから共有リンクを送ると、家族と同じ一覧を見られます。",
            "家族タブで家族を作り、共有リンクで招待すると、同じ一覧を家族で共有できます。",
            "これで使い始められます",
            "分からなくなっても、設定から「はじめての使い方」を見直せます。",
            "使い始める",
            "あとで見る",
            "ここを押す",
            "入れ替えたらここを押す",
            "ここでお知らせを決める",
            "ここで共有を始めます",
            "ここから見直せます",
            "はじめての使い方を見る"
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

    func testInviteCodeShareMessageKeyExistsForSupportedInAppLanguages() throws {
        let key = "備蓄管理アプリ「らくストック」に参加しよう！\n招待コード: %@\nまたはこちらのリンクから: stockpile://join?code=%@"
        let supportedLanguages = AppLanguage.allCases.filter { $0 != .system }

        for language in supportedLanguages {
            let bundle = AppLocalization.bundle(for: language)
            let stringsPath = try XCTUnwrap(
                bundle.path(forResource: "Localizable", ofType: "strings")
            )
            let entries = try XCTUnwrap(
                NSDictionary(contentsOfFile: stringsPath) as? [String: String]
            )

            XCTAssertNotNil(entries[key], "Missing localization for invite code sharing in \(language.rawValue)")
        }
    }
}

final class BackupImportValidatorTests: XCTestCase {
    func testAcceptsValidBackup() throws {
        let data = Data("[{\"name\":\"Water\",\"quantity\":3,\"expiryDate\":\"2027-01-31\"}]".utf8)
        XCTAssertEqual(try BackupImportValidator.decodeAndValidate(data).count, 1)
    }

    func testRejectsInvalidQuantityBeforeImport() {
        let data = Data("[{\"name\":\"Water\",\"quantity\":0}]".utf8)
        XCTAssertThrowsError(try BackupImportValidator.decodeAndValidate(data))
    }

    func testRejectsInvalidDateBeforeImport() {
        let data = Data("[{\"name\":\"Water\",\"expiryDate\":\"2027-02-30\"}]".utf8)
        XCTAssertThrowsError(try BackupImportValidator.decodeAndValidate(data))
    }

    func testRejectsOversizedBackupBeforeDecoding() {
        let data = Data(repeating: 0x20, count: BackupImportValidator.maximumFileSize + 1)
        XCTAssertThrowsError(try BackupImportValidator.decodeAndValidate(data))
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
