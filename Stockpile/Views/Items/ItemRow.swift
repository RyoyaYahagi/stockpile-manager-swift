import SwiftUI

/// アイテム一覧の行表示
struct ItemRow: View {
    let item: Item
    
    var body: some View {
        let expiryStatus = item.expiryStatus
        
        HStack(spacing: 12) {
            // 期限状態インジケーター
            ExpiryBadge(status: expiryStatus)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    Text(L10n.format("×%@", String(item.quantity)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let bag = item.bag {
                        Text(bag.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未分類")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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
                    .foregroundStyle(expiryColor(for: expiryStatus))
            }
        }
        .padding(.vertical, 4)
    }
    
    private func expiryColor(for status: ExpiryStatus) -> Color {
        switch status {
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
