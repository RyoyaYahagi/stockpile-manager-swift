import SwiftUI

/// 収納場所の並べ替え（この端末だけの並び順）
struct BagReorderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let family: Family?
    @State private var bags: [Bag]

    init(bags: [Bag], family: Family?) {
        self.family = family
        _bags = State(initialValue: BagOrderStore.sorted(bags, family: family))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(bags) { bag in
                        HStack(spacing: 12) {
                            Image(systemName: "bag")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AppTheme.ink)
                                .frame(width: 36, height: 36)
                                .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            Text(bag.name)
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { source, destination in
                        bags.move(fromOffsets: source, toOffset: destination)
                    }
                    .listRowBackground(AppTheme.card)
                } footer: {
                    Text("並び順はこの端末にだけ保存されます。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .appScreenBackground()
            .tint(AppTheme.accent)
            .navigationTitle("収納場所の並べ替え")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        BagOrderStore.save(bags, for: family)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .localizedRefresh()
    }
}
