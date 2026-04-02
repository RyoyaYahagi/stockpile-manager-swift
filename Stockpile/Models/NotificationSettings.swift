import Foundation
import SwiftData

enum NotificationTimingUnit: String, CaseIterable, Identifiable {
    case day = "d"
    case week = "w"
    case month = "m"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .day:
            return L10n.string("日")
        case .week:
            return L10n.string("週")
        case .month:
            return L10n.string("月")
        }
    }

    var minimumAmount: Int {
        switch self {
        case .day:
            return 0
        case .week, .month:
            return 1
        }
    }

    var maximumAmount: Int {
        99
    }

    var approximateDays: Int {
        switch self {
        case .day:
            return 1
        case .week:
            return 7
        case .month:
            return 30
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
                return L10n.string("当日")
            }
            return L10n.format("%@日前", String(normalized.amount))
        case .week:
            return L10n.format("%@週間前", String(normalized.amount))
        case .month:
            return L10n.format("%@ヶ月前", String(normalized.amount))
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
    static let freeTimingRulesLimit = 1

    private static let defaultFreeTimingRules = [
        NotificationTimingRule(amount: 0, unit: .day),
    ]
    private static let defaultPremiumTimingRules = [
        NotificationTimingRule(amount: 0, unit: .day),
        NotificationTimingRule(amount: 1, unit: .week),
        NotificationTimingRule(amount: 1, unit: .month)
    ]
    private static let addPresetTimingRules = [
        NotificationTimingRule(amount: 0, unit: .day),
        NotificationTimingRule(amount: 1, unit: .week),
        NotificationTimingRule(amount: 1, unit: .month),
        NotificationTimingRule(amount: 3, unit: .day),
        NotificationTimingRule(amount: 3, unit: .month)
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

    func addNotificationTimingRule(maximumCount: Int? = nil) {
        let allowedCount = maximumCount ?? Self.maximumTimingRules
        let current = Self.normalizeTimingRules(notificationTimingRules)
        guard current.count < allowedCount else { return }
        let used = Set(current)

        if let suggested = Self.addPresetTimingRules.first(where: { !used.contains($0) }) {
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
    static func createDefault(isPremium: Bool = false) -> NotificationSettings {
        let settings = NotificationSettings()
        settings.notificationTimingRules = isPremium ? defaultPremiumTimingRules : defaultFreeTimingRules
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
        var normalizedValues: [NotificationTimingRule] = []
        var seen: Set<NotificationTimingRule> = []

        for rule in values.map(\.normalizedRule) {
            guard !seen.contains(rule) else { continue }
            seen.insert(rule)
            normalizedValues.append(rule)

            if normalizedValues.count == Self.maximumTimingRules {
                break
            }
        }

        return normalizedValues
    }

    private static func parseTimingRuleToken(_ token: String) -> NotificationTimingRule? {
        guard !token.isEmpty else { return nil }

        if let amount = Int(token) {
            return NotificationTimingRule(amount: amount, unit: .day)
        }

        guard let rawUnit = token.last,
              let amount = Int(token.dropLast())
        else {
            return nil
        }

        if rawUnit == "y" {
            return NotificationTimingRule(amount: amount * 12, unit: .month)
        }

        guard let unit = NotificationTimingUnit(rawValue: String(rawUnit)) else {
            return nil
        }

        return NotificationTimingRule(amount: amount, unit: unit)
    }
}
