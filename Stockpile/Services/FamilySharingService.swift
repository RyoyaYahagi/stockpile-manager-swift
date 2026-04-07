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
        static let deletionMarkerRecordType = "DeletionMarker"
        static let shareParticipantsCacheTTL: TimeInterval = 60
    }

    private actor ShareParticipantsCache {
        private struct Entry {
            let participants: [ShareParticipantDisplay]
            let fetchedAt: Date
        }

        private var storage: [String: Entry] = [:]

        func value(for key: String, maxAge: TimeInterval, now: Date = Date()) -> [ShareParticipantDisplay]? {
            guard let entry = storage[key] else { return nil }
            guard now.timeIntervalSince(entry.fetchedAt) <= maxAge else {
                storage.removeValue(forKey: key)
                return nil
            }
            return entry.participants
        }

        func store(_ participants: [ShareParticipantDisplay], for key: String, now: Date = Date()) {
            storage[key] = Entry(participants: participants, fetchedAt: now)
        }

        func removeValue(for key: String) {
            storage.removeValue(forKey: key)
        }
    }

    private struct RemoteZoneState {
        let familyRecord: CKRecord?
        let bagRecords: [CKRecord]
        let itemRecords: [CKRecord]
        let deletionMarkers: [RemoteDeletionMarkerPayload]
    }

    private struct RemoteDeletionMarkerPayload {
        let markerID: UUID
        let familyID: UUID
        let entityType: CloudKitDeletionMarkerEntityType
        let targetRecordID: String
        let deletedAt: Date

        var key: String {
            Self.makeKey(entityType: entityType, targetRecordID: targetRecordID)
        }

        static func makeKey(
            entityType: CloudKitDeletionMarkerEntityType,
            targetRecordID: String
        ) -> String {
            "\(entityType.rawValue)::\(targetRecordID)"
        }
    }

    private enum RemoteSnapshotState {
        case snapshotAvailable(Family)
        case remoteNotReady
        case remoteMissingAfterEstablished
        case sharedAccessRevoked
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

    private static let shareParticipantsCache = ShareParticipantsCache()
    private let logger = Logger(subsystem: "com.stockpile-manager.app", category: "CloudKitSharing")
    private let modelContext: ModelContext
    private let backend: any CloudKitFamilySharingBackend

    init(
        modelContext: ModelContext,
        backend: any CloudKitFamilySharingBackend = DefaultCloudKitFamilySharingBackend(container: .default())
    ) {
        self.modelContext = modelContext
        self.backend = backend
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
                    family.cloudKitPendingSync = false
                    family.cloudKitHasRemoteBaseline = true
                    try? modelContext.save()
                    await cacheShareParticipants(from: existingShare, for: family)
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
        try await syncFamilyDataToCloudKit(for: family)
        try await ensureFamilyRecordExists(for: family)

        if let existingShare = try await fetchExistingShare(for: family, scope: .privateDatabase) {
            return try await finalizePreparedShare(existingShare, for: family)
        }

        let share = CKShare(recordZoneID: zoneID(for: family))
        share[CKShare.SystemFieldKey.title] = family.name as CKRecordValue
        share.publicPermission = .none

        do {
            let savedShare = try await save(record: share, scope: .privateDatabase) as? CKShare
            guard let savedShare else {
                throw CloudKitSharingError.invalidShareRecord
            }

            return try await finalizePreparedShare(savedShare, for: family)
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

    private func finalizePreparedShare(_ share: CKShare, for family: Family) async throws -> CKShare {
        family.cloudKitShareURL = share.url
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        try? modelContext.save()
        await cacheShareParticipants(from: share, for: family)

        // Share 作成後にもう一度 zone へ保存し、参加者側から既存レコードが見える状態を強める。
        try await syncFamilyDataToCloudKit(for: family)
        try await ensureFamilyRecordExists(for: family)
        await logRemoteCountsForDiagnostics(event: "共有リンク準備完了", family: family)
        return share
    }

    @discardableResult
    func acceptShare(metadata: CKShare.Metadata) async throws -> Family {
        logger.notice("CloudKit share accept started")

        let acceptedShare: CKShare
        do {
            acceptedShare = try await accept(metadata: metadata)
        } catch {
            logShareError(error, phase: "acceptShare.accept")
            throw error
        }

        return try await syncAcceptedShare(
            zoneID: acceptedShare.recordID.zoneID,
            fallbackName: acceptedShareFallbackName(from: metadata, acceptedShare: acceptedShare),
            resolvedFamilyID: acceptedShareFamilyID(from: metadata)
        )
    }

    @discardableResult
    func syncAcceptedShare(
        zoneID: CKRecordZone.ID,
        fallbackName: String,
        resolvedFamilyID: UUID?,
        retryIntervalsInNanoseconds: [UInt64] = [
            0,
            500_000_000,
            1_500_000_000,
            3_000_000_000
        ]
    ) async throws -> Family {
        logger.notice("CloudKit share accepted")
        do {
            let family = try await syncAcceptedShareToLocal(
                zoneID: zoneID,
                retryIntervalsInNanoseconds: retryIntervalsInNanoseconds
            )
            family.markAsCurrent()
            try modelContext.save()
            logger.notice("CloudKit share local sync succeeded")
            return family
        } catch {
            logShareError(error, phase: "acceptShare.sync")
            let pendingFamily = createOrUpdatePendingFamily(
                zoneID: zoneID,
                fallbackName: fallbackName,
                resolvedFamilyID: resolvedFamilyID
            )
            guard shouldDeferAcceptedShareCompletion(after: error) else {
                throw error
            }
            logDiagnostics(
                event: "共有受理は成功・共有データ待機中",
                family: pendingFamily,
                extra: [
                    "description": error.localizedDescription,
                    "errorType": String(describing: type(of: error))
                ]
            )
            return pendingFamily
        }
    }

    func deleteItemLocally(_ item: Item, in family: Family?) throws {
        try deleteItemsLocally([item], in: family)
    }

    func deleteItemsLocally(_ items: [Item], in family: Family?) throws {
        let deletedAt = Date()

        for item in items {
            let targetFamily = family ?? item.family
            if let targetFamily, targetFamily.isCloudKitSharedFamily {
                try upsertLocalDeletionMarker(
                    familyID: targetFamily.id,
                    entityType: .item,
                    targetRecordID: item.id.uuidString,
                    deletedAt: deletedAt,
                    isPendingUpload: true
                )
            }
            modelContext.delete(item)
        }
    }

    func deleteBagLocally(_ bag: Bag, in family: Family?) throws {
        let deletedAt = Date()
        let linkedItems = bag.resolvedItems

        for item in linkedItems {
            item.bag = nil
            item.markUpdated(at: deletedAt)
        }

        let targetFamily = family ?? bag.family
        if let targetFamily, targetFamily.isCloudKitSharedFamily {
            try upsertLocalDeletionMarker(
                familyID: targetFamily.id,
                entityType: .bag,
                targetRecordID: bag.id.uuidString,
                deletedAt: deletedAt,
                isPendingUpload: true
            )
        }

        modelContext.delete(bag)
    }

    func removeDeletionMarkerIfNeeded(forItemID itemID: UUID, family: Family) throws {
        try removeLocalDeletionMarkers(
            familyID: family.id,
            entityType: .item,
            targetRecordID: itemID.uuidString
        )
    }

    func removeDeletionMarkerIfNeeded(forBagID bagID: UUID, family: Family) throws {
        try removeLocalDeletionMarkers(
            familyID: family.id,
            entityType: .bag,
            targetRecordID: bagID.uuidString
        )
    }

    func syncFamilyDataToCloudKit(for family: Family) async throws {
        guard family.isCloudKitSharedFamily else { return }
        try attachOrphanLocalDataIfNeeded(to: family)
        LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()

        let scope = databaseScope(for: family)
        if family.cloudKitDatabaseScope == .privateDatabase {
            try await ensureZoneExists(for: family)
        }

        let remoteState = try await fetchRemoteZoneState(
            zoneID: zoneID(for: family),
            scope: scope
        )
        try applyRemoteDeletionMarkersToLocal(remoteState.deletionMarkers, family: family)

        let scopedBags = try fetchLocalBags(for: family)
        let scopedItems = try fetchLocalItems(for: family)
        let localDeletionMarkers = try fetchLocalDeletionMarkers(for: family)
        let remoteDeletionMap = Dictionary(
            remoteState.deletionMarkers.map { ($0.key, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.deletedAt >= rhs.deletedAt ? lhs : rhs }
        )
        let remoteBagMap = Dictionary(
            remoteState.bagRecords.compactMap { record -> (UUID, CKRecord)? in
                guard let bagID = uuidValue(from: record["id"]) else { return nil }
                return (bagID, record)
            },
            uniquingKeysWith: { lhs, rhs in
                remoteRecordTimestamp(rhs) >= remoteRecordTimestamp(lhs) ? rhs : lhs
            }
        )
        let remoteItemMap = Dictionary(
            remoteState.itemRecords.compactMap { record -> (UUID, CKRecord)? in
                guard let itemID = uuidValue(from: record["id"]) else { return nil }
                return (itemID, record)
            },
            uniquingKeysWith: { lhs, rhs in
                remoteRecordTimestamp(rhs) >= remoteRecordTimestamp(lhs) ? rhs : lhs
            }
        )

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        if shouldUploadRecord(
            localTimestamp: family.syncTimestamp,
            remoteRecord: remoteState.familyRecord
        ) {
            recordsToSave.append(makeFamilyRecord(from: family))
        }

        for bag in scopedBags {
            let remoteDeletion = remoteDeletionMap[
                RemoteDeletionMarkerPayload.makeKey(
                    entityType: .bag,
                    targetRecordID: bag.id.uuidString
                )
            ]
            guard shouldUploadRecord(
                localTimestamp: bag.syncTimestamp,
                remoteRecord: remoteBagMap[bag.id],
                remoteDeletionTimestamp: remoteDeletion?.deletedAt
            ) else {
                continue
            }
            recordsToSave.append(makeBagRecord(from: bag, family: family))
        }

        for item in scopedItems {
            let remoteDeletion = remoteDeletionMap[
                RemoteDeletionMarkerPayload.makeKey(
                    entityType: .item,
                    targetRecordID: item.id.uuidString
                )
            ]
            guard shouldUploadRecord(
                localTimestamp: item.syncTimestamp,
                remoteRecord: remoteItemMap[item.id],
                remoteDeletionTimestamp: remoteDeletion?.deletedAt
            ) else {
                continue
            }
            recordsToSave.append(makeItemRecord(from: item, family: family))
        }

        var uploadedDeletionMarkerIDs = Set<UUID>()
        for marker in localDeletionMarkers where marker.isPendingUpload {
            if let remoteMarker = remoteDeletionMap[markerKey(for: marker)],
               remoteMarker.deletedAt >= marker.deletedAt {
                marker.isPendingUpload = false
                continue
            }

            recordsToSave.append(makeDeletionMarkerRecord(from: marker, family: family))
            recordIDsToDelete.append(recordIDForDeletionMarkerTarget(marker, family: family))
            uploadedDeletionMarkerIDs.insert(marker.id)
        }

        if !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty {
            try await modify(
                recordsToSave: recordsToSave,
                recordIDsToDelete: recordIDsToDelete,
                scope: scope
            )
        }

        for marker in localDeletionMarkers
        where uploadedDeletionMarkerIDs.contains(marker.id) {
            marker.isPendingUpload = false
        }

        if remoteState.familyRecord != nil {
            family.cloudKitHasRemoteBaseline = true
        }
        try modelContext.save()
    }

    func syncFamilyStateFromCloudKit(for family: Family) async throws {
        guard family.isCloudKitSharedFamily else { return }
        let shouldPromotePendingSharedFamilyOnSuccess =
            family.cloudKitDatabaseScope == .sharedDatabase
            && family.cloudKitPendingSync
            && family.lastSelectedAt == nil

        switch try await fetchRemoteSnapshotState(for: family) {
        case .snapshotAvailable(let syncedFamily):
            if shouldPromotePendingSharedFamilyOnSuccess,
               syncedFamily.lastSelectedAt == nil {
                syncedFamily.markAsCurrent()
                try modelContext.save()
                logDiagnostics(event: "共有家族を現在の家族へ昇格", family: syncedFamily)
            }
            logDiagnostics(event: "共有スナップショット同期成功", family: syncedFamily)
            return
        case .remoteNotReady:
            logDiagnostics(event: "共有スナップショット未確定", family: family)
            if family.cloudKitDatabaseScope != .sharedDatabase {
                try await syncFamilyDataToCloudKit(for: family)
            }
        case .remoteMissingAfterEstablished:
            logDiagnostics(event: "共有スナップショット消失を検出", family: family)
            try clearRevokedSharedFamilyState(for: family)
        case .sharedAccessRevoked:
            logDiagnostics(event: "共有アクセス失効を検出", family: family)
            try clearRevokedSharedFamilyState(for: family)
        }
    }

    func fetchRemoteRecordCounts(for family: Family) async throws -> RemoteRecordCounts {
        let targetZoneID = zoneID(for: family)
        let targetScope = databaseScope(for: family)
        async let familyRecords = fetchRecords(
            forRecordType: Constants.familyRecordType,
            in: targetZoneID,
            scope: targetScope
        )
        async let bagRecords = fetchRecords(
            forRecordType: Constants.bagRecordType,
            in: targetZoneID,
            scope: targetScope
        )
        async let itemRecords = fetchRecords(
            forRecordType: Constants.itemRecordType,
            in: targetZoneID,
            scope: targetScope
        )

        return try await RemoteRecordCounts(
            familyCount: familyRecords.count,
            bagCount: bagRecords.count,
            itemCount: itemRecords.count
        )
    }

    func fetchShareParticipants(
        for family: Family,
        forceRefresh: Bool = false
    ) async throws -> [ShareParticipantDisplay] {
        guard family.shareState != .localOnly else { return [] }
        let cacheKey = shareParticipantsCacheKey(for: family)

        if !forceRefresh,
           let cachedParticipants = await Self.shareParticipantsCache.value(
            for: cacheKey,
            maxAge: Constants.shareParticipantsCacheTTL
           ) {
            return cachedParticipants
        }

        guard let share = try await fetchZoneWideShare(for: family) else { return [] }
        let participants = shareParticipantDisplays(from: share)
        await Self.shareParticipantsCache.store(participants, for: cacheKey)
        return participants
    }

    func clearShareMetadata(for family: Family) {
        let cacheKey = shareParticipantsCacheKey(for: family)
        family.cloudKitShareURL = nil
        family.cloudKitZoneName = nil
        family.cloudKitZoneOwnerName = nil
        family.cloudKitDatabaseScope = nil
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = false
        Task {
            await Self.shareParticipantsCache.removeValue(for: cacheKey)
        }
        try? modelContext.save()
    }

    func leaveFamily(_ family: Family) async throws {
        guard family.cloudKitDatabaseScope == .sharedDatabase else { return }
        let cacheKey = shareParticipantsCacheKey(for: family)
        for marker in try fetchLocalDeletionMarkers(for: family) {
            modelContext.delete(marker)
        }
        modelContext.delete(family)
        try modelContext.save()
        await Self.shareParticipantsCache.removeValue(for: cacheKey)
    }

    private func shareParticipantDisplays(from share: CKShare) -> [ShareParticipantDisplay] {
        share.participants.enumerated().compactMap { index, participant in
            participantDisplay(from: participant, index: index)
        }
        .sorted { lhs, rhs in
            if lhs.status.rawValue != rhs.status.rawValue {
                return lhs.status.rawValue < rhs.status.rawValue
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func syncZoneToLocal(
        zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> Family {
        let remoteState = try await fetchRemoteZoneState(zoneID: zoneID, scope: scope)

        guard let familyRecord = remoteState.familyRecord else {
            throw CloudKitSharingError.familyRecordNotFound
        }

        let familyID = uuidValue(from: familyRecord["id"]) ?? UUID()
        let familyName = (familyRecord["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFamily = try fetchOrCreateFamily(
            id: familyID,
            fallbackName: familyName?.isEmpty == false ? familyName! : L10n.string("家族")
        )

        let remoteFamilyTimestamp = remoteRecordTimestamp(familyRecord)
        let shouldAdoptRemoteFamilyMetadata = !currentFamily.cloudKitHasRemoteBaseline
            || currentFamily.syncTimestamp <= remoteFamilyTimestamp
        if shouldAdoptRemoteFamilyMetadata {
            currentFamily.name = familyName?.isEmpty == false ? familyName! : currentFamily.name
            currentFamily.updatedAt = remoteFamilyTimestamp
        }
        currentFamily.cloudKitZoneName = zoneID.zoneName
        currentFamily.cloudKitZoneOwnerName = zoneID.ownerName
        currentFamily.cloudKitDatabaseScope = scope
        currentFamily.cloudKitPendingSync = false
        currentFamily.cloudKitHasRemoteBaseline = true

        let remoteDeletionMap = Dictionary(
            remoteState.deletionMarkers.map { ($0.key, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.deletedAt >= rhs.deletedAt ? lhs : rhs }
        )

        var bagMap = Dictionary(
            uniqueKeysWithValues: try fetchLocalBags(for: currentFamily).map { ($0.id, $0) }
        )

        let validBagRecords = remoteState.bagRecords.compactMap { bagRecord -> (UUID, String, Date)? in
            guard let bagID = uuidValue(from: bagRecord["id"]),
                  let bagName = normalizedNonEmptyString(bagRecord["name"] as? String) else { return nil }
            return (bagID, bagName, remoteRecordTimestamp(bagRecord))
        }

        for (bagID, bagName, remoteUpdatedAt) in validBagRecords {
            let bag = bagMap[bagID] ?? {
                let newBag = Bag(name: bagName)
                newBag.id = bagID
                modelContext.insert(newBag)
                return newBag
            }()

            if bag.syncTimestamp <= remoteUpdatedAt {
                bag.name = bagName
                bag.updatedAt = remoteUpdatedAt
            }
            bag.family = currentFamily
            bagMap[bagID] = bag
        }

        let validItemRecords = remoteState.itemRecords.compactMap { itemRecord -> (CKRecord, UUID, String, Date)? in
            guard let itemID = uuidValue(from: itemRecord["id"]),
                  let itemName = normalizedNonEmptyString(itemRecord["name"] as? String) else { return nil }
            return (itemRecord, itemID, itemName, remoteRecordTimestamp(itemRecord))
        }
        for (itemRecord, itemID, itemName, remoteUpdatedAt) in validItemRecords {

            let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.id == itemID })
            let item = try modelContext.fetch(descriptor).first ?? {
                let newItem = Item(name: itemName)
                newItem.id = itemID
                modelContext.insert(newItem)
                return newItem
            }()

            if item.syncTimestamp <= remoteUpdatedAt {
                item.name = itemName
                item.janCode = normalizedOptionalString(itemRecord["janCode"] as? String)
                item.quantity = intValue(from: itemRecord["quantity"]) ?? item.quantity
                item.expiryDate = itemRecord["expiryDate"] as? Date
                item.locationNote = normalizedOptionalString(itemRecord["locationNote"] as? String)
                item.notified30 = (itemRecord["notified30"] as? NSNumber)?.boolValue ?? item.notified30
                item.notified7 = (itemRecord["notified7"] as? NSNumber)?.boolValue ?? item.notified7
                item.notified1 = (itemRecord["notified1"] as? NSNumber)?.boolValue ?? item.notified1
                item.updatedAt = remoteUpdatedAt
                if let bagID = uuidValue(from: itemRecord["bagID"]) {
                    item.bag = bagMap[bagID]
                } else {
                    item.bag = nil
                }
            }
            item.family = currentFamily
        }

        try mergeRemoteDeletionMarkersIntoLocal(remoteState.deletionMarkers)
        try applyRemoteDeletionMarkersToLocal(
            remoteState.deletionMarkers,
            family: currentFamily,
            remoteDeletionMap: remoteDeletionMap
        )

        logDiagnostics(
            event: "共有ゾーン読込",
            family: currentFamily,
            extra: [
                "scope": scope.rawValue,
                "remoteFamilyRecords": remoteState.familyRecord == nil ? "0" : "1",
                "remoteBagRecords": String(remoteState.bagRecords.count),
                "remoteItemRecords": String(remoteState.itemRecords.count),
                "remoteDeletionMarkers": String(remoteState.deletionMarkers.count)
            ]
        )

        try modelContext.save()
        LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()
        NotificationManager.shared.requestReschedule(using: modelContext)
        return currentFamily
    }

    private func syncAcceptedShareToLocal(
        zoneID: CKRecordZone.ID,
        retryIntervalsInNanoseconds: [UInt64]
    ) async throws -> Family {
        var lastError: Error?

        for (index, interval) in retryIntervalsInNanoseconds.enumerated() {
            if interval > 0 {
                try await Task.sleep(nanoseconds: interval)
            }

            do {
                return try await syncZoneToLocal(
                    zoneID: zoneID,
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
        let deletionMarkers = try fetchLocalDeletionMarkers(for: family)
        guard !scopedItems.isEmpty || !scopedBags.isEmpty || !deletionMarkers.isEmpty else { return }

        for item in scopedItems {
            modelContext.delete(item)
        }

        for bag in scopedBags {
            modelContext.delete(bag)
        }

        for marker in deletionMarkers {
            modelContext.delete(marker)
        }

        try modelContext.save()
        NotificationManager.shared.requestReschedule(using: modelContext)
    }

    private func clearRevokedSharedFamilyState(for family: Family) throws {
        let familyID = family.id.uuidString
        let zoneIdentity = family.cloudKitZoneIdentity ?? "-"
        let scopedItems = try fetchLocalItems(for: family)
        let scopedBags = try fetchLocalBags(for: family)
        let deletionMarkers = try fetchLocalDeletionMarkers(for: family)
        let cacheKey = shareParticipantsCacheKey(for: family)

        for item in scopedItems {
            modelContext.delete(item)
        }

        for bag in scopedBags {
            modelContext.delete(bag)
        }

        for member in family.resolvedMembers {
            modelContext.delete(member)
        }

        for marker in deletionMarkers {
            modelContext.delete(marker)
        }

        family.cloudKitShareURL = nil
        family.cloudKitZoneName = nil
        family.cloudKitZoneOwnerName = nil
        family.cloudKitDatabaseScope = nil
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = false
        family.lastSelectedAt = nil

        try modelContext.save()
        Task {
            await Self.shareParticipantsCache.removeValue(for: cacheKey)
        }
        NotificationManager.shared.requestReschedule(using: modelContext)
        CloudKitSharingDiagnostics.log(
            event: "共有家族のローカル状態を解除",
            details: [
                "familyID": familyID,
                "zoneIdentity": zoneIdentity
            ]
        )
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

    private func fetchExistingShare(
        for family: Family,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> CKShare? {
        let shareRecordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: family))

        do {
            let existingRecord = try await fetchRecord(with: shareRecordID, scope: scope)
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
        try await fetchExistingShare(for: family, scope: databaseScope(for: family))
    }

    private func cacheShareParticipants(from share: CKShare, for family: Family) async {
        await Self.shareParticipantsCache.store(
            shareParticipantDisplays(from: share),
            for: shareParticipantsCacheKey(for: family)
        )
    }

    private func shareParticipantsCacheKey(for family: Family) -> String {
        let zoneID = zoneID(for: family)
        let scope = databaseScope(for: family)
        return "\(scope.rawValue)::\(zoneID.ownerName)::\(zoneID.zoneName)"
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
        family.cloudKitHasRemoteBaseline = false
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
            if let existingShare = try await fetchExistingShare(for: family, scope: .privateDatabase) {
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

    private func ensureFamilyRecordExists(for family: Family) async throws {
        let familyRecord = makeFamilyRecord(from: family)
        try await modify(recordsToSave: [familyRecord], recordIDsToDelete: [], scope: .privateDatabase)
    }

    private func ensureZoneExists(for family: Family) async throws {
        try await backend.ensureZoneExists(zoneID(for: family))
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

    private func fetchLocalDeletionMarkers(for family: Family) throws -> [CloudKitDeletionMarker] {
        let familyID = family.id
        let descriptor = FetchDescriptor<CloudKitDeletionMarker>(
            predicate: #Predicate { $0.familyID == familyID }
        )
        return try modelContext.fetch(descriptor)
    }

    private func zoneID(for family: Family) -> CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: family.cloudKitZoneName ?? "family-\(family.id.uuidString)",
            ownerName: family.cloudKitZoneOwnerName ?? CKCurrentUserDefaultName
        )
    }

    private func databaseScope(for family: Family) -> FamilyCloudKitDatabaseScope {
        family.cloudKitDatabaseScope ?? .privateDatabase
    }

    private func makeFamilyRecord(from family: Family) -> CKRecord {
        let record = CKRecord(
            recordType: Constants.familyRecordType,
            recordID: CKRecord.ID(recordName: "family-\(family.id.uuidString)", zoneID: zoneID(for: family))
        )
        record["id"] = family.id.uuidString as CKRecordValue
        record["name"] = family.name as CKRecordValue
        record["createdAt"] = family.createdAt as CKRecordValue
        record["updatedAt"] = family.syncTimestamp as CKRecordValue
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
        record["updatedAt"] = bag.syncTimestamp as CKRecordValue
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
        record["updatedAt"] = item.syncTimestamp as CKRecordValue
        if let bagID = item.bag?.id.uuidString {
            record["bagID"] = bagID as CKRecordValue
        }
        if let familyID = item.family?.id.uuidString {
            record["familyID"] = familyID as CKRecordValue
        }
        return record
    }

    private func makeDeletionMarkerRecord(from marker: CloudKitDeletionMarker, family: Family) -> CKRecord {
        let zoneID = zoneID(for: family)
        let record = CKRecord(
            recordType: Constants.deletionMarkerRecordType,
            recordID: CKRecord.ID(recordName: "deletion-\(marker.id.uuidString)", zoneID: zoneID)
        )
        record["id"] = marker.id.uuidString as CKRecordValue
        record["familyID"] = marker.familyID.uuidString as CKRecordValue
        record["entityType"] = marker.entityType.rawValue as CKRecordValue
        record["targetRecordID"] = marker.targetRecordID as CKRecordValue
        record["deletedAt"] = marker.deletedAt as CKRecordValue
        return record
    }

    private func recordIDForDeletionMarkerTarget(
        _ marker: CloudKitDeletionMarker,
        family: Family
    ) -> CKRecord.ID {
        let recordNamePrefix: String
        switch marker.entityType {
        case .bag:
            recordNamePrefix = "bag"
        case .item:
            recordNamePrefix = "item"
        }

        return CKRecord.ID(
            recordName: "\(recordNamePrefix)-\(marker.targetRecordID)",
            zoneID: zoneID(for: family)
        )
    }

    private func shouldUploadRecord(
        localTimestamp: Date,
        remoteRecord: CKRecord?,
        remoteDeletionTimestamp: Date? = nil
    ) -> Bool {
        if let remoteDeletionTimestamp, remoteDeletionTimestamp > localTimestamp {
            return false
        }
        guard let remoteRecord else {
            return true
        }
        return localTimestamp > remoteRecordTimestamp(remoteRecord)
    }

    private func remoteRecordTimestamp(_ record: CKRecord) -> Date {
        (record["updatedAt"] as? Date)
            ?? (record["createdAt"] as? Date)
            ?? .distantPast
    }

    private func markerKey(for marker: CloudKitDeletionMarker) -> String {
        RemoteDeletionMarkerPayload.makeKey(
            entityType: marker.entityType,
            targetRecordID: marker.targetRecordID
        )
    }

    private func fetchRemoteZoneState(
        zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> RemoteZoneState {
        async let familyRecords = fetchRecords(
            forRecordType: Constants.familyRecordType,
            in: zoneID,
            scope: scope
        )
        async let bagRecords = fetchRecords(
            forRecordType: Constants.bagRecordType,
            in: zoneID,
            scope: scope
        )
        async let itemRecords = fetchRecords(
            forRecordType: Constants.itemRecordType,
            in: zoneID,
            scope: scope
        )
        async let deletionMarkerRecords = fetchRecords(
            forRecordType: Constants.deletionMarkerRecordType,
            in: zoneID,
            scope: scope
        )

        let resolvedFamilyRecords = try await familyRecords
        let resolvedBagRecords = try await bagRecords
        let resolvedItemRecords = try await itemRecords
        let resolvedDeletionMarkerRecords = try await deletionMarkerRecords
        let resolvedDeletionMarkers = resolvedDeletionMarkerRecords.compactMap {
            remoteDeletionMarkerPayload(from: $0)
        }

        return RemoteZoneState(
            familyRecord: resolvedFamilyRecords.first,
            bagRecords: resolvedBagRecords,
            itemRecords: resolvedItemRecords,
            deletionMarkers: resolvedDeletionMarkers
        )
    }

    private func remoteDeletionMarkerPayload(from record: CKRecord) -> RemoteDeletionMarkerPayload? {
        guard let markerID = uuidValue(from: record["id"]),
              let familyID = uuidValue(from: record["familyID"]),
              let entityTypeRawValue = record["entityType"] as? String,
              let entityType = CloudKitDeletionMarkerEntityType(rawValue: entityTypeRawValue),
              let targetRecordID = normalizedNonEmptyString(record["targetRecordID"] as? String),
              let deletedAt = record["deletedAt"] as? Date else {
            return nil
        }

        return RemoteDeletionMarkerPayload(
            markerID: markerID,
            familyID: familyID,
            entityType: entityType,
            targetRecordID: targetRecordID,
            deletedAt: deletedAt
        )
    }

    private func upsertLocalDeletionMarker(
        familyID: UUID,
        entityType: CloudKitDeletionMarkerEntityType,
        targetRecordID: String,
        deletedAt: Date,
        isPendingUpload: Bool
    ) throws {
        let entityTypeRawValue = entityType.rawValue
        let descriptor = FetchDescriptor<CloudKitDeletionMarker>(
            predicate: #Predicate {
                $0.familyID == familyID
                    && $0.entityTypeRawValue == entityTypeRawValue
                    && $0.targetRecordID == targetRecordID
            }
        )
        let existingMarkers = try modelContext.fetch(descriptor)

        let marker = existingMarkers.first ?? {
            let newMarker = CloudKitDeletionMarker(
                familyID: familyID,
                entityType: entityType,
                targetRecordID: targetRecordID,
                deletedAt: deletedAt,
                isPendingUpload: isPendingUpload
            )
            modelContext.insert(newMarker)
            return newMarker
        }()

        marker.deletedAt = max(marker.deletedAt, deletedAt)
        marker.isPendingUpload = marker.isPendingUpload || isPendingUpload

        for duplicate in existingMarkers.dropFirst() {
            modelContext.delete(duplicate)
        }
    }

    private func removeLocalDeletionMarkers(
        familyID: UUID,
        entityType: CloudKitDeletionMarkerEntityType,
        targetRecordID: String
    ) throws {
        let entityTypeRawValue = entityType.rawValue
        let descriptor = FetchDescriptor<CloudKitDeletionMarker>(
            predicate: #Predicate {
                $0.familyID == familyID
                    && $0.entityTypeRawValue == entityTypeRawValue
                    && $0.targetRecordID == targetRecordID
            }
        )
        for marker in try modelContext.fetch(descriptor) {
            modelContext.delete(marker)
        }
    }

    private func mergeRemoteDeletionMarkersIntoLocal(
        _ remoteDeletionMarkers: [RemoteDeletionMarkerPayload]
    ) throws {
        for remoteMarker in remoteDeletionMarkers {
            try upsertLocalDeletionMarker(
                familyID: remoteMarker.familyID,
                entityType: remoteMarker.entityType,
                targetRecordID: remoteMarker.targetRecordID,
                deletedAt: remoteMarker.deletedAt,
                isPendingUpload: false
            )
        }
    }

    private func applyRemoteDeletionMarkersToLocal(
        _ remoteDeletionMarkers: [RemoteDeletionMarkerPayload],
        family: Family,
        remoteDeletionMap: [String: RemoteDeletionMarkerPayload]? = nil
    ) throws {
        let resolvedDeletionMap = remoteDeletionMap ?? Dictionary(
            remoteDeletionMarkers.map { ($0.key, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.deletedAt >= rhs.deletedAt ? lhs : rhs }
        )
        let scopedItems = try fetchLocalItems(for: family)
        let scopedBags = try fetchLocalBags(for: family)
        var didChange = false

        for item in scopedItems {
            let key = RemoteDeletionMarkerPayload.makeKey(
                entityType: .item,
                targetRecordID: item.id.uuidString
            )
            guard let marker = resolvedDeletionMap[key],
                  marker.deletedAt > item.syncTimestamp else { continue }
            modelContext.delete(item)
            didChange = true
        }

        for bag in scopedBags {
            let key = RemoteDeletionMarkerPayload.makeKey(
                entityType: .bag,
                targetRecordID: bag.id.uuidString
            )
            guard let marker = resolvedDeletionMap[key],
                  marker.deletedAt > bag.syncTimestamp else { continue }

            for item in bag.resolvedItems {
                item.bag = nil
                item.markUpdated(at: marker.deletedAt)
            }
            modelContext.delete(bag)
            didChange = true
        }

        if didChange {
            try modelContext.save()
        }
    }

    private func fetchRecords(
        forRecordType recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        try await backend.fetchRecords(recordType: recordType, in: zoneID, scope: scope)
    }

    private func fetchRecordIDs(
        forRecordType recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> Set<CKRecord.ID> {
        Set(try await fetchRecords(forRecordType: recordType, in: zoneID, scope: scope).map(\.recordID))
    }

    private func fetchRecord(with recordID: CKRecord.ID, scope: FamilyCloudKitDatabaseScope) async throws -> CKRecord {
        try await backend.fetchRecord(with: recordID, scope: scope)
    }

    private func save(record: CKRecord, scope: FamilyCloudKitDatabaseScope) async throws -> CKRecord {
        let savedRecords = try await modify(recordsToSave: [record], recordIDsToDelete: [], scope: scope)
        guard let savedRecord = savedRecords.first else {
            throw CloudKitSharingError.recordNotFound
        }
        return savedRecord
    }

    @discardableResult
    private func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        try await backend.modify(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete, scope: scope)
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

    private func shouldDeferAcceptedShareCompletion(after error: Error) -> Bool {
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
                return partialErrors.contains { shouldDeferAcceptedShareCompletion(after: $0) }
            }
            return false
        default:
            return false
        }
    }

    private func isMissingRemoteStateError(_ error: Error) -> Bool {
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
            return partialErrors.allSatisfy { isMissingRemoteStateError($0) }
        default:
            return false
        }
    }

    private func isRevokedSharedAccessError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }

        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            guard let partialErrors = ckError.partialErrorsByItemID?.values,
                  !partialErrors.isEmpty else {
                return false
            }
            return partialErrors.allSatisfy { isRevokedSharedAccessError($0) }
        default:
            return false
        }
    }

    private func fetchRemoteSnapshotState(for family: Family) async throws -> RemoteSnapshotState {
        do {
            let syncedFamily = try await syncZoneToLocal(
                zoneID: zoneID(for: family),
                scope: databaseScope(for: family)
            )
            return .snapshotAvailable(syncedFamily)
        } catch {
            guard isMissingRemoteStateError(error) else {
                throw error
            }

            if family.cloudKitDatabaseScope == .sharedDatabase {
                guard family.cloudKitHasRemoteBaseline else {
                    return .remoteNotReady
                }
                if isRevokedSharedAccessError(error) {
                    return .sharedAccessRevoked
                }
                return .remoteMissingAfterEstablished
            }

            return .remoteNotReady
        }
    }

    private func createOrUpdatePendingFamily(
        zoneID: CKRecordZone.ID,
        fallbackName: String,
        resolvedFamilyID: UUID?
    ) -> Family {
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
        family.cloudKitHasRemoteBaseline = false
        try? modelContext.save()
        CloudKitSharingDiagnostics.log(
            event: "共有家族を保留状態で作成",
            details: [
                "familyID": family.id.uuidString,
                "name": family.name,
                "zoneName": zoneID.zoneName,
                "ownerName": zoneID.ownerName,
                "resolvedFamilyID": resolvedFamilyID?.uuidString ?? "nil"
            ]
        )
        return family
    }

    private func acceptedShareFallbackName(from metadata: CKShare.Metadata, acceptedShare: CKShare) -> String {
        normalizedNonEmptyString(metadata.rootRecord?["name"] as? String)
            ?? normalizedNonEmptyString(acceptedShare[CKShare.SystemFieldKey.title] as? String)
            ?? L10n.string("共有中の家族")
    }

    private func acceptedShareFamilyID(from metadata: CKShare.Metadata) -> UUID? {
        uuidValue(from: metadata.rootRecord?["id"])
            ?? metadata.rootRecord.flatMap { rootRecord in
                let recordName = rootRecord.recordID.recordName
                guard recordName.hasPrefix("family-") else { return nil }
                return UUID(uuidString: String(recordName.dropFirst("family-".count)))
            }
            ?? {
                let zoneName = metadata.share.recordID.zoneID.zoneName
                guard zoneName.hasPrefix("family-") else { return nil }
                return UUID(uuidString: String(zoneName.dropFirst("family-".count)))
            }()
    }

    private func accept(metadata: CKShare.Metadata) async throws -> CKShare {
        try await backend.accept(metadata: metadata)
    }

    private func logDiagnostics(
        event: String,
        family: Family,
        extra: [String: String] = [:]
    ) {
        var details = extra
        details["familyID"] = family.id.uuidString
        details["familyName"] = family.name
        details["shareState"] = family.shareState.label
        details["scope"] = family.cloudKitDatabaseScope?.rawValue ?? "nil"
        details["zoneIdentity"] = family.cloudKitZoneIdentity ?? "-"
        details["pendingSync"] = family.cloudKitPendingSync ? "true" : "false"
        details["hasRemoteBaseline"] = family.cloudKitHasRemoteBaseline ? "true" : "false"
        details["lastSelectedAt"] = CloudKitSharingDiagnostics.formattedTimestamp(family.lastSelectedAt)
        CloudKitSharingDiagnostics.log(event: event, details: details)
    }

    private func logRemoteCountsForDiagnostics(event: String, family: Family) async {
        let localBagCount = (try? fetchLocalBags(for: family).count) ?? 0
        let localItemCount = (try? fetchLocalItems(for: family).count) ?? 0

        do {
            let remoteCounts = try await fetchRemoteRecordCounts(for: family)
            logDiagnostics(
                event: event,
                family: family,
                extra: [
                    "localBags": String(localBagCount),
                    "localItems": String(localItemCount),
                    "remoteFamilyRecords": String(remoteCounts.familyCount),
                    "remoteBagRecords": String(remoteCounts.bagCount),
                    "remoteItemRecords": String(remoteCounts.itemCount)
                ]
            )
        } catch {
            logDiagnostics(
                event: "\(event)（件数確認失敗）",
                family: family,
                extra: [
                    "localBags": String(localBagCount),
                    "localItems": String(localItemCount),
                    "description": error.localizedDescription,
                    "errorType": String(describing: type(of: error))
                ]
            )
        }
    }

}

@MainActor
enum CloudKitSharingDiagnostics {
    private struct Entry: Codable {
        let timestamp: Date
        let event: String
        let details: [String: String]
    }

    private static let storageKey = "cloudkit-sharing-diagnostics.entries"
    private static let maximumEntryCount = 200
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(event: String, details: [String: String] = [:]) {
        var entries = loadEntries()
        entries.append(Entry(timestamp: Date(), event: event, details: details))
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        saveEntries(entries)
    }

    static func logError(context: String, error: Error) {
        var details: [String: String] = [
            "errorType": String(describing: type(of: error)),
            "description": error.localizedDescription
        ]
        if let ckError = error as? CKError {
            details["ckCode"] = String(ckError.code.rawValue)
        }
        log(event: context, details: details)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    static func formattedTimestamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return timestampFormatter.string(from: date)
    }

    static func makeReport(modelContext: ModelContext) -> String {
        let families = (try? modelContext.fetch(FetchDescriptor<Family>())) ?? []
        let bags = (try? modelContext.fetch(FetchDescriptor<Bag>())) ?? []
        let items = (try? modelContext.fetch(FetchDescriptor<Item>())) ?? []
        let currentFamily = CurrentFamilyResolver.currentFamily(from: families)

        let bagCounts = Dictionary(grouping: bags.compactMap { bag in
            bag.family.map { ($0.id, bag) }
        }, by: { $0.0 }).mapValues(\.count)
        let itemCounts = Dictionary(grouping: items.compactMap { item in
            item.family.map { ($0.id, item) }
        }, by: { $0.0 }).mapValues(\.count)

        var lines: [String] = []
        lines.append("CloudKit共有診断レポート")
        lines.append("生成時刻: \(formattedTimestamp(Date()))")
        lines.append("currentFamily: \(currentFamilySummary(currentFamily))")
        lines.append("総家族数: \(families.count)")
        lines.append("孤立収納場所: \(bags.filter { $0.family == nil }.count)")
        lines.append("孤立アイテム: \(items.filter { $0.family == nil }.count)")
        lines.append("")
        lines.append("家族一覧:")

        if families.isEmpty {
            lines.append("- 家族データなし")
        } else {
            for family in families.sorted(by: { familySort(lhs: $0, rhs: $1) }) {
                lines.append(
                    """
                    - id=\(family.id.uuidString) \
                    name=\(sanitized(family.name)) \
                    shareState=\(family.shareState.label) \
                    scope=\(family.cloudKitDatabaseScope?.rawValue ?? "nil") \
                    zone=\(family.cloudKitZoneIdentity ?? "-") \
                    pending=\(family.cloudKitPendingSync) \
                    baseline=\(family.cloudKitHasRemoteBaseline) \
                    selectedAt=\(formattedTimestamp(family.lastSelectedAt)) \
                    members=\(family.uniqueMembers.count) \
                    bags=\(bagCounts[family.id] ?? 0) \
                    items=\(itemCounts[family.id] ?? 0)
                    """
                )
            }
        }

        lines.append("")
        lines.append("最近の共有イベント:")
        let recentLines = loadEntries().suffix(40).map { entry in
            let detailText = entry.details
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(sanitized($0.value))" }
                .joined(separator: " ")
            if detailText.isEmpty {
                return "- [\(formattedTimestamp(entry.timestamp))] \(entry.event)"
            }
            return "- [\(formattedTimestamp(entry.timestamp))] \(entry.event) \(detailText)"
        }

        if recentLines.isEmpty {
            lines.append("- 共有イベントなし")
        } else {
            lines.append(contentsOf: recentLines)
        }

        return lines.joined(separator: "\n")
    }

    private static func currentFamilySummary(_ family: Family?) -> String {
        guard let family else { return "nil" }
        return "\(family.id.uuidString) \(sanitized(family.name))"
    }

    private static func familySort(lhs: Family, rhs: Family) -> Bool {
        if lhs.lastSelectedAt != rhs.lastSelectedAt {
            return (lhs.lastSelectedAt ?? .distantPast) > (rhs.lastSelectedAt ?? .distantPast)
        }
        return lhs.createdAt > rhs.createdAt
    }

    private static func sanitized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    private static func loadEntries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func saveEntries(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

@MainActor
protocol CloudKitFamilySharingBackend {
    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws
    func fetchRecords(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord]
    func fetchRecord(
        with recordID: CKRecord.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> CKRecord
    func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord]
    func accept(metadata: CKShare.Metadata) async throws -> CKShare
}

@MainActor
private final class DefaultCloudKitFamilySharingBackend: CloudKitFamilySharingBackend {
    private let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let database = database(for: .privateDatabase)

        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            operation.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    func fetchRecords(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        let database = database(for: scope)
        var fetchedRecords: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let queryBatch = try await fetchQueryBatch(
                recordType: recordType,
                in: zoneID,
                database: database,
                cursor: cursor
            )
            fetchedRecords.append(contentsOf: queryBatch.records)
            cursor = queryBatch.cursor
        } while cursor != nil

        return fetchedRecords
    }

    private func fetchQueryBatch(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        database: CKDatabase,
        cursor: CKQueryOperation.Cursor?
    ) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            var fetchedRecords: [CKRecord] = []
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                operation = CKQueryOperation(query: query)
                operation.zoneID = zoneID
            }

            if #available(iOS 15.0, *) {
                operation.recordMatchedBlock = { _, result in
                    if case .success(let record) = result {
                        fetchedRecords.append(record)
                    }
                }
                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let nextCursor):
                        continuation.resume(returning: (fetchedRecords, nextCursor))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            } else {
                operation.recordFetchedBlock = { record in
                    fetchedRecords.append(record)
                }
                operation.queryCompletionBlock = { nextCursor, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (fetchedRecords, nextCursor))
                    }
                }
            }

            database.add(operation)
        }
    }

    func fetchRecord(
        with recordID: CKRecord.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> CKRecord {
        let database = database(for: scope)

        return try await withCheckedThrowingContinuation { continuation in
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

    func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        let database = database(for: scope)

        return try await withCheckedThrowingContinuation { continuation in
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

    func accept(metadata: CKShare.Metadata) async throws -> CKShare {
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

    private func database(for scope: FamilyCloudKitDatabaseScope) -> CKDatabase {
        switch scope {
        case .sharedDatabase:
            return container.sharedCloudDatabase
        case .privateDatabase:
            return container.privateCloudDatabase
        }
    }
}

enum CloudKitSharingError: LocalizedError, Equatable {
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
