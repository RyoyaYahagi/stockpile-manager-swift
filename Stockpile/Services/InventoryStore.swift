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

    /// 期限に余裕がある（期限切れでも30日以内でもない）備蓄の割合。0〜100
    static func readinessPercent(of items: [Item]) -> Int {
        guard !items.isEmpty else { return 100 }
        let readyCount = items.filter { !$0.expiryStatus.needsAttention }.count
        return Int((Double(readyCount) / Double(items.count) * 100).rounded())
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
