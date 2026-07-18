import SwiftUI
import SwiftData
import UserNotifications

/// 通知設定画面
struct NotificationSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    @StateObject private var notificationManager = NotificationManager.shared
    @Query private var items: [Item]
    @State private var settings: NotificationSettings?
    @State private var currentSystemSettings: UNNotificationSettings?
    @State private var timingInputTexts: [Int: String] = [:]
    @State private var lastFocusedTimingIndex: Int?
    @FocusState private var focusedTimingIndex: Int?

    private var notificationTimingSectionFooter: String {
        if premiumAccessManager.hasPremiumAccess {
            return L10n.format(
                "通知タイミングは日・週・月単位で設定できます。最大%@件まで追加でき、0日は当日通知です。",
                String(NotificationSettings.maximumTimingRules)
            )
        }

        return L10n.format(
            "無料版では通知タイミングは%@件までです。有料版では最大%@件まで追加できます。0日は当日通知です。",
            String(NotificationSettings.freeTimingRulesLimit),
            String(NotificationSettings.maximumTimingRules)
        )
    }
    
    var body: some View {
        Form {
            if let settings {
                // 通知権限セクション（スクリーンショット撮影時は未許可状態の警告表示を避けるため非表示）
                if !ScreenshotMode.isActive {
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
                        ForEach(Array(settings.notificationTimingRules.enumerated()), id: \.offset) { index, _ in
                            let currentRule = currentTimingRule(at: index, settings: settings)

                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(notificationTimingLabel(for: currentRule))
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button("削除", role: .destructive) {
                                        lastFocusedTimingIndex = nil
                                        settings.removeNotificationTimingRule(at: index)
                                        focusedTimingIndex = nil
                                        persistSettingsAndReschedule(settings)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(!settings.isEnabled)
                                }

                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .center, spacing: 12) {
                                        timingAmountField(at: index, settings: settings)
                                        timingUnitPicker(at: index, settings: settings, currentRule: currentRule)
                                    }

                                    VStack(alignment: .leading, spacing: 12) {
                                        timingAmountField(at: index, settings: settings)
                                        timingUnitPicker(at: index, settings: settings, currentRule: currentRule)
                                    }
                                }
                            }
                        }
                    }

                    Button("通知タイミングを追加") {
                        addNotificationTimingRule(for: settings)
                    }
                    .disabled(!settings.isEnabled || reachedNotificationTimingMaximum(for: settings))
                } header: {
                    Text(notificationTimingSectionTitle(for: settings))
                } footer: {
                    Text(notificationTimingSectionFooter)
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
        .localizedRefresh()
        .task {
            ensureSettingsLoaded()
        }
        .onAppear {
            Task {
                await refreshSystemSettings()
            }
        }
        .onChange(of: settings?.notificationTimingSignature ?? "") { _, _ in
            syncTimingInputTexts()
        }
        .onChange(of: focusedTimingIndex) { _, newValue in
            if let previousIndex = lastFocusedTimingIndex,
               previousIndex != newValue,
               let settings {
                commitTimingInput(at: previousIndex, settings: settings)
            }
            lastFocusedTimingIndex = newValue
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") {
                    if let settings, let focusedTimingIndex {
                        commitTimingInput(at: focusedTimingIndex, settings: settings)
                    }
                    focusedTimingIndex = nil
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
        case .authorized: return L10n.string("許可済み")
        case .denied: return L10n.string("拒否")
        case .provisional: return L10n.string("仮許可")
        case .ephemeral: return L10n.string("一時的")
        case .notDetermined: return L10n.string("未設定")
        @unknown default: return L10n.string("不明")
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
        guard let currentSystemSettings else { return L10n.string("確認中...") }
        switch currentSystemSettings.soundSetting {
        case .enabled:
            return L10n.string("有効")
        case .disabled:
            return L10n.string("無効")
        case .notSupported:
            return L10n.string("未対応")
        @unknown default:
            return L10n.string("不明")
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
            syncTimingInputTexts(from: existing)
            return
        }
        
        let newSettings = NotificationSettings.createDefault(isPremium: premiumAccessManager.hasPremiumAccess)
        modelContext.insert(newSettings)
        try? modelContext.save()
        settings = newSettings
        syncTimingInputTexts(from: newSettings)
    }

    private func notificationTimingSectionTitle(for settings: NotificationSettings) -> String {
        L10n.format(
            "通知タイミング（%@/%@）",
            String(settings.notificationTimingRules.count),
            String(allowedTimingRuleCount(for: settings))
        )
    }

    private func allowedTimingRuleCount(for settings: NotificationSettings) -> Int {
        if premiumAccessManager.hasPremiumAccess {
            return NotificationSettings.maximumTimingRules
        }
        return max(NotificationSettings.freeTimingRulesLimit, settings.notificationTimingRules.count)
    }

    private func canAddNotificationTiming(for settings: NotificationSettings) -> Bool {
        if premiumAccessManager.hasPremiumAccess {
            return settings.notificationTimingRules.count < NotificationSettings.maximumTimingRules
        }
        return premiumAccessManager.canAddNotificationTiming(currentCount: settings.notificationTimingRules.count)
    }

    private func reachedNotificationTimingMaximum(for settings: NotificationSettings) -> Bool {
        premiumAccessManager.hasPremiumAccess
            && settings.notificationTimingRules.count >= NotificationSettings.maximumTimingRules
    }

    private func addNotificationTimingRule(for settings: NotificationSettings) {
        guard settings.isEnabled else { return }

        if canAddNotificationTiming(for: settings) {
            settings.addNotificationTimingRule(maximumCount: allowedTimingRuleCount(for: settings))
            focusedTimingIndex = nil
            persistSettingsAndReschedule(settings)
            return
        }

        premiumAccessManager.presentPaywall(for: .notificationTimingLimit) {
            settings.addNotificationTimingRule(maximumCount: self.allowedTimingRuleCount(for: settings))
            self.focusedTimingIndex = nil
            self.persistSettingsAndReschedule(settings)
        }
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
            return L10n.string("当日に通知")
        }
        return L10n.format("%@に通知", normalizedRule.displayText)
    }

    private func timingAmountField(at index: Int, settings: NotificationSettings) -> some View {
        TextField("0", text: Binding(
            get: {
                timingInputText(at: index, settings: settings)
            },
            set: { newValue in
                updateTimingInputText(newValue, at: index)
            }
        ))
        .keyboardType(.numberPad)
        .multilineTextAlignment(.trailing)
        .textFieldStyle(.roundedBorder)
        .frame(width: 72)
        .focused($focusedTimingIndex, equals: index)
        .disabled(!settings.isEnabled)
    }

    private func timingUnitPicker(
        at index: Int,
        settings: NotificationSettings,
        currentRule: NotificationTimingRule
    ) -> some View {
        Picker(
            "通知単位",
            selection: Binding(
                get: {
                    currentRule.unit
                },
                set: { newValue in
                    commitTimingInput(at: index, settings: settings)
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
        .layoutPriority(1)
    }

    private func timingInputText(at index: Int, settings: NotificationSettings) -> String {
        if let currentText = timingInputTexts[index] {
            return currentText
        }
        return String(currentTimingRule(at: index, settings: settings).amount)
    }

    private func updateTimingInputText(_ value: String, at index: Int) {
        let digitsOnly = String(value.filter(\.isNumber).prefix(2))
        timingInputTexts[index] = digitsOnly
    }

    private func commitTimingInput(at index: Int, settings: NotificationSettings) {
        let currentRule = currentTimingRule(at: index, settings: settings)
        guard settings.notificationTimingRules.indices.contains(index) else { return }

        let rawValue = timingInputTexts[index] ?? String(currentRule.amount)
        let parsedAmount = Int(rawValue) ?? currentRule.unit.minimumAmount
        let normalizedAmount = min(
            max(parsedAmount, currentRule.unit.minimumAmount),
            currentRule.unit.maximumAmount
        )

        if currentRule.amount != normalizedAmount {
            settings.updateNotificationTimingAmount(at: index, to: normalizedAmount)
            persistSettingsAndReschedule(settings)
            return
        }

        timingInputTexts[index] = String(normalizedAmount)
    }

    private func syncTimingInputTexts() {
        guard let settings else { return }
        syncTimingInputTexts(from: settings)
    }

    private func syncTimingInputTexts(from settings: NotificationSettings) {
        let rules = settings.notificationTimingRules
        var syncedTexts: [Int: String] = [:]
        for (index, rule) in rules.enumerated() {
            syncedTexts[index] = String(rule.amount)
        }
        timingInputTexts = syncedTexts
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
        syncTimingInputTexts(from: settings)
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
    .environment(PremiumAccessManager.shared)
    .modelContainer(for: [NotificationSettings.self, Item.self], inMemory: true)
}
