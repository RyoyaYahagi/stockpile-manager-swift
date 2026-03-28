import SwiftUI
import SwiftData

struct ItemDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    @Bindable var item: Item
    
    @State private var showDeleteConfirmation = false

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }
    
    var body: some View {
        let expiryStatus = item.expiryStatus
        let purchaseURL = item.janCode.flatMap(APIConfig.rakutenPurchaseURL(for:))
        
        List {
            // 期限セクション
            Section {
                HStack {
                    Label("期限状態", systemImage: "clock")
                    Spacer()
                    ExpiryBadge(status: expiryStatus)
                    Text(expiryStatus.label)
                        .foregroundStyle(expiryColor(for: expiryStatus))
                }
                
                if let expiryDate = item.expiryDate {
                    HStack {
                        Label("賞味期限", systemImage: "calendar")
                        Spacer()
                        Text(expiryDate, style: .date)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Label("残り日数", systemImage: "hourglass")
                        Spacer()
                        Text(item.expiryDisplayText)
                            .foregroundStyle(expiryColor(for: expiryStatus))
                    }
                }
            } header: {
                Text("期限情報")
            }
            
            // 詳細セクション
            Section {
                HStack {
                    Label("数量", systemImage: "number")
                    Spacer()
                    Text("\(item.quantity)")
                        .foregroundStyle(.secondary)
                }
                
                if let bag = item.bag {
                    HStack {
                        Label("収納場所", systemImage: "bag")
                        Spacer()
                        Text(bag.name)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let locationNote = item.locationNote, !locationNote.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("メモ", systemImage: "note.text")
                        Text(locationNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("詳細")
            }
            
            // 登録情報
            Section {
                HStack {
                    Label("登録日", systemImage: "calendar.badge.plus")
                    Spacer()
                    Text(item.createdAt, style: .date)
                        .foregroundStyle(.secondary)
                }
            }

            if let purchaseURL {
                Section {
                    Link(destination: purchaseURL) {
                        Label("楽天市場で購入", systemImage: "cart")
                    }

                    Text("外部サイトへ移動します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("購入")
                }
            }
            
            // アクション
            Section {
                Button {
                    router.present(.editItem(item))
                } label: {
                    Label("編集", systemImage: "pencil")
                }
                
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.large)
        .alert("この備蓄品を削除しますか？", isPresented: $showDeleteConfirmation) {
            Button("削除", role: .destructive) {
                let deletedItemInfo = DeletedItemInfo(
                    id: item.id,
                    name: item.name,
                    janCode: item.janCode,
                    quantity: item.quantity,
                    expiryDate: item.expiryDate,
                    locationNote: item.locationNote,
                    bagId: item.bag?.id
                )
                modelContext.delete(item)
                do {
                    try modelContext.save()
                } catch {
                    #if DEBUG
                    print("ローカル保存に失敗: \(error)")
                    #endif
                    return
                }
                NotificationManager.shared.requestReschedule(using: modelContext)
                if let family = currentFamily {
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
                router.pop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(
                        name: .didDeleteItems,
                        object: [deletedItemInfo]
                    )
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除した備蓄品は元に戻せません。")
        }
    }
    
    private func expiryColor(for status: ExpiryStatus) -> Color {
        switch status {
        case .expired: return .red
        case .imminent: return .orange
        case .approaching: return .yellow
        case .safe: return .green
        case .noExpiry: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        ItemDetailView(item: Item(name: "缶詰", quantity: 3, expiryDate: Date().addingTimeInterval(86400 * 5)))
    }
    .environment(Router())
    .modelContainer(for: [Family.self, Item.self], inMemory: true)
}
