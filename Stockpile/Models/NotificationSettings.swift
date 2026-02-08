import Foundation
import SwiftData

/// 通知設定モデル
@Model
final class NotificationSettings {
    /// 通知全体の有効/無効
    var isEnabled: Bool
    
    /// 30日前通知
    var notify30DaysBefore: Bool
    
    /// 7日前通知
    var notify7DaysBefore: Bool
    
    /// 当日通知
    var notifyOnDay: Bool
    
    /// 通知時刻（時）
    var notificationHour: Int
    
    /// 通知時刻（分）
    var notificationMinute: Int
    
    /// 作成日時
    var createdAt: Date
    
    init(
        isEnabled: Bool = true,
        notify30DaysBefore: Bool = true,
        notify7DaysBefore: Bool = true,
        notifyOnDay: Bool = true,
        notificationHour: Int = 8,
        notificationMinute: Int = 0
    ) {
        self.isEnabled = isEnabled
        self.notify30DaysBefore = notify30DaysBefore
        self.notify7DaysBefore = notify7DaysBefore
        self.notifyOnDay = notifyOnDay
        self.notificationHour = notificationHour
        self.notificationMinute = notificationMinute
        self.createdAt = Date()
    }
    
    /// 通知時刻をDateComponentsとして取得
    var notificationTimeComponents: DateComponents {
        var components = DateComponents()
        components.hour = notificationHour
        components.minute = notificationMinute
        return components
    }
    
    /// デフォルト設定を作成
    static func createDefault() -> NotificationSettings {
        NotificationSettings()
    }
}
