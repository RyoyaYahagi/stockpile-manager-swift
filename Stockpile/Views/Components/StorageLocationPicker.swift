import SwiftUI
import SwiftData

/// 収納場所選択ピッカー
/// ボトムシート形式で収納場所を検索・選択できるUI
struct StorageLocationPicker: View {
    @Environment(\.dismiss) private var dismiss
    
    let bags: [Bag]
    @Binding var selectedBagId: UUID?
    
    @State private var searchText = ""
    
    private var filteredBags: [Bag] {
        let sorted = bags.sorted { $0.resolvedItems.count > $1.resolvedItems.count }
        let queryForms = SearchNormalizer.normalizedForms(for: searchText)
        if queryForms.isEmpty {
            return sorted
        }
        return sorted.filter { SearchNormalizer.matches($0.name, queryForms: queryForms) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // 「すべて」オプション
                if searchText.isEmpty {
                    Button {
                        selectedBagId = nil
                        dismiss()
                    } label: {
                        HStack {
                            Label("すべて", systemImage: "tray.2")
                            Spacer()
                            if selectedBagId == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                
                // 収納場所リスト
                ForEach(filteredBags) { bag in
                    Button {
                        selectedBagId = bag.id
                        dismiss()
                    } label: {
                        HStack {
                            Label(bag.name, systemImage: "folder")
                            Spacer()
                            if selectedBagId == bag.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                
                // 検索結果が空の場合
                if filteredBags.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("収納場所を選択")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "場所を検索")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    StorageLocationPicker(
        bags: [],
        selectedBagId: .constant(nil)
    )
}
