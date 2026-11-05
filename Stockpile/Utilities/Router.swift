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
    private(set) var design: AppDesign
    var legacyPath = NavigationPath()
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

    init(design: AppDesign = .stored()) {
        self.design = design
    }

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
        get { design == .legacy ? legacyPath : path(for: selectedTab) }
        set {
            if design == .legacy {
                legacyPath = newValue
            } else {
                setPath(newValue, for: selectedTab)
            }
        }
    }

    enum Sheet: Identifiable {
        case addMethod(bagId: UUID? = nil)
        case addItem(bagId: UUID? = nil, prefill: AddItemPrefill? = nil)
        case scanBarcode(bagId: UUID?)
        case scanExpiry(bagId: UUID?)
        case editItem(Item)
        case renewItem(Item)
        case addBag
        case inviteCode(String)
        case importJSON
        case exportJSON
        case aiLink
        case qrScanner

        var id: String {
            switch self {
            case .addMethod: return "addMethod"
            case .addItem: return "addItem"
            case .scanBarcode: return "scanBarcode"
            case .scanExpiry: return "scanExpiry"
            case .editItem(let item): return "editItem-\(item.id)"
            case .renewItem(let item): return "renewItem-\(item.id)"
            case .addBag: return "addBag"
            case .inviteCode: return "inviteCode"
            case .importJSON: return "importJSON"
            case .exportJSON: return "exportJSON"
            case .aiLink: return "aiLink"
            case .qrScanner: return "qrScanner"
            }
        }
    }

    /// 読み取り画面から追加フォームへ渡す内容
    struct AddItemPrefill {
        var name: String?
        var janCode: String?
        var expiryDate: Date?
        /// フォームの上に出す「〜を入れました」
        var message: String
    }

    /// シートを閉じ終わってから次のシートを出す（読み取り画面 → 追加フォーム）
    @MainActor
    func presentAfterDismiss(_ sheet: Sheet) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            presentedSheet = sheet
        }
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
        if design == .legacy {
            legacyPath.append(destination)
            return
        }
        switch destination {
        case .settings:
            select(.settings, resetPath: true)
        case .familySetup, .familySettings:
            select(.family, resetPath: true)
        case .notificationSettings:
            // 通知の設定は設定タブの「お知らせ」カードにまとめた
            select(.settings, resetPath: true)
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

    /// Stay in settings after switching, with no destinations from the other layout.
    func switchDesign(to design: AppDesign) {
        dismissSheet()
        self.design = design
        legacyPath = NavigationPath()
        homePath = NavigationPath()
        stockPath = NavigationPath()
        familyPath = NavigationPath()
        settingsPath = NavigationPath()
        selectedTab = .settings
        isTabBarHidden = false
        stockFocusRequest = nil
        if design == .legacy {
            legacyPath.append(Destination.settings)
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
