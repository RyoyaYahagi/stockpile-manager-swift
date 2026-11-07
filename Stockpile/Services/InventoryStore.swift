import Foundation
import SwiftData

/// 現在の家族に属する備蓄品・収納場所の絞り込みと、保存＋同期の共通処理
enum InventoryStore {
    static func scopedItems(_ items: [Item], family: Family?) -> [Item] {
        guard let family else {
            return deduplicated(items.filter { $0.family == nil })
        }
        let familyItems = deduplicated(items.filter { $0.family?.id == family.id })
        if !familyItems.isEmpty || family.prefersStrictCloudKitScoping {
            return familyItems
        }
        return deduplicated(items.filter { $0.family == nil })
    }

    static func scopedBags(_ bags: [Bag], family: Family?) -> [Bag] {
        guard let family else {
            return deduplicated(bags.filter { $0.family == nil })
        }
        let familyBags = deduplicated(bags.filter { $0.family?.id == family.id })
        if !familyBags.isEmpty || family.prefersStrictCloudKitScoping {
            return familyBags
        }
        return deduplicated(bags.filter { $0.family == nil })
    }

    /// 安心度の内訳
    struct Readiness: Equatable {
        /// 期限に余裕があり（期限切れでも30日以内でもない）、数量が1以上の品目数
        let readyCount: Int
        let itemCount: Int
        /// 必須ジャンルのうち、使える在庫があるもの
        let coveredCategories: [ItemCategory]
        /// 必須ジャンルのうち、使える在庫がないもの
        let missingCategories: [ItemCategory]

        /// 期限と品ぞろえを半分ずつ合わせた安心度。0〜100
        var percent: Int {
            let expiryScore = itemCount == 0 ? 0 : Double(readyCount) / Double(itemCount)
            let essentialCount = coveredCategories.count + missingCategories.count
            let coverageScore = essentialCount == 0 ? 1 : Double(coveredCategories.count) / Double(essentialCount)
            return Int(((expiryScore + coverageScore) / 2 * 100).rounded())
        }
    }

    /// 品ぞろえの判定に使う必須ジャンル（お菓子・その他は含めない）
    static let essentialCategories: [ItemCategory] = [
        .waterDrink, .stapleFood, .sideDish, .hygiene, .medicine, .powerLight
    ]

    static func readiness(of items: [Item]) -> Readiness {
        let readyCount = items.filter { $0.quantity > 0 && !$0.expiryStatus.needsAttention }.count
        // 期限切れでなく数量が1以上なら、そのジャンルは「ある」とみなす
        let usableCategories = Set(
            items
                .filter { $0.quantity > 0 && $0.expiryStatus != .expired }
                .map(\.resolvedCategory)
        )
        return Readiness(
            readyCount: readyCount,
            itemCount: items.count,
            coveredCategories: essentialCategories.filter { usableCategories.contains($0) },
            missingCategories: essentialCategories.filter { !usableCategories.contains($0) }
        )
    }

    static func readinessPercent(of items: [Item]) -> Int {
        readiness(of: items).percent
    }

    /// 期限切れ・30日以内を、期限の近い順に並べたもの
    static func attentionItems(in items: [Item]) -> [Item] {
        items
            .filter { $0.expiryStatus.needsAttention }
            .sorted { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
    }

    static func useOne(of item: Item) {
        item.quantity = max(0, item.quantity - 1)
        item.markUpdated()
    }

    static func renew(_ item: Item, expiryDate: Date?, quantity: Int? = nil) {
        item.expiryDate = expiryDate
        if let quantity {
            item.quantity = max(1, quantity)
        }
        item.notified30 = false
        item.notified7 = false
        item.notified1 = false
        item.markUpdated()
    }

    /// ローカル保存のあと、通知の再設定と家族への同期を行う
    @MainActor
    @discardableResult
    static func saveAndSync(
        _ modelContext: ModelContext,
        family: Family?,
        needsNotificationReschedule: Bool = true
    ) -> Bool {
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("ローカル保存に失敗: \(error)")
            #endif
            return false
        }

        if needsNotificationReschedule {
            NotificationManager.shared.requestReschedule(using: modelContext)
        }

        guard let family else { return true }
        Task {
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try await sharingService.syncFamilyDataToCloudKit(for: family)
            } catch {
                #if DEBUG
                print("CloudKit同期に失敗: \(error)")
                #endif
            }
        }
        return true
    }

    private static func deduplicated<T: Identifiable>(_ source: [T]) -> [T] where T.ID == UUID {
        var seen = Set<UUID>()
        return source.filter { seen.insert($0.id).inserted }
    }
}

extension ExpiryStatus {
    /// ホームの「いま対応が必要」に出す状態か
    var needsAttention: Bool {
        self == .expired || self == .imminent || self == .approaching
    }
}
