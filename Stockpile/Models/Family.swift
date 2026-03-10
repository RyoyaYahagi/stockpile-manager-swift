import Foundation
import SwiftData

/// 家族グループモデル
/// 備蓄品を共有するグループ単位
@Model
final class Family {
    var id: UUID = UUID()
    var name: String = ""
    var inviteCode: String = ""
    var lineGroupId: String?
    var cloudKitZoneName: String?
    var cloudKitZoneOwnerName: String?
    var cloudKitDatabaseScopeRawValue: String?
    var cloudKitShareURLString: String?
    var createdAt: Date = Date()
    
    @Relationship(deleteRule: .cascade, inverse: \User.family)
    var members: [User]? = []
    
    @Relationship(deleteRule: .cascade, inverse: \Bag.family)
    var bags: [Bag]? = []
    
    @Relationship(deleteRule: .cascade, inverse: \Item.family)
    var items: [Item]? = []
    
    init(name: String, inviteCode: String? = nil) {
        self.id = UUID()
        self.name = name
        self.inviteCode = inviteCode ?? Family.generateInviteCode()
        self.createdAt = Date()
    }

    var resolvedMembers: [User] {
        members ?? []
    }

    var resolvedBags: [Bag] {
        bags ?? []
    }

    var resolvedItems: [Item] {
        items ?? []
    }
    
    /// 6桁の招待コードを生成
    static func generateInviteCode() -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<6).map { _ in characters.randomElement()! })
    }
}

enum FamilyCloudKitDatabaseScope: String {
    case privateDatabase
    case sharedDatabase
}

extension Family {
    var cloudKitDatabaseScope: FamilyCloudKitDatabaseScope? {
        get {
            guard let rawValue = cloudKitDatabaseScopeRawValue else { return nil }
            return FamilyCloudKitDatabaseScope(rawValue: rawValue)
        }
        set {
            cloudKitDatabaseScopeRawValue = newValue?.rawValue
        }
    }

    var cloudKitShareURL: URL? {
        get {
            guard let cloudKitShareURLString,
                  let url = URL(string: cloudKitShareURLString) else {
                return nil
            }
            return url
        }
        set {
            cloudKitShareURLString = newValue?.absoluteString
        }
    }

    var isCloudKitSharedFamily: Bool {
        cloudKitZoneName != nil && cloudKitZoneOwnerName != nil && cloudKitDatabaseScope != nil
    }
}
