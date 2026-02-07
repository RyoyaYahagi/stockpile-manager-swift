import SwiftUI
import SwiftData

struct ItemDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Router.self) private var router
    @Bindable var item: Item
    
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        List {
            // 期限セクション
            Section {
                HStack {
                    Label("期限状態", systemImage: "clock")
                    Spacer()
                    ExpiryBadge(status: item.expiryStatus)
                    Text(item.expiryStatus.label)
                        .foregroundStyle(expiryColor)
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
                            .foregroundStyle(expiryColor)
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
        .confirmationDialog(
            "この備蓄品を削除しますか？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                modelContext.delete(item)
                router.pop()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }
    
    private var expiryColor: Color {
        switch item.expiryStatus {
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
    .modelContainer(for: [Item.self], inMemory: true)
}
