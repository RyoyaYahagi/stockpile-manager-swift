import SwiftUI

/// アイテム一覧の行表示
struct ItemRow: View {
    let item: Item
    
    var body: some View {
        HStack(spacing: 12) {
            // 期限状態インジケーター
            ExpiryBadge(status: item.expiryStatus)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    if let bag = item.bag {
                        Label(bag.name, systemImage: "bag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if item.quantity > 1 {
                        Text("×\(item.quantity)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 期限表示
            VStack(alignment: .trailing, spacing: 2) {
                if let expiryDate = item.expiryDate {
                    Text(expiryDate, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.expiryDisplayText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(expiryColor)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var expiryColor: Color {
        switch item.expiryStatus {
        case .expired: return .red
        case .imminent: return .orange
        case .approaching: return .yellow
        case .safe: return .green
        case .noExpiry: return .secondary
        }
    }
}

#Preview {
    List {
        ItemRow(item: Item(name: "缶詰", quantity: 3, expiryDate: Date().addingTimeInterval(-86400)))
        ItemRow(item: Item(name: "水", quantity: 6, expiryDate: Date().addingTimeInterval(86400 * 5)))
        ItemRow(item: Item(name: "乾パン", quantity: 2, expiryDate: Date().addingTimeInterval(86400 * 60)))
    }
}
