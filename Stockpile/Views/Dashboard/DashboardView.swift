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
    @State private var showStorageLocationPicker = false
    @State private var showDeleteConfirmation = false
    @State private var showMoveSheet = false
    @State private var showCopySheet = false
    @State private var deletedItemInfo: DeletedItemInfo?
    @State private var showUndoSnackbar = false
    @State private var undoWorkItem: DispatchWorkItem?
    @State private var selectedExpiryFilter: ExpiryFilter = .all
    
    enum ExpiryFilter {
        case all
        case expired
        case imminent
    }
    
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
        
        // 期限状態フィルタ
        switch selectedExpiryFilter {
        case .expired:
            result = result.filter { $0.expiryStatus == .expired }
        case .imminent:
            result = result.filter { $0.expiryStatus == .expired || $0.expiryStatus == .imminent }
        case .all:
            break
        }
        
        // 賞味期限が早い順にソート（期限なしは最後）
        result.sort { item1, item2 in
            switch (item1.expiryDate, item2.expiryDate) {
            case (nil, nil): return false // 両方nil -> 順序維持
            case (nil, _): return false   // item1がnil -> 後ろへ
            case (_, nil): return true    // item2がnil -> item1を前へ
            case let (date1?, date2?): return date1 < date2 // 日付比較
            }
        }
        
        return result
    }
    
    private var expiredCount: Int {
        items.filter { $0.expiryStatus == .expired }.count
    }
    
    private var imminentCount: Int {
        items.filter { $0.expiryStatus == .imminent }.count
    }
    
    private var selectedBagName: String {
        guard let bagId = selectedBagId,
              let bag = bags.first(where: { $0.id == bagId }) else {
            return "すべて"
        }
        return bag.name
    }
    
    var body: some View {
        List(selection: isSelectionMode ? $selectedItems : nil) {
            // サマリーセクション
            if !items.isEmpty {
                Section {
                    HStack(spacing: 16) {
                        Button {
                            withAnimation {
                                selectedExpiryFilter = selectedExpiryFilter == .expired ? .all : .expired
                            }
                        } label: {
                            SummaryCard(
                                title: "期限切れ",
                                count: expiredCount,
                                color: .red,
                                isSelected: selectedExpiryFilter == .expired
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            withAnimation {
                                selectedExpiryFilter = selectedExpiryFilter == .imminent ? .all : .imminent
                            }
                        } label: {
                            SummaryCard(
                                title: "期限間近",
                                count: imminentCount,
                                color: .orange,
                                isSelected: selectedExpiryFilter == .imminent
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            withAnimation {
                                selectedExpiryFilter = .all
                            }
                        } label: {
                            SummaryCard(
                                title: "合計",
                                count: items.count,
                                color: .blue,
                                isSelected: selectedExpiryFilter == .all
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            
            // 収納場所フィルタ
            if !bags.isEmpty && !isSelectionMode {
                Section {
                    Button {
                        showStorageLocationPicker = true
                    } label: {
                        HStack {
                            Label("収納場所", systemImage: "folder")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(selectedBagName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
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
                                if isSelectionMode {
                                    // 選択モード時は選択/解除
                                    if selectedItems.contains(item.id) {
                                        selectedItems.remove(item.id)
                                        // 全て解除されたら選択モードを終了
                                        if selectedItems.isEmpty {
                                            withAnimation {
                                                isSelectionMode = false
                                            }
                                        }
                                    } else {
                                        selectedItems.insert(item.id)
                                    }
                                } else {
                                    router.push(.itemDetail(item))
                                }
                            }
                            .onLongPressGesture {
                                // 長押しで選択モードに入る
                                withAnimation {
                                    isSelectionMode = true
                                    selectedItems.insert(item.id)
                                }
                                // 触覚フィードバック
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                            }
                            .listRowBackground(
                                isSelectionMode && selectedItems.contains(item.id)
                                    ? Color.blue.opacity(0.15)
                                    : nil
                            )
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
        .contentShape(Rectangle())
        .onTapGesture {
            exitSelectionModeIfNeeded()
        }
        .navigationTitle("備蓄品管理")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "品名で検索")
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image("AppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("備蓄品管理")
                        .font(.headline)
                }
            }
            
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
                    HStack {
                        Button {
                            showMoveSheet = true
                        } label: {
                            Label("移動", systemImage: "folder")
                        }
                        
                        Spacer()
                        
                        Button {
                            showCopySheet = true
                        } label: {
                            Label("コピー", systemImage: "doc.on.doc")
                        }
                        
                        Spacer()
                        
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isSelectionMode {
                Button {
                    router.present(.addItem(bagId: selectedBagId))
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
        .overlay(alignment: .bottom) {
            if showUndoSnackbar, let info = deletedItemInfo {
                UndoSnackbar(
                    message: "「\(info.name)」を削除しました",
                    onUndo: {
                        undoDelete(info)
                    },
                    onDismiss: {
                        dismissUndoSnackbar()
                    }
                )
                .padding(.horizontal)
                .padding(.bottom, isSelectionMode ? 60 : 80)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showStorageLocationPicker) {
            StorageLocationPicker(
                bags: bags,
                selectedBagId: $selectedBagId
            )
        }
        .sheet(isPresented: $showMoveSheet) {
            BulkMoveSheet(
                bags: bags,
                selectedItems: selectedItems,
                items: items,
                onMove: { bagId in
                    moveSelectedItems(to: bagId)
                }
            )
        }
        .sheet(isPresented: $showCopySheet) {
            BulkCopySheet(
                bags: bags,
                selectedItems: selectedItems,
                items: items,
                onCopy: { bagId in
                    copySelectedItems(to: bagId)
                }
            )
        }
        .alert(
            "\(selectedItems.count)件のアイテムを削除しますか？",
            isPresented: $showDeleteConfirmation
        ) {
            Button("削除", role: .destructive) {
                deleteSelectedItems()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
    
    private func deleteItem(_ item: Item) {
        // Undo用に情報を保存
        deletedItemInfo = DeletedItemInfo(
            name: item.name,
            quantity: item.quantity,
            expiryDate: item.expiryDate,
            locationNote: item.locationNote,
            bagId: item.bag?.id
        )
        
        // 通知をキャンセル
        Task {
            await NotificationManager.shared.cancelNotifications(for: item)
        }
        modelContext.delete(item)
        
        // スナックバーを表示
        showUndoSnackbarWithTimeout()
    }
    
    private func showUndoSnackbarWithTimeout() {
        // 既存のタイマーをキャンセル
        undoWorkItem?.cancel()
        
        withAnimation {
            showUndoSnackbar = true
        }
        
        // 5秒後に自動消去
        let workItem = DispatchWorkItem { [self] in
            dismissUndoSnackbar()
        }
        undoWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }
    
    private func undoDelete(_ info: DeletedItemInfo) {
        // アイテムを復元
        let newItem = Item(
            name: info.name,
            quantity: info.quantity,
            expiryDate: info.expiryDate,
            locationNote: info.locationNote
        )
        if let bagId = info.bagId {
            newItem.bag = bags.first { $0.id == bagId }
        }
        modelContext.insert(newItem)
        
        dismissUndoSnackbar()
    }
    
    private func dismissUndoSnackbar() {
        undoWorkItem?.cancel()
        undoWorkItem = nil
        withAnimation {
            showUndoSnackbar = false
        }
        // 少し遅延して情報をクリア
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            deletedItemInfo = nil
        }
    }
    
    private func exitSelectionModeIfNeeded() {
        if isSelectionMode {
            withAnimation {
                isSelectionMode = false
                selectedItems.removeAll()
            }
        }
    }
    
    private func deleteSelectedItems() {
        for item in items where selectedItems.contains(item.id) {
            // 通知をキャンセル
            Task {
                await NotificationManager.shared.cancelNotifications(for: item)
            }
            modelContext.delete(item)
        }
        selectedItems.removeAll()
        isSelectionMode = false
    }
    
    private func moveSelectedItems(to bagId: UUID?) {
        let targetBag = bags.first { $0.id == bagId }
        for item in items where selectedItems.contains(item.id) {
            item.bag = targetBag
        }
        selectedItems.removeAll()
        isSelectionMode = false
    }
    
    private func copySelectedItems(to bagId: UUID?) {
        let targetBag = bags.first { $0.id == bagId }
        for item in items where selectedItems.contains(item.id) {
            let newItem = Item(
                name: item.name,
                quantity: item.quantity,
                expiryDate: item.expiryDate,
                locationNote: item.locationNote
            )
            newItem.bag = targetBag
            modelContext.insert(newItem)
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
    var isSelected: Bool = false
    
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
        .background(color.opacity(isSelected ? 0.2 : 0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? color : Color.clear, lineWidth: 2)
        )
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

// MARK: - Bulk Action Sheets

struct BulkMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bags: [Bag]
    let selectedItems: Set<UUID>
    let items: [Item]
    let onMove: (UUID?) -> Void
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onMove(nil)
                        dismiss()
                    } label: {
                        Label("未分類に移動", systemImage: "tray")
                    }
                }
                
                Section("収納場所を選択") {
                    ForEach(bags) { bag in
                        Button {
                            onMove(bag.id)
                            dismiss()
                        } label: {
                            Label(bag.name, systemImage: "folder")
                        }
                    }
                }
            }
            .navigationTitle("\(selectedItems.count)件を移動")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct BulkCopySheet: View {
    @Environment(\.dismiss) private var dismiss
    let bags: [Bag]
    let selectedItems: Set<UUID>
    let items: [Item]
    let onCopy: (UUID?) -> Void
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onCopy(nil)
                        dismiss()
                    } label: {
                        Label("未分類にコピー", systemImage: "tray")
                    }
                }
                
                Section("収納場所を選択") {
                    ForEach(bags) { bag in
                        Button {
                            onCopy(bag.id)
                            dismiss()
                        } label: {
                            Label(bag.name, systemImage: "folder")
                        }
                    }
                }
            }
            .navigationTitle("\(selectedItems.count)件をコピー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Undo Snackbar

struct DeletedItemInfo {
    let name: String
    let quantity: Int
    let expiryDate: Date?
    let locationNote: String?
    let bagId: UUID?
}

struct UndoSnackbar: View {
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
        DashboardView()
    }
    .environment(Router())
    .modelContainer(for: [Family.self, User.self, Bag.self, Item.self], inMemory: true)
}

