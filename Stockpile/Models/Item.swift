import Foundation
import SwiftData

/// 期限状態
enum ExpiryStatus: Comparable {
    case expired       // 期限切れ
    case imminent      // 7日以内
    case approaching   // 30日以内
    case safe          // 安全
    case noExpiry      // 期限なし
    
    var color: String {
        switch self {
        case .expired: return "red"
        case .imminent: return "orange"
        case .approaching: return "yellow"
        case .safe: return "green"
        case .noExpiry: return "gray"
        }
    }
    
    var label: String {
        switch self {
        case .expired: return L10n.string("期限切れ")
        case .imminent: return L10n.string("期限間近")
        case .approaching: return L10n.string("まもなく期限")
        case .safe: return L10n.string("安全")
        case .noExpiry: return L10n.string("期限なし")
        }
    }
}

/// 備蓄品モデル
@Model
final class Item {
    var id: UUID = UUID()
    var name: String = ""
    var janCode: String?
    var quantity: Int = 1
    var expiryDate: Date?
    var locationNote: String?
    /// ジャンル（`ItemCategory.rawValue`）。未設定の既存データは表示時に推定する。
    var category: String?
    var notified30: Bool = false
    var notified7: Bool = false
    var notified1: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date.distantPast
    
    var family: Family?
    var bag: Bag?
    
    init(
        name: String,
        janCode: String? = nil,
        quantity: Int = 1,
        expiryDate: Date? = nil,
        locationNote: String? = nil,
        category: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.janCode = janCode
        self.quantity = quantity
        self.expiryDate = expiryDate
        self.locationNote = locationNote
        self.category = category
        self.notified30 = false
        self.notified7 = false
        self.notified1 = false
        self.createdAt = Date()
        self.updatedAt = createdAt
    }

    /// 表示に使うジャンル。保存値 → 品名からの推定 → その他の順で決める。
    var resolvedCategory: ItemCategory {
        ItemCategoryInference.resolvedCategory(storedCategory: category, name: name)
    }
    
    /// 期限状態を計算
    var expiryStatus: ExpiryStatus {
        guard let days = daysUntilExpiry else {
            return .noExpiry
        }
        
        if days < 0 {
            return .expired
        } else if days <= 7 {
            return .imminent
        } else if days <= 30 {
            return .approaching
        } else {
            return .safe
        }
    }
    
    /// 期限までの日数を取得
    var daysUntilExpiry: Int? {
        guard let expiryDate = expiryDate else { return nil }
        return Self.calculateDaysUntilExpiry(for: expiryDate)
    }
    
    /// 期限の表示用文字列
    var expiryDisplayText: String {
        guard let days = daysUntilExpiry else {
            return L10n.string("期限なし")
        }
        
        if days < 0 {
            return L10n.format("%@日超過", String(abs(days)))
        } else if days == 0 {
            return L10n.string("本日期限")
        } else {
            return L10n.format("あと%@日", String(days))
        }
    }
    
    private static func calculateDaysUntilExpiry(
        for expiryDate: Date,
        from referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let today = calendar.startOfDay(for: referenceDate)
        let normalizedExpiry = calendar.startOfDay(for: expiryDate)
        return calendar.dateComponents([.day], from: today, to: normalizedExpiry).day ?? 0
    }

    func markUpdated(at date: Date = Date()) {
        updatedAt = date
    }

    var syncTimestamp: Date {
        updatedAt == .distantPast ? createdAt : updatedAt
    }
}
