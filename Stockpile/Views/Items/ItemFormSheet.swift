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
    @AppStorage(BagOrderStore.revisionKey) private var bagOrderRevision = 0

    @State private var name: String = ""
    @State private var quantity: Int = 1
    @State private var expiryDate: Date = Date()
    @State private var hasExpiry: Bool = true
    @State private var janCode: String?
    @State private var selectedBagId: UUID?
    @State private var locationNote: String = ""
    @State private var showOCRCamera = false
    @State private var showBarcodeScanner = false
    @State private var showAddBag = false
    @State private var isSaving = false
    @State private var autofillMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case quantity
        case note
    }

    init(mode: Mode, preselectedBagId: UUID? = nil, prefill: Router.AddItemPrefill? = nil) {
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
            // 追加モードの場合、プリセット収納場所と読み取り結果を設定
            _selectedBagId = State(initialValue: preselectedBagId)
            if let prefill {
                _name = State(initialValue: prefill.name ?? "")
                _janCode = State(initialValue: prefill.janCode)
                if let date = prefill.expiryDate {
                    _expiryDate = State(initialValue: date)
                    _hasExpiry = State(initialValue: true)
                }
                _autofillMessage = State(initialValue: prefill.message)
            }
        }
    }

    private var isAddMode: Bool {
        if case .add = mode { return true }
        return false
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quantity > 0
    }

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    private var scopedBags: [Bag] {
        _ = bagOrderRevision
        return BagOrderStore.sorted(InventoryStore.scopedBags(bags, family: currentFamily), family: currentFamily)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let autofillMessage {
                        Label(autofillMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.accentInk)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    nameField
                    quantityAndExpiry
                    locationField
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .appScreenBackground()
            .tint(AppTheme.accent)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .localizedRefresh()
            .safeAreaInset(edge: .bottom) {
                Button {
                    save()
                } label: {
                    Text(isAddMode ? "備蓄に追加する" : "保存")
                        .font(.body.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!isValid || isSaving)
                .opacity(isValid ? 1 : 0.5)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { focusedField = nil }
                }
            }
            .sheet(isPresented: $showOCRCamera) {
                OCRCameraView { detectedDate in
                    if let date = detectedDate {
                        expiryDate = date
                        hasExpiry = true
                        showAutofill(L10n.string("パッケージから賞味期限を読み取りました"))
                    }
                }
            }
            .sheet(isPresented: $showBarcodeScanner) {
                BarcodeScannerView { product in
                    // スキャン結果を品名に反映
                    name = product.name
                    janCode = product.janCode
                    showAutofill(L10n.string("バーコードから品名を入れました"))
                }
            }
            .sheet(isPresented: $showAddBag) {
                BagFormSheet()
            }
        }
        .premiumPaywallSheet()
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("品名")
            HStack(spacing: 8) {
                TextField("品名（例: 水、缶詰、乾電池）", text: $name)
                    .font(.body)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.done)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(inputBackground)

                if isAddMode {
                    Button {
                        showBarcodeScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(AppTheme.accentInk)
                            .frame(width: 52, height: 52)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.92))
                    .glassSurface(in: Circle(), interactive: true)
                    .accessibilityLabel(Text("バーコードを読み取る"))
                }
            }
            if isAddMode, let barcodeQuotaText {
                Text(barcodeQuotaText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSecondary)
            }
        }
    }

    private var quantityAndExpiry: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("数量")
                    HStack(spacing: 4) {
                        stepButton(symbol: "minus", label: "1つ減らす") {
                            if quantity > 1 { quantity -= 1 }
                        }
                        .disabled(quantity <= 1)
                        TextField("", value: $quantity, format: .number)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .quantity)
                            .multilineTextAlignment(.center)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .onChange(of: quantity) { _, newValue in
                                if newValue < 1 { quantity = 1 }
                                if newValue > 9999 { quantity = 9999 }
                            }
                        stepButton(symbol: "plus", label: "1つ増やす") {
                            if quantity < 9999 { quantity += 1 }
                        }
                        .disabled(quantity >= 9999)
                    }
                    .padding(.horizontal, 4)
                    .frame(minHeight: 52)
                    .background(inputBackground)
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("賞味期限")
                    Group {
                        if hasExpiry {
                            DatePicker("賞味期限", selection: $expiryDate, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        } else {
                            Button {
                                hasExpiry = true
                            } label: {
                                Text("期限なし")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(AppTheme.inkSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .background(inputBackground)
                }
            }

            FlowChips {
                ChoiceChip(title: "撮影して読み取る", systemImage: "camera", isSelected: false) {
                    openOCRCamera()
                }
                ChoiceChip(title: "期限なし", systemImage: nil, isSelected: !hasExpiry) {
                    withAnimation(AppTheme.popAnimation) { hasExpiry.toggle() }
                }
            }

            if let ocrQuotaText {
                Text(ocrQuotaText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.inkSecondary)
            }
        }
    }

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("しまう場所")
            FlowChips {
                ChoiceChip(title: "未分類", systemImage: nil, isSelected: selectedBagId == nil) {
                    selectedBagId = nil
                }
                ForEach(scopedBags) { bag in
                    ChoiceChip(verbatim: bag.name, isSelected: selectedBagId == bag.id) {
                        selectedBagId = bag.id
                    }
                }
                ChoiceChip(title: "新しい場所", systemImage: "plus", isSelected: false, isDashed: true) {
                    showAddBag = true
                }
            }

            TextField("場所メモ", text: $locationNote, axis: .vertical)
                .lineLimit(2...4)
                .focused($focusedField, equals: .note)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(inputBackground)
                .padding(.top, 4)
        }
    }

    private func fieldLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.bold))
            .foregroundStyle(AppTheme.inkSecondary)
            .padding(.horizontal, 4)
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(AppTheme.card)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.ink.opacity(0.1), lineWidth: 1)
            }
    }

    private func stepButton(symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.9))
        .accessibilityLabel(Text(label))
    }

    // MARK: - Actions

    private func showAutofill(_ message: String) {
        withAnimation(AppTheme.riseAnimation) {
            autofillMessage = message
        }
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

// MARK: - Chips

/// 選択チップ（選択中は緑の枠と淡い面）
struct ChoiceChip: View {
    private let title: Text
    private let systemImage: String?
    private let isSelected: Bool
    private let isDashed: Bool
    private let action: () -> Void

    init(
        title: LocalizedStringKey,
        systemImage: String?,
        isSelected: Bool,
        isDashed: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isDashed = isDashed
        self.action = action
    }

    init(verbatim: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = Text(verbatim: verbatim)
        self.systemImage = nil
        self.isSelected = isSelected
        self.isDashed = false
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                title
                    .font(.subheadline.weight(isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AppTheme.accentInk : AppTheme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background {
                Capsule()
                    .fill(isSelected ? AppTheme.accentSoft : AppTheme.card)
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                isSelected ? AppTheme.accent : AppTheme.ink.opacity(0.12),
                                style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: isDashed ? [4, 3] : [])
                            )
                    }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 横に並べ、入りきらなければ折り返すレイアウト
struct FlowChips<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: spacing) {
            content
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if nextWidth > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = nextWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
