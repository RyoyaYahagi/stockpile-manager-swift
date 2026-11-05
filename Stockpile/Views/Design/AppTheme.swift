import SwiftUI
import UIKit

/// アプリ全体の色・形・動きの定義
enum AppTheme {
    // MARK: - Colors

    static let accent = Color(light: 0x2F7D5B, dark: 0x4FB487)
    static let accentSoft = Color(light: 0xE3F0E8, dark: 0x1E3A2D)
    static let accentInk = Color(light: 0x24654A, dark: 0x8FE0B8)

    static let background = Color(light: 0xF3EEE6, dark: 0x16140F)
    static let card = Color(lightRGBA: (255, 255, 255, 0.78), darkRGBA: (255, 255, 255, 0.07))
    static let cardStroke = Color(lightRGBA: (255, 255, 255, 0.85), darkRGBA: (255, 255, 255, 0.10))
    static let softFill = Color(light: 0xF0EAE0, dark: 0x2A2722)
    static let ink = Color(light: 0x2A2723, dark: 0xF2EEE7)
    static let inkSecondary = Color(light: 0x655E54, dark: 0xB4ADA2)

    // 背景の色だまり（ガラス越しに透ける色）
    static let blobGreen = Color(light: 0xCBE5D5, dark: 0x173528)
    static let blobPeach = Color(light: 0xF7D9BC, dark: 0x3A2717)
    static let blobBlue = Color(light: 0xD6DFF3, dark: 0x1A2340)

    // MARK: - Shapes

    static let cardRadius: CGFloat = 24
    static let controlRadius: CGFloat = 16

    // MARK: - Motion（motion-reference の値を SwiftUI に置き換えたもの）

    /// フェード＋スライド／リスト順次表示: 760ms easeOutCubic
    static let riseAnimation = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.76)
    /// タブインジケーター: 520ms easeOutCubic
    static let indicatorAnimation = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.52)
    /// アコーディオン展開: easeInOutCubic
    static let accordionAnimation = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.48)
    /// バッジポップ・トースト: spring
    static let popAnimation = Animation.spring(response: 0.42, dampingFraction: 0.62)
    /// カウントアップ・円形進捗
    static let countAnimation = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 1.1)

    static func color(for status: ExpiryStatus) -> Color {
        switch status {
        case .expired: return Color(light: 0xB83A2B, dark: 0xFF7A66)
        case .imminent: return Color(light: 0xA85208, dark: 0xFFA149)
        case .approaching: return Color(light: 0x8A6D0B, dark: 0xE8C547)
        case .safe: return Color(light: 0x2F7D5B, dark: 0x5FD39A)
        case .noExpiry: return inkSecondary
        }
    }

    static func softColor(for status: ExpiryStatus) -> Color {
        color(for: status).opacity(0.14)
    }

    static func symbol(for status: ExpiryStatus) -> String {
        switch status {
        case .expired: return "exclamationmark.triangle.fill"
        case .imminent, .approaching: return "clock.fill"
        case .safe: return "checkmark.seal.fill"
        case .noExpiry: return "infinity"
        }
    }
}

// MARK: - Color helpers

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(
        lightRGBA: (Int, Int, Int, Double),
        darkRGBA: (Int, Int, Int, Double)
    ) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? darkRGBA : lightRGBA
            return UIColor(
                red: CGFloat(value.0) / 255,
                green: CGFloat(value.1) / 255,
                blue: CGFloat(value.2) / 255,
                alpha: value.3
            )
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Background

/// 色だまりのある背景。ガラスの下に色が透けるようにする
struct AppBackground: View {
    var body: some View {
        ZStack {
            AppTheme.background
            Circle()
                .fill(AppTheme.blobGreen)
                .frame(width: 340, height: 340)
                .blur(radius: 60)
                .offset(x: -140, y: -320)
            Circle()
                .fill(AppTheme.blobPeach)
                .frame(width: 320, height: 320)
                .blur(radius: 60)
                .offset(x: 170, y: 40)
            Circle()
                .fill(AppTheme.blobBlue)
                .frame(width: 300, height: 300)
                .blur(radius: 60)
                .offset(x: -110, y: 360)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Glass

extension View {
    /// iOS 26 以降は Liquid Glass、それ以前はすりガラス素材で代替する
    @ViewBuilder
    func glassSurface<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background {
                    if let tint {
                        shape.fill(tint.opacity(0.9))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    shape.strokeBorder(.white.opacity(0.45), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 8)
        }
    }

    @available(iOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }

    /// 画面の背景を色だまりにする（List / Form の既定背景も隠す）
    func appScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background { AppBackground() }
    }

    /// 一覧やカードなど「中身」の面。読みやすさを優先してガラスにはしない
    func cardSurface(radius: CGFloat = AppTheme.cardRadius) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AppTheme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(AppTheme.cardStroke, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
        }
    }

    /// フェード＋スライドで現れる（リスト順次表示用に index ごとに遅らせる）
    func riseIn(index: Int = 0, delayStep: Double = 0.06) -> some View {
        modifier(RiseInModifier(delay: Double(index) * delayStep))
    }
}

private struct RiseInModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || reduceMotion ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 14)
            .onAppear {
                guard !isVisible else { return }
                withAnimation(AppTheme.riseAnimation.delay(delay)) {
                    isVisible = true
                }
            }
    }
}

// MARK: - Button styles

/// プレスフィードバック: 押すと縮んで戻る
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(
                configuration.isPressed
                    ? .easeOut(duration: 0.08)
                    : .timingCurve(0.33, 1, 0.68, 1, duration: 0.42),
                value: configuration.isPressed
            )
    }
}

/// 主ボタン（塗り）
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.42), value: configuration.isPressed)
    }
}

/// 副ボタン（淡い面）
struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(AppTheme.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.ink.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(AppTheme.ink.opacity(0.12), lineWidth: 1)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.42), value: configuration.isPressed)
    }
}

// MARK: - Small components

/// 期限状態のピル
struct StatusPill: View {
    let text: String
    let status: ExpiryStatus

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(AppTheme.color(for: status))
            .background(AppTheme.softColor(for: status), in: Capsule())
    }
}

/// 見出し
struct SectionHeading: View {
    let title: LocalizedStringKey
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            if let count, count > 0 {
                PopBadge(count: count)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

/// バッジポップ: 現れるときに一度だけ弾む件数バッジ
struct PopBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(AppTheme.color(for: .expired), in: Capsule())
            .scaleEffect(isVisible || reduceMotion ? 1 : 0.01)
            .onAppear {
                withAnimation(AppTheme.popAnimation.delay(0.4)) {
                    isVisible = true
                }
            }
    }
}

/// 画面下に出る短いお知らせ（トーストスタック）
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassSurface(in: Capsule())
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}
