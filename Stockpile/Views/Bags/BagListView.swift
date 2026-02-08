import SwiftUI
import SwiftData

/// 収納場所一覧画面
struct BagListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @Query private var bags: [Bag]
    
    @State private var showAddSheet = false
    @State private var deletedBagInfo: DeletedBagInfo?
    @State private var showUndoSnackbar = false
    @State private var undoWorkItem: DispatchWorkItem?
    
    /// アイテム数が多い順にソート（よく使う収納場所を上に）
    private var sortedBags: [Bag] {
        bags.sorted { $0.items.count > $1.items.count }
    }
    
    var body: some View {
        List {
            if bags.isEmpty {
                ContentUnavailableView(
                    "収納場所がありません",
                    systemImage: "bag",
                    description: Text("右上の+ボタンで収納場所を追加しましょう")
                )
            } else {
                ForEach(sortedBags) { bag in
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
        .overlay(alignment: .bottom) {
            if showUndoSnackbar, let info = deletedBagInfo {
                BagUndoSnackbar(
                    message: "「\(info.name)」を削除しました",
                    onUndo: {
                        undoDelete(info)
                    },
                    onDismiss: {
                        dismissUndoSnackbar()
                    }
                )
                .padding(.horizontal)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    
    private func deleteBag(_ bag: Bag) {
        // Undo用に情報を保存
        deletedBagInfo = DeletedBagInfo(name: bag.name)
        
        // 紐づくアイテムは未分類になる（deleteRule: .nullify）
        modelContext.delete(bag)
        
        // スナックバーを表示
        showUndoSnackbarWithTimeout()
    }
    
    private func showUndoSnackbarWithTimeout() {
        undoWorkItem?.cancel()
        
        withAnimation {
            showUndoSnackbar = true
        }
        
        let workItem = DispatchWorkItem { [self] in
            dismissUndoSnackbar()
        }
        undoWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }
    
    private func undoDelete(_ info: DeletedBagInfo) {
        let newBag = Bag(name: info.name)
        modelContext.insert(newBag)
        dismissUndoSnackbar()
    }
    
    private func dismissUndoSnackbar() {
        undoWorkItem?.cancel()
        undoWorkItem = nil
        withAnimation {
            showUndoSnackbar = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            deletedBagInfo = nil
        }
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

// MARK: - Undo Snackbar

struct DeletedBagInfo {
    let name: String
}

struct BagUndoSnackbar: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
            
            Spacer()
            
            Button("元に戻す") {
                onUndo()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.yellow)
            
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    NavigationStack {
        BagListView()
    }
    .environment(Router())
    .modelContainer(for: [Bag.self, Item.self], inMemory: true)
}
