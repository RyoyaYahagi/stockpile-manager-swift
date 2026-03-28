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
                            persistSettingsAndReschedule(settings)
                        }
                    ))
                }
                
                // 通知タイミング
                Section {
                    if settings.notificationTimingDays.isEmpty {
                        Text("通知タイミングは未設定です")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(settings.notificationTimingDays.enumerated()), id: \.offset) { index, timingDay in
                            HStack(spacing: 12) {
                                Stepper(
                                    value: Binding(
                                        get: {
                                            currentTimingDay(at: index, settings: settings)
                                        },
                                        set: { newValue in
                                            settings.updateNotificationTimingDay(at: index, to: newValue)
                                            persistSettingsAndReschedule(settings)
                                        }
                                    ),
                                    in: 0...365
                                ) {
                                    Text(notificationTimingLabel(for: timingDay))
                                }
                                .disabled(!settings.isEnabled)

                                Button(role: .destructive) {
                                    settings.removeNotificationTimingDay(at: index)
                                    persistSettingsAndReschedule(settings)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .disabled(!settings.isEnabled)
                                .accessibilityLabel("通知タイミングを削除")
                            }
                        }
                    }

                    Button {
                        settings.addNotificationTimingDay()
                        persistSettingsAndReschedule(settings)
                    } label: {
                        Label("通知タイミングを追加", systemImage: "plus.circle")
                    }
                    .disabled(!settings.isEnabled)
                } header: {
                    Text("通知タイミング")
                } footer: {
                    Text("期限の何日前に通知するかを自由に追加できます。0日前は当日通知です。")
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
            if existing.migrateLegacyTimingDaysIfNeeded() {
                try? modelContext.save()
            }
            settings = existing
            return
        }
        
        let newSettings = NotificationSettings.createDefault()
        modelContext.insert(newSettings)
        try? modelContext.save()
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
        persistSettingsAndReschedule(settings)
    }
    
    private func rescheduleNotifications(settings: NotificationSettings) {
        notificationManager.requestReschedule(items: items, settings: settings)
    }

    private func currentTimingDay(at index: Int, settings: NotificationSettings) -> Int {
        let timings = settings.notificationTimingDays
        guard timings.indices.contains(index) else { return 0 }
        return timings[index]
    }

    private func notificationTimingLabel(for daysBefore: Int) -> String {
        daysBefore == 0 ? "当日に通知" : "\(daysBefore)日前に通知"
    }

    private func persistSettingsAndReschedule(_ settings: NotificationSettings) {
        _ = settings.migrateLegacyTimingDaysIfNeeded()
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("通知設定の保存に失敗: \(error)")
            #endif
        }
        rescheduleNotifications(settings: settings)
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
