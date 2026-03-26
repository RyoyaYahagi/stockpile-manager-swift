import SwiftUI
import SwiftData
import UserNotifications

/// 通知設定画面
struct NotificationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var notificationManager = NotificationManager.shared
    @Query private var items: [Item]
    @State private var settings: NotificationSettings?
    @State private var currentSystemSettings: UNNotificationSettings?
    
    var body: some View {
        Form {
            if let settings {
                // 通知権限セクション
                Section {
                    authorizationStatusRow
                    soundStatusRow
                    
                    if notificationManager.authorizationStatus == .notDetermined {
                        Button("通知を許可する") {
                            Task {
                                _ = await notificationManager.requestAuthorization()
                                await refreshSystemSettings()
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
                            rescheduleNotifications(settings: settings)
                        }
                    ))
                }
                
                // 通知タイミング
                Section {
                    Toggle("30日前に通知", isOn: Binding(
                        get: { settings.notify30DaysBefore },
                        set: { newValue in
                            settings.notify30DaysBefore = newValue
                            rescheduleNotifications(settings: settings)
                        }
                    ))
                    .disabled(!settings.isEnabled)
                    
                    Toggle("7日前に通知", isOn: Binding(
                        get: { settings.notify7DaysBefore },
                        set: { newValue in
                            settings.notify7DaysBefore = newValue
                            rescheduleNotifications(settings: settings)
                        }
                    ))
                    .disabled(!settings.isEnabled)
                    
                    Toggle("当日に通知", isOn: Binding(
                        get: { settings.notifyOnDay },
                        set: { newValue in
                            settings.notifyOnDay = newValue
                            rescheduleNotifications(settings: settings)
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
                            get: { timeFromComponents(using: settings) },
                            set: { newValue in
                                updateNotificationTime(from: newValue, settings: settings)
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
                
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("設定を読み込み中...")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("通知設定")
        .task {
            ensureSettingsLoaded()
        }
        .onAppear {
            Task {
                await refreshSystemSettings()
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

    private var soundStatusRow: some View {
        HStack {
            Text("サウンド")
            Spacer()
            Text(soundStatusText)
                .foregroundStyle(soundStatusColor)
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

    private var soundStatusText: String {
        guard let currentSystemSettings else { return "確認中..." }
        switch currentSystemSettings.soundSetting {
        case .enabled:
            return "有効"
        case .disabled:
            return "無効"
        case .notSupported:
            return "未対応"
        @unknown default:
            return "不明"
        }
    }

    private var soundStatusColor: Color {
        guard let currentSystemSettings else { return .secondary }
        switch currentSystemSettings.soundSetting {
        case .enabled:
            return .green
        case .disabled:
            return .red
        case .notSupported:
            return .orange
        @unknown default:
            return .secondary
        }
    }
    
    // MARK: - Helpers
    
    private func ensureSettingsLoaded() {
        guard settings == nil else { return }
        
        let descriptor = FetchDescriptor<NotificationSettings>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        
        if let existing = try? modelContext.fetch(descriptor).first {
            settings = existing
            return
        }
        
        let newSettings = NotificationSettings.createDefault()
        modelContext.insert(newSettings)
        settings = newSettings
    }
    
    private func timeFromComponents(using settings: NotificationSettings) -> Date {
        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = settings.notificationHour
        components.minute = settings.notificationMinute
        return calendar.date(from: components) ?? Date()
    }
    
    private func updateNotificationTime(from date: Date, settings: NotificationSettings) {
        let calendar = Calendar.current
        settings.notificationHour = calendar.component(.hour, from: date)
        settings.notificationMinute = calendar.component(.minute, from: date)
        rescheduleNotifications(settings: settings)
    }
    
    private func rescheduleNotifications(settings: NotificationSettings) {
        notificationManager.requestReschedule(items: items, settings: settings)
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func refreshSystemSettings() async {
        let settings = await notificationManager.currentNotificationSettings()
        currentSystemSettings = settings
        await notificationManager.refreshAuthorizationStatus()
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
    .modelContainer(for: [NotificationSettings.self, Item.self], inMemory: true)
}
