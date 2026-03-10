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

/// アプリ全体のルーティングを管理
@Observable
final class Router {
    var path = NavigationPath()
    var presentedSheet: Sheet?
    
    enum Sheet: Identifiable {
        case addItem(bagId: UUID? = nil)
        case editItem(Item)
        case addBag
        case inviteCode(String)
        case importJSON
        case exportJSON
        case qrScanner
        
        var id: String {
            switch self {
            case .addItem: return "addItem"
            case .editItem(let item): return "editItem-\(item.id)"
            case .addBag: return "addBag"
            case .inviteCode: return "inviteCode"
            case .importJSON: return "importJSON"
            case .exportJSON: return "exportJSON"
            case .qrScanner: return "qrScanner"
            }
        }
    }
    
    func push(_ destination: Destination) {
        path.append(destination)
    }
    
    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }
    
    func popToRoot() {
        path.removeLast(path.count)
    }
    
    func present(_ sheet: Sheet) {
        presentedSheet = sheet
    }
    
    func dismissSheet() {
        presentedSheet = nil
    }
}
