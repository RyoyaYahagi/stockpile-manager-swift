import Foundation
import SwiftData
import CloudKit
import OSLog

@MainActor
final class CloudKitFamilySharingService {
    private enum Constants {
        static let familyRecordType = "Family"
        static let bagRecordType = "Bag"
        static let itemRecordType = "Item"
    }

    struct RemoteRecordCounts {
        let familyCount: Int
        let bagCount: Int
        let itemCount: Int
    }

    struct ShareParticipantDisplay: Identifiable, Sendable {
        enum Status: Int, Sendable {
            case owner = 0
            case accepted = 1
            case pending = 2

            var label: String {
                switch self {
                case .owner:
                    return L10n.string("オーナー")
                case .accepted:
                    return L10n.string("参加中")
                case .pending:
                    return L10n.string("招待中")
                }
            }

            var fallbackName: String {
                switch self {
                case .owner:
                    return L10n.string("オーナー")
                case .accepted:
                    return L10n.string("参加者")
                case .pending:
                    return L10n.string("招待中の参加者")
                }
            }
        }

        let id: String
        let displayName: String
        let status: Status

        var statusLabel: String {
            status.label
        }

        var isOwner: Bool {
            status == .owner
        }
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
            lastError ?? CloudKitSharingError.sharePreparationFailed(detail: L10n.string("不明なエラー"))
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
        logger.notice("CloudKit share accept started")

        let acceptedShare: CKShare
        do {
            acceptedShare = try await accept(metadata: metadata, using: container)
        } catch {
            logShareError(error, phase: "acceptShare.accept")
            throw error
        }

        let acceptedZoneID = acceptedShare.recordID.zoneID
        logger.notice("CloudKit share accepted")
        do {
            let family = try await syncAcceptedShareToLocal(zoneID: acceptedZoneID)
            logger.notice("CloudKit share local sync succeeded")
            return family
        } catch {
            logShareError(error, phase: "acceptShare.sync")
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
        try attachOrphanLocalDataIfNeeded(to: family)
        LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()

        let database = database(for: family)
        if family.cloudKitDatabaseScope == .privateDatabase {
            try await ensureZoneExists(for: family)
        }

        let scopedBags = try fetchLocalBags(for: family)
        let scopedItems = try fetchLocalItems(for: family)
        let familyRecord = makeFamilyRecord(from: family)
        let bagRecords = scopedBags.map { makeBagRecord(from: $0, family: family) }
        let itemRecords = scopedItems.map { makeItemRecord(from: $0, family: family) }
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
        do {
            _ = try await syncZoneToLocal(
                zoneID: zoneID(for: family),
                database: database(for: family),
                scope: family.cloudKitDatabaseScope ?? .privateDatabase
            )
        } catch {
            if shouldTreatMissingRemoteStateAsEmptySnapshot(error) {
                try clearLocalFamilyDataForMissingRemoteState(for: family)
                return
            }
            throw error
        }
    }

    func fetchRemoteRecordCounts(for family: Family) async throws -> RemoteRecordCounts {
        let targetZoneID = zoneID(for: family)
        let targetDatabase = database(for: family)
        async let familyRecords = fetchRecords(
            forRecordType: Constants.familyRecordType,
            in: targetZoneID,
            database: targetDatabase
        )
        async let bagRecords = fetchRecords(
            forRecordType: Constants.bagRecordType,
            in: targetZoneID,
            database: targetDatabase
        )
        async let itemRecords = fetchRecords(
            forRecordType: Constants.itemRecordType,
            in: targetZoneID,
            database: targetDatabase
        )

        return try await RemoteRecordCounts(
            familyCount: familyRecords.count,
            bagCount: bagRecords.count,
            itemCount: itemRecords.count
        )
    }

    func fetchShareParticipants(for family: Family) async throws -> [ShareParticipantDisplay] {
        guard family.shareState != .localOnly else { return [] }
        guard let share = try await fetchZoneWideShare(for: family) else { return [] }

        return share.participants.enumerated().compactMap { index, participant in
            participantDisplay(from: participant, index: index)
        }
        .sorted { lhs, rhs in
            if lhs.status.rawValue != rhs.status.rawValue {
                return lhs.status.rawValue < rhs.status.rawValue
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
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
            fallbackName: familyName?.isEmpty == false ? familyName! : L10n.string("家族")
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
            item.janCode = normalizedOptionalString(itemRecord["janCode"] as? String)
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
        LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()
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
                    "CloudKit shared sync failed phase=acceptShare.sync[\(index)] code=\(self.publicErrorCode(for: error), privacy: .public)"
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

    private func clearLocalFamilyDataForMissingRemoteState(for family: Family) throws {
        let scopedItems = try fetchLocalItems(for: family)
        let scopedBags = try fetchLocalBags(for: family)
        guard !scopedItems.isEmpty || !scopedBags.isEmpty else { return }

        for item in scopedItems {
            modelContext.delete(item)
        }

        for bag in scopedBags {
            modelContext.delete(bag)
        }

        try modelContext.save()
        NotificationManager.shared.requestReschedule(using: modelContext)
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

    private func fetchZoneWideShare(for family: Family) async throws -> CKShare? {
        try await fetchExistingShare(for: family, in: database(for: family))
    }

    private func participantDisplay(
        from participant: CKShare.Participant,
        index: Int
    ) -> ShareParticipantDisplay? {
        let status: ShareParticipantDisplay.Status
        if participant.role == .owner {
            status = .owner
        } else {
            switch participant.acceptanceStatus {
            case .accepted:
                status = .accepted
            case .pending:
                status = .pending
            case .removed, .unknown:
                return nil
            @unknown default:
                return nil
            }
        }

        let displayName = participantDisplayName(from: participant, fallback: status.fallbackName)
        let recordName = participant.userIdentity.userRecordID?.recordName
        let id = recordName ?? "\(status.rawValue)-\(displayName)-\(index)"
        return ShareParticipantDisplay(id: id, displayName: displayName, status: status)
    }

    private func participantDisplayName(from participant: CKShare.Participant, fallback: String) -> String {
        if let nameComponents = participant.userIdentity.nameComponents {
            let formatter = PersonNameComponentsFormatter()
            let formatted = formatter.string(from: nameComponents).trimmingCharacters(in: .whitespacesAndNewlines)
            if !formatted.isEmpty {
                return formatted
            }
        }

        if let contact = participant.userIdentity.contactIdentifiers.first,
           !contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contact
        }

        return fallback
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
                logger.notice("Recovered existing CKShare after transient failure")
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
                "CloudKit share failed phase=\(phase, privacy: .public) code=\(ckError.code.rawValue, privacy: .public)"
            )

            if let partialErrors = ckError.partialErrorsByItemID, !partialErrors.isEmpty {
                logger.error(
                    "CloudKit partial failure phase=\(phase, privacy: .public) count=\(partialErrors.count, privacy: .public)"
                )
            }
            debugLogShareError(error, phase: phase)
            return
        }

        logger.error(
            "CloudKit share failed phase=\(phase, privacy: .public) code=\(self.publicErrorCode(for: error), privacy: .public)"
        )
        debugLogShareError(error, phase: phase)
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

    private func publicErrorCode(for error: Error) -> String {
        if let ckError = error as? CKError {
            return "ck_\(ckError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }

    private func debugLogShareError(_ error: Error, phase: String) {
        #if DEBUG
        logger.debug(
            "CloudKit share debug phase=\(phase, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
        )
        #endif
    }

    private func attachOrphanLocalDataIfNeeded(to family: Family) throws {
        let orphanBagDescriptor = FetchDescriptor<Bag>(
            predicate: #Predicate { $0.family == nil }
        )
        let orphanItemDescriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.family == nil }
        )

        let orphanBags = try modelContext.fetch(orphanBagDescriptor)
        let orphanItems = try modelContext.fetch(orphanItemDescriptor)
        var didChange = false

        for bag in orphanBags {
            guard normalizedNonEmptyString(bag.name) != nil else {
                modelContext.delete(bag)
                didChange = true
                continue
            }
            bag.family = family
            didChange = true
        }

        for item in orphanItems {
            guard normalizedNonEmptyString(item.name) != nil else {
                modelContext.delete(item)
                didChange = true
                continue
            }
            item.family = family
            didChange = true
        }

        if didChange {
            try modelContext.save()
        }
    }

    private func fetchLocalBags(for family: Family) throws -> [Bag] {
        let familyID = family.id
        let descriptor = FetchDescriptor<Bag>(
            predicate: #Predicate { $0.family?.id == familyID }
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchLocalItems(for family: Family) throws -> [Item] {
        let familyID = family.id
        let descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.family?.id == familyID }
        )
        return try modelContext.fetch(descriptor)
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
        if let janCode = normalizedOptionalString(item.janCode) {
            record["janCode"] = janCode as CKRecordValue
        }
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

    private func shouldTreatMissingRemoteStateAsEmptySnapshot(_ error: Error) -> Bool {
        if let sharingError = error as? CloudKitSharingError,
           sharingError == .familyRecordNotFound {
            return true
        }

        guard let ckError = error as? CKError else {
            return false
        }

        switch ckError.code {
        case .zoneNotFound, .userDeletedZone, .unknownItem:
            return true
        case .partialFailure:
            guard let partialErrors = ckError.partialErrorsByItemID?.values,
                  !partialErrors.isEmpty else {
                return false
            }
            return partialErrors.allSatisfy { shouldTreatMissingRemoteStateAsEmptySnapshot($0) }
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
            ?? L10n.string("共有中の家族")

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
            return L10n.string("CloudKit共有レコードの作成に失敗しました。")
        case .invalidShareMetadata:
            return L10n.string("CloudKit共有メタデータの読み取りに失敗しました。")
        case .familyRecordNotFound:
            return L10n.string("共有された家族データが見つかりません。")
        case .recordNotFound:
            return L10n.string("CloudKit上のレコードが見つかりません。")
        case .sharePreparationFailed(let detail):
            return L10n.format("共有リンクの再準備に失敗しました。%@", detail)
        }
    }
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

            didChange = repairBags(validBags) || didChange
            didChange = repairItems(validItems) || didChange

            if didChange {
                try modelContext.save()
            }
        } catch {
            #if DEBUG
            print("データ修復に失敗: \(error)")
            #endif
        }
    }

    private func repairBags(_ bags: [Bag]) -> Bool {
        var didChange = false

        for duplicates in Dictionary(grouping: bags, by: \.id).values where duplicates.count > 1 {
            mergeBagDuplicates(duplicates)
            didChange = true
        }

        let currentBags = ((try? modelContext.fetch(FetchDescriptor<Bag>())) ?? bags)
            .filter { normalizedNonEmptyString($0.name) != nil }
        let semanticGroups = Dictionary(grouping: currentBags, by: bagSemanticKey(for:))
        for duplicates in semanticGroups.values where duplicates.count > 1 {
            guard shouldMergeSemanticBagGroup(duplicates) else { continue }
            mergeBagDuplicates(duplicates)
            didChange = true
        }

        return didChange
    }

    private func repairItems(_ items: [Item]) -> Bool {
        var didChange = false

        for duplicates in Dictionary(grouping: items, by: \.id).values where duplicates.count > 1 {
            mergeItemDuplicates(duplicates)
            didChange = true
        }

        let currentItems = ((try? modelContext.fetch(FetchDescriptor<Item>())) ?? items)
            .filter { normalizedNonEmptyString($0.name) != nil }
        let semanticGroups = Dictionary(grouping: currentItems, by: itemSemanticKey(for:))
        for duplicates in semanticGroups.values where duplicates.count > 1 {
            mergeItemDuplicates(duplicates)
            didChange = true
        }

        return didChange
    }

    private func mergeBagDuplicates(_ duplicates: [Bag]) {
        let keeper = preferredBag(in: duplicates)
        keeper.name = normalizedNonEmptyString(keeper.name) ?? keeper.name
        keeper.createdAt = duplicates.map(\.createdAt).min() ?? keeper.createdAt
        keeper.family = duplicates.compactMap(\.family).first ?? keeper.family

        for duplicate in duplicates where duplicate.persistentModelID != keeper.persistentModelID {
            for item in duplicate.resolvedItems {
                item.bag = keeper
            }
            modelContext.delete(duplicate)
        }
    }

    private func mergeItemDuplicates(_ duplicates: [Item]) {
        let keeper = preferredItem(in: duplicates)
        keeper.name = duplicates
            .compactMap { normalizedNonEmptyString($0.name) }
            .max(by: { $0.count < $1.count }) ?? keeper.name
        keeper.janCode = duplicates.compactMap(\.janCode).compactMap(normalizedOptionalString).first ?? keeper.janCode
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

    private func bagSemanticKey(for bag: Bag) -> String {
        let familyScope = familyScopeKey(for: bag.family)
        let nameKey = foldedLookupKey(for: bag.name) ?? bag.id.uuidString
        return "\(familyScope)::bag::\(nameKey)"
    }

    private func itemSemanticKey(for item: Item) -> ItemSemanticKey {
        ItemSemanticKey(
            familyScope: familyScopeKey(for: item.family),
            bagScope: item.bag?.id.uuidString,
            name: foldedLookupKey(for: item.name) ?? item.id.uuidString,
            janCode: normalizedOptionalString(item.janCode),
            quantity: item.quantity,
            expiryDate: expiryDayKey(for: item.expiryDate),
            locationNote: foldedLookupKey(for: item.locationNote)
        )
    }

    private func shouldMergeSemanticBagGroup(_ bags: [Bag]) -> Bool {
        if bags.contains(where: { $0.resolvedItems.isEmpty }) {
            return true
        }

        let itemSignatureSets = bags.map { bag in
            Set(bag.resolvedItems.map(itemContentKeyIgnoringBag(for:)))
        }

        guard let firstSet = itemSignatureSets.first else {
            return false
        }

        return itemSignatureSets.dropFirst().allSatisfy { $0 == firstSet }
    }

    private func itemContentKeyIgnoringBag(for item: Item) -> ItemContentKey {
        ItemContentKey(
            name: foldedLookupKey(for: item.name) ?? item.id.uuidString,
            janCode: normalizedOptionalString(item.janCode),
            quantity: item.quantity,
            expiryDate: expiryDayKey(for: item.expiryDate),
            locationNote: foldedLookupKey(for: item.locationNote)
        )
    }

    private func familyScopeKey(for family: Family?) -> String {
        guard let family else { return "no-family" }
        if let zoneIdentity = family.cloudKitZoneIdentity {
            return "cloudkit:\(zoneIdentity)"
        }
        return "local:\(family.id.uuidString)"
    }

    private func foldedLookupKey(for value: String?) -> String? {
        guard let normalized = normalizedNonEmptyString(value) else { return nil }
        return normalized.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    private func expiryDayKey(for date: Date?) -> String? {
        guard let date else { return nil }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
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
        guard family.cloudKitZoneName == nil,
              family.cloudKitZoneOwnerName == nil,
              family.cloudKitShareURL == nil else { return false }
        return family.resolvedBags.isEmpty && family.resolvedItems.isEmpty && family.uniqueMembers.isEmpty
    }
}

private struct ItemSemanticKey: Hashable {
    let familyScope: String
    let bagScope: String?
    let name: String
    let janCode: String?
    let quantity: Int
    let expiryDate: String?
    let locationNote: String?
}

private struct ItemContentKey: Hashable {
    let name: String
    let janCode: String?
    let quantity: Int
    let expiryDate: String?
    let locationNote: String?
}
