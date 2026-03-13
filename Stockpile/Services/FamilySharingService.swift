import Foundation
import SwiftData
import CloudKit
import UIKit
import FirebaseAuth
import FirebaseFirestore
import Network
import OSLog

/// 家族共有サービス
/// 招待コードの生成・検証、家族への参加・離脱を管理
@MainActor
final class FamilySharingService {
    private let modelContext: ModelContext
    private let firebaseClient: FirebaseSDKClient

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        APIConfig.configureFirebaseIfNeeded()
        self.firebaseClient = FirebaseSDKClient()
    }

    /// 招待URLを生成
    func generateInviteURL(for family: Family) -> URL? {
        var components = URLComponents()
        components.scheme = "stockpile"
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "code", value: family.inviteCode)
        ]
        return components.url
    }

    /// 招待コードを再生成
    func regenerateInviteCode(for family: Family) {
        family.inviteCode = Family.generateInviteCode()
    }

    /// 共有を開始し、招待を作成
    func startSharing(family: Family) async throws {
        guard APIConfig.isFirebaseEnabled else {
            throw SharingError.firebaseNotConfigured
        }

        let familySnapshot = FamilySnapshot(
            id: family.id.uuidString,
            name: family.name,
            inviteCode: family.inviteCode,
            lineGroupId: family.lineGroupId,
            createdAt: family.createdAt
        )

        do {
            try await firebaseClient.publishInvite(for: familySnapshot)
        } catch {
            throw SharingError.firebaseFailure(error.localizedDescription)
        }
    }

    /// 招待コードの有効期限を延長
    func refreshInviteCode(for family: Family) async throws {
        try await startSharing(family: family)
    }

    /// 招待コードで家族を検索（ローカル）
    func findFamilyLocally(byInviteCode code: String) -> Family? {
        let descriptor = FetchDescriptor<Family>(
            predicate: #Predicate { $0.inviteCode == code }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// 招待コードで家族を検索（Firebase）
    func findFamilyInCloud(byInviteCode code: String) async throws -> FirebaseInviteInfo? {
        guard APIConfig.isFirebaseEnabled else {
            throw SharingError.firebaseNotConfigured
        }

        return try await firebaseClient.fetchInvite(byCode: code)
    }

    /// 招待コードから家族に参加
    func joinFamilyWithCode(_ code: String) async throws -> JoinResult {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard normalizedCode.count == 6 else {
            return .error(SharingError.invalidInviteCode)
        }

        if let existingFamily = findFamilyLocally(byInviteCode: normalizedCode) {
            return .alreadyMember(existingFamily)
        }

        guard let inviteInfo = try await findFamilyInCloud(byInviteCode: normalizedCode) else {
            return .notFound
        }

        if inviteInfo.isExpired {
            return .expired
        }

        do {
            let familyName = inviteInfo.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let family = Family(
                name: familyName.isEmpty ? "家族" : familyName,
                inviteCode: normalizedCode
            )

            if let remoteFamilyID = UUID(uuidString: inviteInfo.familyId) {
                let allFamilies = try modelContext.fetch(FetchDescriptor<Family>())
                if let existingFamily = allFamilies.first(where: { $0.id == remoteFamilyID }) {
                    return .alreadyMember(existingFamily)
                }
                family.id = remoteFamilyID
            }

            modelContext.insert(family)
            try modelContext.save()

            do {
                try await firebaseClient.addCurrentUserAsMember(familyId: inviteInfo.familyId)
                try await syncFamilyMembersFromFirebase(for: family)
                _ = try await syncFamilyDataFromFirebase(for: family)
            } catch {
                return .pendingSync("Firebase同期を後で再試行します: \(error.localizedDescription)")
            }

            return .success(family)
        } catch {
            return .error(error)
        }
    }

    /// URLから招待コードを抽出
    func extractInviteCode(from url: URL) -> String? {
        guard url.scheme == "stockpile",
              url.host == "join",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let codeItem = components.queryItems?.first(where: { $0.name == "code" }) else {
            return nil
        }
        return codeItem.value
    }

    /// 現在の家族を取得
    func getCurrentFamily() -> Family? {
        let descriptor = FetchDescriptor<Family>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// 家族から離脱
    func leaveFamily(_ family: Family) async throws {
        for member in family.resolvedMembers {
            member.family = nil
        }
        try modelContext.save()

        guard APIConfig.isFirebaseEnabled else {
            return
        }

        do {
            try await firebaseClient.deleteInvite(
                familyId: family.id.uuidString,
                inviteCode: family.inviteCode
            )
        } catch {
            throw SharingError.firebaseFailure(error.localizedDescription)
        }
    }

    /// 期限切れの招待を削除
    func cleanupExpiredInvites() async throws {
        guard APIConfig.isFirebaseEnabled else {
            throw SharingError.firebaseNotConfigured
        }

        do {
            try await firebaseClient.deleteExpiredInvites()
        } catch {
            throw SharingError.firebaseFailure(error.localizedDescription)
        }
    }

    /// 初回家族作成時にローカルデータをFirebaseへ移行
    func migrateInitialDataToFirebaseIfNeeded(for family: Family) async throws {
        let migrationService = FirebaseMigrationService(modelContext: modelContext)
        try await migrationService.migrateIfNeeded(for: family)
        _ = try await syncFamilyDataFromFirebase(for: family)
    }

    /// 失敗中のFirebase初回移行を再試行
    func retryInitialFirebaseMigration(for family: Family) async throws {
        let migrationService = FirebaseMigrationService(modelContext: modelContext)
        try await migrationService.retryMigration(for: family)
        _ = try await syncFamilyDataFromFirebase(for: family)
    }

    /// Firebase初回移行の状態を取得
    func firebaseMigrationStatus(for family: Family) -> FirebaseMigrationService.MigrationStatus {
        let migrationService = FirebaseMigrationService(modelContext: modelContext)
        return migrationService.status(for: family)
    }

    /// Firebase上のメンバー情報をローカルへ同期
    @discardableResult
    func syncFamilyMembersFromFirebase(for family: Family) async throws -> Int {
        guard APIConfig.isFirebaseEnabled else {
            return 0
        }

        let remoteMembers = try await firebaseClient.fetchMembers(familyId: family.id.uuidString)
        for member in remoteMembers {
            upsertLocalMember(
                in: family,
                uid: member.uid,
                displayName: member.displayName,
                email: member.email
            )
        }
        try modelContext.save()
        return remoteMembers.count
    }

    /// Firebase上の家族データ（Bag/Item）をローカルへ反映
    @discardableResult
    func syncFamilyDataFromFirebase(for family: Family) async throws -> (bags: Int, items: Int) {
        guard APIConfig.isFirebaseEnabled else {
            return (bags: 0, items: 0)
        }

        let remoteBags = try await firebaseClient.fetchBags(familyId: family.id.uuidString)
        let remoteItems = try await firebaseClient.fetchItems(familyId: family.id.uuidString)
        try applyRemoteFamilyData(in: family, remoteBags: remoteBags, remoteItems: remoteItems)
        try modelContext.save()
        NotificationManager.shared.requestReschedule(using: modelContext)
        return (bags: remoteBags.count, items: remoteItems.count)
    }

    /// Firebase接続済み家族のローカル変更をFirebaseへ同期（削除含む）
    func syncFamilyDataToFirebase(for family: Family) async throws {
        guard APIConfig.isFirebaseEnabled else {
            return
        }

        let snapshots = try buildLocalFamilySnapshots(for: family, modelContext: modelContext)
        do {
            try await firebaseClient.syncFamily(
                family: snapshots.family,
                bags: snapshots.bags,
                items: snapshots.items
            )
        } catch {
            if FirebaseSyncRetryCoordinator.isRetryable(error) {
                FirebaseSyncRetryCoordinator.shared.enqueueFamilySync(familyID: family.id)
            }
            throw error
        }
    }

    /// Firebase上の家族状態をローカルへ同期（メンバー + Bag/Item）
    func syncFamilyStateFromFirebase(for family: Family) async throws {
        do {
            _ = try await syncFamilyMembersFromFirebase(for: family)
            _ = try await syncFamilyDataFromFirebase(for: family)
        } catch {
            if FirebaseSyncRetryCoordinator.isRetryable(error) {
                FirebaseSyncRetryCoordinator.shared.enqueueFamilySync(familyID: family.id)
            }
            throw error
        }
    }

    private func applyRemoteFamilyData(
        in family: Family,
        remoteBags: [FirebaseBagInfo],
        remoteItems: [FirebaseItemInfo]
    ) throws {
        let sanitizedRemoteBags = remoteBags.compactMap { bag -> FirebaseBagInfo? in
            guard let normalizedName = normalizedNonEmptyString(bag.name) else { return nil }
            return FirebaseBagInfo(
                id: bag.id,
                name: normalizedName,
                createdAt: bag.createdAt
            )
        }
        let sanitizedRemoteItems = remoteItems.compactMap { item -> FirebaseItemInfo? in
            guard let normalizedName = normalizedNonEmptyString(item.name) else { return nil }
            return FirebaseItemInfo(
                id: item.id,
                name: normalizedName,
                quantity: item.quantity,
                expiryDate: item.expiryDate,
                bagId: item.bagId,
                locationNote: normalizedOptionalString(item.locationNote),
                notified30: item.notified30,
                notified7: item.notified7,
                notified1: item.notified1,
                createdAt: item.createdAt
            )
        }

        let allBags = try modelContext.fetch(FetchDescriptor<Bag>())
        let allItems = try modelContext.fetch(FetchDescriptor<Item>())
        let localFamilyBags = allBags.filter { $0.family?.id == family.id }
        let localFamilyItems = allItems.filter { $0.family?.id == family.id }

        var bagById = Dictionary(
            uniqueKeysWithValues: localFamilyBags.map { ($0.id.uuidString, $0) }
        )
        for remoteBag in sanitizedRemoteBags {
            guard let remoteBagID = UUID(uuidString: remoteBag.id) else { continue }
            if let existingBag = bagById[remoteBag.id] {
                existingBag.name = remoteBag.name
                existingBag.createdAt = remoteBag.createdAt
                existingBag.family = family
            } else {
                let bag = Bag(name: remoteBag.name)
                bag.id = remoteBagID
                bag.createdAt = remoteBag.createdAt
                bag.family = family
                modelContext.insert(bag)
                bagById[remoteBag.id] = bag
            }
        }

        var itemById = Dictionary(
            uniqueKeysWithValues: localFamilyItems.map { ($0.id.uuidString, $0) }
        )
        for remoteItem in sanitizedRemoteItems {
            guard let remoteItemID = UUID(uuidString: remoteItem.id) else { continue }
            let linkedBag = remoteItem.bagId.flatMap { bagById[$0] }

            if let existingItem = itemById[remoteItem.id] {
                existingItem.name = remoteItem.name
                existingItem.quantity = remoteItem.quantity
                existingItem.expiryDate = remoteItem.expiryDate
                existingItem.bag = linkedBag
                existingItem.locationNote = remoteItem.locationNote
                existingItem.notified30 = remoteItem.notified30
                existingItem.notified7 = remoteItem.notified7
                existingItem.notified1 = remoteItem.notified1
                existingItem.createdAt = remoteItem.createdAt
                existingItem.family = family
            } else {
                let item = Item(
                    name: remoteItem.name,
                    quantity: max(1, remoteItem.quantity),
                    expiryDate: remoteItem.expiryDate,
                    locationNote: remoteItem.locationNote
                )
                item.id = remoteItemID
                item.notified30 = remoteItem.notified30
                item.notified7 = remoteItem.notified7
                item.notified1 = remoteItem.notified1
                item.createdAt = remoteItem.createdAt
                item.family = family
                item.bag = linkedBag
                modelContext.insert(item)
                itemById[remoteItem.id] = item
            }
        }

        let remoteItemIDs = Set(sanitizedRemoteItems.map(\.id))
        for localItem in localFamilyItems where !remoteItemIDs.contains(localItem.id.uuidString) {
            modelContext.delete(localItem)
        }

        let remoteBagIDs = Set(sanitizedRemoteBags.map(\.id))
        for localBag in localFamilyBags where !remoteBagIDs.contains(localBag.id.uuidString) {
            modelContext.delete(localBag)
        }
    }

    private func upsertLocalMember(
        in family: Family,
        uid: String,
        displayName: String,
        email: String?
    ) {
        if let existing = family.resolvedMembers.first(where: { $0.lineUserId == uid }) {
            if !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.displayName = displayName
            }
            existing.email = email
            existing.family = family
            existing.lineUserId = uid
            return
        }

        let user = User(displayName: displayName, email: email)
        user.family = family
        user.lineUserId = uid
        modelContext.insert(user)
    }

    enum JoinResult {
        case success(Family)
        case alreadyMember(Family)
        case pendingSync(String)
        case notFound
        case expired
        case error(Error)

        var isSuccess: Bool {
            switch self {
            case .success, .alreadyMember, .pendingSync:
                return true
            default:
                return false
            }
        }
    }

    enum SharingError: LocalizedError {
        case invalidInviteCode
        case familyNotFound
        case alreadyInFamily
        case firebaseNotConfigured
        case firebaseFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidInviteCode:
                return "無効な招待コードです"
            case .familyNotFound:
                return "家族が見つかりません"
            case .alreadyInFamily:
                return "既にこの家族に参加しています"
            case .firebaseNotConfigured:
                return "Firebase連携は開発者オプション有効時のみ利用できます。設定で有効化し、GoogleService-Info.plistを確認してください。"
            case .firebaseFailure(let detail):
                return "Firebaseエラー: \(detail)"
            }
        }
    }
}

@MainActor
final class CloudKitFamilySharingService {
    private enum Constants {
        static let familyRecordType = "Family"
        static let bagRecordType = "Bag"
        static let itemRecordType = "Item"
    }

    private let logger = Logger(subsystem: "com.stockpile-manager.app", category: "CloudKitSharing")
    private let modelContext: ModelContext
    private let container: CKContainer

    init(modelContext: ModelContext, container: CKContainer = .default()) {
        self.modelContext = modelContext
        self.container = container
    }

    func prepareShare(for family: Family) async throws -> CKShare {
        let retryIntervalsInNanoseconds: [UInt64] = [
            0,
            750_000_000,
            1_500_000_000,
            3_000_000_000
        ]
        var lastError: Error?

        for (index, interval) in retryIntervalsInNanoseconds.enumerated() {
            if interval > 0 {
                try await Task.sleep(nanoseconds: interval)
            }

            do {
                return try await prepareShare(
                    for: family,
                    resettingMetadataOnFailure: index == 0
                )
            } catch {
                lastError = error
                logShareError(error, phase: "prepareShare.retry[\(index)]")

                if index < retryIntervalsInNanoseconds.count - 1,
                   let existingShare = try await fetchExistingShareAfterTransientFailure(for: family) {
                    family.cloudKitShareURL = existingShare.url
                    try? modelContext.save()
                    return existingShare
                }

                guard shouldRetrySharePreparation(after: error),
                      index < retryIntervalsInNanoseconds.count - 1 else {
                    throw normalizeSharePreparationError(error)
                }
            }
        }

        throw normalizeSharePreparationError(
            lastError ?? CloudKitSharingError.sharePreparationFailed(detail: "不明なエラー")
        )
    }

    private func prepareShare(
        for family: Family,
        resettingMetadataOnFailure shouldResetMetadataOnFailure: Bool
    ) async throws -> CKShare {
        ensureCloudKitMetadata(for: family)
        try await ensureZoneExists(for: family)
        // Family レコードをゾーンに先に保存（初回は isCloudKitSharedFamily が false のため
        // syncFamilyDataToCloudKit の guard を通過しないケースに対応）
        try await ensureFamilyRecordExists(for: family)
        try await syncFamilyDataToCloudKit(for: family)

        let database = container.privateCloudDatabase
        if let existingShare = try await fetchExistingShare(for: family, in: database) {
            family.cloudKitShareURL = existingShare.url
            family.cloudKitPendingSync = false
            try? modelContext.save()
            return existingShare
        }

        let share = CKShare(recordZoneID: zoneID(for: family))
        share[CKShare.SystemFieldKey.title] = family.name as CKRecordValue
        share.publicPermission = .none

        do {
            let savedShare = try await save(record: share, in: database) as? CKShare
            guard let savedShare else {
                throw CloudKitSharingError.invalidShareRecord
            }

            family.cloudKitShareURL = savedShare.url
            family.cloudKitPendingSync = false
            try? modelContext.save()
            return savedShare
        } catch {
            logShareError(error, phase: "prepareShare.saveShare")
            if shouldResetMetadataOnFailure,
               shouldRetrySharePreparation(after: error) {
                resetShareMetadata(for: family)
                return try await prepareShare(for: family, resettingMetadataOnFailure: false)
            }

            throw error
        }
    }

    @discardableResult
    func acceptShare(metadata: CKShare.Metadata) async throws -> Family {
        let acceptedShare = try await accept(metadata: metadata, using: container)
        let acceptedZoneID = acceptedShare.recordID.zoneID
        do {
            return try await syncAcceptedShareToLocal(zoneID: acceptedZoneID)
        } catch {
            createOrUpdatePendingFamily(
                from: metadata,
                acceptedShare: acceptedShare,
                zoneID: acceptedZoneID
            )
            throw error
        }
    }

    func syncFamilyDataToCloudKit(for family: Family) async throws {
        guard family.isCloudKitSharedFamily else { return }

        let database = database(for: family)
        if family.cloudKitDatabaseScope == .privateDatabase {
            try await ensureZoneExists(for: family)
        }

        let familyRecord = makeFamilyRecord(from: family)
        let bagRecords = family.resolvedBags.map { makeBagRecord(from: $0, family: family) }
        let itemRecords = family.resolvedItems.map { makeItemRecord(from: $0, family: family) }
        let recordsToSave = [familyRecord] + bagRecords + itemRecords

        let remoteBagIDs = try await fetchRecordIDs(
            forRecordType: Constants.bagRecordType,
            in: zoneID(for: family),
            database: database
        )
        let remoteItemIDs = try await fetchRecordIDs(
            forRecordType: Constants.itemRecordType,
            in: zoneID(for: family),
            database: database
        )

        let desiredBagIDs = Set(bagRecords.map(\.recordID))
        let desiredItemIDs = Set(itemRecords.map(\.recordID))
        let recordIDsToDelete = Array(remoteBagIDs.subtracting(desiredBagIDs))
            + Array(remoteItemIDs.subtracting(desiredItemIDs))

        try await modify(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete, in: database)
    }

    func syncFamilyStateFromCloudKit(for family: Family) async throws {
        guard family.isCloudKitSharedFamily else { return }
        _ = try await syncZoneToLocal(
            zoneID: zoneID(for: family),
            database: database(for: family),
            scope: family.cloudKitDatabaseScope ?? .privateDatabase
        )
    }

    func leaveFamily(_ family: Family) async throws {
        guard family.cloudKitDatabaseScope == .sharedDatabase else { return }
        modelContext.delete(family)
        try modelContext.save()
    }

    func clearShareMetadata(for family: Family) {
        family.cloudKitShareURL = nil
        family.cloudKitZoneName = nil
        family.cloudKitZoneOwnerName = nil
        family.cloudKitDatabaseScope = nil
        family.cloudKitPendingSync = false
        try? modelContext.save()
    }

    private func syncZoneToLocal(
        zoneID: CKRecordZone.ID,
        database: CKDatabase,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> Family {
        let familyRecords = try await fetchRecords(
            forRecordType: Constants.familyRecordType,
            in: zoneID,
            database: database
        )

        guard let familyRecord = familyRecords.first else {
            throw CloudKitSharingError.familyRecordNotFound
        }

        let bags = try await fetchRecords(
            forRecordType: Constants.bagRecordType,
            in: zoneID,
            database: database
        )
        let items = try await fetchRecords(
            forRecordType: Constants.itemRecordType,
            in: zoneID,
            database: database
        )

        let familyID = uuidValue(from: familyRecord["id"]) ?? UUID()
        let familyName = (familyRecord["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFamily = try fetchOrCreateFamily(
            id: familyID,
            fallbackName: familyName?.isEmpty == false ? familyName! : "家族"
        )

        currentFamily.name = familyName?.isEmpty == false ? familyName! : currentFamily.name
        currentFamily.cloudKitZoneName = zoneID.zoneName
        currentFamily.cloudKitZoneOwnerName = zoneID.ownerName
        currentFamily.cloudKitDatabaseScope = scope
        currentFamily.cloudKitPendingSync = false

        let validBagRecords = bags.compactMap { bagRecord -> (UUID, String)? in
            guard let bagID = uuidValue(from: bagRecord["id"]),
                  let bagName = normalizedNonEmptyString(bagRecord["name"] as? String) else { return nil }
            return (bagID, bagName)
        }

        var bagMap: [UUID: Bag] = [:]
        let remoteBagIDs = Set(validBagRecords.map(\.0))
        for (bagID, bagName) in validBagRecords {

            let descriptor = FetchDescriptor<Bag>(predicate: #Predicate { $0.id == bagID })
            let bag = try modelContext.fetch(descriptor).first ?? {
                let newBag = Bag(name: bagName)
                newBag.id = bagID
                modelContext.insert(newBag)
                return newBag
            }()

            bag.name = bagName
            bag.family = currentFamily
            bagMap[bagID] = bag
        }

        for existingBag in currentFamily.resolvedBags where !remoteBagIDs.contains(existingBag.id) {
            modelContext.delete(existingBag)
        }

        let validItemRecords = items.compactMap { itemRecord -> (CKRecord, UUID, String)? in
            guard let itemID = uuidValue(from: itemRecord["id"]),
                  let itemName = normalizedNonEmptyString(itemRecord["name"] as? String) else { return nil }
            return (itemRecord, itemID, itemName)
        }
        let remoteItemIDs = Set(validItemRecords.map(\.1))
        for (itemRecord, itemID, itemName) in validItemRecords {

            let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.id == itemID })
            let item = try modelContext.fetch(descriptor).first ?? {
                let newItem = Item(name: itemName)
                newItem.id = itemID
                modelContext.insert(newItem)
                return newItem
            }()

            item.name = itemName
            item.quantity = intValue(from: itemRecord["quantity"]) ?? item.quantity
            item.expiryDate = itemRecord["expiryDate"] as? Date
            item.locationNote = normalizedOptionalString(itemRecord["locationNote"] as? String)
            item.notified30 = (itemRecord["notified30"] as? NSNumber)?.boolValue ?? item.notified30
            item.notified7 = (itemRecord["notified7"] as? NSNumber)?.boolValue ?? item.notified7
            item.notified1 = (itemRecord["notified1"] as? NSNumber)?.boolValue ?? item.notified1
            item.family = currentFamily

            if let bagID = uuidValue(from: itemRecord["bagID"]) {
                item.bag = bagMap[bagID]
            } else {
                item.bag = nil
            }
        }

        for existingItem in currentFamily.resolvedItems where !remoteItemIDs.contains(existingItem.id) {
            modelContext.delete(existingItem)
        }

        try modelContext.save()
        NotificationManager.shared.requestReschedule(using: modelContext)
        return currentFamily
    }

    private func syncAcceptedShareToLocal(zoneID: CKRecordZone.ID) async throws -> Family {
        let retryIntervalsInNanoseconds: [UInt64] = [
            0,
            500_000_000,
            1_500_000_000,
            3_000_000_000
        ]
        var lastError: Error?

        for (index, interval) in retryIntervalsInNanoseconds.enumerated() {
            if interval > 0 {
                try await Task.sleep(nanoseconds: interval)
            }

            do {
                return try await syncZoneToLocal(
                    zoneID: zoneID,
                    database: container.sharedCloudDatabase,
                    scope: .sharedDatabase
                )
            } catch {
                lastError = error
                logger.error(
                    "CloudKit shared sync failed phase=acceptShare.sync[\(index)] zone=\(zoneID.zoneName, privacy: .public) owner=\(zoneID.ownerName, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
                )

                guard shouldRetryAcceptedShareSync(after: error),
                      index < retryIntervalsInNanoseconds.count - 1 else {
                    throw error
                }
            }
        }

        throw lastError ?? CloudKitSharingError.invalidShareMetadata
    }

    private func fetchOrCreateFamily(id: UUID, fallbackName: String) throws -> Family {
        let descriptor = FetchDescriptor<Family>(predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }

        let family = Family(name: fallbackName)
        family.id = id
        modelContext.insert(family)
        return family
    }

    private func ensureCloudKitMetadata(for family: Family) {
        if family.cloudKitZoneName == nil {
            family.cloudKitZoneName = "family-\(family.id.uuidString)"
        }
        if family.cloudKitZoneOwnerName == nil {
            family.cloudKitZoneOwnerName = CKCurrentUserDefaultName
        }
        if family.cloudKitDatabaseScope == nil {
            family.cloudKitDatabaseScope = .privateDatabase
        }
        if family.cloudKitShareURL == nil {
            family.cloudKitPendingSync = true
        }
        // メタデータをローカルDBに永続化（isCloudKitSharedFamily が正しく評価されるよう保証）
        try? modelContext.save()
    }

    private func fetchExistingShare(for family: Family, in database: CKDatabase) async throws -> CKShare? {
        let shareRecordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: family))

        do {
            let existingRecord = try await fetchRecord(with: shareRecordID, in: database)
            return existingRecord as? CKShare
        } catch let error as CloudKitSharingError where error == .recordNotFound {
            return nil
        } catch {
            if shouldRetrySharePreparation(after: error) {
                return nil
            }
            throw error
        }
    }

    private func shouldRetrySharePreparation(after error: Error) -> Bool {
        if let sharingError = error as? CloudKitSharingError,
           case .recordNotFound = sharingError {
            return true
        }

        guard let ckError = error as? CKError else {
            return false
        }

        switch ckError.code {
        case .unknownItem, .zoneNotFound, .userDeletedZone, .networkFailure,
             .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return true
        case .partialFailure:
            if let partialErrors = ckError.partialErrorsByItemID?.values {
                return partialErrors.contains { shouldRetrySharePreparation(after: $0) }
            }
            return false
        default:
            return false
        }
    }

    private func resetShareMetadata(for family: Family) {
        family.cloudKitShareURL = nil
        family.cloudKitZoneName = nil
        family.cloudKitZoneOwnerName = nil
        family.cloudKitDatabaseScope = .privateDatabase
        family.cloudKitPendingSync = false
        try? modelContext.save()
    }

    private func normalizeSharePreparationError(_ error: Error) -> Error {
        if shouldRetrySharePreparation(after: error) {
            return CloudKitSharingError.sharePreparationFailed(detail: makeShareErrorDetail(from: error))
        }
        return error
    }

    private func fetchExistingShareAfterTransientFailure(for family: Family) async throws -> CKShare? {
        let fallbackIntervalsInNanoseconds: [UInt64] = [
            250_000_000,
            1_000_000_000
        ]

        for interval in fallbackIntervalsInNanoseconds {
            try await Task.sleep(nanoseconds: interval)
            if let existingShare = try await fetchExistingShare(for: family, in: container.privateCloudDatabase) {
                logger.notice("Recovered existing CKShare after transient failure for family=\(family.id.uuidString, privacy: .public)")
                return existingShare
            }
        }

        return nil
    }

    private func makeShareErrorDetail(from error: Error) -> String {
        if let ckError = error as? CKError {
            let code = ckError.code.rawValue
            let description = ckError.localizedDescription
            return "CKError(\(code)): \(description)"
        }
        return error.localizedDescription
    }

    private func logShareError(_ error: Error, phase: String) {
        if let ckError = error as? CKError {
            logger.error(
                "CloudKit share failed phase=\(phase, privacy: .public) code=\(ckError.code.rawValue, privacy: .public) message=\(ckError.localizedDescription, privacy: .public)"
            )

            if let partialErrors = ckError.partialErrorsByItemID {
                for (itemID, partialError) in partialErrors {
                    logger.error(
                        "CloudKit partial failure item=\(String(describing: itemID), privacy: .public) message=\(partialError.localizedDescription, privacy: .public)"
                    )
                }
            }
            return
        }

        logger.error(
            "CloudKit share failed phase=\(phase, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
        )
    }

    /// ゾーンに Family レコードが存在することを保証する
    /// prepareShare の初回実行時は isCloudKitSharedFamily が false のため
    /// syncFamilyDataToCloudKit の guard を通過しない。このメソッドで事前に保存する。
    private func ensureFamilyRecordExists(for family: Family) async throws {
        let database = container.privateCloudDatabase
        let familyRecord = makeFamilyRecord(from: family)
        // savePolicy = .changedKeys なので既存レコードがあっても安全に上書き
        try await modify(recordsToSave: [familyRecord], recordIDsToDelete: [], in: database)
    }

    private func ensureZoneExists(for family: Family) async throws {
        let zone = CKRecordZone(zoneID: zoneID(for: family))
        _ = try await save(zone: zone, in: container.privateCloudDatabase)
    }

    private func zoneID(for family: Family) -> CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: family.cloudKitZoneName ?? "family-\(family.id.uuidString)",
            ownerName: family.cloudKitZoneOwnerName ?? CKCurrentUserDefaultName
        )
    }

    private func database(for family: Family) -> CKDatabase {
        switch family.cloudKitDatabaseScope {
        case .sharedDatabase:
            return container.sharedCloudDatabase
        default:
            return container.privateCloudDatabase
        }
    }

    private func makeFamilyRecord(from family: Family) -> CKRecord {
        let record = CKRecord(
            recordType: Constants.familyRecordType,
            recordID: CKRecord.ID(recordName: "family-\(family.id.uuidString)", zoneID: zoneID(for: family))
        )
        record["id"] = family.id.uuidString as CKRecordValue
        record["name"] = family.name as CKRecordValue
        record["createdAt"] = family.createdAt as CKRecordValue
        return record
    }

    private func makeBagRecord(from bag: Bag, family: Family) -> CKRecord {
        let zoneID = zoneID(for: family)
        let record = CKRecord(
            recordType: Constants.bagRecordType,
            recordID: CKRecord.ID(recordName: "bag-\(bag.id.uuidString)", zoneID: zoneID)
        )
        record["id"] = bag.id.uuidString as CKRecordValue
        record["name"] = bag.name as CKRecordValue
        record["createdAt"] = bag.createdAt as CKRecordValue
        if let familyID = bag.family?.id.uuidString {
            record["familyID"] = familyID as CKRecordValue
        }
        return record
    }

    private func makeItemRecord(from item: Item, family: Family) -> CKRecord {
        let zoneID = zoneID(for: family)
        let record = CKRecord(
            recordType: Constants.itemRecordType,
            recordID: CKRecord.ID(recordName: "item-\(item.id.uuidString)", zoneID: zoneID)
        )
        record["id"] = item.id.uuidString as CKRecordValue
        record["name"] = item.name as CKRecordValue
        record["quantity"] = item.quantity as CKRecordValue
        if let expiryDate = item.expiryDate {
            record["expiryDate"] = expiryDate as CKRecordValue
        }
        if let locationNote = item.locationNote {
            record["locationNote"] = locationNote as CKRecordValue
        }
        record["notified30"] = item.notified30 as CKRecordValue
        record["notified7"] = item.notified7 as CKRecordValue
        record["notified1"] = item.notified1 as CKRecordValue
        record["createdAt"] = item.createdAt as CKRecordValue
        if let bagID = item.bag?.id.uuidString {
            record["bagID"] = bagID as CKRecordValue
        }
        if let familyID = item.family?.id.uuidString {
            record["familyID"] = familyID as CKRecordValue
        }
        return record
    }

    private func fetchRecords(
        forRecordType recordType: String,
        in zoneID: CKRecordZone.ID,
        database: CKDatabase
    ) async throws -> [CKRecord] {
        return try await withCheckedThrowingContinuation { continuation in
            var fetchedRecords: [CKRecord] = []
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = nil

            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result, record.recordType == recordType {
                    fetchedRecords.append(record)
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: fetchedRecords)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchRecordIDs(
        forRecordType recordType: String,
        in zoneID: CKRecordZone.ID,
        database: CKDatabase
    ) async throws -> Set<CKRecord.ID> {
        Set(try await fetchRecords(forRecordType: recordType, in: zoneID, database: database).map(\.recordID))
    }

    private func fetchRecord(with recordID: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [recordID])
            var fetchedRecord: CKRecord?
            operation.perRecordResultBlock = { _, result in
                if case .success(let record) = result {
                    fetchedRecord = record
                }
            }
            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success:
                    if let fetchedRecord {
                        continuation.resume(returning: fetchedRecord)
                    } else {
                        continuation.resume(throwing: CloudKitSharingError.recordNotFound)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func save(record: CKRecord, in database: CKDatabase) async throws -> CKRecord {
        let savedRecords = try await modify(recordsToSave: [record], recordIDsToDelete: [], in: database)
        guard let savedRecord = savedRecords.first else {
            throw CloudKitSharingError.recordNotFound
        }
        return savedRecord
    }

    private func save(zone: CKRecordZone, in database: CKDatabase) async throws -> CKRecordZone {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: zone)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    @discardableResult
    private func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID],
        in database: CKDatabase
    ) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
            operation.savePolicy = .changedKeys
            operation.isAtomic = false

            var savedRecords: [CKRecord] = []

            operation.perRecordSaveBlock = { _, result in
                if case .success(let record) = result {
                    savedRecords.append(record)
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: savedRecords)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func uuidValue(from raw: Any?) -> UUID? {
        if let string = raw as? String {
            return UUID(uuidString: string)
        }
        return nil
    }

    private func intValue(from raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func shouldRetryAcceptedShareSync(after error: Error) -> Bool {
        if let sharingError = error as? CloudKitSharingError,
           sharingError == .familyRecordNotFound {
            return true
        }

        guard let ckError = error as? CKError else {
            return false
        }

        switch ckError.code {
        case .zoneNotFound, .unknownItem, .networkFailure, .networkUnavailable,
             .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return true
        case .partialFailure:
            if let partialErrors = ckError.partialErrorsByItemID?.values {
                return partialErrors.contains { shouldRetryAcceptedShareSync(after: $0) }
            }
            return false
        default:
            return false
        }
    }

    private func createOrUpdatePendingFamily(
        from metadata: CKShare.Metadata,
        acceptedShare: CKShare,
        zoneID: CKRecordZone.ID
    ) {
        let fallbackName = normalizedNonEmptyString(metadata.rootRecord?["name"] as? String)
            ?? normalizedNonEmptyString(acceptedShare[CKShare.SystemFieldKey.title] as? String)
            ?? "共有中の家族"

        let resolvedFamilyID = uuidValue(from: metadata.rootRecord?["id"])
            ?? metadata.rootRecord.flatMap { rootRecord in
                let recordName = rootRecord.recordID.recordName
                guard recordName.hasPrefix("family-") else { return nil }
                return UUID(uuidString: String(recordName.dropFirst("family-".count)))
            }

        let family: Family
        if let resolvedFamilyID,
           let existing = try? modelContext.fetch(
                FetchDescriptor<Family>(predicate: #Predicate { $0.id == resolvedFamilyID })
           ).first {
            family = existing
        } else if let existing = try? modelContext.fetch(FetchDescriptor<Family>()).first(where: {
            $0.cloudKitZoneName == zoneID.zoneName && $0.cloudKitZoneOwnerName == zoneID.ownerName
        }) {
            family = existing
        } else {
            family = Family(name: fallbackName)
            if let resolvedFamilyID {
                family.id = resolvedFamilyID
            }
            modelContext.insert(family)
        }

        family.name = fallbackName
        family.cloudKitZoneName = zoneID.zoneName
        family.cloudKitZoneOwnerName = zoneID.ownerName
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = true
        try? modelContext.save()
    }

    private func accept(metadata: CKShare.Metadata, using container: CKContainer) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            var acceptedShare: CKShare?

            if #available(iOS 15.0, *) {
                operation.perShareResultBlock = { _, result in
                    if case .success(let share) = result {
                        acceptedShare = share
                    }
                }
            }
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    if let acceptedShare {
                        continuation.resume(returning: acceptedShare)
                    } else {
                        continuation.resume(throwing: CloudKitSharingError.invalidShareMetadata)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            container.add(operation)
        }
    }

}

private enum CloudKitSharingError: LocalizedError, Equatable {
    case invalidShareRecord
    case invalidShareMetadata
    case familyRecordNotFound
    case recordNotFound
    case sharePreparationFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidShareRecord:
            return "CloudKit共有レコードの作成に失敗しました。"
        case .invalidShareMetadata:
            return "CloudKit共有メタデータの読み取りに失敗しました。"
        case .familyRecordNotFound:
            return "共有された家族データが見つかりません。"
        case .recordNotFound:
            return "CloudKit上のレコードが見つかりません。"
        case .sharePreparationFailed(let detail):
            return "共有リンクの再準備に失敗しました。\(detail)"
        }
    }
}

@MainActor
final class FirebaseMigrationService {
    enum MigrationStatus: Equatable {
        case notConfigured
        case notStarted
        case pending(lastError: String?)
        case completed
    }

    enum MigrationError: LocalizedError {
        case firebaseNotConfigured
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .firebaseNotConfigured:
                return "Firebase連携は開発者オプション有効時のみ利用できます。設定で有効化し、GoogleService-Info.plistを確認してください。"
            case .uploadFailed(let message):
                return "Firebase移行に失敗しました: \(message)"
            }
        }
    }

    private enum DefaultsKey {
        static let migrationCompleted = "firebase.initialMigration.completed"
        static let migrationFamilyId = "firebase.initialMigration.familyId"
        static let migrationPendingFamilyId = "firebase.initialMigration.pendingFamilyId"
        static let migrationLastError = "firebase.initialMigration.lastError"
    }

    private let modelContext: ModelContext
    private let defaults: UserDefaults

    init(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
    }

    func status(for family: Family) -> MigrationStatus {
        guard APIConfig.isFirebaseEnabled else {
            return .notConfigured
        }

        if isCompleted(for: family.id) {
            return .completed
        }

        if defaults.string(forKey: DefaultsKey.migrationPendingFamilyId) == family.id.uuidString {
            return .pending(lastError: defaults.string(forKey: DefaultsKey.migrationLastError))
        }

        return .notStarted
    }

    func migrateIfNeeded(for family: Family) async throws {
        guard APIConfig.isFirebaseEnabled else {
            throw MigrationError.firebaseNotConfigured
        }

        if isCompleted(for: family.id) {
            return
        }

        do {
            let client = FirebaseSDKClient()
            if try await hasRemoteFamilyData(for: family.id.uuidString, client: client) {
                markCompleted(for: family.id)
                return
            }

            try attachOrphanDataIfNeeded(to: family)
            try modelContext.save()
            try await uploadFamilySnapshot(family)
            markCompleted(for: family.id)
        } catch {
            markPending(for: family.id, error: error)
            throw error
        }
    }

    func retryMigration(for family: Family) async throws {
        guard APIConfig.isFirebaseEnabled else {
            throw MigrationError.firebaseNotConfigured
        }

        do {
            let client = FirebaseSDKClient()
            if try await hasRemoteFamilyData(for: family.id.uuidString, client: client) {
                markCompleted(for: family.id)
                return
            }

            // 初回移行と同様に、未紐付けローカルデータを対象家族に関連付けてから再送する。
            try attachOrphanDataIfNeeded(to: family)
            try modelContext.save()
            try await uploadFamilySnapshot(family)
            markCompleted(for: family.id)
        } catch {
            markPending(for: family.id, error: error)
            throw error
        }
    }

    private func isCompleted(for familyId: UUID) -> Bool {
        defaults.bool(forKey: DefaultsKey.migrationCompleted)
            && defaults.string(forKey: DefaultsKey.migrationFamilyId) == familyId.uuidString
    }

    private func markCompleted(for familyId: UUID) {
        defaults.set(true, forKey: DefaultsKey.migrationCompleted)
        defaults.set(familyId.uuidString, forKey: DefaultsKey.migrationFamilyId)
        defaults.removeObject(forKey: DefaultsKey.migrationPendingFamilyId)
        defaults.removeObject(forKey: DefaultsKey.migrationLastError)
    }

    private func markPending(for familyId: UUID, error: Error) {
        defaults.set(familyId.uuidString, forKey: DefaultsKey.migrationPendingFamilyId)
        defaults.set(error.localizedDescription, forKey: DefaultsKey.migrationLastError)
    }

    private func attachOrphanDataIfNeeded(to family: Family) throws {
        let orphanBagDescriptor = FetchDescriptor<Bag>(
            predicate: #Predicate { $0.family == nil }
        )
        let orphanItemDescriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.family == nil }
        )

        let orphanBags = try modelContext.fetch(orphanBagDescriptor)
        let orphanItems = try modelContext.fetch(orphanItemDescriptor)

        for bag in orphanBags {
            guard normalizedNonEmptyString(bag.name) != nil else {
                modelContext.delete(bag)
                continue
            }
            bag.family = family
        }

        for item in orphanItems {
            guard normalizedNonEmptyString(item.name) != nil else {
                modelContext.delete(item)
                continue
            }
            item.family = family
        }
    }

    private func uploadFamilySnapshot(_ family: Family) async throws {
        let snapshots = try buildLocalFamilySnapshots(for: family, modelContext: modelContext)

        let client = FirebaseSDKClient()
        try await client.migrateFamily(
            family: snapshots.family,
            bags: snapshots.bags,
            items: snapshots.items
        )
    }

    private func hasRemoteFamilyData(for familyId: String, client: FirebaseSDKClient) async throws -> Bool {
        let counts = try await client.fetchFamilyDataCounts(familyId: familyId)
        return counts.bags > 0 || counts.items > 0
    }
}

private struct FamilySnapshot: Sendable {
    let id: String
    let name: String
    let inviteCode: String
    let lineGroupId: String?
    let createdAt: Date
}

private struct BagSnapshot: Sendable {
    let id: String
    let name: String
    let createdAt: Date
}

private struct ItemSnapshot: Sendable {
    let id: String
    let name: String
    let quantity: Int
    let expiryDate: Date?
    let bagId: String?
    let locationNote: String?
    let notified30: Bool
    let notified7: Bool
    let notified1: Bool
    let createdAt: Date
}

private func buildLocalFamilySnapshots(
    for family: Family,
    modelContext: ModelContext
) throws -> (family: FamilySnapshot, bags: [BagSnapshot], items: [ItemSnapshot]) {
    let allBags = try modelContext.fetch(FetchDescriptor<Bag>())
    let allItems = try modelContext.fetch(FetchDescriptor<Item>())

    let bagSnapshots = allBags
        .filter { $0.family?.id == family.id }
        .compactMap { bag -> BagSnapshot? in
            guard let normalizedName = normalizedNonEmptyString(bag.name) else { return nil }
            return BagSnapshot(
                id: bag.id.uuidString,
                name: normalizedName,
                createdAt: bag.createdAt
            )
        }

    let itemSnapshots = allItems
        .filter { $0.family?.id == family.id }
        .compactMap { item -> ItemSnapshot? in
            guard let normalizedName = normalizedNonEmptyString(item.name) else { return nil }
            return ItemSnapshot(
                id: item.id.uuidString,
                name: normalizedName,
                quantity: item.quantity,
                expiryDate: item.expiryDate,
                bagId: item.bag?.id.uuidString,
                locationNote: normalizedOptionalString(item.locationNote),
                notified30: item.notified30,
                notified7: item.notified7,
                notified1: item.notified1,
                createdAt: item.createdAt
            )
        }

    let familySnapshot = FamilySnapshot(
        id: family.id.uuidString,
        name: family.name,
        inviteCode: family.inviteCode,
        lineGroupId: family.lineGroupId,
        createdAt: family.createdAt
    )

    return (family: familySnapshot, bags: bagSnapshots, items: itemSnapshots)
}

struct FirebaseInviteInfo: Sendable {
    let inviteCode: String
    let familyName: String
    let familyId: String
    let expiresAt: Date

    var isExpired: Bool {
        expiresAt <= Date()
    }
}

struct FirebaseMemberInfo: Sendable {
    let uid: String
    let displayName: String
    let email: String?
}

struct FirebaseBagInfo: Sendable {
    let id: String
    let name: String
    let createdAt: Date
}

struct FirebaseItemInfo: Sendable {
    let id: String
    let name: String
    let quantity: Int
    let expiryDate: Date?
    let bagId: String?
    let locationNote: String?
    let notified30: Bool
    let notified7: Bool
    let notified1: Bool
    let createdAt: Date
}

private func normalizedOptionalString(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

private func normalizedNonEmptyString(_ value: String?) -> String? {
    normalizedOptionalString(value)
}

@MainActor
final class LocalDataRepairService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func repairInvalidAndDuplicateRecordsIfNeeded() {
        do {
            let allFamilies = try modelContext.fetch(FetchDescriptor<Family>())
            let allUsers = try modelContext.fetch(FetchDescriptor<User>())
            let allBags = try modelContext.fetch(FetchDescriptor<Bag>())
            let allItems = try modelContext.fetch(FetchDescriptor<Item>())
            var didChange = false

            didChange = repairFamilies(allFamilies) || didChange
            didChange = repairUsers(allUsers) || didChange

            let invalidBags = allBags.filter { normalizedNonEmptyString($0.name) == nil }
            for bag in invalidBags {
                for item in bag.resolvedItems {
                    if item.bag?.persistentModelID == bag.persistentModelID {
                        item.bag = nil
                    }
                }
                modelContext.delete(bag)
                didChange = true
            }

            let invalidItems = allItems.filter { normalizedNonEmptyString($0.name) == nil }
            for item in invalidItems {
                modelContext.delete(item)
                didChange = true
            }

            let validBags = allBags.filter { normalizedNonEmptyString($0.name) != nil }
            let validItems = allItems.filter { normalizedNonEmptyString($0.name) != nil }

            for duplicates in Dictionary(grouping: validBags, by: \.id).values where duplicates.count > 1 {
                let keeper = preferredBag(in: duplicates)
                keeper.name = normalizedNonEmptyString(keeper.name) ?? keeper.name
                keeper.createdAt = duplicates.map(\.createdAt).min() ?? keeper.createdAt
                keeper.family = duplicates.compactMap(\.family).first ?? keeper.family

                for duplicate in duplicates where duplicate.persistentModelID != keeper.persistentModelID {
                    for item in duplicate.resolvedItems {
                        item.bag = keeper
                    }
                    modelContext.delete(duplicate)
                    didChange = true
                }
            }

            for duplicates in Dictionary(grouping: validItems, by: \.id).values where duplicates.count > 1 {
                let keeper = preferredItem(in: duplicates)
                keeper.name = duplicates
                    .compactMap { normalizedNonEmptyString($0.name) }
                    .max(by: { $0.count < $1.count }) ?? keeper.name
                keeper.quantity = duplicates.map(\.quantity).max() ?? keeper.quantity
                keeper.expiryDate = duplicates.compactMap(\.expiryDate).min() ?? keeper.expiryDate
                keeper.locationNote = duplicates.compactMap(\.locationNote).compactMap(normalizedOptionalString).first ?? keeper.locationNote
                keeper.notified30 = duplicates.contains { $0.notified30 }
                keeper.notified7 = duplicates.contains { $0.notified7 }
                keeper.notified1 = duplicates.contains { $0.notified1 }
                keeper.createdAt = duplicates.map(\.createdAt).min() ?? keeper.createdAt
                keeper.family = duplicates.compactMap(\.family).first ?? keeper.family
                keeper.bag = duplicates.compactMap(\.bag).first ?? keeper.bag

                for duplicate in duplicates where duplicate.persistentModelID != keeper.persistentModelID {
                    modelContext.delete(duplicate)
                    didChange = true
                }
            }

            if didChange {
                try modelContext.save()
            }
        } catch {
            #if DEBUG
            print("データ修復に失敗: \(error)")
            #endif
        }
    }

    private func preferredBag(in bags: [Bag]) -> Bag {
        bags.max { lhs, rhs in
            score(of: lhs) < score(of: rhs)
        } ?? bags[0]
    }

    private func preferredFamily(in families: [Family]) -> Family {
        CurrentFamilyResolver.currentFamily(from: families) ?? families[0]
    }

    private func preferredUser(in users: [User]) -> User {
        users.max { lhs, rhs in
            score(of: lhs) < score(of: rhs)
        } ?? users[0]
    }

    private func preferredItem(in items: [Item]) -> Item {
        items.max { lhs, rhs in
            score(of: lhs) < score(of: rhs)
        } ?? items[0]
    }

    private func score(of bag: Bag) -> Int {
        var score = 0
        if normalizedNonEmptyString(bag.name) != nil { score += 4 }
        if bag.family != nil { score += 2 }
        score += min(bag.resolvedItems.count, 3)
        return score
    }

    private func score(of family: Family) -> Int {
        var score = 0
        switch family.shareState {
        case .shared:
            score += 50
        case .preparing:
            score += 25
        case .localOnly:
            break
        }
        score += min(family.uniqueMembers.count, 5) * 3
        score += min(family.resolvedBags.count, 5) * 2
        score += min(family.resolvedItems.count, 10)
        if family.cloudKitShareURL != nil { score += 5 }
        return score
    }

    private func score(of item: Item) -> Int {
        var score = 0
        if normalizedNonEmptyString(item.name) != nil { score += 8 }
        if item.family != nil { score += 4 }
        if item.bag != nil { score += 2 }
        if item.expiryDate != nil { score += 1 }
        if normalizedOptionalString(item.locationNote) != nil { score += 1 }
        return score
    }

    private func score(of user: User) -> Int {
        var score = 0
        if let uid = user.lineUserId, !uid.isEmpty { score += 8 }
        if let email = user.email, !email.isEmpty { score += 4 }
        if !user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 2 }
        if user.family != nil { score += 1 }
        return score
    }

    private func repairFamilies(_ families: [Family]) -> Bool {
        var didChange = false

        for duplicates in Dictionary(grouping: families, by: \.id).values where duplicates.count > 1 {
            let keeper = preferredFamily(in: duplicates)
            mergeFamilies(duplicates, into: keeper)
            didChange = true
        }

        let familiesAfterMerge = (try? modelContext.fetch(FetchDescriptor<Family>())) ?? families
        let zoneKeyFamilies = Dictionary(
            grouping: familiesAfterMerge.filter { $0.cloudKitZoneIdentity != nil },
            by: { $0.cloudKitZoneIdentity! }
        )
        for duplicates in zoneKeyFamilies.values where duplicates.count > 1 {
            let keeper = preferredFamily(in: duplicates)
            mergeFamilies(duplicates, into: keeper)
            didChange = true
        }

        let currentFamilies = (try? modelContext.fetch(FetchDescriptor<Family>())) ?? familiesAfterMerge
        let hasBetterFamily = currentFamilies.contains { $0.shareState != .localOnly }
        for family in currentFamilies where shouldDeleteOrphanFamily(family, hasBetterFamily: hasBetterFamily) {
            modelContext.delete(family)
            didChange = true
        }

        return didChange
    }

    private func repairUsers(_ users: [User]) -> Bool {
        var didChange = false
        let grouped = Dictionary(grouping: users) { user in
            let familyID = user.family?.id.uuidString ?? "no-family"
            if let uid = user.lineUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty {
                return "family:\(familyID):uid:\(uid)"
            }
            if let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
                return "family:\(familyID):email:\(email)"
            }
            return "family:\(familyID):local:\(user.id.uuidString)"
        }

        for duplicates in grouped.values where duplicates.count > 1 {
            let keeper = preferredUser(in: duplicates)
            keeper.displayName = duplicates
                .map(\.displayName)
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                ?? keeper.displayName
            keeper.email = duplicates.compactMap(\.email).first(where: { !$0.isEmpty }) ?? keeper.email
            keeper.lineUserId = duplicates.compactMap(\.lineUserId).first(where: { !$0.isEmpty }) ?? keeper.lineUserId
            keeper.family = duplicates.compactMap(\.family).first ?? keeper.family

            for duplicate in duplicates where duplicate.persistentModelID != keeper.persistentModelID {
                modelContext.delete(duplicate)
                didChange = true
            }
        }

        return didChange
    }

    private func mergeFamilies(_ families: [Family], into keeper: Family) {
        keeper.name = families
            .compactMap { normalizedNonEmptyString($0.name) }
            .max(by: { $0.count < $1.count }) ?? keeper.name
        keeper.inviteCode = families
            .compactMap { normalizedNonEmptyString($0.inviteCode) }
            .first ?? keeper.inviteCode
        keeper.lineGroupId = families.compactMap(\.lineGroupId).first ?? keeper.lineGroupId
        keeper.cloudKitZoneName = families.compactMap(\.cloudKitZoneName).first ?? keeper.cloudKitZoneName
        keeper.cloudKitZoneOwnerName = families.compactMap(\.cloudKitZoneOwnerName).first ?? keeper.cloudKitZoneOwnerName
        keeper.cloudKitDatabaseScope = families.compactMap(\.cloudKitDatabaseScope).first ?? keeper.cloudKitDatabaseScope
        keeper.cloudKitShareURL = families.compactMap(\.cloudKitShareURL).first ?? keeper.cloudKitShareURL
        keeper.cloudKitPendingSync = families.contains { $0.cloudKitPendingSync }
        keeper.createdAt = families.map(\.createdAt).min() ?? keeper.createdAt

        for family in families where family.persistentModelID != keeper.persistentModelID {
            for user in family.resolvedMembers {
                user.family = keeper
            }
            for bag in family.resolvedBags {
                bag.family = keeper
            }
            for item in family.resolvedItems {
                item.family = keeper
            }
            modelContext.delete(family)
        }
    }

    private func shouldDeleteOrphanFamily(_ family: Family, hasBetterFamily: Bool) -> Bool {
        guard hasBetterFamily else { return false }
        guard family.shareState == .localOnly else { return false }
        guard normalizedNonEmptyString(family.lineGroupId) == nil else { return false }
        guard family.cloudKitZoneName == nil,
              family.cloudKitZoneOwnerName == nil,
              family.cloudKitShareURL == nil else { return false }
        return family.resolvedBags.isEmpty && family.resolvedItems.isEmpty && family.uniqueMembers.isEmpty
    }
}

@MainActor
final class FirebaseSyncRetryCoordinator {
    static let shared = FirebaseSyncRetryCoordinator()

    private enum DefaultsKey {
        static let pendingFamilyIDs = "firebase.sync.pendingFamilyIds"
    }

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.stockpile.firebase-sync.monitor")
    private let defaults: UserDefaults
    private var hasStartedMonitor = false
    private var isReachable = false
    private var isRetrying = false
    private weak var modelContext: ModelContext?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        startMonitorIfNeeded()
        triggerRetryIfNeeded()
    }

    func enqueueFamilySync(familyID: UUID) {
        var familyIDs = pendingFamilyIDs()
        let rawID = familyID.uuidString
        if !familyIDs.contains(rawID) {
            familyIDs.append(rawID)
            savePendingFamilyIDs(familyIDs)
        }
        triggerRetryIfNeeded()
    }

    static func isRetryable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }

        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .unavailable, .deadlineExceeded, .aborted, .cancelled:
                return true
            default:
                break
            }
        }

        if nsError.domain == "FIRAuthErrorDomain",
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .networkError, .tooManyRequests, .internalError:
                return true
            default:
                break
            }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isRetryable(underlying)
        }
        return false
    }

    private func startMonitorIfNeeded() {
        guard !hasStartedMonitor else { return }
        hasStartedMonitor = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                let reachable = path.status == .satisfied
                let becameReachable = reachable && !self.isReachable
                self.isReachable = reachable
                if becameReachable {
                    self.triggerRetryIfNeeded()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func triggerRetryIfNeeded() {
        guard isReachable, !pendingFamilyIDs().isEmpty else { return }
        Task { await retryQueuedSyncIfNeeded() }
    }

    private func retryQueuedSyncIfNeeded() async {
        guard isReachable, !isRetrying, let modelContext else { return }
        let queuedFamilyIDs = pendingFamilyIDs()
        guard !queuedFamilyIDs.isEmpty else { return }
        isRetrying = true
        defer { isRetrying = false }

        let allFamilies: [Family]
        do {
            allFamilies = try modelContext.fetch(FetchDescriptor<Family>())
        } catch {
            return
        }
        let familyMap = Dictionary(uniqueKeysWithValues: allFamilies.map { ($0.id.uuidString, $0) })
        let sharingService = FamilySharingService(modelContext: modelContext)
        var remainingFamilyIDs: [String] = []

        for familyID in queuedFamilyIDs {
            guard let family = familyMap[familyID] else { continue }
            do {
                try await sharingService.syncFamilyDataToFirebase(for: family)
                try await sharingService.syncFamilyStateFromFirebase(for: family)
            } catch {
                remainingFamilyIDs.append(familyID)
            }
        }

        savePendingFamilyIDs(remainingFamilyIDs)
    }

    private func pendingFamilyIDs() -> [String] {
        defaults.stringArray(forKey: DefaultsKey.pendingFamilyIDs) ?? []
    }

    private func savePendingFamilyIDs(_ familyIDs: [String]) {
        if familyIDs.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.pendingFamilyIDs)
            return
        }
        defaults.set(familyIDs, forKey: DefaultsKey.pendingFamilyIDs)
    }
}

@MainActor
final class FamilyRealtimeSyncCoordinator {
    static let shared = FamilyRealtimeSyncCoordinator()

    private weak var modelContext: ModelContext?
    private var observedFamilyID: UUID?
    private var familyListener: ListenerRegistration?
    private var isSyncing = false
    private var pendingSync = false

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func activate(for family: Family?) {
        guard APIConfig.isFirebaseConfigured, let family else {
            stop()
            return
        }

        // 同一家族の監視中は listener を貼り直さず、即時同期だけ実行
        if observedFamilyID == family.id {
            requestImmediateSync()
            return
        }

        stop()
        observedFamilyID = family.id
        startListening(familyID: family.id)
        requestImmediateSync()
    }

    func requestImmediateSync() {
        guard observedFamilyID != nil else { return }
        enqueueSync()
    }

    func stop() {
        familyListener?.remove()
        familyListener = nil
        observedFamilyID = nil
        pendingSync = false
    }

    private func startListening(familyID: UUID) {
        let familyIDString = familyID.uuidString
        familyListener = Firestore.firestore()
            .collection("families")
            .document(familyIDString)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.handleSnapshot(
                        for: familyID,
                        snapshot: snapshot,
                        error: error
                    )
                }
            }
    }

    private func handleSnapshot(
        for familyID: UUID,
        snapshot: DocumentSnapshot?,
        error: Error?
    ) {
        guard observedFamilyID == familyID else { return }
        guard error == nil else { return }
        guard snapshot?.exists == true else { return }
        enqueueSync()
    }

    private func enqueueSync() {
        pendingSync = true
        guard !isSyncing else { return }

        Task { @MainActor in
            isSyncing = true
            defer { isSyncing = false }

            while pendingSync {
                pendingSync = false
                await syncObservedFamilyFromFirebase()
            }
        }
    }

    private func syncObservedFamilyFromFirebase() async {
        guard let modelContext, let familyID = observedFamilyID else { return }
        let descriptor = FetchDescriptor<Family>(
            predicate: #Predicate { $0.id == familyID }
        )
        guard let family = (try? modelContext.fetch(descriptor))?.first else { return }

        let sharingService = FamilySharingService(modelContext: modelContext)
        do {
            try await sharingService.syncFamilyStateFromFirebase(for: family)
        } catch {
            // 監視同期の失敗はリトライキュー側に委譲し、UI操作を妨げない
        }
    }
}

private struct FirestoreWriteOperation {
    let path: String
    let data: [String: Any]
}

private actor FirebaseSDKClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case missingUser
        case invalidInviteData

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Firebaseが初期化されていません。"
            case .missingUser:
                return "Firebaseユーザー情報を取得できませんでした。"
            case .invalidInviteData:
                return "招待データが不正です。"
            }
        }
    }

    private var auth: Auth { Auth.auth() }
    private var firestore: Firestore { Firestore.firestore() }

    func migrateFamily(family: FamilySnapshot, bags: [BagSnapshot], items: [ItemSnapshot]) async throws {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        let uid = try await ensureAnonymousUser()
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60)

        var operations = baseFamilyOperations(
            family: family,
            uid: uid,
            now: now,
            expiresAt: expiresAt
        )
        operations.reserveCapacity(3 + bags.count + items.count)

        for bag in bags {
            operations.append(
                FirestoreWriteOperation(
                    path: "families/\(family.id)/bags/\(bag.id)",
                    data: [
                        "id": bag.id,
                        "familyId": family.id,
                        "name": bag.name,
                        "createdAt": bag.createdAt
                    ]
                )
            )
        }

        for item in items {
            operations.append(
                FirestoreWriteOperation(
                    path: "families/\(family.id)/items/\(item.id)",
                    data: [
                        "id": item.id,
                        "familyId": family.id,
                        "name": item.name,
                        "quantity": item.quantity,
                        "expiryDate": item.expiryDate ?? NSNull(),
                        "bagId": item.bagId ?? NSNull(),
                        "locationNote": item.locationNote ?? NSNull(),
                        "notified30": item.notified30,
                        "notified7": item.notified7,
                        "notified1": item.notified1,
                        "createdAt": item.createdAt
                    ]
                )
            )
        }

        try await commitWritesInBatches(operations)
    }

    func syncFamily(family: FamilySnapshot, bags: [BagSnapshot], items: [ItemSnapshot]) async throws {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        let uid = try await ensureAnonymousUser()
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60)

        var writeOperations = baseFamilyOperations(
            family: family,
            uid: uid,
            now: now,
            expiresAt: expiresAt
        )
        writeOperations.reserveCapacity(3 + bags.count + items.count)

        let localBagIDs = Set(bags.map(\.id))
        let localItemIDs = Set(items.map(\.id))

        for bag in bags {
            writeOperations.append(
                FirestoreWriteOperation(
                    path: "families/\(family.id)/bags/\(bag.id)",
                    data: [
                        "id": bag.id,
                        "familyId": family.id,
                        "name": bag.name,
                        "createdAt": bag.createdAt
                    ]
                )
            )
        }

        for item in items {
            writeOperations.append(
                FirestoreWriteOperation(
                    path: "families/\(family.id)/items/\(item.id)",
                    data: [
                        "id": item.id,
                        "familyId": family.id,
                        "name": item.name,
                        "quantity": item.quantity,
                        "expiryDate": item.expiryDate ?? NSNull(),
                        "bagId": item.bagId ?? NSNull(),
                        "locationNote": item.locationNote ?? NSNull(),
                        "notified30": item.notified30,
                        "notified7": item.notified7,
                        "notified1": item.notified1,
                        "createdAt": item.createdAt
                    ]
                )
            )
        }

        try await commitWritesInBatches(writeOperations)

        let remoteBagIDs = Set(try await fetchCollectionDocumentIDs(path: "families/\(family.id)/bags"))
        let remoteItemIDs = Set(try await fetchCollectionDocumentIDs(path: "families/\(family.id)/items"))
        let deletePaths = remoteBagIDs
            .subtracting(localBagIDs)
            .map { "families/\(family.id)/bags/\($0)" }
            + remoteItemIDs
            .subtracting(localItemIDs)
            .map { "families/\(family.id)/items/\($0)" }
        try await commitDeletesInBatches(deletePaths)
    }

    func publishInvite(for family: FamilySnapshot) async throws {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        let uid = try await ensureAnonymousUser()
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60)
        let operations = baseFamilyOperations(
            family: family,
            uid: uid,
            now: now,
            expiresAt: expiresAt
        )

        try await commitWritesInBatches(operations)
    }

    func fetchInvite(byCode code: String) async throws -> FirebaseInviteInfo? {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        // Firestoreルールで request.auth を要求するため、読み取り前に匿名サインインを保証する。
        _ = try await ensureAnonymousUser()

        let reference = firestore.document("invites/\(code)")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FirebaseInviteInfo?, Error>) in
            reference.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data = snapshot?.data() else {
                    continuation.resume(returning: nil)
                    return
                }

                guard let familyId = data["familyId"] as? String, !familyId.isEmpty else {
                    continuation.resume(throwing: ClientError.invalidInviteData)
                    return
                }

                let inviteCode = (data["inviteCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let familyName = data["familyName"] as? String ?? ""
                let expiresAtTimestamp = data["expiresAt"] as? Timestamp
                let expiresAt = expiresAtTimestamp?.dateValue() ?? .distantPast

                continuation.resume(
                    returning: FirebaseInviteInfo(
                        inviteCode: (inviteCode?.isEmpty == false ? inviteCode! : code),
                        familyName: familyName,
                        familyId: familyId,
                        expiresAt: expiresAt
                    )
                )
            }
        }
    }

    func addCurrentUserAsMember(familyId: String) async throws {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        let uid = try await ensureAnonymousUser()
        let now = Date()
        try await upsertDocument(
            path: "families/\(familyId)/members/\(uid)",
            data: [
                "uid": uid,
                "displayName": "匿名ユーザー",
                "createdAt": now
            ]
        )
    }

    func fetchMembers(familyId: String) async throws -> [FirebaseMemberInfo] {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        _ = try await ensureAnonymousUser()

        let query = firestore.collection("families/\(familyId)/members")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FirebaseMemberInfo], Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let members: [FirebaseMemberInfo] = snapshot?.documents.compactMap { document in
                    let data = document.data()
                    let uid = (data["uid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedUID = (uid?.isEmpty == false) ? uid! : document.documentID
                    guard !normalizedUID.isEmpty else { return nil }

                    let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedDisplayName = (displayName?.isEmpty == false) ? displayName! : "匿名ユーザー"
                    let email = (data["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    return FirebaseMemberInfo(
                        uid: normalizedUID,
                        displayName: normalizedDisplayName,
                        email: email?.isEmpty == true ? nil : email
                    )
                } ?? []

                continuation.resume(returning: members)
            }
        }
    }

    func fetchFamilyDataCounts(familyId: String) async throws -> (bags: Int, items: Int) {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        _ = try await ensureAnonymousUser()
        let bagIDs = try await fetchCollectionDocumentIDs(path: "families/\(familyId)/bags")
        let itemIDs = try await fetchCollectionDocumentIDs(path: "families/\(familyId)/items")
        return (bags: bagIDs.count, items: itemIDs.count)
    }

    func fetchBags(familyId: String) async throws -> [FirebaseBagInfo] {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        _ = try await ensureAnonymousUser()

        let query = firestore.collection("families/\(familyId)/bags")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FirebaseBagInfo], Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let bags: [FirebaseBagInfo] = snapshot?.documents.compactMap { document in
                    let data = document.data()
                    let id = (data["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedID = (id?.isEmpty == false) ? id! : document.documentID
                    guard !normalizedID.isEmpty else { return nil }

                    guard let normalizedName = normalizedNonEmptyString(data["name"] as? String) else {
                        return nil
                    }
                    let createdAt = self.dateValue(from: data["createdAt"]) ?? .distantPast

                    return FirebaseBagInfo(
                        id: normalizedID,
                        name: normalizedName,
                        createdAt: createdAt
                    )
                } ?? []

                continuation.resume(returning: bags)
            }
        }
    }

    func fetchItems(familyId: String) async throws -> [FirebaseItemInfo] {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        _ = try await ensureAnonymousUser()

        let query = firestore.collection("families/\(familyId)/items")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FirebaseItemInfo], Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let items: [FirebaseItemInfo] = snapshot?.documents.compactMap { document in
                    let data = document.data()
                    let id = (data["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedID = (id?.isEmpty == false) ? id! : document.documentID
                    guard !normalizedID.isEmpty else { return nil }

                    guard let normalizedName = normalizedNonEmptyString(data["name"] as? String) else {
                        return nil
                    }
                    let quantity = max(1, self.intValue(from: data["quantity"]) ?? 1)
                    let expiryDate = self.dateValue(from: data["expiryDate"])
                    let bagID = self.stringValue(from: data["bagId"])
                    let locationNote = normalizedOptionalString(self.stringValue(from: data["locationNote"]))
                    let notified30 = self.boolValue(from: data["notified30"]) ?? false
                    let notified7 = self.boolValue(from: data["notified7"]) ?? false
                    let notified1 = self.boolValue(from: data["notified1"]) ?? false
                    let createdAt = self.dateValue(from: data["createdAt"]) ?? .distantPast

                    return FirebaseItemInfo(
                        id: normalizedID,
                        name: normalizedName,
                        quantity: quantity,
                        expiryDate: expiryDate,
                        bagId: bagID,
                        locationNote: locationNote,
                        notified30: notified30,
                        notified7: notified7,
                        notified1: notified1,
                        createdAt: createdAt
                    )
                } ?? []

                continuation.resume(returning: items)
            }
        }
    }

    func deleteInvite(familyId: String, inviteCode: String?) async throws {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        if let inviteCode,
           let invite = try await fetchInvite(byCode: inviteCode),
           invite.familyId == familyId {
            try await deleteDocument(path: "invites/\(inviteCode)")
            return
        }

        let inviteDocumentIDs = try await fetchInviteDocumentIDs(familyId: familyId)
        for documentID in inviteDocumentIDs {
            try await deleteDocument(path: "invites/\(documentID)")
        }
    }

    func deleteExpiredInvites() async throws {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        let expiredDocumentIDs = try await fetchExpiredInviteDocumentIDs(before: Date())
        for documentID in expiredDocumentIDs {
            try await deleteDocument(path: "invites/\(documentID)")
        }
    }

    private func ensureAnonymousUser() async throws -> String {
        if let currentUser = auth.currentUser {
            return currentUser.uid
        }

        let userID: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            auth.signInAnonymously { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else {
                    continuation.resume(throwing: ClientError.missingUser)
                    return
                }
                continuation.resume(returning: result.user.uid)
            }
        }
        return userID
    }

    private func baseFamilyOperations(
        family: FamilySnapshot,
        uid: String,
        now: Date,
        expiresAt: Date
    ) -> [FirestoreWriteOperation] {
        [
            FirestoreWriteOperation(
                path: "families/\(family.id)",
                data: [
                    "id": family.id,
                    "name": family.name,
                    "inviteCode": family.inviteCode,
                    "createdAt": family.createdAt,
                    "lineGroupId": family.lineGroupId ?? NSNull(),
                    "migratedAt": now
                ]
            ),
            FirestoreWriteOperation(
                path: "families/\(family.id)/members/\(uid)",
                data: [
                    "uid": uid,
                    "displayName": "匿名ユーザー",
                    "createdAt": now
                ]
            ),
            FirestoreWriteOperation(
                path: "invites/\(family.inviteCode)",
                data: [
                    "familyId": family.id,
                    "familyName": family.name,
                    "inviteCode": family.inviteCode,
                    "createdBy": uid,
                    "createdAt": now,
                    "expiresAt": expiresAt
                ]
            )
        ]
    }

    private func fetchInviteDocumentIDs(familyId: String) async throws -> [String] {
        let query = firestore
            .collection("invites")
            .whereField("familyId", isEqualTo: familyId)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let documentIDs = snapshot?.documents.map(\.documentID) ?? []
                continuation.resume(returning: documentIDs)
            }
        }
    }

    private func fetchExpiredInviteDocumentIDs(before date: Date) async throws -> [String] {
        let query = firestore
            .collection("invites")
            .whereField("expiresAt", isLessThan: Timestamp(date: date))

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let documentIDs = snapshot?.documents.map(\.documentID) ?? []
                continuation.resume(returning: documentIDs)
            }
        }
    }

    private func fetchCollectionDocumentIDs(path: String) async throws -> [String] {
        let query = firestore.collection(path)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: snapshot?.documents.map(\.documentID) ?? [])
            }
        }
    }

    private func upsertDocument(path: String, data: [String: Any]) async throws {
        let reference = firestore.document(path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setData(data, merge: true) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func deleteDocument(path: String) async throws {
        let reference = firestore.document(path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func commitWritesInBatches(_ operations: [FirestoreWriteOperation], batchSize: Int = 400) async throws {
        guard !operations.isEmpty else {
            return
        }

        var startIndex = operations.startIndex
        while startIndex < operations.endIndex {
            let endIndex = min(startIndex + batchSize, operations.endIndex)
            let batch = firestore.batch()

            for operation in operations[startIndex..<endIndex] {
                let reference = firestore.document(operation.path)
                batch.setData(operation.data, forDocument: reference, merge: true)
            }

            try await commitBatch(batch)
            startIndex = endIndex
        }
    }

    private func commitDeletesInBatches(_ paths: [String], batchSize: Int = 400) async throws {
        guard !paths.isEmpty else {
            return
        }

        var startIndex = paths.startIndex
        while startIndex < paths.endIndex {
            let endIndex = min(startIndex + batchSize, paths.endIndex)
            let batch = firestore.batch()

            for path in paths[startIndex..<endIndex] {
                let reference = firestore.document(path)
                batch.deleteDocument(reference)
            }

            try await commitBatch(batch)
            startIndex = endIndex
        }
    }

    nonisolated private func stringValue(from raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        return normalizedOptionalString(value)
    }

    nonisolated private func intValue(from raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        return nil
    }

    nonisolated private func boolValue(from raw: Any?) -> Bool? {
        if let value = raw as? Bool {
            return value
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    nonisolated private func dateValue(from raw: Any?) -> Date? {
        if let timestamp = raw as? Timestamp {
            return timestamp.dateValue()
        }
        if let date = raw as? Date {
            return date
        }
        return nil
    }

    private func commitBatch(_ batch: WriteBatch) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            batch.commit { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}
