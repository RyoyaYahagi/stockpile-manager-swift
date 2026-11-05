#if DEBUG
import Foundation
import SwiftData

/// スクリーンショットモード（`ScreenshotMode`）用のサンプルデータ。
/// ダッシュボード・収納場所・家族共有・通知設定のいずれの画面でも自然に見えるよう、
/// ひとつのin-memoryコンテナに一式のデータをまとめて投入する。
/// Releaseビルドには含まれない（DEBUGビルドのみ）。
@MainActor
enum ScreenshotFixtures {
    static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Family.self,
            User.self,
            Bag.self,
            Item.self,
            CloudKitDeletionMarker.self,
            NotificationSettings.self,
            configurations: configuration
        )
        let context = container.mainContext

        let pantry = Bag(name: "キッチン棚")
        let emergency = Bag(name: "非常袋")
        let trunk = Bag(name: "車載ボックス")
        [pantry, emergency, trunk].forEach { context.insert($0) }

        // ダッシュボードの一覧が下部の検索バーに掛からず収まる件数（6点）に抑える
        let items = [
            Item(name: "飲料水", quantity: 12, expiryDate: date(daysFromNow: 30)),
            Item(name: "レトルトカレー", quantity: 6, expiryDate: date(daysFromNow: 5)),
            Item(name: "アルファ米", quantity: 4, expiryDate: date(daysFromNow: 2)),
            Item(name: "カセットボンベ", quantity: 3, expiryDate: date(daysFromNow: 31)),
            Item(name: "簡易トイレ", quantity: 10, expiryDate: nil),
            Item(name: "救急セット", quantity: 1, expiryDate: date(daysFromNow: -3))
        ]
        items[0].bag = pantry
        items[1].bag = pantry
        items[2].bag = trunk
        items[3].bag = trunk
        items[4].bag = emergency
        items[5].bag = emergency
        items.forEach { context.insert($0) }

        let family = Family(name: "ひなた家")
        let members = [
            User(displayName: "ゆうき", email: "yuki@example.com"),
            User(displayName: "みさき", email: "misaki@example.com"),
            User(displayName: "はると", email: "haruto@example.com")
        ]
        members.forEach { $0.family = family }
        context.insert(family)
        members.forEach { context.insert($0) }

        let settings = NotificationSettings.createDefault(isPremium: true)
        settings.notificationHour = 9
        settings.notificationMinute = 0
        context.insert(settings)

        try? context.save()
        return container
    }

    private static func date(daysFromNow days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }
}
#endif
