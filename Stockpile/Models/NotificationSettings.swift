import Foundation
import SwiftData

enum NotificationTimingUnit: String, CaseIterable, Identifiable {
    case day = "d"
    case month = "m"
    case year = "y"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .day:
            return "日"
        case .month:
            return "ヶ月"
        case .year:
            return "年"
        }
    }

    var minimumAmount: Int {
        switch self {
        case .day:
            return 0
        case .month, .year:
            return 1
        }
    }

    var maximumAmount: Int {
        switch self {
        case .day:
            return 3650
        case .month:
            return 120
        case .year:
            return 20
        }
    }

    var approximateDays: Int {
        switch self {
        case .day:
            return 1
        case .month:
            return 30
        case .year:
            return 365
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .day:
            return .day
        case .month:
            return .month
        case .year:
            return .year
        }
    }
}

struct NotificationTimingRule: Hashable, Identifiable {
    var amount: Int
    var unit: NotificationTimingUnit

    var id: String { serializedValue }

    var serializedValue: String {
        let normalized = normalizedRule
        return "\(normalized.amount)\(normalized.unit.rawValue)"
    }

    var displayText: String {
        let normalized = normalizedRule
        switch normalized.unit {
        case .day:
            if normalized.amount == 0 {
                return "当日"
            }
            return "\(normalized.amount)日前"
        case .month:
            return "\(normalized.amount)ヶ月前"
        case .year:
            return "\(normalized.amount)年前"
        }
    }

    var sortWeight: Int {
        let normalized = normalizedRule
        return normalized.amount * normalized.unit.approximateDays
    }

    var normalizedRule: NotificationTimingRule {
        let lowerBound = unit.minimumAmount
        let upperBound = unit.maximumAmount
        return NotificationTimingRule(
            amount: min(max(amount, lowerBound), upperBound),
            unit: unit
        )
    }
}

/// 通知設定モデル
@Model
final class NotificationSettings {
    static let maximumTimingRules = 5

    private static let defaultTimingRules = [
        NotificationTimingRule(amount: 30, unit: .day),
        NotificationTimingRule(amount: 7, unit: .day),
        NotificationTimingRule(amount: 0, unit: .day)
    ]
    private static let suggestedTimingRules = [
        NotificationTimingRule(amount: 1, unit: .year),
        NotificationTimingRule(amount: 6, unit: .month),
        NotificationTimingRule(amount: 3, unit: .month),
        NotificationTimingRule(amount: 1, unit: .month),
        NotificationTimingRule(amount: 30, unit: .day),
        NotificationTimingRule(amount: 14, unit: .day),
        NotificationTimingRule(amount: 7, unit: .day),
        NotificationTimingRule(amount: 3, unit: .day),
        NotificationTimingRule(amount: 1, unit: .day),
        NotificationTimingRule(amount: 0, unit: .day)
    ]

    /// 通知全体の有効/無効
    var isEnabled: Bool = true
    
    /// 30日前通知
    var notify30DaysBefore: Bool = true
    
    /// 7日前通知
    var notify7DaysBefore: Bool = true
    
    /// 当日通知
    var notifyOnDay: Bool = true
    
    /// 通知時刻（時）
    var notificationHour: Int = 8
    
    /// 通知時刻（分）
    var notificationMinute: Int = 0

    /// 可変の通知タイミング（数値＋単位）を永続化したCSV
    var notificationTimingDaysData: String = ""

    /// 通知タイミングの可変ルールへ移行済みかどうか
    var usesNotificationTimingList: Bool = false
    
    /// 作成日時
    var createdAt: Date = Date()
    
    init(
        isEnabled: Bool = true,
        notify30DaysBefore: Bool = true,
        notify7DaysBefore: Bool = true,
        notifyOnDay: Bool = true,
        notificationHour: Int = 8,
        notificationMinute: Int = 0,
        notificationTimingDaysData: String = "",
        usesNotificationTimingList: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.notify30DaysBefore = notify30DaysBefore
        self.notify7DaysBefore = notify7DaysBefore
        self.notifyOnDay = notifyOnDay
        self.notificationHour = notificationHour
        self.notificationMinute = notificationMinute
        self.notificationTimingDaysData = notificationTimingDaysData
        self.usesNotificationTimingList = usesNotificationTimingList
        self.createdAt = Date()
    }
    
    /// 通知時刻をDateComponentsとして取得
    var notificationTimeComponents: DateComponents {
        var components = DateComponents()
        components.hour = notificationHour
        components.minute = notificationMinute
        return components
    }

    /// 通知タイミング（数値＋単位）を取得・保存
    var notificationTimingRules: [NotificationTimingRule] {
        get {
            if usesNotificationTimingList {
                return Self.parseTimingRules(from: notificationTimingDaysData)
            }
            return legacyTimingRules
        }
        set {
            let normalized = Self.normalizeTimingRules(newValue)
            notificationTimingDaysData = Self.serializeTimingRules(normalized)
            usesNotificationTimingList = true
            syncLegacyFlags(with: normalized)
        }
    }

    /// タイミング変更検知用の署名
    var notificationTimingSignature: String {
        let normalized = Self.normalizeTimingRules(notificationTimingRules)
        return Self.serializeTimingRules(normalized)
    }

    @discardableResult
    func migrateLegacyTimingRulesIfNeeded() -> Bool {
        let normalized: [NotificationTimingRule]
        if usesNotificationTimingList {
            normalized = Self.parseTimingRules(from: notificationTimingDaysData)
        } else {
            normalized = legacyTimingRules
        }

        let serialized = Self.serializeTimingRules(normalized)
        let shouldUpdate =
            notificationTimingDaysData != serialized
            || !usesNotificationTimingList
            || notify30DaysBefore != normalized.contains(NotificationTimingRule(amount: 30, unit: .day))
            || notify7DaysBefore != normalized.contains(NotificationTimingRule(amount: 7, unit: .day))
            || notifyOnDay != normalized.contains(NotificationTimingRule(amount: 0, unit: .day))

        guard shouldUpdate else { return false }

        notificationTimingDaysData = serialized
        usesNotificationTimingList = true
        syncLegacyFlags(with: normalized)
        return true
    }

    func addNotificationTimingRule() {
        let current = Self.normalizeTimingRules(notificationTimingRules)
        guard current.count < Self.maximumTimingRules else { return }
        let used = Set(current)

        if let suggested = Self.suggestedTimingRules.first(where: { !used.contains($0) }) {
            notificationTimingRules = current + [suggested]
            return
        }

        if let firstAvailableDay = (0...NotificationTimingUnit.day.maximumAmount).first(where: {
            !used.contains(NotificationTimingRule(amount: $0, unit: .day))
        }) {
            notificationTimingRules = current + [NotificationTimingRule(amount: firstAvailableDay, unit: .day)]
        }
    }

    func updateNotificationTimingAmount(at index: Int, to value: Int) {
        var timings = Self.normalizeTimingRules(notificationTimingRules)
        guard timings.indices.contains(index) else { return }
        timings[index].amount = value
        notificationTimingRules = timings
    }

    func updateNotificationTimingUnit(at index: Int, to unit: NotificationTimingUnit) {
        var timings = Self.normalizeTimingRules(notificationTimingRules)
        guard timings.indices.contains(index) else { return }
        timings[index].unit = unit
        if unit != .day, timings[index].amount == 0 {
            timings[index].amount = unit.minimumAmount
        }
        notificationTimingRules = timings
    }

    func removeNotificationTimingRule(at index: Int) {
        var timings = Self.normalizeTimingRules(notificationTimingRules)
        guard timings.indices.contains(index) else { return }
        timings.remove(at: index)
        notificationTimingRules = timings
    }
    
    /// デフォルト設定を作成
    static func createDefault() -> NotificationSettings {
        let settings = NotificationSettings()
        settings.notificationTimingRules = defaultTimingRules
        return settings
    }

    private var legacyTimingRules: [NotificationTimingRule] {
        var timings: [NotificationTimingRule] = []
        if notify30DaysBefore {
            timings.append(NotificationTimingRule(amount: 30, unit: .day))
        }
        if notify7DaysBefore {
            timings.append(NotificationTimingRule(amount: 7, unit: .day))
        }
        if notifyOnDay {
            timings.append(NotificationTimingRule(amount: 0, unit: .day))
        }
        return Self.normalizeTimingRules(timings)
    }

    private func syncLegacyFlags(with timings: [NotificationTimingRule]) {
        let normalized = Self.normalizeTimingRules(timings)
        notify30DaysBefore = normalized.contains(NotificationTimingRule(amount: 30, unit: .day))
        notify7DaysBefore = normalized.contains(NotificationTimingRule(amount: 7, unit: .day))
        notifyOnDay = normalized.contains(NotificationTimingRule(amount: 0, unit: .day))
    }

    private static func parseTimingRules(from rawValue: String) -> [NotificationTimingRule] {
        normalizeTimingRules(
            rawValue
                .split(separator: ",")
                .compactMap { parseTimingRuleToken(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    private static func serializeTimingRules(_ values: [NotificationTimingRule]) -> String {
        normalizeTimingRules(values)
            .map(\.serializedValue)
            .joined(separator: ",")
    }

    private static func normalizeTimingRules(_ values: [NotificationTimingRule]) -> [NotificationTimingRule] {
        Array(
            Set(values.map(\.normalizedRule))
        )
        .sorted {
            if $0.sortWeight == $1.sortWeight {
                return $0.unit.approximateDays > $1.unit.approximateDays
            }
            return $0.sortWeight > $1.sortWeight
        }
        .prefix(Self.maximumTimingRules)
        .map { $0 }
    }

    private static func parseTimingRuleToken(_ token: String) -> NotificationTimingRule? {
        guard !token.isEmpty else { return nil }

        if let amount = Int(token) {
            return NotificationTimingRule(amount: amount, unit: .day)
        }

        guard let rawUnit = token.last,
              let unit = NotificationTimingUnit(rawValue: String(rawUnit)),
              let amount = Int(token.dropLast())
        else {
            return nil
        }

        return NotificationTimingRule(amount: amount, unit: unit)
    }
}
