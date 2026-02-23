import SwiftUI
import SwiftData
import UserNotifications

/// 通知設定画面
struct NotificationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var notificationManager = NotificationManager.shared
    @Query private var items: [Item]
    @State private var settings: NotificationSettings?
    
    @State private var showPendingNotifications = false
    @State private var pendingNotifications: [UNNotificationRequest] = []
    @State private var deliveredNotifications: [UNNotification] = []
    @State private var isSchedulingTestNotification = false
    @State private var testNotificationAlertMessage: String?
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
                
                // スケジュール済み通知（デバッグ用）
                Section {
                    Button("スケジュール済み通知を確認") {
                        Task {
                            await refreshNotificationDebugList()
                            showPendingNotifications = true
                        }
                    }
                    
                    Button("テスト通知（5秒後）") {
                        Task {
                            await sendTestNotification()
                        }
                    }
                    .disabled(isSchedulingTestNotification)
                    
                    Button("すべての通知を再スケジュール") {
                        rescheduleNotifications(settings: settings)
                    }
                } header: {
                    Text("デバッグ")
                } footer: {
                    #if targetEnvironment(simulator)
                    Text("シミュレーターでは通知音が鳴らない場合があります。音の確認は実機で行ってください。")
                    #else
                    Text("端末がサイレント/集中モード中の場合、通知音が鳴らないことがあります。")
                    #endif
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
        .sheet(isPresented: $showPendingNotifications) {
            NavigationStack {
                List {
                    Section("予約済み（Pending）") {
                        if pendingNotifications.isEmpty {
                            Text("予約済み通知はありません")
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

                    Section("配信済み（Delivered）") {
                        if deliveredNotifications.isEmpty {
                            Text("配信済み通知はありません")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(deliveredNotifications.enumerated()), id: \.offset) { _, notification in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(notification.request.content.body)
                                        .font(.subheadline)
                                    Text(notification.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("通知デバッグ一覧")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("更新") {
                            Task {
                                await refreshNotificationDebugList()
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") {
                            showPendingNotifications = false
                        }
                    }
                }
            }
        }
        .alert(
            "テスト通知",
            isPresented: Binding(
                get: { testNotificationAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        testNotificationAlertMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                testNotificationAlertMessage = nil
            }
        } message: {
            Text(testNotificationAlertMessage ?? "")
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

    private func refreshNotificationDebugList() async {
        pendingNotifications = await notificationManager.getPendingNotifications()
        deliveredNotifications = await notificationManager.getDeliveredNotifications()
    }
    
    private func sendTestNotification() async {
        isSchedulingTestNotification = true
        defer { isSchedulingTestNotification = false }
        
        let authorizationStatus = currentSystemSettings?.authorizationStatus ?? notificationManager.authorizationStatus
        if authorizationStatus == .notDetermined {
            _ = await notificationManager.requestAuthorization()
        }

        await refreshSystemSettings()
        let status = currentSystemSettings?.authorizationStatus ?? notificationManager.authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            testNotificationAlertMessage = "通知権限が未許可のため、テスト通知を送信できません。設定アプリで通知を許可してください。"
            return
        }

        if currentSystemSettings?.soundSetting == .disabled {
            testNotificationAlertMessage = "通知のサウンドがオフです。設定アプリ > 通知 > 備蓄品管理 で「サウンド」を有効にしてください。"
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "テスト通知"
        content.body = "通知が正常に動作しています！"
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "test-notification",
            content: content,
            trigger: trigger
        )
        
        do {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["test-notification"])
            center.removeDeliveredNotifications(withIdentifiers: ["test-notification"])
            try await center.add(request)
            print("✅ Test notification scheduled for 5 seconds later")
            #if targetEnvironment(simulator)
            testNotificationAlertMessage = "5秒後にテスト通知を予約しました。シミュレーターでは音が鳴らない場合があるため、実機でも確認してください。"
            #else
            testNotificationAlertMessage = "5秒後にテスト通知を予約しました。音が出ない場合は、本体の消音スイッチ・音量・集中モード・通知サウンド設定を確認してください。"
            #endif
        } catch {
            print("❌ Failed to schedule test notification: \(error)")
            testNotificationAlertMessage = "テスト通知の予約に失敗しました: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
    }
    .modelContainer(for: [NotificationSettings.self, Item.self], inMemory: true)
}
