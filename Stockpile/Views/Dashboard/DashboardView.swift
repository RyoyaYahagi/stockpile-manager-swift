import SwiftUI
import SwiftData

enum SearchNormalizer {
    static func normalizedForms(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results = Set<String>()
        let base = normalize(trimmed)
        if !base.isEmpty {
            results.insert(base)
        }

        let hiragana = toHiragana(trimmed)
        let hiraganaNormalized = normalize(hiragana)
        if !hiraganaNormalized.isEmpty {
            results.insert(hiraganaNormalized)
        }

        let latin = toLatinReading(trimmed)
        let latinNormalized = normalize(latin)
        if !latinNormalized.isEmpty {
            results.insert(latinNormalized)
        }

        return Array(results)
    }

    static func matches(_ source: String, queryForms: [String]) -> Bool {
        guard !queryForms.isEmpty else { return true }

        let sourceForms = normalizedForms(for: source)
        guard !sourceForms.isEmpty else { return false }

        return queryForms.contains { query in
            sourceForms.contains { $0.contains(query) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .replacingOccurrences(of: "[\\p{P}\\p{S}\\p{Z}]", with: "", options: .regularExpression)
    }

    private static func toHiragana(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return mutable as String
    }

    private static func toLatinReading(_ text: String) -> String {
        let cfText = text as CFString
        let length = CFStringGetLength(cfText)
        let range = CFRange(location: 0, length: length)
        let locale = CFLocaleCopyCurrent()
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfText,
            range,
            kCFStringTokenizerUnitWordBoundary,
            locale
        )

        var parts: [String] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                parts.append(latin)
            } else {
                let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let token = CFStringCreateWithSubstring(kCFAllocatorDefault, cfText, tokenRange) as String
                parts.append(token)
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return parts.isEmpty ? text : parts.joined(separator: " ")
    }
}

extension Notification.Name {
    static let didDeleteItems = Notification.Name("didDeleteItems")
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    
    @Query(sort: \Item.expiryDate) private var items: [Item]
    @Query private var bags: [Bag]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    
    @State private var selectedBagId: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var searchText = ""
    @State private var showStorageLocationPicker = false
    @State private var showDeleteConfirmation = false
    @State private var showMoveSheet = false
    @State private var showCopySheet = false
    @State private var deletedItemInfoList: [DeletedItemInfo] = []
    @State private var showUndoSnackbar = false
    @State private var undoWorkItem: DispatchWorkItem?
    @State private var selectedExpiryFilter: ExpiryFilter = .all
    @State private var autoSyncedFamilyID: UUID?
    
    enum ExpiryFilter {
        case all
        case expired
        case imminent
    }
    
    private struct DashboardData {
        let filteredItems: [Item]
        let expiredCount: Int
        let imminentCount: Int
    }

    private var currentFamily: Family? {
        families.first
    }

    private var scopedItems: [Item] {
        guard let family = currentFamily else {
            return items.filter { $0.family == nil }
        }
        let familyItems = items.filter { $0.family?.id == family.id }
        if !familyItems.isEmpty {
            return familyItems
        }
        return items.filter { $0.family == nil }
    }

    private var scopedBags: [Bag] {
        guard let family = currentFamily else {
            return bags.filter { $0.family == nil }
        }
        let familyBags = bags.filter { $0.family?.id == family.id }
        if !familyBags.isEmpty {
            return familyBags
        }
        return bags.filter { $0.family == nil }
    }
    
    private var dashboardData: DashboardData {
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryForms = SearchNormalizer.normalizedForms(for: normalizedSearchText)
        let hasSearchText = !queryForms.isEmpty
        
        var filtered: [Item] = []
        var expiredCount = 0
        var imminentCount = 0
        
        for item in scopedItems {
            let status = item.expiryStatus
            
            if status == .expired {
                expiredCount += 1
            }
            if status == .imminent {
                imminentCount += 1
            }
            
            if let bagId = selectedBagId, item.bag?.id != bagId {
                continue
            }
            
            if hasSearchText, !SearchNormalizer.matches(item.name, queryForms: queryForms) {
                continue
            }
            
            switch selectedExpiryFilter {
            case .expired:
                guard status == .expired else { continue }
            case .imminent:
                guard status == .expired || status == .imminent else { continue }
            case .all:
                break
            }
            
            filtered.append(item)
        }
        
        filtered.sort { item1, item2 in
            switch (item1.expiryDate, item2.expiryDate) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (date1?, date2?): return date1 < date2
            }
        }
        
        return DashboardData(
            filteredItems: filtered,
            expiredCount: expiredCount,
            imminentCount: imminentCount
        )
    }
    
    private var selectedBagName: String {
        guard let bagId = selectedBagId,
              let bag = scopedBags.first(where: { $0.id == bagId }) else {
            return "すべて"
        }
        return bag.name
    }

    private var deletedItemsMessage: String {
        if deletedItemInfoList.count == 1, let first = deletedItemInfoList.first {
            return "「\(first.name)」を削除しました"
        }
        return "\(deletedItemInfoList.count)件の備蓄品を削除しました"
    }
    
    var body: some View {
        let data = dashboardData
        
        List(selection: isSelectionMode ? $selectedItems : nil) {
            // サマリーセクション
            if !scopedItems.isEmpty {
                Section {
                    HStack(spacing: 16) {
                        Button {
                            withAnimation {
                                selectedExpiryFilter = selectedExpiryFilter == .expired ? .all : .expired
                            }
                        } label: {
                            SummaryCard(
                                title: "期限切れ",
                                count: data.expiredCount,
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
                                count: data.imminentCount,
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
                                count: scopedItems.count,
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
            if !scopedBags.isEmpty && !isSelectionMode {
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
                if data.filteredItems.isEmpty {
                    ContentUnavailableView(
                        "備蓄品がありません",
                        systemImage: "tray",
                        description: Text("右下の+ボタンで備蓄品を追加しましょう")
                    )
                } else {
                    ForEach(data.filteredItems) { item in
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
                if !data.filteredItems.isEmpty {
                    Text("備蓄品 (\(data.filteredItems.count))")
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
                if !scopedItems.isEmpty {
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
        .task(id: currentFamily?.id) {
            await autoSyncFromFirebaseIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didDeleteItems)) { notification in
            guard let deletedItems = notification.object as? [DeletedItemInfo],
                  !deletedItems.isEmpty else { return }
            deletedItemInfoList = deletedItems
            showUndoSnackbarWithTimeout()
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
            if showUndoSnackbar, !deletedItemInfoList.isEmpty {
                UndoSnackbar(
                    message: deletedItemsMessage,
                    onUndo: {
                        undoDelete(deletedItemInfoList)
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
                bags: scopedBags,
                selectedBagId: $selectedBagId
            )
        }
        .sheet(isPresented: $showMoveSheet) {
            BulkMoveSheet(
                bags: scopedBags,
                selectedItems: selectedItems,
                items: scopedItems,
                onMove: { bagId in
                    moveSelectedItems(to: bagId)
                }
            )
        }
        .sheet(isPresented: $showCopySheet) {
            BulkCopySheet(
                bags: scopedBags,
                selectedItems: selectedItems,
                items: scopedItems,
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
        deletedItemInfoList = [snapshotForUndo(from: item)]
        
        modelContext.delete(item)
        persistAndSyncFamilyDataIfPossible(needsNotificationReschedule: true)
        
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
    
    private func undoDelete(_ infoList: [DeletedItemInfo]) {
        for info in infoList {
            let newItem = Item(
                name: info.name,
                quantity: info.quantity,
                expiryDate: info.expiryDate,
                locationNote: info.locationNote
            )
            newItem.id = info.id
            if let bagId = info.bagId {
                newItem.bag = scopedBags.first { $0.id == bagId }
            }
            newItem.family = currentFamily
            modelContext.insert(newItem)
        }
        persistAndSyncFamilyDataIfPossible(needsNotificationReschedule: true)
        
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
            deletedItemInfoList = []
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
        deletedItemInfoList = scopedItems
            .filter { selectedItems.contains($0.id) }
            .map { snapshotForUndo(from: $0) }

        for item in scopedItems where selectedItems.contains(item.id) {
            modelContext.delete(item)
        }
        persistAndSyncFamilyDataIfPossible(needsNotificationReschedule: true)
        if !deletedItemInfoList.isEmpty {
            showUndoSnackbarWithTimeout()
        }
        selectedItems.removeAll()
        isSelectionMode = false
    }
    
    private func moveSelectedItems(to bagId: UUID?) {
        let targetBag = scopedBags.first { $0.id == bagId }
        for item in scopedItems where selectedItems.contains(item.id) {
            item.bag = targetBag
        }
        persistAndSyncFamilyDataIfPossible()
        selectedItems.removeAll()
        isSelectionMode = false
    }
    
    private func copySelectedItems(to bagId: UUID?) {
        let targetBag = scopedBags.first { $0.id == bagId }
        for item in scopedItems where selectedItems.contains(item.id) {
            let newItem = Item(
                name: item.name,
                quantity: item.quantity,
                expiryDate: item.expiryDate,
                locationNote: item.locationNote
            )
            newItem.bag = targetBag
            newItem.family = currentFamily
            modelContext.insert(newItem)
        }
        persistAndSyncFamilyDataIfPossible(needsNotificationReschedule: true)
        selectedItems.removeAll()
        isSelectionMode = false
    }

    private func persistAndSyncFamilyDataIfPossible(needsNotificationReschedule: Bool = false) {
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("ローカル保存に失敗: \(error)")
            #endif
            return
        }

        if needsNotificationReschedule {
            NotificationManager.shared.requestReschedule(using: modelContext)
        }

        guard let family = currentFamily else { return }
        Task {
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try await sharingService.syncFamilyDataToCloudKit(for: family)
            } catch {
                #if DEBUG
                print("CloudKit同期に失敗: \(error)")
                #endif
            }
        }
    }

    private func autoSyncFromFirebaseIfNeeded() async {
        guard let family = currentFamily else { return }
        guard autoSyncedFamilyID != family.id else { return }
        autoSyncedFamilyID = family.id

        do {
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            try await sharingService.syncFamilyStateFromCloudKit(for: family)
        } catch {
            // 自動同期の失敗はUI操作を妨げない
        }
    }

    private func snapshotForUndo(from item: Item) -> DeletedItemInfo {
        DeletedItemInfo(
            id: item.id,
            name: item.name,
            quantity: item.quantity,
            expiryDate: item.expiryDate,
            locationNote: item.locationNote,
            bagId: item.bag?.id
        )
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
    let id: UUID
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
