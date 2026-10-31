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

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(text: expiryStatus.label, status: expiryStatus)
                    Text(item.name)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(AppTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(item.bag?.name ?? L10n.string("未分類"), systemImage: item.bag == nil ? "tray" : "bag")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.inkSecondary)
                }
                .riseIn()

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("賞味期限")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.inkSecondary)
                        if let expiryDate = item.expiryDate {
                            Text(expiryDate, format: .dateTime.year().month().day())
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(item.expiryDisplayText)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppTheme.color(for: expiryStatus))
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("数量")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.inkSecondary)
                        QuantityStepper(quantity: item.quantity, onChange: setQuantity)
                    }
                }
                .padding(20)
                .cardSurface()
                .riseIn(index: 1)

                HStack(spacing: 10) {
                    Button("1つ使った") {
                        setQuantity(item.quantity - 1)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(item.quantity == 0)

                    Button {
                        router.present(.renewItem(item))
                    } label: {
                        Label("入れ替えた", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
                .riseIn(index: 2)

                VStack(alignment: .leading, spacing: 0) {
                    if let janCode = item.janCode, !janCode.isEmpty {
                        detailRow("JANコード", systemImage: "barcode", value: janCode)
                    }
                    if let locationNote = normalizedLocationNote {
                        detailRow("場所メモ", systemImage: "note.text", value: locationNote)
                    }
                    detailRow(
                        "登録日",
                        systemImage: "calendar.badge.plus",
                        value: item.createdAt.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                .padding(.horizontal, 16)
                .cardSurface()
                .riseIn(index: 3)

                HStack {
                    Button {
                        router.present(.editItem(item))
                    } label: {
                        Label("編集", systemImage: "pencil")
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(AppTheme.inkSecondary)
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("削除", systemImage: "trash")
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(AppTheme.color(for: .expired))
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .appScreenBackground()
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
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
                do {
                    let sharingService = CloudKitFamilySharingService(modelContext: modelContext)
                    try sharingService.deleteItemLocally(item, in: currentFamily)
                } catch {
                    #if DEBUG
                    print("ローカル削除に失敗: \(error)")
                    #endif
                    return
                }
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
    
    private func setQuantity(_ newValue: Int) {
        let clamped = min(max(0, newValue), 9999)
        guard clamped != item.quantity else { return }
        item.quantity = clamped
        item.markUpdated()
        InventoryStore.saveAndSync(modelContext, family: currentFamily)
    }

    private func detailRow(_ title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(AppTheme.inkSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }

    private var normalizedLocationNote: String? {
        guard let locationNote = item.locationNote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !locationNote.isEmpty else {
            return nil
        }
        return locationNote
    }
}

#Preview {
    NavigationStack {
        let item = Item(
            name: "缶詰",
            quantity: 3,
            expiryDate: Date().addingTimeInterval(86400 * 5),
            locationNote: "キッチン収納棚の上段"
        )
        let bag = Bag(name: "非常用バッグ")
        item.bag = bag
        return ItemDetailView(item: item)
    }
    .environment(Router())
    .modelContainer(for: [Family.self, Item.self, Bag.self], inMemory: true)
}
