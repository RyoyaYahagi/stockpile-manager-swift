import SwiftUI

/// 期限状態バッジ
struct ExpiryBadge: View {
    let status: ExpiryStatus
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay {
                if status == .expired {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }
    
    private var color: Color {
        switch status {
        case .expired: return .red
        case .imminent: return .orange
        case .approaching: return .yellow
        case .safe: return .green
        case .noExpiry: return .gray
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        ExpiryBadge(status: .expired)
        ExpiryBadge(status: .imminent)
        ExpiryBadge(status: .approaching)
        ExpiryBadge(status: .safe)
        ExpiryBadge(status: .noExpiry)
    }
    .padding()
}
