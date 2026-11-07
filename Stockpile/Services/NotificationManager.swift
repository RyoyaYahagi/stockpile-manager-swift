import Foundation
import UserNotifications
import SwiftData

/// 通知アイテムと種類のペア
private struct NotificationItem {
    let item: Item
    let rule: NotificationTimingRule
    let ledgerKey: String
}

/// MainActor の外で通知を登録するための、値だけを持った通知
private struct ScheduledNotification: Sendable {
    enum Trigger: Sendable {
        case calendar(DateComponents)
        case timeInterval(TimeInterval)
    }

    enum UserInfo: Sendable {
        case singleItem(String)
        case multipleItems([String])

        var dictionary: [AnyHashable: Any] {
            switch self {
            case .singleItem(let itemId):
                return ["itemId": itemId]
            case .multipleItems(let itemIds):
                return ["itemIds": itemIds]
            }
        }
    }

    let identifier: String
    let title: String
    let body: String
    let userInfo: UserInfo
    let trigger: Trigger
    let effectiveDate: Date
}

/// 予定した通知の発火日時を端末に記録し、届け済みの通知を出し直さないようにする
struct NotificationLedger {
    private static let storageKey = "notificationLedger.fireDates"
    private var fireDates: [String: Date]

    init(fireDates: [String: Date] = [:]) {
        self.fireDates = fireDates
    }

    static func load(from defaults: UserDefaults = .standard) -> NotificationLedger {
        let raw = defaults.dictionary(forKey: storageKey) as? [String: Date] ?? [:]
        return NotificationLedger(fireDates: raw)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(fireDates, forKey: Self.storageKey)
    }

    /// 期限日が変われば別の通知として扱うよう、品目・タイミング・通知の基準日で区別する
    static func key(itemId: UUID, rule: NotificationTimingRule, thresholdDate: Date) -> String {
        let day = Int(thresholdDate.timeIntervalSince1970 / 86_400)
        return "\(itemId.uuidString)|\(rule.normalizedRule.serializedValue)|\(day)"
    }

    func hasDelivered(_ key: String, now: Date) -> Bool {
        guard let fireDate = fireDates[key] else { return false }
        return fireDate <= now
    }

    mutating func record(_ key: String, fireDate: Date) {
        fireDates[key] = fireDate
    }

    mutating func forgetPending(after date: Date) {
        fireDates = fireDates.filter { $0.value <= date }
    }

    mutating func prune(before date: Date) {
        fireDates = fireDates.filter { $0.value >= date }
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
    /// 直前に登録した通知の内容。変わっていなければ登録し直さない
    private var lastRescheduleSignature: String?
    private var isRescheduling = false
    private var pendingRescheduleRequest: (items: [Item], settings: NotificationSettings)?
    
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
        guard !ScreenshotMode.isActive else { return false }
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
    /// 実行中に次の要求が来たら、終わってから最新の内容で 1 回だけやり直す
    func rescheduleAllNotifications(items: [Item], settings: NotificationSettings) async {
        cancelPendingReschedule()
        if isRescheduling {
            pendingRescheduleRequest = (items, settings)
            return
        }
        isRescheduling = true
        defer { isRescheduling = false }

        var nextItems = items
        var nextSettings = settings
        while true {
            pendingRescheduleRequest = nil
            await performReschedule(items: nextItems, settings: nextSettings)
            guard let pending = pendingRescheduleRequest else { break }
            nextItems = pending.items
            nextSettings = pending.settings
        }
    }

    private func performReschedule(items: [Item], settings: NotificationSettings) async {
        guard settings.isEnabled else {
            lastRescheduleSignature = nil
            cancelAllNotifications()
            // 取り消した予定は届いていないので、記録からも外す
            var ledger = NotificationLedger.load()
            ledger.forgetPending(after: Date())
            ledger.save()
            return
        }

        let timingRules = settings.notificationTimingRules
        let signature = Self.rescheduleSignature(items: items, settings: settings)
        if signature == lastRescheduleSignature {
            return
        }

        cancelAllNotifications()
        guard await ensureAuthorizationForScheduling() else { return }
        guard !timingRules.isEmpty else { return }
        
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        
        // 今日の日付成分のみを取得（時刻を無視）
        let todayComponents = calendar.dateComponents([.year, .month, .day], from: Date())
        guard let today = calendar.date(from: todayComponents) else { return }
        let now = Date()
        var ledger = NotificationLedger.load()

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
            
            let scheduledRules = timingRules
                .compactMap { rule -> (rule: NotificationTimingRule, thresholdDate: Date)? in
                    guard let thresholdDate = notificationThresholdDate(
                        for: rule,
                        expiryDate: normalizedExpiryDate,
                        calendar: calendar
                    ) else {
                        return nil
                    }
                    return (rule: rule, thresholdDate: thresholdDate)
                }
                .sorted { $0.thresholdDate < $1.thresholdDate }

            for (index, scheduledRule) in scheduledRules.enumerated() {
                let nextThresholdDate = scheduledRules.dropFirst(index + 1).first?.thresholdDate
                guard let notifyDate = scheduledNotificationDate(
                    for: scheduledRule.rule,
                    thresholdDate: scheduledRule.thresholdDate,
                    nextThresholdDate: nextThresholdDate,
                    today: today,
                    expiryDate: normalizedExpiryDate
                ) else {
                    continue
                }

                let ledgerKey = NotificationLedger.key(
                    itemId: item.id,
                    rule: scheduledRule.rule,
                    thresholdDate: scheduledRule.thresholdDate
                )
                // 一度届けた通知は、アプリを開き直したり再スケジュールしたりしても出し直さない
                if ledger.hasDelivered(ledgerKey, now: now) {
                    continue
                }

                groupedNotifications[notifyDate, default: []].append(
                    NotificationItem(item: item, rule: scheduledRule.rule, ledgerKey: ledgerKey)
                )
            }
        }
        
        // 通知の組み立ては値だけにして、登録は MainActor の外で行う
        var scheduled: [(notification: ScheduledNotification, ledgerKeys: [String])] = []
        scheduled.reserveCapacity(groupedNotifications.count)
        for (notifyDate, notificationItems) in groupedNotifications {
            guard let notification = makeScheduledNotification(
                notificationItems: notificationItems,
                at: notifyDate,
                settings: settings
            ) else { continue }
            scheduled.append((notification, notificationItems.map(\.ledgerKey)))
        }

        let results = await Self.addScheduledNotifications(scheduled.map(\.notification))
        for (index, success) in results.enumerated() where success {
            let entry = scheduled[index]
            for ledgerKey in entry.ledgerKeys {
                ledger.record(ledgerKey, fireDate: entry.notification.effectiveDate)
            }
        }
        ledger.prune(before: calendar.date(byAdding: .year, value: -1, to: today) ?? today)
        ledger.save()
        // 登録に失敗したものがあれば、次の機会にやり直せるよう署名を残さない
        if results.allSatisfy({ $0 }) {
            lastRescheduleSignature = signature
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
            if settings.migrateLegacyTimingRulesIfNeeded() {
                try? modelContext.save()
            }
        } else {
            let created = NotificationSettings.createDefault(
                isPremium: PremiumAccessManager.shared.hasPremiumAccess
            )
            modelContext.insert(created)
            try? modelContext.save()
            settings = created
        }
        
        let itemDescriptor = FetchDescriptor<Item>()
        let allItems = (try? modelContext.fetch(itemDescriptor)) ?? []
        
        await rescheduleAllNotifications(items: allItems, settings: settings)
    }
    
    /// グループ化された通知を、MainActor の外に渡せる値に組み立てる
    private func makeScheduledNotification(
        notificationItems: [NotificationItem],
        at date: Date,
        settings: NotificationSettings
    ) -> ScheduledNotification? {
        let (title, body) = generateNotificationContent(notificationItems: notificationItems)

        // 複数アイテムの場合はitemIdsを配列で渡す
        let allItemIds = notificationItems.map { $0.item.id.uuidString }
        let userInfo: ScheduledNotification.UserInfo = allItemIds.count == 1
            ? .singleItem(allItemIds[0])
            : .multipleItems(allItemIds)

        // 通知時刻を設定
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current

        var dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dateComponents.hour = settings.notificationHour
        dateComponents.minute = settings.notificationMinute

        // 実際の通知発火日時を計算
        guard let scheduledDate = calendar.date(from: dateComponents) else {
            debugLog("⚠️ Failed to create scheduled date")
            return nil
        }

        let now = Date()
        let trigger: ScheduledNotification.Trigger
        let effectiveScheduledDate: Date
        if scheduledDate > now {
            trigger = .calendar(dateComponents)
            effectiveScheduledDate = scheduledDate
        } else if calendar.isDate(date, inSameDayAs: now) {
            // 追加直後などで当日通知時刻を過ぎていた場合、通知を取りこぼさないよう近い将来にフォールバックする
            trigger = .timeInterval(immediateFallbackInterval)
            effectiveScheduledDate = now.addingTimeInterval(immediateFallbackInterval)
        } else {
            debugLog("⚠️ Skipped grouped notification - \(formatDate(scheduledDate)) is in the past")
            return nil
        }

        // 日付でユニークなidentifierを生成
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let identifier = "grouped-\(dateFormatter.string(from: date))"

        return ScheduledNotification(
            identifier: identifier,
            title: title,
            body: body,
            userInfo: userInfo,
            trigger: trigger,
            effectiveDate: effectiveScheduledDate
        )
    }

    /// 通知の登録は待ち時間が長いため、MainActor を塞がないよう外で順番に行う
    nonisolated private static func addScheduledNotifications(
        _ notifications: [ScheduledNotification]
    ) async -> [Bool] {
        let center = UNUserNotificationCenter.current()
        var results: [Bool] = []
        results.reserveCapacity(notifications.count)
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.sound = .default
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }
            content.title = notification.title
            content.body = notification.body
            content.userInfo = notification.userInfo.dictionary

            let trigger: UNNotificationTrigger
            switch notification.trigger {
            case .calendar(let components):
                trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            case .timeInterval(let interval):
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            }

            let request = UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                results.append(true)
            } catch {
                results.append(false)
            }
        }
        return results
    }

    /// 通知の内容が変わったかを見るための署名。同じなら登録し直さない
    private static func rescheduleSignature(
        items: [Item],
        settings: NotificationSettings
    ) -> String {
        var hasher = Hasher()
        hasher.combine(settings.notificationTimingSignature)
        hasher.combine(settings.notificationHour)
        hasher.combine(settings.notificationMinute)
        // 表示言語が変わると通知文も変わるため、言語も含める
        hasher.combine(AppLanguage.current.rawValue)
        hasher.combine(AppLanguage.currentLanguageCandidates.first ?? "")
        // 日付が変わると通知対象が変わるため、その日も含める
        hasher.combine(Calendar.current.startOfDay(for: Date()))
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.expiryDate)
            hasher.combine(item.name)
        }
        return String(hasher.finalize())
    }

    /// 通知内容を生成（日付ごとにグループ化、種類別に表示）
    private func generateNotificationContent(notificationItems: [NotificationItem]) -> (title: String, body: String) {
        let totalCount = notificationItems.count
        
        // 種類ごとにグループ化
        var byRule: [NotificationTimingRule: [Item]] = [:]
        for ni in notificationItems {
            byRule[ni.rule, default: []].append(ni.item)
        }
        
        if totalCount == 1 {
            let ni = notificationItems[0]
            return (
                title: L10n.string("備蓄品の期限通知"),
                body: singleNotificationMessage(for: ni.item.name, rule: ni.rule)
            )
        } else {
            let title = L10n.format("備蓄品の期限通知（%@件）", String(totalCount))
            
            // 種類順にソートして表示
            let sortedRules = sortNotificationRules(Array(byRule.keys))
            var parts: [String] = []
            
            for rule in sortedRules {
                guard let items = byRule[rule] else { continue }
                let names = items.prefix(2).map { $0.name }.joined(separator: "、")
                let suffix = items.count > 2 ? L10n.string("他") : ""
                parts.append(L10n.format("%@: %@%@", notificationDisplayText(for: rule), names, suffix))
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
        let timingRules = settings.notificationTimingRules
        guard !timingRules.isEmpty else { return }
        
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
        
        let scheduledRules = timingRules
            .compactMap { rule -> (rule: NotificationTimingRule, thresholdDate: Date)? in
                guard let thresholdDate = notificationThresholdDate(
                    for: rule,
                    expiryDate: normalizedExpiryDate,
                    calendar: calendar
                ) else {
                    return nil
                }
                return (rule: rule, thresholdDate: thresholdDate)
            }
            .sorted { $0.thresholdDate < $1.thresholdDate }

        for (index, scheduledRule) in scheduledRules.enumerated() {
            let nextThresholdDate = scheduledRules.dropFirst(index + 1).first?.thresholdDate
            guard let notifyDate = scheduledNotificationDate(
                for: scheduledRule.rule,
                thresholdDate: scheduledRule.thresholdDate,
                nextThresholdDate: nextThresholdDate,
                today: today,
                expiryDate: normalizedExpiryDate
            ) else {
                continue
            }

            await scheduleSingleNotification(
                for: item,
                at: notifyDate,
                settings: settings,
                suffix: scheduledRule.rule.serializedValue,
                message: singleNotificationMessage(for: item.name, rule: scheduledRule.rule)
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
        content.title = L10n.string("備蓄品の期限通知")
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
        let prefix = "\(item.id.uuidString)-"
        let pendingIdentifiers = await pendingNotificationIdentifiers()
        let identifiers = pendingIdentifiers
            .filter { $0.hasPrefix(prefix) }
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

    private func notificationThresholdDate(
        for rule: NotificationTimingRule,
        expiryDate: Date,
        calendar: Calendar
    ) -> Date? {
        let normalizedRule = rule.normalizedRule
        if normalizedRule.unit == .day && normalizedRule.amount == 0 {
            return expiryDate
        }

        switch normalizedRule.unit {
        case .day:
            return calendar.date(
                byAdding: .day,
                value: -normalizedRule.amount,
                to: expiryDate
            )
        case .week:
            return calendar.date(
                byAdding: .day,
                value: -(normalizedRule.amount * 7),
                to: expiryDate
            )
        case .month:
            return calendar.date(
                byAdding: .month,
                value: -normalizedRule.amount,
                to: expiryDate
            )
        }
    }

    private func scheduledNotificationDate(
        for rule: NotificationTimingRule,
        thresholdDate: Date,
        nextThresholdDate: Date?,
        today: Date,
        expiryDate: Date
    ) -> Date? {
        if today < thresholdDate {
            return thresholdDate
        }

        if let nextThresholdDate {
            if today < nextThresholdDate {
                return today
            }
            return nil
        }

        let normalizedRule = rule.normalizedRule
        if normalizedRule.unit == .day && normalizedRule.amount == 0 {
            return today == expiryDate ? today : nil
        }
        return today <= expiryDate ? today : nil
    }

    private func notificationDisplayText(for rule: NotificationTimingRule) -> String {
        rule.displayText
    }

    private func singleNotificationMessage(for itemName: String, rule: NotificationTimingRule) -> String {
        let normalizedRule = rule.normalizedRule
        if normalizedRule.unit == .day && normalizedRule.amount == 0 {
            return L10n.format("「%@」の期限は本日です", itemName)
        }
        return L10n.format("「%@」の期限が近づいています（%@のお知らせ）", itemName, normalizedRule.displayText)
    }

    private func sortNotificationRules(_ rules: [NotificationTimingRule]) -> [NotificationTimingRule] {
        rules.sorted {
            if $0.sortWeight == $1.sortWeight {
                return $0.unit.approximateDays < $1.unit.approximateDays
            }
            return $0.sortWeight < $1.sortWeight
        }
    }

    private func pendingNotificationIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
    }
}
