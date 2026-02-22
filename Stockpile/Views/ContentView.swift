import SwiftUI
import SwiftData

extension Notification.Name {
    static let didTapNotification = Notification.Name("didTapNotification")
}

@MainActor
enum NotificationTapRelay {
    private static var pendingUserInfo: [AnyHashable: Any]?
    
    static func storeAndPost(_ userInfo: [AnyHashable: Any]) {
        pendingUserInfo = userInfo
        NotificationCenter.default.post(
            name: .didTapNotification,
            object: nil,
            userInfo: userInfo
        )
    }
    
    static func consumePending() -> [AnyHashable: Any]? {
        defer { pendingUserInfo = nil }
        return pendingUserInfo
    }
}

struct ContentView: View {
    @State private var router = Router()
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    
    var body: some View {
        NavigationStack(path: $router.path) {
            DashboardView()
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .itemDetail(let item):
                        ItemDetailView(item: item)
                    case .bagList:
                        BagListView()
                    case .settings:
                        SettingsView()
                    case .familySetup:
                        FamilySetupView()
                    case .familySettings(let family):
                        FamilySettingsView(family: family)
                    case .notificationSettings:
                        NotificationSettingsView()
                    }
                }
        }
        .environment(router)
        .sheet(item: $router.presentedSheet) { sheet in
            sheetContent(for: sheet)
                .environment(router)
        }
        .task {
            if let pendingUserInfo = NotificationTapRelay.consumePending() {
                handleNotificationTap(
                    Notification(
                        name: .didTapNotification,
                        object: nil,
                        userInfo: pendingUserInfo
                    )
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapNotification)) { notification in
            _ = NotificationTapRelay.consumePending()
            handleNotificationTap(notification)
        }
    }
    
    @ViewBuilder
    private func sheetContent(for sheet: Router.Sheet) -> some View {
        switch sheet {
        case .addItem(let bagId):
            ItemFormSheet(mode: .add, preselectedBagId: bagId)
        case .editItem(let item):
            ItemFormSheet(mode: .edit(item))
        case .addBag:
            BagFormSheet()
        case .inviteCode(let code):
            InviteCodeView(code: code)
        case .importJSON:
            ImportJSONView()
        case .qrScanner:
            QRScannerView { _ in
                // QRスキャン結果の処理はFamilySetupViewで行う
            }
        }
    }
    
    /// プッシュ通知タップ時のハンドリング
    private func handleNotificationTap(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        
        // シートが開いている場合は閉じる
        router.dismissSheet()
        
        // 単一アイテムの場合 → アイテム詳細へ遷移
        if let itemId = extractItemId(from: userInfo["itemId"]) {
            if let item = items.first(where: { $0.id == itemId }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    router.popToRoot()
                    router.push(.itemDetail(item))
                }
            }
        }
        // 複数アイテムの場合 → ダッシュボード（すべて表示）へ遷移
        else if userInfo["itemIds"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                router.popToRoot()
                // ルートに戻るだけでOK（DashboardViewのselectedBagIdはデフォルトでnil=すべて）
            }
        }
    }
    
    private func extractItemId(from rawValue: Any?) -> UUID? {
        if let uuid = rawValue as? UUID {
            return uuid
        }
        
        if let uuidString = rawValue as? String {
            return UUID(uuidString: uuidString)
        }
        
        return nil
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Family.self, User.self, Bag.self, Item.self, NotificationSettings.self], inMemory: true)
}
