import SwiftUI
import SwiftData

/// 収納場所一覧画面
struct BagListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @Query(sort: \Bag.createdAt) private var bags: [Bag]
    
    @State private var showAddSheet = false
    
    var body: some View {
        List {
            if bags.isEmpty {
                ContentUnavailableView(
                    "収納場所がありません",
                    systemImage: "bag",
                    description: Text("右上の+ボタンで収納場所を追加しましょう")
                )
            } else {
                ForEach(bags) { bag in
                    BagRow(bag: bag)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteBag(bag)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle("収納場所")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            BagFormSheet()
        }
    }
    
    private func deleteBag(_ bag: Bag) {
        // 紐づくアイテムは未分類になる（deleteRule: .nullify）
        modelContext.delete(bag)
    }
}

struct BagRow: View {
    let bag: Bag
    
    var body: some View {
        HStack {
            Image(systemName: "bag")
                .foregroundStyle(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(bag.name)
                    .font(.body)
                
                Text("\(bag.items.count)個のアイテム")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 収納場所追加シート
struct BagFormSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("収納場所名", text: $name)
                } header: {
                    Text("収納場所名")
                } footer: {
                    Text("例: 玄関用、車載用、寝室")
                }
            }
            .navigationTitle("収納場所を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        let bag = Bag(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                        modelContext.insert(bag)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack {
        BagListView()
    }
    .environment(Router())
    .modelContainer(for: [Bag.self, Item.self], inMemory: true)
}
