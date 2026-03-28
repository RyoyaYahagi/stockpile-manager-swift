import Foundation
import SwiftData

/// 通知設定モデル
@Model
final class NotificationSettings {
    private static let defaultTimingDays = [30, 7, 0]
    private static let suggestedTimingDays = [30, 14, 7, 3, 1, 0]

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

    /// 可変の通知タイミング（日数リスト）を永続化したCSV
    var notificationTimingDaysData: String = ""

    /// 通知タイミングの可変リストへ移行済みかどうか
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

    /// 通知タイミング（日数リスト）を取得・保存
    var notificationTimingDays: [Int] {
        get {
            if usesNotificationTimingList {
                return Self.parseTimingDays(from: notificationTimingDaysData)
            }
            return legacyTimingDays
        }
        set {
            let normalized = Self.normalizeTimingDays(newValue)
            notificationTimingDaysData = Self.serializeTimingDays(normalized)
            usesNotificationTimingList = true
            syncLegacyFlags(with: normalized)
        }
    }

    /// タイミング変更検知用の署名
    var notificationTimingSignature: String {
        let normalized = Self.normalizeTimingDays(notificationTimingDays)
        return Self.serializeTimingDays(normalized)
    }

    @discardableResult
    func migrateLegacyTimingDaysIfNeeded() -> Bool {
        let normalized: [Int]
        if usesNotificationTimingList {
            normalized = Self.parseTimingDays(from: notificationTimingDaysData)
        } else {
            normalized = legacyTimingDays
        }

        let serialized = Self.serializeTimingDays(normalized)
        let shouldUpdate =
            notificationTimingDaysData != serialized
            || !usesNotificationTimingList
            || notify30DaysBefore != normalized.contains(30)
            || notify7DaysBefore != normalized.contains(7)
            || notifyOnDay != normalized.contains(0)

        guard shouldUpdate else { return false }

        notificationTimingDaysData = serialized
        usesNotificationTimingList = true
        syncLegacyFlags(with: normalized)
        return true
    }

    func addNotificationTimingDay() {
        let current = Self.normalizeTimingDays(notificationTimingDays)
        let used = Set(current)

        if let suggested = Self.suggestedTimingDays.first(where: { !used.contains($0) }) {
            notificationTimingDays = current + [suggested]
            return
        }

        if let firstAvailable = (0...365).first(where: { !used.contains($0) }) {
            notificationTimingDays = current + [firstAvailable]
        }
    }

    func updateNotificationTimingDay(at index: Int, to value: Int) {
        var timings = Self.normalizeTimingDays(notificationTimingDays)
        guard timings.indices.contains(index) else { return }
        timings[index] = min(max(value, 0), 365)
        notificationTimingDays = timings
    }

    func removeNotificationTimingDay(at index: Int) {
        var timings = Self.normalizeTimingDays(notificationTimingDays)
        guard timings.indices.contains(index) else { return }
        timings.remove(at: index)
        notificationTimingDays = timings
    }
    
    /// デフォルト設定を作成
    static func createDefault() -> NotificationSettings {
        let settings = NotificationSettings()
        settings.notificationTimingDays = defaultTimingDays
        return settings
    }

    private var legacyTimingDays: [Int] {
        var timings: [Int] = []
        if notify30DaysBefore {
            timings.append(30)
        }
        if notify7DaysBefore {
            timings.append(7)
        }
        if notifyOnDay {
            timings.append(0)
        }
        return Self.normalizeTimingDays(timings)
    }

    private func syncLegacyFlags(with timings: [Int]) {
        notify30DaysBefore = timings.contains(30)
        notify7DaysBefore = timings.contains(7)
        notifyOnDay = timings.contains(0)
    }

    private static func parseTimingDays(from rawValue: String) -> [Int] {
        normalizeTimingDays(
            rawValue
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    private static func serializeTimingDays(_ values: [Int]) -> String {
        normalizeTimingDays(values)
            .map(String.init)
            .joined(separator: ",")
    }

    private static func normalizeTimingDays(_ values: [Int]) -> [Int] {
        Array(
            Set(values.map { min(max($0, 0), 365) })
        )
        .sorted(by: >)
    }
}
