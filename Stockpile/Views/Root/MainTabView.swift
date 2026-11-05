import SwiftUI
import SwiftData

/// 4つのタブと、ガラスのタブバー＋追加ボタンを持つ画面の土台
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(TutorialCoordinator.self) private var tutorial
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    var body: some View {
        @Bindable var router = router

        ZStack {
            AppBackground()

            tabStack(.home, path: $router.homePath) {
                HomeView()
            }
            tabStack(.stock, path: $router.stockPath) {
                DashboardView()
            }
            tabStack(.family, path: $router.familyPath) {
                if let family = currentFamily {
                    FamilySettingsView(family: family)
                } else {
                    FamilySetupView()
                }
            }
            tabStack(.settings, path: $router.settingsPath) {
                SettingsView()
            }
        }
        .overlay(alignment: .bottom) {
            if router.path.isEmpty && !router.isTabBarHidden {
                GlassTabBar(
                    selection: $router.selectedTab,
                    onAdd: { router.present(.addMethod()) }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(AppTheme.indicatorAnimation, value: router.path.isEmpty && !router.isTabBarHidden)
        // 「はじめての使い方」: 実画面の部品を照らす案内を、タブバーより上に重ねる
        .overlayPreferenceValue(TutorialTargetKey.self) { targets in
            if tutorial.isActive {
                CoachMarkOverlay(
                    targets: targets,
                    didSetUpFamily: currentFamily != nil
                )
            }
        }
        .animation(AppTheme.indicatorAnimation, value: tutorial.isActive)
    }

    /// 各タブの NavigationStack。非表示のタブも状態を保つため ZStack に重ねて切り替える
    private func tabStack<Content: View>(
        _ tab: AppTab,
        path: Binding<NavigationPath>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = router.selectedTab == tab
        return NavigationStack(path: path) {
            content()
                .navigationDestination(for: Destination.self) { destination in
                    destinationView(destination)
                }
        }
        .contentMargins(.bottom, router.path.isEmpty ? 96 : 0, for: .scrollContent)
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .itemDetail(let item):
            ItemDetailView(item: item)
        case .bagList:
            BagListView()
        case .settings:
            SettingsView()
        case .familySetup:
            FamilySetupView()
        case .familySettings(let family):
            FamilySettingsView(family: family)
        case .notificationSettings:
            NotificationSettingsView()
        }
    }
}

/// 浮いたガラスのタブバーと、右に離した色付きガラスの追加ボタン（iOS 26 の並び）
struct GlassTabBar: View {
    @Binding var selection: AppTab
    let onAdd: () -> Void
    @Namespace private var indicatorNamespace

    var body: some View {
        HStack(spacing: 12) {
            tabCapsule
            addButton
        }
    }

    @ViewBuilder
    private var tabCapsule: some View {
        let content = HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .frame(height: 64)

        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content.glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            content.glassSurface(in: Capsule())
        }
    }

    private func tabButton(_ tab: AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(AppTheme.indicatorAnimation) {
                selection = tab
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? "\(tab.symbol).fill" : tab.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(height: 24)
                Text(tab.title)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? AppTheme.accentInk : AppTheme.inkSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(AppTheme.accentSoft.opacity(0.9))
                        .matchedGeometryEffect(id: "indicator", in: indicatorNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tutorialTarget(.tab(tab))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
        .glassSurface(in: Circle(), tint: AppTheme.accent, interactive: true)
        .tutorialTarget(.addButton)
        .accessibilityLabel(Text("備蓄品を追加"))
    }
}
