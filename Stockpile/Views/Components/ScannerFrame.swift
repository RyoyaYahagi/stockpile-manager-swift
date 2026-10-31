import SwiftUI

/// 読み取り枠: 四隅のかぎ括弧と、上下に動くスキャンライン
struct ScannerFrame: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lineAtBottom = false

    var width: CGFloat = 280
    var height: CGFloat = 180
    var isScanning = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.06))
            CornerBrackets()
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            if isScanning {
                Capsule()
                    .fill(Color(red: 0.5, green: 0.88, blue: 0.69))
                    .frame(height: 2)
                    .padding(.horizontal, width * 0.08)
                    .shadow(color: Color(red: 0.5, green: 0.88, blue: 0.69).opacity(0.8), radius: 8)
                    .offset(y: lineAtBottom ? height * 0.36 : -height * 0.36)
                    .opacity(reduceMotion ? 0 : 1)
            }
        }
        .frame(width: width, height: height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                lineAtBottom = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.2
        let radius: CGFloat = 22
        var path = Path()

        // 左上
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        // 右上
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        // 右下
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        // 左下
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))

        return path
    }
}
