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
    var firebaseFamilyID: String?
    var firebaseContentHidden: Bool = false
    var cloudKitZoneName: String?
    var cloudKitZoneOwnerName: String?
    var cloudKitDatabaseScopeRawValue: String?
    var cloudKitShareURLString: String?
    var cloudKitPendingSync: Bool = false
    var cloudKitHasRemoteBaseline: Bool = false
    var lastSelectedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date.distantPast
    
    @Relationship(deleteRule: .cascade, inverse: \User.family)
    var members: [User]? = []
    
    @Relationship(deleteRule: .cascade, inverse: \Bag.family)
    var bags: [Bag]? = []
    
    @Relationship(deleteRule: .cascade, inverse: \Item.family)
    var items: [Item]? = []
    
    init(name: String, inviteCode: String? = nil) {
        self.id = UUID()
        self.name = name
        self.inviteCode = inviteCode ?? ""
        self.createdAt = Date()
        self.updatedAt = createdAt
    }

    var resolvedMembers: [User] {
        members ?? []
    }

    var uniqueMembers: [User] {
        var seenKeys = Set<String>()
        return resolvedMembers.filter { member in
            let key = member.deduplicationKey(familyID: id)
            return seenKeys.insert(key).inserted
        }
    }

    var resolvedBags: [Bag] {
        bags ?? []
    }

    var resolvedItems: [Item] {
        items ?? []
    }
    
}

enum FamilyCloudKitDatabaseScope: String {
    case privateDatabase
    case sharedDatabase
}

enum FamilyShareState {
    case localOnly
    case preparing
    case shared

    var label: String {
        switch self {
        case .localOnly:
            return L10n.string("未共有")
        case .preparing:
            return L10n.string("共有準備中")
        case .shared:
            return L10n.string("iCloud共有")
        }
    }
}

extension Family {
    func markAsCurrent(at date: Date = Date()) {
        lastSelectedAt = date
    }

    func markUpdated(at date: Date = Date()) {
        updatedAt = date
    }

    var syncTimestamp: Date {
        updatedAt == .distantPast ? createdAt : updatedAt
    }

    var hasScopedLocalData: Bool {
        !uniqueMembers.isEmpty || !resolvedBags.isEmpty || !resolvedItems.isEmpty
    }

    var isVisibleInApp: Bool {
        true
    }

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

    var shareState: FamilyShareState {
        if !cloudKitPendingSync {
            if cloudKitDatabaseScope == .sharedDatabase {
                return .shared
            }
            if cloudKitDatabaseScope == .privateDatabase, cloudKitShareURL != nil {
                return .shared
            }
        }

        if cloudKitPendingSync
            || cloudKitZoneName != nil
            || cloudKitZoneOwnerName != nil
            || cloudKitDatabaseScope != nil
            || cloudKitShareURL != nil {
            return .preparing
        }

        return .localOnly
    }

    var isCloudKitSharedFamily: Bool {
        shareState != .localOnly
    }

    var cloudKitZoneIdentity: String? {
        guard let cloudKitZoneName, let cloudKitZoneOwnerName else { return nil }
        return "\(cloudKitZoneOwnerName)::\(cloudKitZoneName)"
    }

    var shouldHideLegacyDisplayDetails: Bool {
        false
    }

    var shouldShowMemberList: Bool {
        return true
    }

    var prefersStrictCloudKitScoping: Bool {
        shareState != .localOnly && (cloudKitHasRemoteBaseline || hasScopedLocalData)
    }

    var displayNameForCurrentState: String {
        name
    }
}

extension User {
    func deduplicationKey(familyID: UUID) -> String {
        if let uid = lineUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !uid.isEmpty {
            return "family:\(familyID.uuidString):uid:\(uid)"
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !email.isEmpty {
            return "family:\(familyID.uuidString):email:\(email)"
        }
        return "family:\(familyID.uuidString):local:\(id.uuidString)"
    }
}

enum CurrentFamilyResolver {
    static func currentFamily(from families: [Family]) -> Family? {
        families
            .filter(\.isVisibleInApp)
            .max { lhs, rhs in
            compare(lhs, rhs)
        }
    }

    private static func compare(_ lhs: Family, _ rhs: Family) -> Bool {
        if let selectionComparison = compareSelectionPriority(lhs, rhs) {
            return selectionComparison
        }

        let lhsScore = score(for: lhs)
        let rhsScore = score(for: rhs)
        if lhsScore != rhsScore {
            return lhsScore < rhsScore
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static func compareSelectionPriority(_ lhs: Family, _ rhs: Family) -> Bool? {
        switch (lhs.lastSelectedAt, rhs.lastSelectedAt) {
        case let (lhsDate?, rhsDate?):
            guard lhsDate != rhsDate else { return nil }
            return lhsDate < rhsDate
        case (_?, nil):
            return false
        case (nil, _?):
            return true
        case (nil, nil):
            return nil
        }
    }

    private static func score(for family: Family) -> Int {
        let hasEstablishedSharedContext = family.cloudKitHasRemoteBaseline || family.hasScopedLocalData
        switch family.shareState {
        case .shared:
            if family.cloudKitDatabaseScope == .sharedDatabase {
                return hasEstablishedSharedContext ? 300 : 90
            }
            return hasEstablishedSharedContext ? 250 : 90
        case .preparing:
            return hasEstablishedSharedContext ? 200 : 80
        case .localOnly:
            var score = 100
            score += min(family.uniqueMembers.count, 5) * 4
            score += min(family.resolvedBags.count, 5) * 3
            score += min(family.resolvedItems.count, 10) * 2
            return score
        }
    }
}
