import SwiftUI

/// ルーティング用の宛先定義
enum Destination: Hashable {
    case itemDetail(Item)
    case bagList
    case settings
    case familySetup
    case familySettings(Family)
    case notificationSettings
}

/// 下部タブ
enum AppTab: Hashable, CaseIterable {
    case home
    case stock
    case family
    case settings

    var title: LocalizedStringKey {
        switch self {
        case .home: return "ホーム"
        case .stock: return "在庫"
        case .family: return "家族"
        case .settings: return "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .stock: return "shippingbox"
        case .family: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

/// アプリ全体のルーティングを管理
@Observable
final class Router {
    var selectedTab: AppTab = .home
    var homePath = NavigationPath()
    var stockPath = NavigationPath()
    var familyPath = NavigationPath()
    var settingsPath = NavigationPath()
    var presentedSheet: Sheet?
    /// 在庫タブで開いて表示する収納場所（ホームの収納場所カードから指定する。nil の bagId は未分類）
    var stockFocusRequest: StockFocusRequest?
    /// 在庫の複数選択中など、下部のツールバーを使う画面でタブバーを隠す
    var isTabBarHidden = false

    struct StockFocusRequest {
        let bagId: UUID?
        let token = UUID()
    }

    func showStock(focusing bagId: UUID?) {
        stockFocusRequest = StockFocusRequest(bagId: bagId)
        select(.stock, resetPath: true)
    }

    /// 選択中タブのナビゲーション履歴
    var path: NavigationPath {
        get { path(for: selectedTab) }
        set { setPath(newValue, for: selectedTab) }
    }

    enum Sheet: Identifiable {
        case addMethod(bagId: UUID? = nil)
        case addItem(bagId: UUID? = nil, start: AddItemStart = .manual)
        case editItem(Item)
        case renewItem(Item)
        case addBag
        case inviteCode(String)
        case importJSON
        case exportJSON
        case qrScanner

        var id: String {
            switch self {
            case .addMethod: return "addMethod"
            case .addItem: return "addItem"
            case .editItem(let item): return "editItem-\(item.id)"
            case .renewItem(let item): return "renewItem-\(item.id)"
            case .addBag: return "addBag"
            case .inviteCode: return "inviteCode"
            case .importJSON: return "importJSON"
            case .exportJSON: return "exportJSON"
            case .qrScanner: return "qrScanner"
            }
        }
    }

    /// 追加フォームを開いたときに最初に行う読み取り
    enum AddItemStart {
        case manual
        case barcode
        case expiryPhoto
    }

    func path(for tab: AppTab) -> NavigationPath {
        switch tab {
        case .home: return homePath
        case .stock: return stockPath
        case .family: return familyPath
        case .settings: return settingsPath
        }
    }

    func setPath(_ newValue: NavigationPath, for tab: AppTab) {
        switch tab {
        case .home: homePath = newValue
        case .stock: stockPath = newValue
        case .family: familyPath = newValue
        case .settings: settingsPath = newValue
        }
    }

    /// タブのルートにあたる宛先はタブ切り替えに置き換え、それ以外は選択中タブに積む
    func push(_ destination: Destination) {
        switch destination {
        case .settings:
            select(.settings, resetPath: true)
        case .familySetup, .familySettings:
            select(.family, resetPath: true)
        case .notificationSettings:
            select(.settings, resetPath: true)
            settingsPath.append(destination)
        case .itemDetail, .bagList:
            path.append(destination)
        }
    }

    func select(_ tab: AppTab, resetPath: Bool = false) {
        selectedTab = tab
        if resetPath {
            setPath(NavigationPath(), for: tab)
        }
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path = NavigationPath()
    }

    func present(_ sheet: Sheet) {
        presentedSheet = sheet
    }

    func dismissSheet() {
        presentedSheet = nil
    }
}
