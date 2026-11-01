import SwiftUI

// MARK: - 照らす対象

/// 「はじめての使い方」で照らす、実画面の部品
enum TutorialTarget: Hashable {
    case addButton
    case tab(AppTab)
    case homeReadiness
    case homeAttention
    case notificationCard
    case familyAction

    /// 丸や カプセル形に照らす部品
    fileprivate var isPill: Bool {
        switch self {
        case .addButton, .tab: return true
        default: return false
        }
    }
}

/// 実画面の部品の位置を集める。同じ対象に複数の部品を付けたときは、全体を囲む範囲になる
struct TutorialTargetKey: PreferenceKey {
    static let defaultValue: [TutorialTarget: [Anchor<CGRect>]] = [:]

    static func reduce(
        value: inout [TutorialTarget: [Anchor<CGRect>]],
        nextValue: () -> [TutorialTarget: [Anchor<CGRect>]]
    ) {
        value.merge(nextValue()) { $0 + $1 }
    }
}

extension View {
    /// この部品を「はじめての使い方」で照らせるようにする
    /// - Parameters:
    ///   - isEnabled: false のときは対象にしない（データがなく、部品が出ないとき）
    ///   - scrollID: true のとき、スクロールで見える位置へ動かす目印にもなる
    @ViewBuilder
    func tutorialTarget(
        _ target: TutorialTarget,
        isEnabled: Bool = true,
        scrollID: Bool = false
    ) -> some View {
        if isEnabled {
            if scrollID {
                anchorPreference(key: TutorialTargetKey.self, value: .bounds) { [target: [$0]] }
                    .id(target)
            } else {
                anchorPreference(key: TutorialTargetKey.self, value: .bounds) { [target: [$0]] }
            }
        } else {
            self
        }
    }
}

// MARK: - 状態

/// 「はじめての使い方」の進み具合。ContentView が持ち、MainTabView が案内を重ねる
@MainActor
@Observable
final class TutorialCoordinator {
    static let stepCount = 6
    static let addStepIndex = 1

    private(set) var isActive = false
    var stepIndex = 0
    /// ＋を押して追加方法のシートが開いている間、true。閉じたら次の手順へ進む
    var awaitingAddSheet = false
    /// 最後まで進んだ回数（ContentView が「完了」を記録する合図）
    private(set) var finishCount = 0
    /// スクロールで見せたい部品。token が変わるたびにスクロールする
    private(set) var scrollTarget: TutorialTarget?
    private(set) var scrollToken = UUID()

    func start(at index: Int = 0) {
        stepIndex = min(max(0, index), Self.stepCount - 1)
        awaitingAddSheet = false
        isActive = true
    }

    func advance() {
        awaitingAddSheet = false
        guard stepIndex < Self.stepCount - 1 else {
            finish()
            return
        }
        stepIndex += 1
    }

    func finish() {
        isActive = false
        awaitingAddSheet = false
        stepIndex = 0
        finishCount += 1
    }

    /// 「あとで見る」: 完了にはせず閉じる
    func close() {
        isActive = false
        awaitingAddSheet = false
        stepIndex = 0
    }

    func requestScroll(to target: TutorialTarget) {
        scrollTarget = target
        scrollToken = UUID()
    }
}

/// 案内が指す部品までスクロールできるようにする（ホームと設定のスクロールで使う）
struct TutorialScrollReader<Content: View>: View {
    @Environment(TutorialCoordinator.self) private var coordinator
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .onChange(of: coordinator.scrollToken) { _, _ in
                    guard let target = coordinator.scrollTarget else { return }
                    withAnimation(AppTheme.indicatorAnimation) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
        }
    }
}

// MARK: - 手順

private struct CoachStep {
    struct Hint {
        let text: LocalizedStringKey
        let symbol: String
    }

    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let primaryTitle: LocalizedStringKey
    let hint: Hint?
    /// この手順で見せるタブ
    let tab: AppTab
    /// 照らす部品。前にあるものを優先し、見つからなければ次を探す。すべてなければ照らさない
    let targets: [TutorialTarget]
    /// 見える位置までスクロールする部品
    let scrollTarget: TutorialTarget?
    /// 照らした部品を、そのまま押せるか
    let allowsTargetTap: Bool

    static func all(didSetUpFamily: Bool) -> [CoachStep] {
        [
            CoachStep(
                title: "家の備えを、ひと目で",
                message: "食べ物や日用品を登録すると、期限が近いものを教えてくれます。ホームでは備えの「安心度」が分かります。",
                primaryTitle: "使い方を見る",
                hint: nil,
                tab: .home,
                targets: [.homeReadiness],
                scrollTarget: nil,
                allowsTargetTap: false
            ),
            CoachStep(
                title: "右下の ＋ で追加します",
                message: "＋ を押すと、バーコード、賞味期限の撮影、手入力から追加方法を選べます。",
                primaryTitle: "次へ進む",
                hint: Hint(text: "ここを押す", symbol: "hand.tap.fill"),
                tab: .home,
                targets: [.addButton],
                scrollTarget: nil,
                allowsTargetTap: true
            ),
            CoachStep(
                title: "期限が近いものはホームで分かります",
                message: "「いま対応が必要」に、期限切れと7日以内の備蓄が並びます。使ったら「1つ使った」、買い替えたら「入れ替えた」を押します。",
                primaryTitle: "次へ進む",
                hint: Hint(text: "入れ替えたらここを押す", symbol: "arrow.triangle.2.circlepath"),
                tab: .home,
                targets: [.homeAttention],
                scrollTarget: .homeAttention,
                allowsTargetTap: false
            ),
            CoachStep(
                title: "お知らせは設定タブで決めます",
                message: "設定タブの「お知らせ」で、賞味期限のお知らせのオン・オフ、いつ知らせるか、時刻を決められます。",
                primaryTitle: "次へ進む",
                hint: Hint(text: "ここでお知らせを決める", symbol: "bell.badge.fill"),
                tab: .settings,
                targets: [.notificationCard],
                scrollTarget: .notificationCard,
                allowsTargetTap: false
            ),
            CoachStep(
                title: didSetUpFamily ? "家族共有の準備もできます" : "家族と使うときは共有を設定できます",
                message: didSetUpFamily
                    ? "家族タブから共有リンクを送ると、家族と同じ一覧を見られます。"
                    : "家族タブで家族を作り、共有リンクで招待すると、同じ一覧を家族で共有できます。",
                primaryTitle: "次へ進む",
                hint: Hint(text: "ここで共有を始めます", symbol: "person.3.fill"),
                tab: .family,
                targets: [.familyAction, .tab(.family)],
                scrollTarget: nil,
                allowsTargetTap: false
            ),
            CoachStep(
                title: "これで使い始められます",
                message: "分からなくなっても、設定から「はじめての使い方」を見直せます。",
                primaryTitle: "使い始める",
                hint: Hint(text: "ここから見直せます", symbol: "arrow.uturn.backward.circle.fill"),
                tab: .home,
                targets: [.tab(.settings)],
                scrollTarget: nil,
                allowsTargetTap: false
            )
        ]
    }
}

// MARK: - 切り抜き

/// 画面全体の暗幕から、角丸の穴を抜いた形。穴は動いたり大きさが変わったりしてもなめらかに移る
private struct SpotlightShape: Shape {
    var hole: CGRect
    var radius: CGFloat
    /// true のとき画面全体を塗り、穴を抜く（偶奇規則）。false のときは穴の輪郭だけ
    var coversScreen: Bool

    typealias Pair = AnimatablePair<CGFloat, CGFloat>
    var animatableData: AnimatablePair<AnimatablePair<Pair, Pair>, CGFloat> {
        get {
            AnimatablePair(
                AnimatablePair(
                    Pair(hole.origin.x, hole.origin.y),
                    Pair(hole.size.width, hole.size.height)
                ),
                radius
            )
        }
        set {
            hole = CGRect(
                x: newValue.first.first.first,
                y: newValue.first.first.second,
                width: newValue.first.second.first,
                height: newValue.first.second.second
            )
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if coversScreen {
            path.addRect(rect)
        }
        let r = max(0, min(radius, min(hole.width, hole.height) / 2))
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: r, height: r), style: .continuous)
        return path
    }
}

// MARK: - 案内

struct CoachMarkOverlay: View {
    @Environment(TutorialCoordinator.self) private var coordinator
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let targets: [TutorialTarget: [Anchor<CGRect>]]
    let didSetUpFamily: Bool

    private let spotlightPadding: CGFloat = 8
    private let cardGap: CGFloat = 16
    private let cardEstimatedHeight: CGFloat = 230

    private var steps: [CoachStep] { CoachStep.all(didSetUpFamily: didSetUpFamily) }

    private var safeIndex: Int {
        min(max(coordinator.stepIndex, 0), TutorialCoordinator.stepCount - 1)
    }

    var body: some View {
        let step = steps[safeIndex]

        GeometryReader { outer in
            let insets = outer.safeAreaInsets

            GeometryReader { full in
                let spotlight = spotlight(for: step, in: full)
                let hole = spotlight?.rect ?? CGRect(x: full.size.width / 2, y: full.size.height / 2, width: 0, height: 0)
                let radius = spotlight?.radius ?? 0
                let blocksHole = !(spotlight != nil && step.allowsTargetTap)

                ZStack {
                    scrim(hole: hole, radius: radius, blocksHole: blocksHole)

                    SpotlightShape(hole: hole, radius: radius, coversScreen: false)
                        .stroke(AppTheme.accent, lineWidth: 3)
                        .shadow(color: AppTheme.accent.opacity(0.5), radius: 8)
                        .opacity(spotlight == nil ? 0 : 1)
                        .allowsHitTesting(false)

                    cardLayer(
                        step: step,
                        spotlight: spotlight?.rect,
                        size: full.size,
                        insets: insets
                    )
                }
                .animation(reduceMotion ? nil : AppTheme.indicatorAnimation, value: safeIndex)
            }
            .ignoresSafeArea()
        }
        .accessibilityAddTraits(.isModal)
        .onAppear { prepare(step: step, delayScroll: 0.5) }
        .onChange(of: safeIndex) { _, newValue in
            prepare(step: steps[newValue], delayScroll: 0.35)
        }
        .transition(.opacity)
    }

    // MARK: Parts

    private func scrim(hole: CGRect, radius: CGFloat, blocksHole: Bool) -> some View {
        SpotlightShape(hole: hole, radius: radius, coversScreen: true)
            .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
            .contentShape(
                SpotlightShape(hole: blocksHole ? .zero : hole, radius: radius, coversScreen: true),
                eoFill: true
            )
            .onTapGesture {}
            .accessibilityHidden(true)
    }

    private func cardLayer(
        step: CoachStep,
        spotlight: CGRect?,
        size: CGSize,
        insets: EdgeInsets
    ) -> some View {
        let card = card(step: step)
            .padding(.horizontal, 20)
            .id(safeIndex)
            .transition(.opacity)

        return Group {
            if let spotlight {
                let spaceAbove = spotlight.minY - insets.top - cardGap
                let spaceBelow = size.height - spotlight.maxY - insets.bottom - cardGap
                if spaceBelow >= cardEstimatedHeight {
                    VStack(spacing: 0) {
                        card
                        Spacer(minLength: 0)
                    }
                    .padding(.top, spotlight.maxY + cardGap)
                    .padding(.bottom, insets.bottom + 8)
                } else if spaceAbove >= cardEstimatedHeight {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        card
                    }
                    .padding(.top, insets.top + 8)
                    .padding(.bottom, size.height - spotlight.minY + cardGap)
                } else {
                    // 照らす範囲が大きく、上下どちらにも収まらないときは、下に重ねる
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        card
                    }
                    .padding(.top, insets.top + 8)
                    .padding(.bottom, insets.bottom + 12)
                }
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    card
                    Spacer(minLength: 0)
                }
                .padding(.vertical, insets.top + 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(step: CoachStep) -> some View {
        let isLast = safeIndex == TutorialCoordinator.stepCount - 1

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<TutorialCoordinator.stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == safeIndex ? AppTheme.accent : AppTheme.ink.opacity(0.18))
                        .frame(width: index == safeIndex ? 22 : 7, height: 7)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(safeIndex + 1) / \(TutorialCoordinator.stepCount)"))

            if let hint = step.hint {
                Label {
                    Text(hint.text)
                        .font(.caption.weight(.bold))
                } icon: {
                    Image(systemName: hint.symbol)
                        .font(.footnote.weight(.bold))
                }
                .foregroundStyle(AppTheme.accentInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppTheme.accentSoft, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(step.title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(step.message)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 4) {
                Button(step.primaryTitle) {
                    advance()
                }
                .buttonStyle(PrimaryActionButtonStyle())

                if !isLast {
                    Button {
                        coordinator.close()
                    } label: {
                        Text("あとで見る")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.inkSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .cardSurface()
    }

    // MARK: Behavior

    private func advance() {
        if reduceMotion {
            coordinator.advance()
        } else {
            withAnimation(AppTheme.indicatorAnimation) {
                coordinator.advance()
            }
        }
    }

    /// 手順のタブへ移り、必要なら部品が見える位置までスクロールする
    private func prepare(step: CoachStep, delayScroll: Double) {
        if router.selectedTab != step.tab || !router.path.isEmpty {
            if reduceMotion {
                router.select(step.tab, resetPath: true)
            } else {
                withAnimation(AppTheme.indicatorAnimation) {
                    router.select(step.tab, resetPath: true)
                }
            }
        }

        guard let scrollTarget = step.scrollTarget else { return }
        let index = safeIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + delayScroll) {
            guard coordinator.isActive, coordinator.stepIndex == index else { return }
            coordinator.requestScroll(to: scrollTarget)
        }
    }

    /// 手順で照らす部品の範囲。見つからない、または画面にほぼ入っていないときは nil
    private func spotlight(for step: CoachStep, in proxy: GeometryProxy) -> (rect: CGRect, radius: CGFloat)? {
        let screen = CGRect(origin: .zero, size: proxy.size)

        for target in step.targets {
            guard let anchors = targets[target], !anchors.isEmpty else { continue }
            let union = anchors
                .map { proxy[$0] }
                .reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull else { continue }

            let padded = union.insetBy(dx: -spotlightPadding, dy: -spotlightPadding)
            let visible = padded.intersection(screen)
            guard !visible.isNull, visible.width >= 24, visible.height >= 24 else { continue }

            let radius = target.isPill ? min(visible.width, visible.height) / 2 : AppTheme.cardRadius + 4
            return (visible, radius)
        }
        return nil
    }
}
