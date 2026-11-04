import SwiftUI

enum AppDesign: String, CaseIterable, Identifiable {
    case modern
    case legacy

    static let storageKey = "settings.appDesign"
    var id: String { rawValue }

    static func stored(in defaults: UserDefaults = .standard) -> AppDesign {
        defaults.string(forKey: storageKey).flatMap(AppDesign.init(rawValue:)) ?? .modern
    }

    var title: String {
        switch self {
        case .modern: return L10n.string("新デザイン")
        case .legacy: return L10n.string("旧デザイン")
        }
    }
}

/// Both settings screens use the same persisted preference.
struct AppDesignPicker: View {
    @AppStorage(AppDesign.storageKey) private var design: AppDesign = .modern

    var body: some View {
        Menu {
            ForEach(AppDesign.allCases) { option in
                Button {
                    design = option
                } label: {
                    if design == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack {
                Label("デザイン", systemImage: "rectangle.2.swap")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(design.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("デザイン"))
        .accessibilityValue(design.title)
        .accessibilityIdentifier("settings.design")
    }
}

struct LegacyRootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.legacyPath) {
            LegacyDashboardView()
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .itemDetail(let item): LegacyItemDetailView(item: item)
                    case .bagList: LegacyBagListView()
                    case .settings: LegacySettingsView()
                    case .familySetup: LegacyFamilySetupView()
                    case .familySettings(let family): LegacyFamilySettingsView(family: family)
                    case .notificationSettings: LegacyNotificationSettingsView()
                    }
                }
        }
        .tint(.blue)
    }
}

/// The old layout has no tab targets for the modern coach marks.
struct LegacyDesignGuide: View {
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("まずは右下の + を押します") {
                    Text("登録画面では、名前を入れて保存すれば使い始められます。")
                }
                Section("通知は必要になってから設定できます") {
                    Text("通知を開くと、いつお知らせするかを決められます。")
                }
                Section("設定") {
                    Text("収納場所")
                    Text("家族共有設定")
                    AppDesignPicker()
                }
            }
            .navigationTitle("はじめての使い方を見る")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", action: onFinish)
                }
            }
        }
    }
}
