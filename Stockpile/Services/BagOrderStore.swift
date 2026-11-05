import Foundation

/// 収納場所の並び順。家族とは共有せず、この端末にだけ保存する
enum BagOrderStore {
    /// 並び順が変わったことを画面に知らせるための AppStorage キー
    static let revisionKey = "bagOrder.revision"

    static func sorted(_ bags: [Bag], family: Family?, defaults: UserDefaults = .standard) -> [Bag] {
        let order = savedOrder(for: family, defaults: defaults)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return bags.sorted { lhs, rhs in
            switch (position[lhs.id], position[rhs.id]) {
            case let (left?, right?):
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.createdAt < rhs.createdAt
            }
        }
    }

    static func save(_ bags: [Bag], for family: Family?, defaults: UserDefaults = .standard) {
        defaults.set(bags.map(\.id.uuidString), forKey: storageKey(for: family))
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    static func savedOrder(for family: Family?, defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: storageKey(for: family)) ?? []).compactMap(UUID.init(uuidString:))
    }

    private static func storageKey(for family: Family?) -> String {
        "bagOrder.\(family?.id.uuidString ?? "local")"
    }
}
