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

    private static let amountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.generatesDecimalNumbers = false
        formatter.zeroSymbol = "0"
        return formatter
    }()
    
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
                    if settings.notificationTimingRules.isEmpty {
                        Text("通知タイミングは未設定です")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(settings.notificationTimingRules.enumerated()), id: \.offset) { index, rule in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("通知タイミング \(index + 1)")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Button("削除", role: .destructive) {
                                        settings.removeNotificationTimingRule(at: index)
                                        persistSettingsAndReschedule(settings)
                                    }
                                    .disabled(!settings.isEnabled)
                                }

                                HStack(alignment: .center, spacing: 12) {
                                    TextField(
                                        "数値",
                                        value: Binding(
                                            get: {
                                                currentTimingRule(at: index, settings: settings).amount
                                            },
                                            set: { newValue in
                                                settings.updateNotificationTimingAmount(at: index, to: newValue)
                                                persistSettingsAndReschedule(settings)
                                            }
                                        ),
                                        formatter: Self.amountFormatter
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 88)
                                    .disabled(!settings.isEnabled)

                                    Text("単位")
                                        .foregroundStyle(.secondary)

                                    Spacer(minLength: 0)
                                }

                                Picker(
                                    "通知単位",
                                    selection: Binding(
                                        get: {
                                            currentTimingRule(at: index, settings: settings).unit
                                        },
                                        set: { newValue in
                                            settings.updateNotificationTimingUnit(at: index, to: newValue)
                                            persistSettingsAndReschedule(settings)
                                        }
                                    )
                                ) {
                                    ForEach(NotificationTimingUnit.allCases) { unit in
                                        Text(unit.shortLabel).tag(unit)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .disabled(!settings.isEnabled)

                                Text(notificationTimingLabel(for: rule))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("通知タイミングを追加") {
                        settings.addNotificationTimingRule()
                        persistSettingsAndReschedule(settings)
                    }
                    .disabled(!settings.isEnabled || settings.notificationTimingRules.count >= NotificationSettings.maximumTimingRules)
                } header: {
                    Text("通知タイミング（\(settings.notificationTimingRules.count)/\(NotificationSettings.maximumTimingRules)）")
                } footer: {
                    Text("通知タイミングは年・ヶ月・日単位で自由に追加できます。最大\(NotificationSettings.maximumTimingRules)件まで設定でき、0日前は当日通知です。")
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
            if existing.migrateLegacyTimingRulesIfNeeded() {
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

    private func currentTimingRule(at index: Int, settings: NotificationSettings) -> NotificationTimingRule {
        let timings = settings.notificationTimingRules
        guard timings.indices.contains(index) else {
            return NotificationTimingRule(amount: 0, unit: .day)
        }
        return timings[index]
    }

    private func notificationTimingLabel(for rule: NotificationTimingRule) -> String {
        let normalizedRule = rule.normalizedRule
        if normalizedRule.unit == .day && normalizedRule.amount == 0 {
            return "当日に通知"
        }
        return "\(normalizedRule.displayText)に通知"
    }

    private func persistSettingsAndReschedule(_ settings: NotificationSettings) {
        _ = settings.migrateLegacyTimingRulesIfNeeded()
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
