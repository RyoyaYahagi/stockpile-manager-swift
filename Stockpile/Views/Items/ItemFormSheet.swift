import SwiftUI
import SwiftData

/// アイテム追加/編集フォーム
struct ItemFormSheet: View {
    enum Mode {
        case add
        case edit(Item)
        
        var title: String {
            switch self {
            case .add: return L10n.string("備蓄品を追加")
            case .edit: return L10n.string("備蓄品を編集")
            }
        }
    }
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    
    let mode: Mode
    
    @Query private var bags: [Bag]
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]
    
    @State private var name: String = ""
    @State private var quantity: Int = 1
    @State private var expiryDate: Date = Date()
    @State private var hasExpiry: Bool = true
    @State private var janCode: String?
    @State private var selectedBagId: UUID?
    @State private var locationNote: String = ""
    @State private var showOCRCamera = false
    @State private var showBarcodeScanner = false
    @State private var isSaving = false
    
    init(mode: Mode, preselectedBagId: UUID? = nil) {
        self.mode = mode
        
        // 編集モードの場合、初期値を設定
        if case .edit(let item) = mode {
            _name = State(initialValue: item.name)
            _quantity = State(initialValue: item.quantity)
            _expiryDate = State(initialValue: item.expiryDate ?? Date())
            _hasExpiry = State(initialValue: item.expiryDate != nil)
            _janCode = State(initialValue: item.janCode)
            _selectedBagId = State(initialValue: item.bag?.id)
            _locationNote = State(initialValue: item.locationNote ?? "")
        } else {
            // 追加モードの場合、プリセット収納場所を設定
            _selectedBagId = State(initialValue: preselectedBagId)
        }
    }
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quantity > 0
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
                // 基本情報
                Section {
                    TextField("品名（例: 水、缶詰、乾電池）", text: $name)
                    
                    // バーコードスキャンボタン（追加モードのみ）
                    if case .add = mode {
                        Button {
                            showBarcodeScanner = true
                        } label: {
                            Label("バーコードで登録", systemImage: "barcode.viewfinder")
                        }

                        if let barcodeQuotaText {
                            Text(barcodeQuotaText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    HStack {
                        Text("数量")
                        Spacer()
                        
                        // -ボタン
                        Button {
                            if quantity > 1 { quantity -= 1 }
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 28, height: 28)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        
                        // 数量入力フィールド
                        TextField("", value: $quantity, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .frame(width: 50)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onChange(of: quantity) { oldValue, newValue in
                                if newValue < 1 { quantity = 1 }
                                if newValue > 9999 { quantity = 9999 }
                            }
                        
                        // +ボタン
                        Button {
                            if quantity < 9999 { quantity += 1 }
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 28, height: 28)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("基本情報")
                }
                
                // 賞味期限
                Section {
                    Toggle("賞味期限を設定", isOn: $hasExpiry)
                    
                    if hasExpiry {
                        DatePicker(
                            "賞味期限",
                            selection: $expiryDate,
                            displayedComponents: .date
                        )
                        
                        Button {
                            openOCRCamera()
                        } label: {
                            Label("カメラで読み取り", systemImage: "camera")
                        }

                        if let ocrQuotaText {
                            Text(ocrQuotaText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("賞味期限")
                }
                
                // 収納場所
                Section {
                    Picker("収納場所", selection: $selectedBagId) {
                        Text("未分類").tag(nil as UUID?)
                        ForEach(scopedBags) { bag in
                            Text(bag.name).tag(bag.id as UUID?)
                        }
                    }
                    
                    TextField("場所メモ", text: $locationNote, axis: .vertical)
                        .lineLimit(3...5)
                } header: {
                    Text("収納場所")
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .localizedRefresh()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!isValid || isSaving)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .sheet(isPresented: $showOCRCamera) {
                OCRCameraView { detectedDate in
                    if let date = detectedDate {
                        expiryDate = date
                        hasExpiry = true
                    }
                }
            }
            .sheet(isPresented: $showBarcodeScanner) {
                BarcodeScannerView { product in
                    // スキャン結果を品名に反映
                    name = product.name
                    janCode = product.janCode
                }
            }
        }
        .premiumPaywallSheet()
    }
    
    private func save() {
        guard !isSaving else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = locationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJANCode = janCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedJANCode = (trimmedJANCode?.isEmpty == false) ? trimmedJANCode : nil
        guard !trimmedName.isEmpty, quantity > 0 else { return }

        isSaving = true
        
        let selectedBag = scopedBags.first { $0.id == selectedBagId }
        let family = currentFamily
        
        switch mode {
        case .add:
            let newItem = Item(
                name: trimmedName,
                janCode: normalizedJANCode,
                quantity: quantity,
                expiryDate: hasExpiry ? expiryDate : nil,
                locationNote: trimmedNote.isEmpty ? nil : trimmedNote
            )
            newItem.bag = selectedBag
            newItem.family = family
            modelContext.insert(newItem)
            
        case .edit(let item):
            item.name = trimmedName
            item.janCode = normalizedJANCode
            item.quantity = quantity
            item.expiryDate = hasExpiry ? expiryDate : nil
            item.locationNote = trimmedNote.isEmpty ? nil : trimmedNote
            item.bag = selectedBag
            if item.family == nil {
                item.family = family
            }
            item.markUpdated()
        }
        
        do {
            try modelContext.save()
        } catch {
            isSaving = false
            #if DEBUG
            print("ローカル保存に失敗: \(error)")
            #endif
            return
        }
        
        NotificationManager.shared.requestReschedule(using: modelContext)
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

    private var ocrQuotaText: String? {
        guard let remaining = premiumAccessManager.remainingOCRQuota else { return nil }
        return L10n.format("無料版はあと%@回OCRを使えます。", String(remaining))
    }

    private var barcodeQuotaText: String? {
        guard let remaining = premiumAccessManager.remainingBarcodeQuota else { return nil }
        return L10n.format("無料版はあと%@回バーコード検索できます。", String(remaining))
    }

    private func openOCRCamera() {
        if premiumAccessManager.canUseOCR() {
            showOCRCamera = true
            return
        }

        premiumAccessManager.presentPaywall(for: .ocrQuota) {
            self.showOCRCamera = true
        }
    }
}

#Preview("Add") {
    ItemFormSheet(mode: .add)
        .environment(Router())
        .environment(PremiumAccessManager.shared)
        .modelContainer(for: [Family.self, Item.self, Bag.self, NotificationSettings.self], inMemory: true)
}
