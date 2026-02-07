import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @Query(sort: \Item.expiryDate) private var items: [Item]
    @Query private var bags: [Bag]
    
    @State private var selectedBagId: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var searchText = ""
    
    private var filteredItems: [Item] {
        var result = items
        
        // 収納場所フィルタ
        if let bagId = selectedBagId {
            result = result.filter { $0.bag?.id == bagId }
        }
        
        // 検索フィルタ
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        return result
    }
    
    private var expiredCount: Int {
        items.filter { $0.expiryStatus == .expired }.count
    }
    
    private var imminentCount: Int {
        items.filter { $0.expiryStatus == .imminent }.count
    }
    
    var body: some View {
        List(selection: isSelectionMode ? $selectedItems : nil) {
            // サマリーセクション
            if !items.isEmpty {
                Section {
                    HStack(spacing: 16) {
                        SummaryCard(
                            title: "期限切れ",
                            count: expiredCount,
                            color: .red
                        )
                        SummaryCard(
                            title: "期限間近",
                            count: imminentCount,
                            color: .orange
                        )
                        SummaryCard(
                            title: "合計",
                            count: items.count,
                            color: .blue
                        )
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            
            // 収納場所フィルタ
            if !bags.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(
                                title: "すべて",
                                isSelected: selectedBagId == nil,
                                action: { selectedBagId = nil }
                            )
                            ForEach(bags) { bag in
                                FilterChip(
                                    title: bag.name,
                                    isSelected: selectedBagId == bag.id,
                                    action: { selectedBagId = bag.id }
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            
            // アイテム一覧
            Section {
                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "備蓄品がありません",
                        systemImage: "tray",
                        description: Text("右下の+ボタンで備蓄品を追加しましょう")
                    )
                } else {
                    ForEach(filteredItems) { item in
                        ItemRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !isSelectionMode {
                                    router.push(.itemDetail(item))
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteItem(item)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    router.present(.editItem(item))
                                } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
            } header: {
                if !filteredItems.isEmpty {
                    Text("備蓄品 (\(filteredItems.count))")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("備蓄品管理")
        .searchable(text: $searchText, prompt: "品名で検索")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.push(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button(isSelectionMode ? "完了" : "選択") {
                        withAnimation {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedItems.removeAll()
                            }
                        }
                    }
                }
            }
            
            ToolbarItem(placement: .bottomBar) {
                if isSelectionMode && !selectedItems.isEmpty {
                    Button(role: .destructive) {
                        deleteSelectedItems()
                    } label: {
                        Label("\(selectedItems.count)件を削除", systemImage: "trash")
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isSelectionMode {
                Button {
                    router.present(.addItem)
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.blue, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                }
                .padding()
            }
        }
    }
    
    private func deleteItem(_ item: Item) {
        modelContext.delete(item)
    }
    
    private func deleteSelectedItems() {
        for item in items where selectedItems.contains(item.id) {
            modelContext.delete(item)
        }
        selectedItems.removeAll()
        isSelectionMode = false
    }
}

// MARK: - Supporting Views

struct SummaryCard: View {
    let title: String
    let count: Int
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray5), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        DashboardView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self, User.self, Bag.self, Item.self], inMemory: true)
}
