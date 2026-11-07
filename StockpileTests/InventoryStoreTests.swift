import XCTest
@testable import Stockpile

final class InventoryStoreTests: XCTestCase {
    private func item(_ name: String, daysFromNow days: Int?) -> Item {
        let date = days.map { Calendar.current.date(byAdding: .day, value: $0, to: Date())! }
        return Item(name: name, quantity: 2, expiryDate: date)
    }

    func testReadinessCountsItemsBeyondThirtyDaysOrWithoutExpiry() {
        let items = [
            item("期限切れ", daysFromNow: -3),
            item("7日以内", daysFromNow: 2),
            item("1か月以内", daysFromNow: 20),
            item("余裕あり", daysFromNow: 90),
            item("期限なし", daysFromNow: nil)
        ]

        let readiness = InventoryStore.readiness(of: items)
        XCTAssertEqual(readiness.readyCount, 2)
        XCTAssertEqual(readiness.itemCount, 5)
        // 期限 40% と、必須ジャンル 0/6 を半分ずつ
        XCTAssertEqual(readiness.percent, 20)
    }

    func testReadinessIsZeroWhenThereAreNoItems() {
        let readiness = InventoryStore.readiness(of: [])
        XCTAssertEqual(readiness.percent, 0)
        XCTAssertEqual(readiness.missingCategories, InventoryStore.essentialCategories)
    }

    func testReadinessIsFullWhenAllEssentialCategoriesHaveTimeToSpare() {
        let items = InventoryStore.essentialCategories.map { category -> Item in
            let item = self.item("備蓄", daysFromNow: 90)
            item.category = category.rawValue
            return item
        }

        let readiness = InventoryStore.readiness(of: items)
        XCTAssertEqual(readiness.missingCategories, [])
        XCTAssertEqual(readiness.percent, 100)
    }

    func testReadinessTreatsEmptyOrExpiredItemsAsMissingCategory() {
        let water = item("水", daysFromNow: 90)
        water.category = ItemCategory.waterDrink.rawValue
        water.quantity = 0
        let rice = item("米", daysFromNow: -1)
        rice.category = ItemCategory.stapleFood.rawValue
        let medicine = item("薬", daysFromNow: 10)
        medicine.category = ItemCategory.medicine.rawValue

        let readiness = InventoryStore.readiness(of: [water, rice, medicine])
        // 数量0の水と期限切れの米はジャンルを満たさない。30日以内の薬は満たす
        XCTAssertEqual(readiness.coveredCategories, [.medicine])
        XCTAssertTrue(readiness.missingCategories.contains(.waterDrink))
        XCTAssertTrue(readiness.missingCategories.contains(.stapleFood))
        // 数量0の水は期限に余裕があっても「余裕あり」に数えない
        XCTAssertEqual(readiness.readyCount, 0)
        // 期限 0% と、必須ジャンル 1/6 を半分ずつ
        XCTAssertEqual(readiness.percent, 8)
    }

    func testAttentionItemsIncludeThirtyDaysAndExcludeLaterDatesInExpiryOrder() {
        let soon = item("7日以内", daysFromNow: 5)
        let expired = item("期限切れ", daysFromNow: -1)
        let today = item("本日期限", daysFromNow: 0)
        let month = item("30日以内", daysFromNow: 30)
        let safe = item("31日以降", daysFromNow: 31)
        let noExpiry = item("期限なし", daysFromNow: nil)

        let result = InventoryStore.attentionItems(in: [month, soon, safe, noExpiry, today, expired])

        XCTAssertEqual(result.map(\.name), ["期限切れ", "本日期限", "7日以内", "30日以内"])
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
            "外観", "システム", "ライトモード", "ダークモード",
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

    func testNotificationLedgerSkipsDeliveredNotificationsOnly() {
        let now = Date()
        let rule = NotificationTimingRule(amount: 1, unit: .week)
        let delivered = NotificationLedger.key(itemId: UUID(), rule: rule, thresholdDate: now)
        let upcoming = NotificationLedger.key(itemId: UUID(), rule: rule, thresholdDate: now)
        var ledger = NotificationLedger()
        ledger.record(delivered, fireDate: now.addingTimeInterval(-60))
        ledger.record(upcoming, fireDate: now.addingTimeInterval(3_600))

        XCTAssertTrue(ledger.hasDelivered(delivered, now: now))
        XCTAssertFalse(ledger.hasDelivered(upcoming, now: now))

        ledger.forgetPending(after: now)
        ledger.record(upcoming, fireDate: now.addingTimeInterval(7_200))
        XCTAssertFalse(ledger.hasDelivered(upcoming, now: now.addingTimeInterval(3_700)))
    }

    func testNotificationLimitKeepsEarliestDatesInOrder() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = [5, 1, 3, 1, 4, 2].map { base.addingTimeInterval(Double($0) * 86_400) }

        // 早い順。同じ日時（1 日後が 2 つ）は元の順を保つ
        XCTAssertEqual(NotificationManager.earliestIndices(of: dates, limit: 4), [1, 3, 5, 2])
        XCTAssertEqual(NotificationManager.earliestIndices(of: dates, limit: 10).count, dates.count)
        XCTAssertEqual(NotificationManager.earliestIndices(of: dates, limit: 0), [])
        XCTAssertLessThan(NotificationManager.maxScheduledNotifications, 64)
    }

    func testNotificationLedgerKeyChangesWhenExpiryChanges() {
        let id = UUID()
        let rule = NotificationTimingRule(amount: 3, unit: .day)
        let base = Calendar.current.startOfDay(for: Date())
        let next = Calendar.current.date(byAdding: .day, value: 30, to: base)!
        XCTAssertEqual(
            NotificationLedger.key(itemId: id, rule: rule, thresholdDate: base),
            NotificationLedger.key(itemId: id, rule: rule, thresholdDate: base)
        )
        XCTAssertNotEqual(
            NotificationLedger.key(itemId: id, rule: rule, thresholdDate: base),
            NotificationLedger.key(itemId: id, rule: rule, thresholdDate: next)
        )
    }

    func testGroupedByCategoryMatchesFilteringPerCategory() {
        let names = ["水", "米", "缶詰", "薬", "マスク", "乾電池", "チョコ", "謎の品"]
        let items = names.map { Item(name: $0) }

        let grouped = InventoryStore.groupedByCategory(items)

        for category in ItemCategory.allCases {
            XCTAssertEqual(
                grouped[category]?.map(\.id) ?? [],
                items.filter { $0.resolvedCategory == category }.map(\.id),
                "\(category.rawValue) の振り分けが一致しません"
            )
        }
        XCTAssertEqual(grouped.values.flatMap { $0 }.count, items.count)
    }
}

final class ModernAppearanceTests: XCTestCase {
    func testAppearanceSupportsSystemLightAndDark() {
        XCTAssertEqual(AppAppearance.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }
}

final class ItemCategoryInferenceTests: XCTestCase {
    func testInfersWaterFromJapaneseName() {
        XCTAssertEqual(
            ItemCategoryInference.category(forName: "ミネラルウォーター 2L"),
            .waterDrink
        )
    }

    func testInfersSideDishFromCannedFoodName() {
        XCTAssertEqual(ItemCategoryInference.category(forName: "ツナ缶"), .sideDish)
    }

    func testInfersPowerLightFromBatteryName() {
        XCTAssertEqual(ItemCategoryInference.category(forName: "乾電池 単3"), .powerLight)
    }

    func testUsesProductCategoryWhenNameHasNoKeyword() {
        XCTAssertEqual(
            ItemCategoryInference.category(forName: "箱", productCategory: "医薬品、医療用品"),
            .medicine
        )
    }

    func testEnglishKeywordsMatchWholeWords() {
        XCTAssertEqual(ItemCategoryInference.category(forName: "candy"), .snackSupplement)
        XCTAssertNotEqual(ItemCategoryInference.category(forName: "steak"), .waterDrink)
    }

    func testUnknownNameReturnsNilAndResolvedFallsBackToOther() {
        XCTAssertNil(ItemCategoryInference.category(forName: "謎の品"))
        let item = Item(name: "謎の品")
        XCTAssertEqual(item.resolvedCategory, .other)
    }

    func testStoredCategoryWinsOverInference() {
        let item = Item(name: "水 2L", category: ItemCategory.snackSupplement.rawValue)
        XCTAssertEqual(item.resolvedCategory, .snackSupplement)
    }

    func testCategoryKeysExistInAllEightLocalizations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let languages = ["ja", "en", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"]
        let keys = [
            "ジャンル",
            "水・飲料",
            "主食",
            "おかず・缶詰",
            "お菓子・栄養補助",
            "衛生用品",
            "医薬品",
            "電池・電源・照明",
            "その他のジャンル",
            "収納場所: %@"
        ]

        for language in languages {
            let url = repositoryRoot
                .appendingPathComponent("Stockpile/Localization/\(language).lproj/Localizable.strings")
            let entries = try XCTUnwrap(
                NSDictionary(contentsOf: url) as? [String: String],
                "\(language) の Localizable.strings を読めません"
            )
            for key in keys {
                XCTAssertNotNil(entries[key], "\(language) に「\(key)」がありません")
            }
        }
    }

    func testInferenceIsStableAcrossRepeatedAndWidthInsensitiveLookups() {
        XCTAssertEqual(ItemCategoryInference.category(forName: "ＣＡＮＤＹ"), .snackSupplement)
        XCTAssertEqual(ItemCategoryInference.category(forName: "candy"), .snackSupplement)
        XCTAssertNil(ItemCategoryInference.category(forName: "謎の品"))
        XCTAssertNil(ItemCategoryInference.category(forName: "謎の品"))
    }
}

final class BackupJSONCategoryTests: XCTestCase {
    func testCategoryRoundTripsThroughBackupJSON() throws {
        let item = Item(
            name: "ウェットティッシュ",
            quantity: 3,
            category: ItemCategory.hygiene.rawValue
        )

        let data = try BackupJSONCodec.makeExportData(from: [item])
        let payloads = try BackupImportValidator.decodeAndValidate(data)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.category, ItemCategory.hygiene.rawValue)
        XCTAssertEqual(payloads.first?.resolvedCategory, ItemCategory.hygiene.rawValue)
    }

    func testOldBackupWithoutCategoryDecodesAsNil() throws {
        let data = Data("[{\"name\":\"Water\",\"quantity\":3}]".utf8)
        let payloads = try BackupImportValidator.decodeAndValidate(data)
        XCTAssertNil(payloads.first?.category)
        XCTAssertNil(payloads.first?.resolvedCategory)
    }

    func testUnknownCategoryIsIgnored() throws {
        let data = Data("[{\"name\":\"Water\",\"category\":\"unknown\"}]".utf8)
        let payloads = try BackupImportValidator.decodeAndValidate(data)
        XCTAssertEqual(payloads.first?.category, "unknown")
        XCTAssertNil(payloads.first?.resolvedCategory)
    }

    func testSnapshotJSONRoundTripsCategory() throws {
        let item = Item(
            name: "ウェットティッシュ",
            quantity: 3,
            category: ItemCategory.hygiene.rawValue
        )
        let data = try SnapshotBuilder.makeJSONData(items: [item], familyName: nil)
        let snapshot = try JSONDecoder().decode(StockpileSnapshot.self, from: data)
        XCTAssertEqual(snapshot.items.first?.category, ItemCategory.hygiene.rawValue)
    }

    func testSnapshotWithoutCategoryStillDecodes() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-11-05T18:00:00+09:00",
          "items": [
            {
              "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
              "name": "水",
              "quantity": 1,
              "updatedAt": "2026-11-01T10:15:00+09:00"
            }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(StockpileSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.items.first?.category)
    }
}
