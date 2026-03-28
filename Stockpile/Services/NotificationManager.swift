import Foundation
import UserNotifications
import SwiftData

/// 通知アイテムと種類のペア
private struct NotificationItem {
    let item: Item
    let daysBefore: Int
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
            debugLog("Notification authorization error: \(error)")
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
        let timingDays = settings.notificationTimingDays
        guard !timingDays.isEmpty else { return }
        
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
            
            for (index, daysBefore) in timingDays.enumerated() {
                let nextLowerDays = timingDays.dropFirst(index + 1).first
                guard let notifyDate = scheduledNotificationDate(
                    for: daysBefore,
                    nextLowerDays: nextLowerDays,
                    daysUntilExpiry: daysUntilExpiry,
                    today: today,
                    expiryDate: normalizedExpiryDate,
                    calendar: calendar
                ) else {
                    continue
                }

                groupedNotifications[notifyDate, default: []].append(
                    NotificationItem(item: item, daysBefore: daysBefore)
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
        debugLog("📋 Scheduled \(groupedNotifications.count) grouped notifications")
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
            if settings.migrateLegacyTimingDaysIfNeeded() {
                try? modelContext.save()
            }
        } else {
            let created = NotificationSettings.createDefault()
            modelContext.insert(created)
            try? modelContext.save()
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
            debugLog("⚠️ Failed to create scheduled date")
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
            // 追加直後などで当日通知時刻を過ぎていた場合、通知を取りこぼさないよう近い将来にフォールバックする
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: immediateFallbackInterval,
                repeats: false
            )
            effectiveScheduledDate = now.addingTimeInterval(immediateFallbackInterval)
        } else {
            debugLog("⚠️ Skipped grouped notification - \(formatDate(scheduledDate)) is in the past")
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
            debugLog("✅ Scheduled grouped: \(notificationItems.count)件 at \(formatDate(effectiveScheduledDate))")
        } catch {
            debugLog("❌ Failed to schedule grouped notification: \(error)")
        }
    }
    
    /// 通知内容を生成（日付ごとにグループ化、種類別に表示）
    private func generateNotificationContent(notificationItems: [NotificationItem]) -> (title: String, body: String) {
        let totalCount = notificationItems.count
        
        // 種類ごとにグループ化
        var byTiming: [Int: [Item]] = [:]
        for ni in notificationItems {
            byTiming[ni.daysBefore, default: []].append(ni.item)
        }
        
        if totalCount == 1 {
            let ni = notificationItems[0]
            return (
                title: "備蓄品の期限通知",
                body: singleNotificationMessage(for: ni.item.name, daysBefore: ni.daysBefore)
            )
        } else {
            let title = "備蓄品の期限通知（\(totalCount)件）"
            
            // 種類順にソートして表示
            let sortedTimings = byTiming.keys.sorted()
            var parts: [String] = []
            
            for daysBefore in sortedTimings {
                guard let items = byTiming[daysBefore] else { continue }
                let names = items.prefix(2).map { $0.name }.joined(separator: "、")
                let suffix = items.count > 2 ? "他" : ""
                parts.append("\(notificationDisplayText(for: daysBefore)): \(names)\(suffix)")
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
        let timingDays = settings.notificationTimingDays
        guard !timingDays.isEmpty else { return }
        
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
        
        debugLog("📋 Scheduling notifications for \(item.name):")
        debugLog("   - Expiry date: \(formatDate(normalizedExpiryDate))")
        debugLog("   - Days until expiry: \(daysUntilExpiry)")
        
        for (index, daysBefore) in timingDays.enumerated() {
            let nextLowerDays = timingDays.dropFirst(index + 1).first
            guard let notifyDate = scheduledNotificationDate(
                for: daysBefore,
                nextLowerDays: nextLowerDays,
                daysUntilExpiry: daysUntilExpiry,
                today: today,
                expiryDate: normalizedExpiryDate,
                calendar: calendar
            ) else {
                continue
            }

            await scheduleSingleNotification(
                for: item,
                at: notifyDate,
                settings: settings,
                suffix: "day\(daysBefore)",
                message: singleNotificationMessage(for: item.name, daysBefore: daysBefore)
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
        let identifiers = (0...365).map { "\(item.id.uuidString)-day\($0)" }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
    /// すべての通知をキャンセル
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
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

    private func scheduledNotificationDate(
        for daysBefore: Int,
        nextLowerDays: Int?,
        daysUntilExpiry: Int,
        today: Date,
        expiryDate: Date,
        calendar: Calendar
    ) -> Date? {
        if daysBefore == 0 {
            return daysUntilExpiry == 0 ? today : expiryDate
        }

        if daysUntilExpiry <= daysBefore {
            let lowerBound = nextLowerDays ?? -1
            if daysUntilExpiry > lowerBound {
                return today
            }
            return nil
        }

        return calendar.date(byAdding: .day, value: -daysBefore, to: expiryDate)
    }

    private func notificationDisplayText(for daysBefore: Int) -> String {
        daysBefore == 0 ? "当日" : "\(daysBefore)日前"
    }

    private func singleNotificationMessage(for itemName: String, daysBefore: Int) -> String {
        if daysBefore == 0 {
            return "「\(itemName)」の期限は本日です"
        }
        return "「\(itemName)」の期限が近づいています（\(daysBefore)日前のお知らせ）"
    }
}
