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
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: AppLanguage.currentLocale)
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
        let locale = AppLanguage.currentLocale as CFLocale
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
    
    @State private var collapsedGroupIds: Set<String> = []
    @State private var showBagReorder = false
    @AppStorage(BagOrderStore.revisionKey) private var bagOrderRevision = 0
    @State private var selectedItems: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var showMoveSheet = false
    @State private var showCopySheet = false
    @State private var deletedItemInfoList: [DeletedItemInfo] = []
    @State private var showUndoSnackbar = false
    @State private var undoWorkItem: DispatchWorkItem?
    @State private var selectedExpiryFilter: ExpiryFilter = .all
    @State private var autoSyncedFamilyID: UUID?
    
    enum ExpiryFilter: CaseIterable {
        case all
        case attention
        case approaching
        case safe

        var title: LocalizedStringKey {
            switch self {
            case .all: return "すべて"
            case .attention: return "要対応"
            case .approaching: return "1か月以内"
            case .safe: return "余裕あり"
            }
        }

        func matches(_ status: ExpiryStatus) -> Bool {
            switch self {
            case .all: return true
            case .attention: return status.needsAttention
            case .approaching: return status == .approaching
            case .safe: return status == .safe || status == .noExpiry
            }
        }
    }

    /// 収納場所ごとのまとまり
    private struct ItemGroup: Identifiable {
        let id: String
        let bagId: UUID?
        let name: String
        let items: [Item]

        var attentionCount: Int {
            items.filter { $0.expiryStatus.needsAttention }.count
        }
    }

    private static let unassignedGroupId = "unassigned"

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var scopedItems: [Item] {
        InventoryStore.scopedItems(items, family: currentFamily)
    }

    private var scopedBags: [Bag] {
        InventoryStore.scopedBags(bags, family: currentFamily)
    }

    private var isNarrowing: Bool {
        selectedExpiryFilter != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredItems: [Item] {
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryForms = SearchNormalizer.normalizedForms(for: normalizedSearchText)
        let hasSearchText = !queryForms.isEmpty

        let filtered = scopedItems.filter { item in
            if hasSearchText, !SearchNormalizer.matches(item.name, queryForms: queryForms) {
                return false
            }
            return selectedExpiryFilter.matches(item.expiryStatus)
        }

        return filtered.sorted { item1, item2 in
            switch (item1.expiryDate, item2.expiryDate) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (date1?, date2?): return date1 < date2
            }
        }
    }

    private func groups(for filtered: [Item]) -> [ItemGroup] {
        _ = bagOrderRevision
        var result = BagOrderStore.sorted(scopedBags, family: currentFamily)
            .map { bag in
                ItemGroup(
                    id: bag.id.uuidString,
                    bagId: bag.id,
                    name: bag.name,
                    items: filtered.filter { $0.bag?.id == bag.id }
                )
            }
        let knownBagIds = Set(scopedBags.map(\.id))
        let unassigned = filtered.filter { item in
            guard let bagId = item.bag?.id else { return true }
            return !knownBagIds.contains(bagId)
        }
        result.append(
            ItemGroup(
                id: Self.unassignedGroupId,
                bagId: nil,
                name: L10n.string("未分類"),
                items: unassigned
            )
        )
        return result.filter { !$0.items.isEmpty }
    }

    private func isExpanded(_ group: ItemGroup) -> Bool {
        isNarrowing || !collapsedGroupIds.contains(group.id)
    }

    private func toggle(_ group: ItemGroup) {
        withAnimation(AppTheme.accordionAnimation) {
            if collapsedGroupIds.contains(group.id) {
                collapsedGroupIds.remove(group.id)
            } else {
                collapsedGroupIds.insert(group.id)
            }
        }
    }

    private var deletedItemsMessage: String {
        if deletedItemInfoList.count == 1, let first = deletedItemInfoList.first {
            return L10n.format("「%@」を削除しました", first.name)
        }
        return L10n.format("%@件の備蓄品を削除しました", String(deletedItemInfoList.count))
    }

    private var bulkDeleteConfirmationTitle: String {
        L10n.format("%@件のアイテムを削除しますか？", String(selectedItems.count))
    }

    private func filteredItemsSectionTitle(count: Int) -> String {
        L10n.format("備蓄品（%@）", String(count))
    }
    
    var body: some View {
        let filtered = filteredItems
        let itemGroups = groups(for: filtered)

        ScrollViewReader { proxy in
            List(selection: isSelectionMode ? $selectedItems : nil) {
                if !scopedItems.isEmpty {
                    Section {
                        ExpiryFilterControl(selection: $selectedExpiryFilter)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                }

                if itemGroups.isEmpty {
                    Section {
                        ContentUnavailableView(
                            scopedItems.isEmpty ? "備蓄品がありません" : "該当する備蓄はありません",
                            systemImage: "tray",
                            description: Text(scopedItems.isEmpty ? "右下の＋から、1件登録してみましょう" : "")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(itemGroups) { group in
                        Section {
                            groupHeader(group)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowBackground(AppTheme.card)
                                .id(group.id)

                            if isExpanded(group) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    itemRow(item, index: index)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(14)
            .appScreenBackground()
            .onAppear { scrollToFocusedBag(using: proxy) }
            .onChange(of: router.stockFocusRequest?.token) { _, _ in scrollToFocusedBag(using: proxy) }
        }
        .navigationTitle("在庫")
        .navigationBarTitleDisplayMode(.large)
        .localizedRefresh()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "品名で検索")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !scopedItems.isEmpty {
                        Button {
                            setSelectionMode(!isSelectionMode)
                        } label: {
                            Label(
                                isSelectionMode ? LocalizedStringKey("選択を終了") : LocalizedStringKey("選択して移動・削除"),
                                systemImage: "checkmark.circle"
                            )
                        }
                    }
                    if scopedBags.count > 1 {
                        Button {
                            showBagReorder = true
                        } label: {
                            Label("収納場所の並べ替え", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    Button {
                        router.push(.bagList)
                    } label: {
                        Label("収納場所を編集", systemImage: "bag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel(Text("その他"))
                }
            }

            if isSelectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完了") {
                        setSelectionMode(false)
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
            await autoSyncFromCloudKitIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didDeleteItems)) { notification in
            guard let deletedItems = notification.object as? [DeletedItemInfo],
                  !deletedItems.isEmpty else { return }
            deletedItemInfoList = deletedItems
            showUndoSnackbarWithTimeout()
        }
        .onChange(of: isSelectionMode) { _, newValue in
            // 選択中は下のツールバーと重ならないよう、タブバーを隠す
            router.isTabBarHidden = newValue
        }
        .onDisappear {
            if isSelectionMode {
                setSelectionMode(false)
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
                .padding(.bottom, isSelectionMode ? 60 : 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showBagReorder) {
            BagReorderSheet(bags: scopedBags, family: currentFamily)
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
            bulkDeleteConfirmationTitle,
            isPresented: $showDeleteConfirmation
        ) {
            Button("削除", role: .destructive) {
                deleteSelectedItems()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
    
    // MARK: - Rows

    private func groupHeader(_ group: ItemGroup) -> some View {
        let expanded = isExpanded(group)
        return Button {
            toggle(group)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: group.bagId == nil ? "tray" : "bag")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.softFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.body.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Text(groupSummary(group))
                        .font(.caption)
                        .foregroundStyle(group.attentionCount > 0 ? AppTheme.color(for: .imminent) : AppTheme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.inkSecondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isNarrowing)
        .accessibilityValue(Text(expanded ? "開いています" : "閉じています"))
    }

    private func groupSummary(_ group: ItemGroup) -> String {
        let count = L10n.format("%@品目", String(group.items.count))
        if group.attentionCount > 0 {
            return "\(count) ・ " + L10n.format("要対応 %@件", String(group.attentionCount))
        }
        return "\(count) ・ " + L10n.string("すべて期限内")
    }

    private func itemRow(_ item: Item, index: Int) -> some View {
        ItemRow(item: item, isSelected: isSelectionMode ? selectedItems.contains(item.id) : nil)
            .riseIn(index: index, delayStep: 0.05)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectionMode {
                    if selectedItems.contains(item.id) {
                        selectedItems.remove(item.id)
                        if selectedItems.isEmpty {
                            setSelectionMode(false)
                        }
                    } else {
                        selectedItems.insert(item.id)
                    }
                } else {
                    router.push(.itemDetail(item))
                }
            }
            .onLongPressGesture {
                withAnimation {
                    isSelectionMode = true
                    selectedItems.insert(item.id)
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .listRowBackground(AppTheme.card)
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
                .tint(AppTheme.accent)
            }
    }

    private func setSelectionMode(_ enabled: Bool) {
        withAnimation {
            isSelectionMode = enabled
            if !enabled {
                selectedItems.removeAll()
            }
        }
    }

    /// ホームの収納場所カードから来たとき、その場所を開いて表示する
    private func scrollToFocusedBag(using proxy: ScrollViewProxy) {
        guard let request = router.stockFocusRequest else { return }
        router.stockFocusRequest = nil
        let groupId = request.bagId?.uuidString ?? Self.unassignedGroupId
        selectedExpiryFilter = .all
        searchText = ""
        let allGroupIds = Set(groups(for: filteredItems).map(\.id))
        collapsedGroupIds = allGroupIds.subtracting([groupId])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(AppTheme.accordionAnimation) {
                proxy.scrollTo(groupId, anchor: .top)
            }
        }
    }

    private func deleteItem(_ item: Item) {
        deletedItemInfoList = [snapshotForUndo(from: item)]

        do {
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            try sharingService.deleteItemLocally(item, in: currentFamily)
        } catch {
            #if DEBUG
            print("ローカル削除に失敗: \(error)")
            #endif
            return
        }
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
        let restoredAt = Date()
        for info in infoList {
            let newItem = Item(
                name: info.name,
                janCode: info.janCode,
                quantity: info.quantity,
                expiryDate: info.expiryDate,
                locationNote: info.locationNote
            )
            newItem.id = info.id
            newItem.markUpdated(at: restoredAt)
            if let bagId = info.bagId {
                newItem.bag = scopedBags.first { $0.id == bagId }
            }
            newItem.family = currentFamily
            modelContext.insert(newItem)
        }

        if let family = currentFamily {
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                for info in infoList {
                    try sharingService.removeDeletionMarkerIfNeeded(forItemID: info.id, family: family)
                }
            } catch {
                #if DEBUG
                print("削除マーカーの取り消しに失敗: \(error)")
                #endif
            }
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

        do {
            let itemsToDelete = scopedItems.filter { selectedItems.contains($0.id) }
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            try sharingService.deleteItemsLocally(itemsToDelete, in: currentFamily)
        } catch {
            #if DEBUG
            print("ローカル削除に失敗: \(error)")
            #endif
            return
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
            item.markUpdated()
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
                janCode: item.janCode,
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

    private func autoSyncFromCloudKitIfNeeded() async {
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
            janCode: item.janCode,
            quantity: item.quantity,
            expiryDate: item.expiryDate,
            locationNote: item.locationNote,
            bagId: item.bag?.id
        )
    }
}

// MARK: - Supporting Views

/// 期限での絞り込み（ガラスの切り替え。選択中の玉がスライドする）
private struct ExpiryFilterControl: View {
    @Binding var selection: DashboardView.ExpiryFilter
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DashboardView.ExpiryFilter.allCases, id: \.self) { filter in
                let isSelected = selection == filter
                Button {
                    withAnimation(AppTheme.indicatorAnimation) {
                        selection = filter
                    }
                } label: {
                    Text(filter.title)
                        .font(.footnote.weight(isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? AppTheme.ink : AppTheme.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(AppTheme.card)
                                    .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
                                    .matchedGeometryEffect(id: "filter", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassSurface(in: Capsule())
    }
}

struct SummaryCard: View {
    let title: LocalizedStringKey
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
    let title: LocalizedStringKey
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

    private var titleText: String {
        L10n.format("%@件を移動", String(selectedItems.count))
    }
    
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
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .localizedRefresh()
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

    private var titleText: String {
        L10n.format("%@件をコピー", String(selectedItems.count))
    }
    
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
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .localizedRefresh()
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
    let janCode: String?
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
