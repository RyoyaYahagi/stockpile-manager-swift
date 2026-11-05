import SwiftUI

/// 数量の −／＋。ボタンは小さなガラス
struct QuantityStepper: View {
    let quantity: Int
    var minimum = 0
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            stepButton(symbol: "minus", label: "1つ減らす", delta: -1)
                .disabled(quantity <= minimum)
            Text("\(quantity)")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(quantity)))
                .foregroundStyle(AppTheme.ink)
                .frame(minWidth: 36)
            stepButton(symbol: "plus", label: "1つ増やす", delta: 1)
                .disabled(quantity >= 9999)
        }
        .accessibilityElement(children: .contain)
    }

    private func stepButton(symbol: String, label: LocalizedStringKey, delta: Int) -> some View {
        Button {
            withAnimation(AppTheme.popAnimation) {
                onChange(quantity + delta)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .glassSurface(in: Circle(), interactive: true)
        .accessibilityLabel(Text(label))
    }
}
