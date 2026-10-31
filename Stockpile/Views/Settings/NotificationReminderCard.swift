import SwiftUI
import SwiftData
import UserNotifications

/// 設定タブの「お知らせ」カード。通知の有効／無効、通知タイミング、通知時刻をその場で変更できる
struct NotificationReminderCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    @StateObject private var notificationManager = NotificationManager.shared
    @Query(sort: \NotificationSettings.createdAt) private var allSettings: [NotificationSettings]
    @Query private var items: [Item]

    /// チップに常に並べる通知タイミングの選択肢
    private static let presetRules: [NotificationTimingRule] = [
        NotificationTimingRule(amount: 0, unit: .day),
        NotificationTimingRule(amount: 3, unit: .day),
        NotificationTimingRule(amount: 1, unit: .week),
        NotificationTimingRule(amount: 1, unit: .month),
        NotificationTimingRule(amount: 3, unit: .month),
    ]

    private var settings: NotificationSettings? { allSettings.first }

    var body: some View {
        SettingsCard {
            VStack(spacing: 0) {
                toggleRow

                if showsPermissionNotice {
                    SettingsDivider()
                    permissionNotice
                }

                if let settings, settings.isEnabled {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 0) {
                        timingSection(settings: settings)
                        timeRow(settings: settings)
                    }
                    .transition(.opacity)
                }
            }
            .clipped()
            .animation(AppTheme.accordionAnimation, value: settings?.isEnabled ?? false)
        }
        .task {
            ensureSettingsLoaded()
            await notificationManager.refreshAuthorizationStatus()
        }
    }

    // MARK: - Rows

    private var toggleRow: some View {
        HStack(spacing: 14) {
            SettingsIconTile(symbol: "bell.fill", tint: AppTheme.color(for: .imminent))

            VStack(alignment: .leading, spacing: 2) {
                Text("賞味期限のお知らせ")
                    .font(.body.weight(.bold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text("期限が近づく備蓄をお知らせします")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle(
                "賞味期限のお知らせ",
                isOn: Binding(
                    get: { settings?.isEnabled ?? false },
                    set: { newValue in
                        guard let settings else { return }
                        settings.isEnabled = newValue
                        persistSettingsAndReschedule(settings)
                    }
                )
            )
            .labelsHidden()
            .tint(AppTheme.accent)
            .disabled(settings == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 64)
    }

    private var showsPermissionNotice: Bool {
        guard !ScreenshotMode.isActive else { return false }
        switch notificationManager.authorizationStatus {
        case .denied, .notDetermined: return true
        default: return false
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            if notificationManager.authorizationStatus == .denied {
                Text("通知を有効にするには、設定アプリから許可してください。")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.color(for: .expired))
                    .fixedSize(horizontal: false, vertical: true)
                Button("設定アプリを開く") {
                    openSettings()
                }
                .buttonStyle(SecondaryActionButtonStyle())
            } else {
                Button("通知を許可する") {
                    Task {
                        _ = await notificationManager.requestAuthorization()
                        await notificationManager.refreshAuthorizationStatus()
                    }
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func timingSection(settings: NotificationSettings) -> some View {
        let selected = settings.notificationTimingRules
        let chips = chipRules(selected: selected)

        return VStack(alignment: .leading, spacing: 12) {
            Text("いつ知らせる？（複数選べます）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            ChipFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(chips, id: \.serializedValue) { rule in
                    TimingChip(
                        title: rule.displayText,
                        isSelected: selected.contains(rule.normalizedRule)
                    ) {
                        toggle(rule, settings: settings)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeRow(settings: NotificationSettings) -> some View {
        HStack(spacing: 12) {
            Text("通知する時刻")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            DatePicker(
                "通知する時刻",
                selection: Binding(
                    get: { timeFromComponents(using: settings) },
                    set: { updateNotificationTime(from: $0, settings: settings) }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .tint(AppTheme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(minHeight: 44)
    }

    // MARK: - Timing logic

    /// 既定の選択肢と、すでに設定されている（既定以外の）ルールを日数順に並べる
    private func chipRules(selected: [NotificationTimingRule]) -> [NotificationTimingRule] {
        var rules = Self.presetRules
        for rule in selected.map(\.normalizedRule) where !rules.contains(rule) {
            rules.append(rule)
        }
        return rules.sorted { $0.sortWeight < $1.sortWeight }
    }

    private func toggle(_ rule: NotificationTimingRule, settings: NotificationSettings) {
        let current = settings.notificationTimingRules

        if let index = current.firstIndex(of: rule.normalizedRule) {
            settings.removeNotificationTimingRule(at: index)
            persistSettingsAndReschedule(settings)
            return
        }

        if canAddNotificationTiming(for: settings) {
            addRule(rule, to: settings)
            return
        }

        premiumAccessManager.presentPaywall(for: .notificationTimingLimit) {
            self.addRule(rule, to: settings)
        }
    }

    private func addRule(_ rule: NotificationTimingRule, to settings: NotificationSettings) {
        let current = settings.notificationTimingRules
        guard current.count < NotificationSettings.maximumTimingRules else { return }
        settings.notificationTimingRules = current + [rule]
        persistSettingsAndReschedule(settings)
    }

    private func canAddNotificationTiming(for settings: NotificationSettings) -> Bool {
        if premiumAccessManager.hasPremiumAccess {
            return settings.notificationTimingRules.count < NotificationSettings.maximumTimingRules
        }
        return premiumAccessManager.canAddNotificationTiming(currentCount: settings.notificationTimingRules.count)
    }

    // MARK: - Settings persistence（NotificationSettingsView と同じ処理）

    private func ensureSettingsLoaded() {
        guard allSettings.isEmpty else {
            if let existing = allSettings.first, existing.migrateLegacyTimingRulesIfNeeded() {
                try? modelContext.save()
            }
            return
        }
        let newSettings = NotificationSettings.createDefault(isPremium: premiumAccessManager.hasPremiumAccess)
        modelContext.insert(newSettings)
        try? modelContext.save()
    }

    private func timeFromComponents(using settings: NotificationSettings) -> Date {
        var components = DateComponents()
        components.hour = settings.notificationHour
        components.minute = settings.notificationMinute
        return Calendar.current.date(from: components) ?? Date()
    }

    private func updateNotificationTime(from date: Date, settings: NotificationSettings) {
        let calendar = Calendar.current
        settings.notificationHour = calendar.component(.hour, from: date)
        settings.notificationMinute = calendar.component(.minute, from: date)
        persistSettingsAndReschedule(settings)
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
        notificationManager.requestReschedule(items: items, settings: settings)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Chip

private struct TimingChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.accentInk : AppTheme.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background {
                    Capsule()
                        .fill(isSelected ? AppTheme.accentSoft : AppTheme.softFill)
                }
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? AppTheme.accent : Color.clear, lineWidth: 1.5)
                }
                .contentShape(Capsule())
                .animation(AppTheme.popAnimation, value: isSelected)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 子ビューを左上から並べ、幅を超えたら折り返す
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
