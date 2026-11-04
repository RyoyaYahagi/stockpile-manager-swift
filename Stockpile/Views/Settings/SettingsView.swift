import SwiftUI
import SwiftData

/// 設定画面
struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(LocalizationController.self) private var localizationController
    @Environment(PremiumAccessManager.self) private var premiumAccessManager

    @Query private var bags: [Bag]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @AppStorage("app.tutorial.replayRequestToken")
    private var tutorialReplayRequestToken = 0

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var bagCount: Int {
        InventoryStore.scopedBags(bags, family: currentFamily).count
    }

    private var selectedAppLanguage: AppLanguage {
        localizationController.selectedLanguage
    }

    var body: some View {
        let refreshToken = localizationController.uiRefreshToken

        TutorialScrollReader {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("設定")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                    .padding(.horizontal, 4)

                SectionHeading(title: "お知らせ")
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                NotificationReminderCard()
                    .tutorialTarget(.notificationCard, scrollID: true)
                    .riseIn()

                SectionHeading(title: "管理")
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                managementCard
                    .riseIn(index: 1)

                SectionHeading(title: "データ")
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                dataCard
                    .riseIn(index: 2)

                if !premiumAccessManager.hasPremiumAccess {
                    premiumCard
                        .padding(.top, 28)
                        .riseIn(index: 3)
                }

                SectionHeading(title: "ヘルプ")
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                helpCard
                    .riseIn(index: 4)

                appFooter
                    .padding(.top, 32)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        }
        .appScreenBackground()
        .tint(AppTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .id(refreshToken)
        .localizedRefresh()
    }

    // MARK: - Cards

    private var managementCard: some View {
        SettingsCard {
            VStack(spacing: 0) {
                AppDesignPicker()
                    .padding(16)

                SettingsDivider()

                NavigationLink(value: Destination.bagList) {
                    SettingsRowLabel(
                        symbol: "bag.fill",
                        tint: AppTheme.accent,
                        title: "収納場所の編集",
                        detail: L10n.format("%@件", String(bagCount))
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    SettingsRowLabel(
                        symbol: "globe",
                        tint: Color(light: 0x3D5A9E, dark: 0x8FA8E8),
                        title: "言語",
                        detail: selectedAppLanguage.displayName
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var dataCard: some View {
        SettingsCard {
            VStack(spacing: 0) {
                Button {
                    router.present(.exportJSON)
                } label: {
                    SettingsRowLabel(
                        symbol: "square.and.arrow.up",
                        tint: AppTheme.accent,
                        title: "バックアップを書き出す"
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()

                Button {
                    router.present(.importJSON)
                } label: {
                    SettingsRowLabel(
                        symbol: "square.and.arrow.down",
                        tint: AppTheme.color(for: .imminent),
                        title: "バックアップから復元"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 濃い面のプレミアムプランカード（有料版でないときだけ表示）
    private var premiumCard: some View {
        Button {
            premiumAccessManager.presentPlanOverview()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(light: 0xF3C969, dark: 0xF3C969))
                    .frame(width: 36, height: 36)
                    .background(
                        Color.white.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("有料プラン")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text("制限なしで、もっと便利に使えます")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .fill(Color(light: 0x2A2723, dark: 0x3A362F))
                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
    }

    private var helpCard: some View {
        SettingsCard {
            VStack(spacing: 0) {
                Button {
                    tutorialReplayRequestToken += 1
                    router.popToRoot()
                } label: {
                    SettingsRowLabel(
                        symbol: "questionmark.circle.fill",
                        tint: AppTheme.accent,
                        title: "はじめての使い方を見る"
                    )
                }
                .buttonStyle(.plain)

                if let privacyPolicyURL = APIConfig.privacyPolicyURL {
                    SettingsDivider()
                    Link(destination: privacyPolicyURL) {
                        SettingsRowLabel(
                            symbol: "hand.raised.fill",
                            tint: AppTheme.inkSecondary,
                            title: "プライバシーポリシー",
                            trailingSymbol: "arrow.up.right"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let supportURL = APIConfig.supportURL {
                    SettingsDivider()
                    Link(destination: supportURL) {
                        SettingsRowLabel(
                            symbol: "envelope.fill",
                            tint: AppTheme.inkSecondary,
                            title: "お問い合わせ",
                            trailingSymbol: "arrow.up.right"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var appFooter: some View {
        VStack(spacing: 4) {
            Text(verbatim: appName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.inkSecondary)
            Text(verbatim: "\(L10n.string("バージョン")) \(appVersion)")
                .font(.caption)
                .foregroundStyle(AppTheme.inkSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "らくストック"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
}

// MARK: - Shared components

/// 設定タブのカード面
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

/// カード内の区切り線（アイコン列の右から始める）
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.ink.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 66)
    }
}

/// 角丸四角のアイコン
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// カード内の 1 行（アイコン・タイトル・補足・chevron）
struct SettingsRowLabel: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    var detail: String?
    var trailingSymbol = "chevron.right"

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(symbol: symbol, tint: tint)

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Image(systemName: trailingSymbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(AppTheme.inkSecondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self], inMemory: true)
}
