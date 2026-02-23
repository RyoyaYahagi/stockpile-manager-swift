import Foundation
import UserNotifications
import SwiftData

/// 通知アイテムと種類のペア
private struct NotificationItem {
    let item: Item
    let type: NotificationType
}

/// 通知種類
private enum NotificationType: String {
    case days30 = "30days"
    case days7 = "7days"
    case onday = "onday"
    
    var displayText: String {
        switch self {
        case .days30: return "30日前"
        case .days7: return "7日前"
        case .onday: return "本日"
        }
    }
    
    var order: Int {
        switch self {
        case .onday: return 0
        case .days7: return 1
        case .days30: return 2
        }
    }
}

/// 通知管理サービス
@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var pendingRescheduleWorkItem: DispatchWorkItem?
    private let rescheduleDebounceInterval: TimeInterval = 0.25
    private let immediateFallbackInterval: TimeInterval = 60
    
    private init() {
        Task {
            await refreshAuthorizationStatus()
        }
    }
    
    // MARK: - Authorization
    
    /// 通知権限をリクエスト
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            print("Notification authorization error: \(error)")
            return false
        }
    }
    
    /// 通知権限ステータスを更新
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// 現在の通知システム設定を取得
    func currentNotificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }
    
    /// 通知スケジュールに必要な権限を確認（未決定ならリクエスト）
    private func ensureAuthorizationForScheduling() async -> Bool {
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            _ = await requestAuthorization()
        }
        
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Scheduling (Grouped by Date)
    
    /// 再スケジュール要求をデバウンスして実行
    func requestReschedule(using modelContext: ModelContext) {
        enqueueReschedule { [weak self] in
            guard let self else { return }
            await self.rescheduleAllNotifications(using: modelContext)
        }
    }
    
    /// 再スケジュール要求をデバウンスして実行（設定画面用）
    func requestReschedule(items: [Item], settings: NotificationSettings) {
        enqueueReschedule { [weak self] in
            guard let self else { return }
            await self.rescheduleAllNotifications(items: items, settings: settings)
        }
    }
    
    /// すべてのアイテムの通知を再スケジュール（日付でグループ化）
    func rescheduleAllNotifications(items: [Item], settings: NotificationSettings) async {
        cancelPendingReschedule()
        cancelAllNotifications()
        
        guard settings.isEnabled else { return }
        guard await ensureAuthorizationForScheduling() else { return }
        
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        
        // 今日の日付成分のみを取得（時刻を無視）
        let todayComponents = calendar.dateComponents([.year, .month, .day], from: Date())
        guard let today = calendar.date(from: todayComponents) else { return }
        
        // 通知日ごとにアイテムをグループ化（日付のみでグループ化）
        var groupedNotifications: [Date: [NotificationItem]] = [:]
        
        for item in items {
            guard let expiryDate = item.expiryDate else { continue }
            
            // 期限日の日付成分のみを取得（時刻を無視）
            let expiryComponents = calendar.dateComponents([.year, .month, .day], from: expiryDate)
            guard let normalizedExpiryDate = calendar.date(from: expiryComponents) else { continue }
            
            // 残り日数を計算（Item.daysUntilExpiryと同じ計算方法）
            let daysUntilExpiry = calendar.dateComponents([.day], from: today, to: normalizedExpiryDate).day ?? 0
            
            // 過去の期限はスキップ
            guard daysUntilExpiry >= 0 else { continue }
            
            // 30日前通知: 残り30日以下で、まだ通知日が来ていない場合は今日通知
            if settings.notify30DaysBefore && daysUntilExpiry <= 30 && daysUntilExpiry > 7 {
                // 残り30日以下なので今日通知
                groupedNotifications[today, default: []].append(
                    NotificationItem(item: item, type: .days30)
                )
            } else if settings.notify30DaysBefore && daysUntilExpiry > 30 {
                // まだ30日以上あるので、30日前の日にスケジュール
                if let notifyDate = calendar.date(byAdding: .day, value: -30, to: normalizedExpiryDate) {
                    groupedNotifications[notifyDate, default: []].append(
                        NotificationItem(item: item, type: .days30)
                    )
                }
            }
            
            // 7日前通知: 残り7日以下で、まだ通知日が来ていない場合は今日通知
            if settings.notify7DaysBefore && daysUntilExpiry <= 7 && daysUntilExpiry > 0 {
                // 残り7日以下なので今日通知
                groupedNotifications[today, default: []].append(
                    NotificationItem(item: item, type: .days7)
                )
            } else if settings.notify7DaysBefore && daysUntilExpiry > 7 {
                // まだ7日以上あるので、7日前の日にスケジュール
                if let notifyDate = calendar.date(byAdding: .day, value: -7, to: normalizedExpiryDate) {
                    groupedNotifications[notifyDate, default: []].append(
                        NotificationItem(item: item, type: .days7)
                    )
                }
            }
            
            // 当日通知
            if settings.notifyOnDay && daysUntilExpiry == 0 {
                groupedNotifications[today, default: []].append(
                    NotificationItem(item: item, type: .onday)
                )
            } else if settings.notifyOnDay && daysUntilExpiry > 0 {
                groupedNotifications[normalizedExpiryDate, default: []].append(
                    NotificationItem(item: item, type: .onday)
                )
            }
        }

        
        // グループ化された通知をスケジュール
        for (notifyDate, notificationItems) in groupedNotifications {
            await scheduleGroupedNotification(
                notificationItems: notificationItems,
                at: notifyDate,
                settings: settings
            )
        }
        
        #if DEBUG
        print("📋 Scheduled \(groupedNotifications.count) grouped notifications")
        #endif
    }
    
    /// SwiftDataストアから設定とアイテムを再取得して通知を再スケジュール
    func rescheduleAllNotifications(using modelContext: ModelContext) async {
        cancelPendingReschedule()
        let settingsDescriptor = FetchDescriptor<NotificationSettings>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        
        let settings: NotificationSettings
        if let existing = try? modelContext.fetch(settingsDescriptor).first {
            settings = existing
        } else {
            let created = NotificationSettings.createDefault()
            modelContext.insert(created)
            settings = created
        }
        
        let itemDescriptor = FetchDescriptor<Item>()
        let allItems = (try? modelContext.fetch(itemDescriptor)) ?? []
        
        await rescheduleAllNotifications(items: allItems, settings: settings)
    }
    
    /// グループ化された通知をスケジュール
    private func scheduleGroupedNotification(
        notificationItems: [NotificationItem],
        at date: Date,
        settings: NotificationSettings
    ) async {
        let content = UNMutableNotificationContent()
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        
        // 通知タイトルとメッセージを生成
        let (title, body) = generateNotificationContent(notificationItems: notificationItems)
        content.title = title
        content.body = body
        
        // 複数アイテムの場合はitemIdsを配列で渡す
        let allItemIds = notificationItems.map { $0.item.id.uuidString }
        if allItemIds.count == 1 {
            content.userInfo = ["itemId": allItemIds[0]]
        } else {
            content.userInfo = ["itemIds": allItemIds]
        }
        
        // 通知時刻を設定
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        
        var dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dateComponents.hour = settings.notificationHour
        dateComponents.minute = settings.notificationMinute
        
        // 実際の通知発火日時を計算
        guard let scheduledDate = calendar.date(from: dateComponents) else {
            print("⚠️ Failed to create scheduled date")
            return
        }
        
        let now = Date()
        
        // 過去の日時は通知しない
        guard scheduledDate > now else {
            print("⚠️ Skipped grouped notification - \(formatDate(scheduledDate)) is in the past")
            return
        }
        
        let trigger: UNNotificationTrigger
        let effectiveScheduledDate: Date
        if scheduledDate > now {
            trigger = UNCalendarNotificationTrigger(
                dateMatching: dateComponents,
                repeats: false
            )
            effectiveScheduledDate = scheduledDate
        } else if calendar.isDate(date, inSameDayAs: now) {
            // 追加直後などで当日通知時刻を過ぎていた場合、通知を取りこぼさないよう近い将来にフォールバックする
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: immediateFallbackInterval,
                repeats: false
            )
            effectiveScheduledDate = now.addingTimeInterval(immediateFallbackInterval)
        } else {
            print("⚠️ Skipped grouped notification - \(formatDate(scheduledDate)) is in the past")
            return
        }
        
        // 日付でユニークなidentifierを生成
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let identifier = "grouped-\(dateFormatter.string(from: date))"
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("✅ Scheduled grouped: \(notificationItems.count)件 at \(formatDate(effectiveScheduledDate))")
        } catch {
            print("❌ Failed to schedule grouped notification: \(error)")
        }
    }
    
    /// 通知内容を生成（日付ごとにグループ化、種類別に表示）
    private func generateNotificationContent(notificationItems: [NotificationItem]) -> (title: String, body: String) {
        let totalCount = notificationItems.count
        
        // 種類ごとにグループ化
        var byType: [NotificationType: [Item]] = [:]
        for ni in notificationItems {
            byType[ni.type, default: []].append(ni.item)
        }
        
        if totalCount == 1 {
            let ni = notificationItems[0]
            return (
                title: "備蓄品の期限通知",
                body: "「\(ni.item.name)」の期限が\(ni.type.displayText)に迫っています"
            )
        } else {
            let title = "備蓄品の期限通知（\(totalCount)件）"
            
            // 種類順にソートして表示
            let sortedTypes = byType.keys.sorted { $0.order < $1.order }
            var parts: [String] = []
            
            for type in sortedTypes {
                guard let items = byType[type] else { continue }
                let names = items.prefix(2).map { $0.name }.joined(separator: "、")
                let suffix = items.count > 2 ? "他" : ""
                parts.append("\(type.displayText): \(names)\(suffix)")
            }
            
            let body = parts.joined(separator: " / ")
            return (title: title, body: body)
        }
    }
    
    /// 日付フォーマット用ヘルパー
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return formatter.string(from: date) + " JST"
    }
    
    // MARK: - Single Item Scheduling (for add/edit)
    
    /// 単一アイテムの通知をスケジュール（追加・編集時用）
    func scheduleNotifications(for item: Item, settings: NotificationSettings) async {
        guard settings.isEnabled else { return }
        guard await ensureAuthorizationForScheduling() else { return }
        guard let expiryDate = item.expiryDate else { return }
        
        // 既存の通知をキャンセル
        await cancelNotifications(for: item)
        
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        
        // 期限日の日付成分のみを取得（時刻を無視）
        let expiryComponents = calendar.dateComponents([.year, .month, .day], from: expiryDate)
        guard let normalizedExpiryDate = calendar.date(from: expiryComponents) else { return }
        
        // 今日の日付成分のみを取得（時刻を無視）
        let todayComponents = calendar.dateComponents([.year, .month, .day], from: Date())
        guard let today = calendar.date(from: todayComponents) else { return }
        
        // 日数差を計算（時刻の影響を排除）
        let daysUntilExpiry = calendar.dateComponents([.day], from: today, to: normalizedExpiryDate).day ?? 0
        
        print("📋 Scheduling notifications for \(item.name):")
        print("   - Expiry date: \(formatDate(normalizedExpiryDate))")
        print("   - Days until expiry: \(daysUntilExpiry)")
        
        // 30日前通知
        if settings.notify30DaysBefore {
            if let notifyDate = calendar.date(byAdding: .day, value: -30, to: normalizedExpiryDate) {
                await scheduleSingleNotification(
                    for: item,
                    at: notifyDate,
                    settings: settings,
                    suffix: "30days",
                    message: "「\(item.name)」の期限が30日後に迫っています"
                )
            }
        }
        
        // 7日前通知
        if settings.notify7DaysBefore {
            if let notifyDate = calendar.date(byAdding: .day, value: -7, to: normalizedExpiryDate) {
                await scheduleSingleNotification(
                    for: item,
                    at: notifyDate,
                    settings: settings,
                    suffix: "7days",
                    message: "「\(item.name)」の期限が7日後に迫っています"
                )
            }
        }
        
        // 当日通知
        if settings.notifyOnDay {
            await scheduleSingleNotification(
                for: item,
                at: normalizedExpiryDate,
                settings: settings,
                suffix: "onday",
                message: "「\(item.name)」の期限は本日です"
            )
        }
    }
    
    /// 単一アイテムの通知をスケジュール
    private func scheduleSingleNotification(
        for item: Item,
        at date: Date,
        settings: NotificationSettings,
        suffix: String,
        message: String
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "備蓄品の期限通知"
        content.body = message
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        content.userInfo = ["itemId": item.id.uuidString]
        
        // 通知時刻を設定
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        
        var dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dateComponents.hour = settings.notificationHour
        dateComponents.minute = settings.notificationMinute
        
        // 実際の通知発火日時を計算
        guard let scheduledDate = calendar.date(from: dateComponents) else {
            #if DEBUG
            print("⚠️ Failed to create scheduled date for \(item.name)")
            #endif
            return
        }
        
        let now = Date()
        
        let trigger: UNNotificationTrigger
        let effectiveScheduledDate: Date
        if scheduledDate > now {
            trigger = UNCalendarNotificationTrigger(
                dateMatching: dateComponents,
                repeats: false
            )
            effectiveScheduledDate = scheduledDate
        } else if calendar.isDate(date, inSameDayAs: now) {
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: immediateFallbackInterval,
                repeats: false
            )
            effectiveScheduledDate = now.addingTimeInterval(immediateFallbackInterval)
        } else {
            #if DEBUG
            print("⚠️ Skipped: \(item.name) (\(suffix)) - \(formatDate(scheduledDate)) is in the past")
            #endif
            return
        }
        
        let identifier = "\(item.id.uuidString)-\(suffix)"
        
        // 同一identifierの既存通知を先にキャンセル（重複防止）
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            #if DEBUG
            print("✅ Scheduled: \(item.name) (\(suffix)) at \(formatDate(effectiveScheduledDate))")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to schedule notification: \(error)")
            #endif
        }
    }
    
    /// アイテムの通知をキャンセル
    func cancelNotifications(for item: Item) async {
        let identifiers = [
            "\(item.id.uuidString)-30days",
            "\(item.id.uuidString)-7days",
            "\(item.id.uuidString)-onday"
        ]
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
    /// すべての通知をキャンセル
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    private func enqueueReschedule(_ operation: @escaping @MainActor () async -> Void) {
        pendingRescheduleWorkItem?.cancel()
        
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                await operation()
            }
        }
        pendingRescheduleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + rescheduleDebounceInterval,
            execute: workItem
        )
    }
    
    private func cancelPendingReschedule() {
        pendingRescheduleWorkItem?.cancel()
        pendingRescheduleWorkItem = nil
    }
    
    // MARK: - Debug
    
    /// スケジュール済み通知を取得（デバッグ用）
    func getPendingNotifications() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    /// 配信済み通知を取得（デバッグ用）
    func getDeliveredNotifications() async -> [UNNotification] {
        await UNUserNotificationCenter.current().deliveredNotifications()
    }
}
