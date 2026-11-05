// Original layout from 7d8b85c; uses the current models and services.
import SwiftUI
import SwiftData

/// 収納場所一覧画面
struct LegacyBagListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    
    @Query private var bags: [Bag]
    @Query private var items: [Item]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    
    @State private var showAddSheet = false
    @State private var deletedBagInfo: LegacyDeletedBagInfo?
    @State private var showUndoSnackbar = false
    @State private var undoWorkItem: DispatchWorkItem?

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var scopedBags: [Bag] {
        guard let family = currentFamily else {
            return bags.filter { $0.family == nil }
        }
        let familyBags = bags.filter { $0.family?.id == family.id }
        if !familyBags.isEmpty || family.prefersStrictCloudKitScoping {
            return familyBags
        }
        return bags.filter { $0.family == nil }
    }
    
    /// アイテム数が多い順にソート（よく使う収納場所を上に）
    private var sortedBags: [Bag] {
        scopedBags.sorted { $0.resolvedItems.count > $1.resolvedItems.count }
    }
    
    var body: some View {
        List {
            if scopedBags.isEmpty {
                ContentUnavailableView(
                    "収納場所がありません",
                    systemImage: "bag",
                    description: Text("右上の+ボタンで収納場所を追加しましょう")
                )
            } else {
                ForEach(sortedBags) { bag in
                    LegacyBagRow(bag: bag)
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
        .localizedRefresh()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentAddBagFlow()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            LegacyBagFormSheet()
        }
        .overlay(alignment: .bottom) {
            if showUndoSnackbar, let info = deletedBagInfo {
                LegacyBagUndoSnackbar(
                    message: L10n.format("「%@」を削除しました", info.name),
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
        deletedBagInfo = LegacyDeletedBagInfo(id: bag.id, name: bag.name, itemIDs: bag.resolvedItems.map(\.id))

        do {
            let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
            try sharingService.deleteBagLocally(bag, in: currentFamily)
        } catch {
            #if DEBUG
            print("ローカル削除に失敗: \(error)")
            #endif
            return
        }
        persistAndSyncFamilyIfPossible()
        
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
    
    private func undoDelete(_ info: LegacyDeletedBagInfo) {
        let newBag = Bag(name: info.name)
        newBag.id = info.id
        newBag.markUpdated()
        newBag.family = currentFamily
        modelContext.insert(newBag)

        for item in items where info.itemIDs.contains(item.id) {
            item.bag = newBag
            item.markUpdated()
        }

        if let family = currentFamily {
            do {
                let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                try sharingService.removeDeletionMarkerIfNeeded(forBagID: info.id, family: family)
            } catch {
                #if DEBUG
                print("削除マーカーの取り消しに失敗: \(error)")
                #endif
            }
        }
        persistAndSyncFamilyIfPossible()
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

    private func persistAndSyncFamilyIfPossible() {
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("ローカル保存に失敗: \(error)")
            #endif
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

    private func presentAddBagFlow() {
        if premiumAccessManager.canAddBag(currentCount: scopedBags.count) {
            showAddSheet = true
            return
        }

        premiumAccessManager.presentPaywall(for: .bagLimit) {
            self.showAddSheet = true
        }
    }
}

struct LegacyBagRow: View {
    let bag: Bag
    
    var body: some View {
        HStack {
            Image(systemName: "bag")
                .foregroundStyle(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(bag.name)
                    .font(.body)
                
                Text(L10n.format("%@個のアイテム", String(bag.resolvedItems.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 収納場所追加シート
struct LegacyBagFormSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    @Query private var bags: [Bag]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    
    @State private var name = ""
    @State private var isSaving = false
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var scopedBags: [Bag] {
        guard let family = currentFamily else {
            return bags.filter { $0.family == nil }
        }
        let familyBags = bags.filter { $0.family?.id == family.id }
        if !familyBags.isEmpty || family.prefersStrictCloudKitScoping {
            return familyBags
        }
        return bags.filter { $0.family == nil }
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
            .localizedRefresh()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        addBag()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("追加")
                        }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
        .premiumPaywallSheet()
        .presentationDetents([.medium])
    }

    private func addBag() {
        guard !isSaving else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        guard premiumAccessManager.canAddBag(currentCount: scopedBags.count) else {
            premiumAccessManager.presentPaywall(for: .bagLimit) {
                self.addBag()
            }
            return
        }

        isSaving = true

        let bag = Bag(name: trimmedName)
        let family = currentFamily
        bag.family = family
        modelContext.insert(bag)

        do {
            try modelContext.save()
        } catch {
            isSaving = false
            #if DEBUG
            print("ローカル保存に失敗: \(error)")
            #endif
            return
        }

        if let family {
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

        dismiss()
    }
}

// MARK: - Undo Snackbar

struct LegacyDeletedBagInfo {
    let id: UUID
    let name: String
    let itemIDs: [UUID]
}

struct LegacyBagUndoSnackbar: View {
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
        LegacyBagListView()
    }
    .environment(Router())
    .environment(PremiumAccessManager.shared)
    .modelContainer(for: [Family.self, Bag.self, Item.self], inMemory: true)
}
