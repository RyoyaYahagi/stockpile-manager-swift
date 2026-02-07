import SwiftUI
import SwiftData

/// アイテム追加/編集フォーム
struct ItemFormSheet: View {
    enum Mode {
        case add
        case edit(Item)
        
        var title: String {
            switch self {
            case .add: return "備蓄品を追加"
            case .edit: return "備蓄品を編集"
            }
        }
    }
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    let mode: Mode
    
    @Query private var bags: [Bag]
    
    @State private var name: String = ""
    @State private var quantity: Int = 1
    @State private var expiryDate: Date = Date()
    @State private var hasExpiry: Bool = true
    @State private var selectedBagId: UUID?
    @State private var locationNote: String = ""
    @State private var showOCRCamera = false
    
    init(mode: Mode) {
        self.mode = mode
        
        // 編集モードの場合、初期値を設定
        if case .edit(let item) = mode {
            _name = State(initialValue: item.name)
            _quantity = State(initialValue: item.quantity)
            _expiryDate = State(initialValue: item.expiryDate ?? Date())
            _hasExpiry = State(initialValue: item.expiryDate != nil)
            _selectedBagId = State(initialValue: item.bag?.id)
            _locationNote = State(initialValue: item.locationNote ?? "")
        }
    }
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quantity > 0
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // 基本情報
                Section {
                    TextField("品名", text: $name)
                    
                    Stepper("数量: \(quantity)", value: $quantity, in: 1...999)
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
                            showOCRCamera = true
                        } label: {
                            Label("カメラで読み取り", systemImage: "camera")
                        }
                    }
                } header: {
                    Text("賞味期限")
                }
                
                // 収納場所
                Section {
                    Picker("収納場所", selection: $selectedBagId) {
                        Text("未分類").tag(nil as UUID?)
                        ForEach(bags) { bag in
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!isValid)
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
        }
    }
    
    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = locationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let selectedBag = bags.first { $0.id == selectedBagId }
        
        switch mode {
        case .add:
            let newItem = Item(
                name: trimmedName,
                quantity: quantity,
                expiryDate: hasExpiry ? expiryDate : nil,
                locationNote: trimmedNote.isEmpty ? nil : trimmedNote
            )
            newItem.bag = selectedBag
            modelContext.insert(newItem)
            
        case .edit(let item):
            item.name = trimmedName
            item.quantity = quantity
            item.expiryDate = hasExpiry ? expiryDate : nil
            item.locationNote = trimmedNote.isEmpty ? nil : trimmedNote
            item.bag = selectedBag
        }
        
        dismiss()
    }
}

#Preview("Add") {
    ItemFormSheet(mode: .add)
        .environment(Router())
        .modelContainer(for: [Item.self, Bag.self], inMemory: true)
}
