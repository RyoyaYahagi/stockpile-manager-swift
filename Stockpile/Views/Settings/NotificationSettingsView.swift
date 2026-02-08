import SwiftUI
import SwiftData
import UserNotifications

/// 通知設定画面
struct NotificationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsArray: [NotificationSettings]
    @StateObject private var notificationManager = NotificationManager.shared
    @Query private var items: [Item]
    
    @State private var showPendingNotifications = false
    @State private var pendingNotifications: [UNNotificationRequest] = []
    
    private var settings: NotificationSettings {
        if let existing = settingsArray.first {
            return existing
        }
        let newSettings = NotificationSettings.createDefault()
        modelContext.insert(newSettings)
        return newSettings
    }
    
    var body: some View {
        Form {
            // 通知権限セクション
            Section {
                authorizationStatusRow
                
                if notificationManager.authorizationStatus == .notDetermined {
                    Button("通知を許可する") {
                        Task {
                            await notificationManager.requestAuthorization()
                        }
                    }
                } else if notificationManager.authorizationStatus == .denied {
                    Button("設定アプリを開く") {
                        openSettings()
                    }
                }
            } header: {
                Text("通知権限")
            } footer: {
                if notificationManager.authorizationStatus == .denied {
                    Text("通知を有効にするには、設定アプリから許可してください。")
                }
            }
            
            // 通知有効/無効
            Section {
                Toggle("通知を有効にする", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { newValue in
                        settings.isEnabled = newValue
                        rescheduleNotifications()
                    }
                ))
            }
            
            // 通知タイミング
            Section {
                Toggle("30日前に通知", isOn: Binding(
                    get: { settings.notify30DaysBefore },
                    set: { newValue in
                        settings.notify30DaysBefore = newValue
                        rescheduleNotifications()
                    }
                ))
                .disabled(!settings.isEnabled)
                
                Toggle("7日前に通知", isOn: Binding(
                    get: { settings.notify7DaysBefore },
                    set: { newValue in
                        settings.notify7DaysBefore = newValue
                        rescheduleNotifications()
                    }
                ))
                .disabled(!settings.isEnabled)
                
                Toggle("当日に通知", isOn: Binding(
                    get: { settings.notifyOnDay },
                    set: { newValue in
                        settings.notifyOnDay = newValue
                        rescheduleNotifications()
                    }
                ))
                .disabled(!settings.isEnabled)
            } header: {
                Text("通知タイミング")
            } footer: {
                Text("備蓄品の期限が近づくと通知でお知らせします。")
            }
            
            // 通知時刻
            Section {
                DatePicker(
                    "通知時刻",
                    selection: Binding(
                        get: { timeFromComponents() },
                        set: { newValue in
                            updateNotificationTime(from: newValue)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .disabled(!settings.isEnabled)
            } header: {
                Text("通知時刻")
            } footer: {
                Text("毎日この時刻に通知をお届けします。")
            }
            
            // スケジュール済み通知（デバッグ用）
            Section {
                Button("スケジュール済み通知を確認") {
                    Task {
                        pendingNotifications = await notificationManager.getPendingNotifications()
                        showPendingNotifications = true
                    }
                }
                
                Button("テスト通知（5秒後）") {
                    Task {
                        await sendTestNotification()
                    }
                }
                
                Button("すべての通知を再スケジュール") {
                    rescheduleNotifications()
                }
            } header: {
                Text("デバッグ")
            }
        }
        .navigationTitle("通知設定")
        .onAppear {
            Task {
                await notificationManager.refreshAuthorizationStatus()
            }
        }
        .sheet(isPresented: $showPendingNotifications) {
            NavigationStack {
                List {
                    if pendingNotifications.isEmpty {
                        Text("スケジュール済み通知はありません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pendingNotifications, id: \.identifier) { request in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(request.content.body)
                                    .font(.subheadline)
                                if let trigger = request.trigger as? UNCalendarNotificationTrigger,
                                   let nextDate = trigger.nextTriggerDate() {
                                    Text(nextDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("スケジュール済み通知")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") {
                            showPendingNotifications = false
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Views
    
    private var authorizationStatusRow: some View {
        HStack {
            Text("ステータス")
            Spacer()
            Text(statusText)
                .foregroundStyle(statusColor)
        }
    }
    
    private var statusText: String {
        switch notificationManager.authorizationStatus {
        case .authorized: return "許可済み"
        case .denied: return "拒否"
        case .provisional: return "仮許可"
        case .ephemeral: return "一時的"
        case .notDetermined: return "未設定"
        @unknown default: return "不明"
        }
    }
    
    private var statusColor: Color {
        switch notificationManager.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        @unknown default: return .secondary
        }
    }
    
    // MARK: - Helpers
    
    private func timeFromComponents() -> Date {
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = settings.notificationHour
        components.minute = settings.notificationMinute
        return calendar.date(from: components) ?? Date()
    }
    
    private func updateNotificationTime(from date: Date) {
        let calendar = Calendar.current
        settings.notificationHour = calendar.component(.hour, from: date)
        settings.notificationMinute = calendar.component(.minute, from: date)
        rescheduleNotifications()
    }
    
    private func rescheduleNotifications() {
        Task {
            await notificationManager.rescheduleAllNotifications(
                items: items,
                settings: settings
            )
        }
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "テスト通知"
        content.body = "通知が正常に動作しています！"
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "test-notification",
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("✅ Test notification scheduled for 5 seconds later")
        } catch {
            print("❌ Failed to schedule test notification: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
    .modelContainer(for: [NotificationSettings.self, Item.self], inMemory: true)
}
