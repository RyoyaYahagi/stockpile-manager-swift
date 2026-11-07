import SwiftUI

/// アイテム一覧の行表示
struct ItemRow: View {
    let item: Item
    var showsBag = false
    var showsCategoryIcon = false
    /// 選択モード中は選択状態、それ以外は nil
    var isSelected: Bool? = nil

    var body: some View {
        let expiryStatus = item.expiryStatus

        HStack(spacing: 12) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.inkSecondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(Text(isSelected ? "選択中" : "未選択"))
            }

            Circle()
                .fill(AppTheme.color(for: expiryStatus))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)

                    Text(L10n.format("×%@", String(item.quantity)))
                        .font(.callout)
                        .foregroundStyle(AppTheme.inkSecondary)
                }

                HStack(spacing: 6) {
                    if let expiryDate = item.expiryDate {
                        Text(expiryDate, format: .dateTime.year().month().day())
                    }
                    if showsCategoryIcon {
                        Image(systemName: item.resolvedCategory.systemImage)
                            .accessibilityLabel(Text(item.resolvedCategory.displayName))
                    }
                    if showsBag {
                        Text(item.bag?.name ?? L10n.string("未分類"))
                    }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.inkSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            StatusPill(text: item.expiryDisplayText, status: expiryStatus)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    List {
        ItemRow(item: Item(name: "缶詰", quantity: 3, expiryDate: Date().addingTimeInterval(-86400)))
        ItemRow(item: Item(name: "水", quantity: 6, expiryDate: Date().addingTimeInterval(86400 * 5)))
        ItemRow(item: Item(name: "乾パン", quantity: 2, expiryDate: Date().addingTimeInterval(86400 * 60)), showsBag: true)
    }
}
