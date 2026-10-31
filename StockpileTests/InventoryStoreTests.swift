import XCTest
@testable import Stockpile

final class InventoryStoreTests: XCTestCase {
    private func item(_ name: String, daysFromNow days: Int?) -> Item {
        let date = days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! }
        return Item(name: name, quantity: 2, expiryDate: date)
    }

    func testReadinessCountsItemsThatAreNotExpiredOrImminent() {
        let items = [
            item("期限切れ", daysFromNow: -3),
            item("7日以内", daysFromNow: 2),
            item("1か月以内", daysFromNow: 20),
            item("余裕あり", daysFromNow: 90),
            item("期限なし", daysFromNow: nil)
        ]

        XCTAssertEqual(InventoryStore.readinessPercent(of: items), 60)
    }

    func testReadinessIsFullWhenThereAreNoItems() {
        XCTAssertEqual(InventoryStore.readinessPercent(of: []), 100)
    }

    func testAttentionItemsAreExpiredOrImminentInExpiryOrder() {
        let soon = item("7日以内", daysFromNow: 5)
        let expired = item("期限切れ", daysFromNow: -1)
        let safe = item("余裕あり", daysFromNow: 60)

        let result = InventoryStore.attentionItems(in: [soon, safe, expired])

        XCTAssertEqual(result.map(\.name), ["期限切れ", "7日以内"])
    }

    func testRenewUpdatesExpiryAndResetsNotificationFlags() {
        let target = item("アルファ米", daysFromNow: 2)
        target.notified30 = true
        target.notified7 = true
        target.notified1 = true
        let newDate = Calendar.current.date(byAdding: .year, value: 1, to: Date())!

        InventoryStore.renew(target, expiryDate: newDate)

        XCTAssertEqual(target.expiryDate, newDate)
        XCTAssertEqual(target.expiryStatus, .safe)
        XCTAssertFalse(target.notified30)
        XCTAssertFalse(target.notified7)
        XCTAssertFalse(target.notified1)
    }

    func testUseOneNeverGoesBelowZero() {
        let target = item("救急セット", daysFromNow: 10)
        target.quantity = 1

        InventoryStore.useOne(of: target)
        InventoryStore.useOne(of: target)

        XCTAssertEqual(target.quantity, 0)
    }

    func testRedesignKeysExistForSupportedInAppLanguages() throws {
        let keys = [
            "ホーム", "在庫", "いま対応が必要", "わが家の備え", "安心度",
            "1つ使った", "入れ替えた", "要対応", "1か月以内", "余裕あり",
            "どうやって追加しますか？", "バーコードを読み取る", "賞味期限を撮影する", "手で入力する",
            "%@品目のうち %@品目", "期限が近い%@品を入れ替えると、安心度が上がります。"
        ]

        for language in AppLanguage.allCases where language != .system {
            let bundle = AppLocalization.bundle(for: language)
            let stringsPath = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings"))
            let entries = try XCTUnwrap(NSDictionary(contentsOfFile: stringsPath) as? [String: String])
            for key in keys {
                XCTAssertNotNil(entries[key], "\(language.rawValue) に「\(key)」がありません")
            }
        }
    }
}
