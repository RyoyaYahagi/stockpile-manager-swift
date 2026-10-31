import SwiftUI
import SwiftData

/// 「入れ替えた」: 新しく買った分の賞味期限を入れる
struct RenewExpirySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PremiumAccessManager.self) private var premiumAccessManager
    @Query(sort: \Family.createdAt, order: .reverse) private var families: [Family]

    @Bindable var item: Item

    @State private var expiryDate: Date
    @State private var hasExpiry = true
    @State private var quantity: Int
    @State private var showOCRCamera = false
    @State private var didReadFromPhoto = false

    init(item: Item) {
        self.item = item
        let base = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        _expiryDate = State(initialValue: base)
        _quantity = State(initialValue: max(1, item.quantity))
    }

    private var currentFamily: Family? {
        CurrentFamilyResolver.currentFamily(from: families)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name)
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                        Text("新しく用意した分の賞味期限を入れてください。")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(AppTheme.card)

                Section {
                    HStack {
                        Text("数量")
                        Spacer()
                        QuantityStepper(quantity: quantity, minimum: 1) { quantity = $0 }
                    }
                }
                .listRowBackground(AppTheme.card)

                Section {
                    Toggle("賞味期限を設定", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker(
                            "賞味期限",
                            selection: $expiryDate,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)

                        Button {
                            openOCRCamera()
                        } label: {
                            Label("撮影して読み取る", systemImage: "camera")
                        }

                        if didReadFromPhoto {
                            Label("パッケージから賞味期限を読み取りました", systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppTheme.accentInk)
                        }
                    }
                }
                .listRowBackground(AppTheme.card)
            }
            .appScreenBackground()
            .tint(AppTheme.accent)
            .navigationTitle("入れ替えた")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.bold)
                }
            }
            .sheet(isPresented: $showOCRCamera) {
                OCRCameraView { detectedDate in
                    if let detectedDate {
                        expiryDate = detectedDate
                        hasExpiry = true
                        didReadFromPhoto = true
                    }
                }
            }
        }
        .localizedRefresh()
        .premiumPaywallSheet()
    }

    private func save() {
        InventoryStore.renew(item, expiryDate: hasExpiry ? expiryDate : nil, quantity: quantity)
        InventoryStore.saveAndSync(modelContext, family: currentFamily)
        dismiss()
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
