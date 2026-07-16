import Foundation
import SwiftData
import CloudKit
import OSLog

struct CloudKitSharePreparationRuntime {
    let isSimulatorApp: Bool
    let isTestFlightBuild: Bool

    var shouldAllowDeferredSharePreparationAutomatically: Bool {
        // TestFlight uses Production CloudKit, so a share link must not be returned
        // until Family/Bag/Item records are verified in CloudKit.
        isSimulatorApp
    }

    static func live(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CloudKitSharePreparationRuntime {
        let isSimulatorApp = environment["SIMULATOR_UDID"] != nil
            && environment["XCTestConfigurationFilePath"] == nil
        let usesSandboxReceipt = bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif

        return CloudKitSharePreparationRuntime(
            isSimulatorApp: isSimulatorApp,
            isTestFlightBuild: !isDebugBuild && usesSandboxReceipt
        )
    }
}


@MainActor
final class CloudKitFamilySharingService {
    enum SharePreparationVerificationPolicy {
        case automatic
        case strict
        case allowPendingUpload
    }

    enum ShareAcceptanceAction: Equatable {
        case accept
        case syncExistingShare
    }

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

    private actor SharedAccessRevocationTracker {
        private var failureCounts: [String: Int] = [:]

        func recordExplicitRevocationFailure(
            for key: String,
            confirmationsRequired: Int
        ) -> Bool {
            let count = failureCounts[key, default: 0] + 1
            failureCounts[key] = count
            return count >= confirmationsRequired
        }

        func clear(for key: String) {
            failureCounts.removeValue(forKey: key)
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
    private static let sharedAccessRevocationTracker = SharedAccessRevocationTracker()
    private let logger = Logger(subsystem: "com.stockpile-manager.app", category: "CloudKitSharing")
    private let modelContext: ModelContext
    private let backend: any CloudKitFamilySharingBackend
    private let sharePreparationVerificationPolicy: SharePreparationVerificationPolicy
    private let sharePreparationRuntime: CloudKitSharePreparationRuntime

    init(
        modelContext: ModelContext,
        backend: (any CloudKitFamilySharingBackend)? = nil,
        sharePreparationVerificationPolicy: SharePreparationVerificationPolicy = .automatic,
        sharePreparationRuntime: CloudKitSharePreparationRuntime = .live()
    ) {
        self.modelContext = modelContext
        self.backend = backend ?? DefaultCloudKitFamilySharingBackend(container: .default())
        self.sharePreparationVerificationPolicy = sharePreparationVerificationPolicy
        self.sharePreparationRuntime = sharePreparationRuntime
    }

    func prepareShare(for family: Family) async throws -> CKShare {
        guard family.cloudKitDatabaseScope != .sharedDatabase else {
            throw CloudKitSharingError.shareOwnerRequired
        }
        try await ensureCloudKitAccountAvailable()
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

                guard shouldRetrySharePreparation(after: error),
                      index < retryIntervalsInNanoseconds.count - 1 else {
                    throw normalizeSharePreparationError(error)
                }

                do {
                    guard let existingShare = try await fetchExistingShareAfterTransientFailure(for: family) else {
                        continue
                    }
                    do {
                        return try await finalizePreparedShare(existingShare, for: family)
                    } catch {
                        lastError = error
                        logShareError(error, phase: "prepareShare.recoveredExistingShare[\(index)]")
                    }
                } catch {
                    lastError = error
                    logShareError(error, phase: "prepareShare.recoveryFetch[\(index)]")
                }
            }
        }

        throw normalizeSharePreparationError(
            lastError ?? CloudKitSharingError.sharePreparationFailed(detail: L10n.string("不明なエラー"))
        )
    }

    func prepareInvitationURL(
        for family: Family,
        preparedShare: CKShare? = nil
    ) async throws -> URL {
        let share = if let preparedShare {
            preparedShare
        } else {
            try await prepareShare(for: family)
        }

        if #available(iOS 26.0, *) {
            do {
                return try await prepareOneTimeInvitationURL(for: family, share: share)
            } catch {
                logShareError(error, phase: "prepareInvitationURL.oneTime")
            }
        }

        let hydratedShare = try await hydrateShareURLIfNeeded(share, for: family)
        if hydratedShare.publicPermission != .none,
           let shareURL = hydratedShare.url {
            updatePreparedShareState(
                for: family,
                shareURL: shareURL,
                pendingSync: family.cloudKitPendingSync,
                hasRemoteBaseline: family.cloudKitHasRemoteBaseline
            )
            return shareURL
        }

        throw CloudKitSharingError.invitationURLUnavailable
    }

    private func prepareShare(
        for family: Family,
        resettingMetadataOnFailure shouldResetMetadataOnFailure: Bool
    ) async throws -> CKShare {
        ensureCloudKitMetadata(for: family)

        if shouldTryExistingShareFastPath(for: family),
           let existingShare = try await fetchExistingShare(for: family, scope: .privateDatabase) {
            return try await finalizePreparedShare(existingShare, for: family)
        }

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
        if shouldReturnPreparedShareImmediately(for: family) {
            updatePreparedShareState(
                for: family,
                shareURL: share.url ?? family.cloudKitShareURL,
                pendingSync: family.cloudKitPendingSync,
                hasRemoteBaseline: family.cloudKitHasRemoteBaseline
            )
            await cacheShareParticipants(from: share, for: family)

            if family.cloudKitPendingSync || !family.cloudKitHasRemoteBaseline {
                scheduleDeferredSharePreparationCompletion(for: family)
            }

            return share
        }

        let preparedShare = try await hydrateShareURLIfNeeded(share, for: family)
        updatePreparedShareState(
            for: family,
            shareURL: preparedShare.url,
            pendingSync: true,
            hasRemoteBaseline: false
        )
        await cacheShareParticipants(from: preparedShare, for: family)

        do {
            try await verifyCloudKitUpload(for: family)
            updatePreparedShareState(
                for: family,
                shareURL: preparedShare.url,
                pendingSync: false,
                hasRemoteBaseline: true
            )
            scheduleRemoteCountsDiagnostics(event: "共有リンク準備完了", family: family)
            return preparedShare
        } catch {
            updatePreparedShareState(
                for: family,
                shareURL: preparedShare.url,
                pendingSync: true,
                hasRemoteBaseline: false
            )
            if shouldAllowDeferredSharePreparation(after: error) {
                logDiagnostics(
                    event: "共有リンクを検証待ちで返却",
                    family: family,
                    extra: [
                        "description": error.localizedDescription,
                        "shareURLAvailable": preparedShare.url == nil ? "false" : "true"
                    ]
                )
                return preparedShare
            }
            throw error
        }
    }

    private func shouldTryExistingShareFastPath(for family: Family) -> Bool {
        resolvedSharePreparationVerificationPolicy == .allowPendingUpload
            || isRemoteBaselineReady(for: family)
    }

    private func shouldReturnPreparedShareImmediately(for family: Family) -> Bool {
        resolvedSharePreparationVerificationPolicy == .allowPendingUpload
            || isRemoteBaselineReady(for: family)
    }

    private func isRemoteBaselineReady(for family: Family) -> Bool {
        family.cloudKitHasRemoteBaseline && !family.cloudKitPendingSync
    }

    private func scheduleDeferredSharePreparationCompletion(for family: Family) {
        Task { @MainActor in
            do {
                try await syncFamilyDataToCloudKit(for: family)
                try await ensureFamilyRecordExists(for: family)
                try await verifyCloudKitUpload(for: family)
                updatePreparedShareState(
                    for: family,
                    shareURL: family.cloudKitShareURL,
                    pendingSync: false,
                    hasRemoteBaseline: true
                )
                scheduleRemoteCountsDiagnostics(event: "共有リンク準備完了(非同期)", family: family)
            } catch {
                logDiagnostics(
                    event: "共有リンクの非同期検証を継続",
                    family: family,
                    extra: [
                        "description": error.localizedDescription,
                        "errorType": String(describing: type(of: error))
                    ]
                )
            }
        }
    }

    private func hydrateShareURLIfNeeded(_ share: CKShare, for family: Family) async throws -> CKShare {
        guard share.url == nil else { return share }

        let retryIntervalsInNanoseconds: [UInt64] = [
            250_000_000,
            1_000_000_000,
            2_000_000_000
        ]

        for interval in retryIntervalsInNanoseconds {
            try await Task.sleep(nanoseconds: interval)
            do {
                if let existingShare = try await fetchExistingShare(for: family, scope: .privateDatabase),
                   existingShare.url != nil {
                    logger.notice("Recovered CKShare URL after delayed fetch")
                    return existingShare
                }
            } catch {
                guard shouldRetrySharePreparation(after: error) else {
                    throw error
                }
                logShareError(error, phase: "hydrateShareURLIfNeeded")
            }
        }

        return share
    }

    @available(iOS 26.0, *)
    private func prepareOneTimeInvitationURL(for family: Family, share: CKShare) async throws -> URL {
        let existingParticipantIDs = Set(share.participants.compactMap(\.participantID))
        let invitation = try Self.makeOneTimeInvitationShare(
            from: share,
            replacingPendingOneTimeParticipants: true
        )
        let invitationShare = invitation.share
        let participant = invitation.participant

        let savedRecord = try await save(record: invitationShare, scope: .privateDatabase)
        let savedShare = (savedRecord as? CKShare) ?? invitationShare
        await cacheShareParticipants(from: savedShare, for: family)

        let savedParticipantID = invitationParticipantID(
            in: savedShare,
            existingParticipantIDs: existingParticipantIDs,
            fallbackParticipantID: participant.participantID
        )
        if let savedParticipantID,
           let invitationURL = oneTimeInvitationURL(from: savedShare, participantID: savedParticipantID) {
            updatePreparedShareState(
                for: family,
                shareURL: savedShare.url,
                pendingSync: family.cloudKitPendingSync,
                hasRemoteBaseline: family.cloudKitHasRemoteBaseline
            )
            logger.notice("Generated one-time CloudKit invitation URL")
            return invitationURL
        }

        let refetchedShare: CKShare?
        do {
            refetchedShare = try await fetchZoneWideShare(for: family)
        } catch {
            await removeUnusedOneTimeParticipant(
                participantID: savedParticipantID ?? participant.participantID,
                from: savedShare,
                family: family
            )
            throw error
        }
        let refetchedParticipantID = refetchedShare.flatMap {
            invitationParticipantID(
                in: $0,
                existingParticipantIDs: existingParticipantIDs,
                fallbackParticipantID: participant.participantID
            )
        }
        if let refetchedShare,
           let refetchedParticipantID,
           let invitationURL = oneTimeInvitationURL(
                from: refetchedShare,
                participantID: refetchedParticipantID
           ) {
            updatePreparedShareState(
                for: family,
                shareURL: refetchedShare.url,
                pendingSync: family.cloudKitPendingSync,
                hasRemoteBaseline: family.cloudKitHasRemoteBaseline
            )
            logger.notice("Recovered one-time CloudKit invitation URL after refetch")
            return invitationURL
        }

        await removeUnusedOneTimeParticipant(
            participantID: refetchedParticipantID ?? savedParticipantID ?? participant.participantID,
            from: refetchedShare ?? savedShare,
            family: family
        )
        throw CloudKitSharingError.invitationURLUnavailable
    }

    @available(iOS 26.0, *)
    static func makeOneTimeInvitationShare(
        from share: CKShare
    ) throws -> (share: CKShare, participant: CKShare.Participant) {
        try makeOneTimeInvitationShare(
            from: share,
            replacingPendingOneTimeParticipants: false
        )
    }

    @available(iOS 26.0, *)
    static func makeOneTimeInvitationShare(
        from share: CKShare,
        replacingPendingOneTimeParticipants: Bool
    ) throws -> (share: CKShare, participant: CKShare.Participant) {
        guard let invitationShare = share.copy() as? CKShare else {
            throw CloudKitSharingError.invalidShareRecord
        }

        if replacingPendingOneTimeParticipants {
            invitationShare.participants
                .filter(Self.isPendingOneTimeURLParticipant)
                .forEach(invitationShare.removeParticipant)
        }

        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readWrite
        invitationShare.addParticipant(participant)
        return (invitationShare, participant)
    }

    @available(iOS 26.0, *)
    static func isPendingOneTimeURLParticipant(
        _ participant: CKShare.Participant
    ) -> Bool {
        guard participant.acceptanceStatus == .pending else { return false }

        let identity = participant.userIdentity
        let hasName = identity.nameComponents.map {
            !PersonNameComponentsFormatter()
                .string(from: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        } ?? false

        return identity.userRecordID == nil
            && identity.lookupInfo == nil
            && identity.contactIdentifiers.isEmpty
            && !hasName
    }

    @available(iOS 26.0, *)
    private func removeUnusedOneTimeParticipant(
        participantID: CKShare.Participant.ID?,
        from share: CKShare,
        family: Family
    ) async {
        guard let participantID,
              let participant = share.participants.first(where: { $0.participantID == participantID }) else {
            return
        }

        share.removeParticipant(participant)
        do {
            let savedRecord = try await save(record: share, scope: .privateDatabase)
            if let savedShare = savedRecord as? CKShare {
                await cacheShareParticipants(from: savedShare, for: family)
            }
        } catch {
            logShareError(error, phase: "prepareInvitationURL.cleanupUnusedParticipant")
        }
    }

    @available(iOS 26.0, *)
    private func invitationParticipantID(
        in share: CKShare,
        existingParticipantIDs: Set<CKShare.Participant.ID>,
        fallbackParticipantID: CKShare.Participant.ID?
    ) -> CKShare.Participant.ID? {
        if let fallbackParticipantID,
           !existingParticipantIDs.contains(fallbackParticipantID) {
            return fallbackParticipantID
        }

        return share.participants
            .compactMap(\.participantID)
            .first(where: { !existingParticipantIDs.contains($0) })
    }

    @available(iOS 26.0, *)
    private func oneTimeInvitationURL(
        from share: CKShare,
        participantID: CKShare.Participant.ID
    ) -> URL? {
        share.oneTimeURL(for: participantID)
    }

    @discardableResult
    func acceptShare(metadata: CKShare.Metadata) async throws -> Family {
        logger.notice("CloudKit share accept started")

        let acceptedShare: CKShare
        switch try Self.acceptanceAction(for: metadata.participantStatus) {
        case .accept:
            do {
                acceptedShare = try await accept(metadata: metadata)
            } catch {
                logShareError(error, phase: "acceptShare.accept")
                throw error
            }
        case .syncExistingShare:
            acceptedShare = metadata.share
        }

        return try await syncAcceptedShare(
            zoneID: acceptedShare.recordID.zoneID,
            fallbackName: acceptedShareFallbackName(from: metadata, acceptedShare: acceptedShare),
            resolvedFamilyID: acceptedShareFamilyID(from: metadata)
        )
    }

    static func acceptanceAction(
        for participantStatus: CKShare.ParticipantAcceptanceStatus
    ) throws -> ShareAcceptanceAction {
        switch participantStatus {
        case .pending:
            return .accept
        case .accepted:
            return .syncExistingShare
        case .removed, .unknown:
            throw CloudKitSharingError.invalidShareMetadata
        @unknown default:
            throw CloudKitSharingError.invalidShareMetadata
        }
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

    func syncFamilyDataToCloudKit(
        for family: Family,
        attachOrphanLocalData: Bool = true
    ) async throws {
        guard family.isCloudKitSharedFamily else { return }
        try await ensureCloudKitAccountAvailable()
        if attachOrphanLocalData {
            try attachOrphanLocalDataIfNeeded(to: family)
        }
        LocalDataRepairService(modelContext: modelContext).repairInvalidAndDuplicateRecordsIfNeeded()

        let scope = databaseScope(for: family)
        if family.cloudKitDatabaseScope == .privateDatabase {
            try await ensureZoneExists(for: family)
        }
        let operationZoneID = try await readableZoneID(for: family, scope: scope)

        let remoteState = try await fetchRemoteZoneState(
            zoneID: operationZoneID,
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
            recordsToSave.append(
                makeFamilyRecord(
                    from: family,
                    zoneID: operationZoneID,
                    existingRecord: remoteState.familyRecord
                )
            )
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
            recordsToSave.append(
                makeBagRecord(
                    from: bag,
                    zoneID: operationZoneID,
                    existingRecord: remoteBagMap[bag.id]
                )
            )
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
            recordsToSave.append(
                makeItemRecord(
                    from: item,
                    zoneID: operationZoneID,
                    existingRecord: remoteItemMap[item.id]
                )
            )
        }

        var uploadedDeletionMarkerIDs = Set<UUID>()
        for marker in localDeletionMarkers where marker.isPendingUpload {
            if let remoteMarker = remoteDeletionMap[markerKey(for: marker)],
               remoteMarker.deletedAt >= marker.deletedAt {
                marker.isPendingUpload = false
                continue
            }

            recordsToSave.append(
                makeDeletionMarkerRecord(from: marker, zoneID: operationZoneID)
            )
            recordIDsToDelete.append(
                recordIDForDeletionMarkerTarget(marker, zoneID: operationZoneID)
            )
            uploadedDeletionMarkerIDs.insert(marker.id)
        }

        if !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty {
            do {
                try await modify(
                    recordsToSave: recordsToSave,
                    recordIDsToDelete: recordIDsToDelete,
                    scope: scope
                )
            } catch {
                if CloudKitConflictCompatibility.isServerRecordChanged(error) {
                    CloudKitSharingDiagnostics.logError(
                        context: "共有データの競合を検出",
                        error: error
                    )
                    NotificationCenter.default.post(
                        name: .didDetectCloudKitConflict,
                        object: family.id
                    )
                    // Refresh against the server's current change tag. The local
                    // timestamp guard keeps a newer local edit available for retry.
                    try? await syncFamilyStateFromCloudKit(for: family)
                }
                throw error
            }
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

    /// Ensures that CloudKit can notify every device participating in a family.
    /// The operation is idempotent and safe to call at launch and after accepting a share.
    func ensureAutomaticSyncSubscriptions(for families: [Family]) async throws {
        guard families.contains(where: \.isCloudKitSharedFamily) else { return }
        try await ensureCloudKitAccountAvailable()
        try await backend.ensureAutomaticSyncSubscriptions(for: families)
    }

    func syncFamilyStateFromCloudKit(for family: Family) async throws {
        guard family.isCloudKitSharedFamily else { return }
        try await ensureCloudKitAccountAvailable()

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
        case .sharedAccessRevoked:
            logDiagnostics(event: "共有アクセス失効を複数回検出", family: family)
            await Self.sharedAccessRevocationTracker.clear(
                for: "\(family.id.uuidString)::\(family.cloudKitZoneName ?? "-")"
            )
            try clearRevokedSharedFamilyState(for: family)
        }
    }

    func fetchRemoteRecordCounts(for family: Family) async throws -> RemoteRecordCounts {
        try await ensureCloudKitAccountAvailable()
        let targetScope = databaseScope(for: family)
        let targetZoneID = try await readableZoneID(for: family, scope: targetScope)
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

    /// Returns the owner and accepted participants for member lists and counts.
    /// Pending invitations are intentionally excluded.
    func fetchShareParticipants(
        for family: Family,
        forceRefresh: Bool = false
    ) async throws -> [ShareParticipantDisplay] {
        guard family.shareState != .localOnly else { return [] }
        try await ensureCloudKitAccountAvailable()
        let cacheKey = shareParticipantsCacheKey(for: family)

        if !forceRefresh,
           let cachedParticipants = await Self.shareParticipantsCache.value(
            for: cacheKey,
            maxAge: Constants.shareParticipantsCacheTTL
           ) {
            return cachedParticipants.filter { $0.status != .pending }
        }

        guard let share = try await fetchZoneWideShare(for: family) else { return [] }
        let participants = shareParticipantDisplays(from: share)
        await Self.shareParticipantsCache.store(participants, for: cacheKey)
        return participants.filter { $0.status != .pending }
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
        try await deleteSharedZoneIfPossible(for: family)
        for marker in try fetchLocalDeletionMarkers(for: family) {
            modelContext.delete(marker)
        }
        modelContext.delete(family)
        try modelContext.save()
        await Self.shareParticipantsCache.removeValue(for: cacheKey)
    }

    private func deleteSharedZoneIfPossible(for family: Family) async throws {
        let zoneID = try await readableZoneID(for: family, scope: .sharedDatabase)
        try await backend.deleteZone(with: zoneID, scope: .sharedDatabase)
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
        let remoteFamilyCreatedAt = (familyRecord["createdAt"] as? Date) ?? remoteFamilyTimestamp
        let shouldAdoptRemoteFamilyMetadata = !currentFamily.cloudKitHasRemoteBaseline
            || currentFamily.syncTimestamp <= remoteFamilyTimestamp
        if shouldAdoptRemoteFamilyMetadata {
            currentFamily.name = familyName?.isEmpty == false ? familyName! : currentFamily.name
            currentFamily.createdAt = remoteFamilyCreatedAt
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

        let validBagRecords = remoteState.bagRecords.compactMap { bagRecord -> (UUID, String, Date, Date)? in
            guard let bagID = uuidValue(from: bagRecord["id"]),
                  let bagName = normalizedNonEmptyString(bagRecord["name"] as? String) else { return nil }
            let remoteCreatedAt = (bagRecord["createdAt"] as? Date) ?? remoteRecordTimestamp(bagRecord)
            return (bagID, bagName, remoteCreatedAt, remoteRecordTimestamp(bagRecord))
        }

        for (bagID, bagName, remoteCreatedAt, remoteUpdatedAt) in validBagRecords {
            let existingBag = bagMap[bagID]
            let bag = existingBag ?? {
                let newBag = Bag(name: bagName)
                newBag.id = bagID
                modelContext.insert(newBag)
                return newBag
            }()

            if shouldAdoptRemoteRecord(
                existingTimestamp: bag.syncTimestamp,
                existingCreatedAt: bag.createdAt,
                existingUpdatedAt: bag.updatedAt,
                remoteUpdatedAt: remoteUpdatedAt,
                isExistingRecord: existingBag != nil
            ) {
                bag.name = bagName
                bag.createdAt = remoteCreatedAt
                bag.updatedAt = remoteUpdatedAt
            }
            bag.family = currentFamily
            bagMap[bagID] = bag
        }

        let validItemRecords = remoteState.itemRecords.compactMap { itemRecord -> (CKRecord, UUID, String, Date, Date)? in
            guard let itemID = uuidValue(from: itemRecord["id"]),
                  let itemName = normalizedNonEmptyString(itemRecord["name"] as? String) else { return nil }
            let remoteCreatedAt = (itemRecord["createdAt"] as? Date) ?? remoteRecordTimestamp(itemRecord)
            return (itemRecord, itemID, itemName, remoteCreatedAt, remoteRecordTimestamp(itemRecord))
        }
        for (itemRecord, itemID, itemName, remoteCreatedAt, remoteUpdatedAt) in validItemRecords {

            let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.id == itemID })
            let existingItem = try modelContext.fetch(descriptor).first
            let item = existingItem ?? {
                let newItem = Item(name: itemName)
                newItem.id = itemID
                modelContext.insert(newItem)
                return newItem
            }()

            if shouldAdoptRemoteRecord(
                existingTimestamp: item.syncTimestamp,
                existingCreatedAt: item.createdAt,
                existingUpdatedAt: item.updatedAt,
                remoteUpdatedAt: remoteUpdatedAt,
                isExistingRecord: existingItem != nil
            ) {
                item.name = itemName
                item.janCode = normalizedOptionalString(itemRecord["janCode"] as? String)
                item.quantity = intValue(from: itemRecord["quantity"]) ?? item.quantity
                item.expiryDate = itemRecord["expiryDate"] as? Date
                item.locationNote = normalizedOptionalString(itemRecord["locationNote"] as? String)
                item.notified30 = (itemRecord["notified30"] as? NSNumber)?.boolValue ?? item.notified30
                item.notified7 = (itemRecord["notified7"] as? NSNumber)?.boolValue ?? item.notified7
                item.notified1 = (itemRecord["notified1"] as? NSNumber)?.boolValue ?? item.notified1
                item.createdAt = remoteCreatedAt
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
                let readableZoneID = try await readableSharedZoneID(forAcceptedZoneID: zoneID)
                return try await syncZoneToLocal(
                    zoneID: readableZoneID,
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

    private func readableSharedZoneID(forAcceptedZoneID acceptedZoneID: CKRecordZone.ID) async throws -> CKRecordZone.ID {
        let sharedZoneIDs = try await backend.fetchAllRecordZoneIDs(scope: .sharedDatabase)
        let matchingZoneIDs = sharedZoneIDs.filter { $0.zoneName == acceptedZoneID.zoneName }
        guard matchingZoneIDs.count <= 1 else {
            throw CloudKitSharingError.ambiguousSharedZone(zoneName: acceptedZoneID.zoneName)
        }

        if let matchingZoneID = matchingZoneIDs.first {
            if matchingZoneID != acceptedZoneID {
                CloudKitSharingDiagnostics.log(
                    event: "共有受理ゾーンIDをsharedCloudDatabaseから解決",
                    details: [
                        "acceptedZoneName": acceptedZoneID.zoneName,
                        "acceptedOwnerName": acceptedZoneID.ownerName,
                        "resolvedZoneName": matchingZoneID.zoneName,
                        "resolvedOwnerName": matchingZoneID.ownerName
                    ]
                )
            }
            return matchingZoneID
        }

        CloudKitSharingDiagnostics.log(
            event: "共有受理ゾーンIDを受理結果で継続",
            details: [
                "zoneName": acceptedZoneID.zoneName,
                "ownerName": acceptedZoneID.ownerName,
                "sharedZoneCount": String(sharedZoneIDs.count)
            ]
        )
        return acceptedZoneID
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
        let deletionMarkers = try fetchLocalDeletionMarkers(for: family)
        let cacheKey = shareParticipantsCacheKey(for: family)

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
            event: "共有アクセス解除・ローカルデータ保持",
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

    private func updatePreparedShareState(
        for family: Family,
        shareURL: URL?,
        pendingSync: Bool,
        hasRemoteBaseline: Bool
    ) {
        family.cloudKitShareURL = shareURL
        family.cloudKitPendingSync = pendingSync
        family.cloudKitHasRemoteBaseline = hasRemoteBaseline
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
        } catch where CloudKitMissingRecordCompatibility.isRecordNotFound(error) {
            return nil
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
        let normalizedError = normalizeCloudKitAccessError(error)
        if normalizedError is CloudKitSharingError {
            return normalizedError
        }

        if shouldRetrySharePreparation(after: error) {
            return CloudKitSharingError.sharePreparationFailed(detail: makeShareErrorDetail(from: error))
        }
        return normalizedError
    }

    private func shouldAllowDeferredSharePreparation(after error: Error) -> Bool {
        guard resolvedSharePreparationVerificationPolicy == .allowPendingUpload else {
            return false
        }

        if let sharingError = error as? CloudKitSharingError,
           case .shareDataNotUploaded = sharingError {
            return true
        }

        return shouldRetrySharePreparation(after: error)
            || shouldRetryCloudKitUploadVerification(after: error)
    }

    private var resolvedSharePreparationVerificationPolicy: SharePreparationVerificationPolicy {
        switch sharePreparationVerificationPolicy {
        case .automatic:
            return sharePreparationRuntime.shouldAllowDeferredSharePreparationAutomatically
                ? .allowPendingUpload
                : .strict
        case .strict, .allowPendingUpload:
            return sharePreparationVerificationPolicy
        }
    }

    private func fetchExistingShareAfterTransientFailure(for family: Family) async throws -> CKShare? {
        let fallbackIntervalsInNanoseconds: [UInt64] = [
            250_000_000,
            1_000_000_000
        ]

        for interval in fallbackIntervalsInNanoseconds {
            try await Task.sleep(nanoseconds: interval)
            do {
                if let existingShare = try await fetchExistingShare(for: family, scope: .privateDatabase) {
                    logger.notice("Recovered existing CKShare after transient failure")
                    return existingShare
                }
            } catch {
                guard shouldRetrySharePreparation(after: error) else {
                    throw error
                }
                logShareError(error, phase: "fetchExistingShareAfterTransientFailure")
            }
        }

        return nil
    }

    private func ensureCloudKitAccountAvailable() async throws {
        do {
            switch try await backend.accountStatus() {
            case .available:
                return
            case .noAccount:
                throw CloudKitSharingError.authenticatedAccountRequired(
                    isSimulator: sharePreparationRuntime.isSimulatorApp
                )
            case .restricted:
                throw CloudKitSharingError.iCloudAccountRestricted
            case .couldNotDetermine:
                throw CloudKitSharingError.iCloudAccountTemporarilyUnavailable
            case .temporarilyUnavailable:
                throw CloudKitSharingError.iCloudAccountTemporarilyUnavailable
            @unknown default:
                throw CloudKitSharingError.iCloudAccountTemporarilyUnavailable
            }
        } catch {
            throw normalizeCloudKitAccessError(error)
        }
    }

    private func normalizeCloudKitAccessError(_ error: Error) -> Error {
        if let sharingError = error as? CloudKitSharingError {
            return sharingError
        }

        if CloudKitQuotaCompatibility.isQuotaExceeded(error) {
            return CloudKitSharingError.iCloudStorageQuotaExceeded
        }

        if let ckError = error as? CKError,
           ckError.code == .notAuthenticated {
            return CloudKitSharingError.authenticatedAccountRequired(
                isSimulator: sharePreparationRuntime.isSimulatorApp
            )
        }

        let normalizedDescription = error.localizedDescription.lowercased()
        if normalizedDescription.contains("requires an authenticated account")
            || normalizedDescription.contains("not authenticated")
            || normalizedDescription.contains("sign in to icloud") {
            return CloudKitSharingError.authenticatedAccountRequired(
                isSimulator: sharePreparationRuntime.isSimulatorApp
            )
        }

        return error
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
        let scope = databaseScope(for: family)
        let zoneID = try await readableZoneID(for: family, scope: scope)
        let remoteFamilyRecord: CKRecord?
        do {
            remoteFamilyRecord = try await fetchRecord(
                with: familyRecordID(for: family, zoneID: zoneID),
                scope: scope
            )
        } catch where CloudKitMissingRecordCompatibility.isRecordNotFound(error) {
            remoteFamilyRecord = nil
        }
        guard shouldUploadRecord(
            localTimestamp: family.syncTimestamp,
            remoteRecord: remoteFamilyRecord
        ) else {
            return
        }

        let familyRecord = makeFamilyRecord(from: family, zoneID: zoneID)
        try await modify(recordsToSave: [familyRecord], recordIDsToDelete: [], scope: scope)
    }

    func verifyCloudKitUpload(for family: Family) async throws {
        guard family.isCloudKitSharedFamily else { return }

        let scope = databaseScope(for: family)
        let verificationZoneID = try await readableZoneID(for: family, scope: scope)
        let recordIDs = try ownerShareVerificationRecordIDs(
            for: family,
            zoneID: verificationZoneID
        )
        let retryIntervalsInNanoseconds: [UInt64] = [
            0,
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000
        ]
        var lastError: Error?

        for interval in retryIntervalsInNanoseconds {
            if interval > 0 {
                try await Task.sleep(nanoseconds: interval)
            }

            do {
                _ = try await fetchRecords(with: recordIDs, scope: scope)

                logDiagnostics(
                    event: "共有ゾーン保存検証成功",
                    family: family,
                    extra: [
                        "scope": scope.rawValue,
                        "verifiedRecordNames": recordIDs.map(\.recordName).joined(separator: ",")
                    ]
                )
                return
            } catch {
                lastError = error
                guard shouldRetryCloudKitUploadVerification(after: error) else {
                    throw error
                }
            }
        }

        logDiagnostics(
            event: "共有ゾーン保存検証失敗",
            family: family,
            extra: [
                "scope": scope.rawValue,
                "verifiedRecordNames": recordIDs.map(\.recordName).joined(separator: ","),
                "description": lastError?.localizedDescription ?? L10n.string("不明なエラー"),
                "errorType": lastError.map { String(describing: type(of: $0)) } ?? "Unknown"
            ]
        )
        throw CloudKitSharingError.shareDataNotUploaded(
            detail: makeShareErrorDetail(from: lastError ?? CloudKitSharingError.recordNotFound)
        )
    }

    private func ownerShareVerificationRecordIDs(
        for family: Family,
        zoneID: CKRecordZone.ID
    ) throws -> [CKRecord.ID] {
        var recordIDs: [CKRecord.ID] = [familyRecordID(for: family, zoneID: zoneID)]

        if let bag = try fetchLocalBags(for: family).first {
            recordIDs.append(bagRecordID(for: bag, zoneID: zoneID))
        }
        if let item = try fetchLocalItems(for: family).first {
            recordIDs.append(itemRecordID(for: item, zoneID: zoneID))
        }

        return recordIDs
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
        // sharedDatabase の family で ownerName が nil の場合、
        // CKCurrentUserDefaultName（参加者自身のID）を使うと存在しない zone を参照してしまう。
        // そのため sharedDatabase の場合は ownerName が確定している場合のみ組み立てる。
        // privateDatabase の場合は CKCurrentUserDefaultName が正しいオーナーなので問題ない。
        let resolvedOwnerName: String
        if family.cloudKitDatabaseScope == .sharedDatabase,
           let savedOwnerName = family.cloudKitZoneOwnerName {
            resolvedOwnerName = savedOwnerName
        } else if family.cloudKitDatabaseScope == .sharedDatabase {
            // ownerName が未確定の場合も、readableZoneID が shared database の
            // 実ゾーン一覧から zoneName を使って解決できるよう仮IDを組み立てる。
            logger.error(
                "zoneID(for:) called for sharedDatabase family with nil ownerName; using CKCurrentUserDefaultName as fallback which may be incorrect familyID=\(family.id.uuidString, privacy: .public)"
            )
            resolvedOwnerName = CKCurrentUserDefaultName
        } else {
            // privateDatabase: 自分がオーナーなので CKCurrentUserDefaultName で正しい
            resolvedOwnerName = family.cloudKitZoneOwnerName ?? CKCurrentUserDefaultName
        }
        return CKRecordZone.ID(
            zoneName: family.cloudKitZoneName ?? "family-\(family.id.uuidString)",
            ownerName: resolvedOwnerName
        )
    }

    private func databaseScope(for family: Family) -> FamilyCloudKitDatabaseScope {
        family.cloudKitDatabaseScope ?? .privateDatabase
    }

    private func readableZoneID(
        for family: Family,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> CKRecordZone.ID {
        let savedZoneID = zoneID(for: family)
        guard scope == .sharedDatabase else {
            return savedZoneID
        }

        let sharedZoneIDs = try await backend.fetchAllRecordZoneIDs(scope: .sharedDatabase)
        let matchingZoneIDs = sharedZoneIDs.filter { $0.zoneName == savedZoneID.zoneName }
        guard matchingZoneIDs.count <= 1 else {
            throw CloudKitSharingError.ambiguousSharedZone(zoneName: savedZoneID.zoneName)
        }

        if let matchingZoneID = matchingZoneIDs.first {
            if matchingZoneID != savedZoneID {
                logDiagnostics(
                    event: "共有ゾーンIDをsharedCloudDatabaseから解決",
                    family: family,
                    extra: [
                        "savedZoneName": savedZoneID.zoneName,
                        "savedOwnerName": savedZoneID.ownerName,
                        "resolvedZoneName": matchingZoneID.zoneName,
                        "resolvedOwnerName": matchingZoneID.ownerName
                    ]
                )
            }
            family.cloudKitZoneName = matchingZoneID.zoneName
            family.cloudKitZoneOwnerName = matchingZoneID.ownerName
            try? modelContext.save()
            return matchingZoneID
        }

        logDiagnostics(
            event: "共有ゾーンIDを保存値で継続",
            family: family,
            extra: [
                "zoneName": savedZoneID.zoneName,
                "ownerName": savedZoneID.ownerName,
                "sharedZoneCount": String(sharedZoneIDs.count)
            ]
        )
        return savedZoneID
    }

    private func makeFamilyRecord(
        from family: Family,
        zoneID: CKRecordZone.ID,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let record = mutableRecord(
            existingRecord,
            recordType: Constants.familyRecordType,
            recordID: familyRecordID(for: family, zoneID: zoneID)
        )
        record["id"] = family.id.uuidString as CKRecordValue
        record["name"] = family.name as CKRecordValue
        record["createdAt"] = family.createdAt as CKRecordValue
        record["updatedAt"] = family.syncTimestamp as CKRecordValue
        return record
    }

    private func makeBagRecord(
        from bag: Bag,
        zoneID: CKRecordZone.ID,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let record = mutableRecord(
            existingRecord,
            recordType: Constants.bagRecordType,
            recordID: bagRecordID(for: bag, zoneID: zoneID)
        )
        record["id"] = bag.id.uuidString as CKRecordValue
        record["name"] = bag.name as CKRecordValue
        record["createdAt"] = bag.createdAt as CKRecordValue
        record["updatedAt"] = bag.syncTimestamp as CKRecordValue
        if let familyID = bag.family?.id.uuidString {
            record["familyID"] = familyID as CKRecordValue
        } else {
            record["familyID"] = nil
        }
        return record
    }

    private func makeItemRecord(
        from item: Item,
        zoneID: CKRecordZone.ID,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let record = mutableRecord(
            existingRecord,
            recordType: Constants.itemRecordType,
            recordID: itemRecordID(for: item, zoneID: zoneID)
        )
        record["id"] = item.id.uuidString as CKRecordValue
        record["name"] = item.name as CKRecordValue
        if let janCode = normalizedOptionalString(item.janCode) {
            record["janCode"] = janCode as CKRecordValue
        } else {
            record["janCode"] = nil
        }
        record["quantity"] = item.quantity as CKRecordValue
        if let expiryDate = item.expiryDate {
            record["expiryDate"] = expiryDate as CKRecordValue
        } else {
            record["expiryDate"] = nil
        }
        if let locationNote = item.locationNote {
            record["locationNote"] = locationNote as CKRecordValue
        } else {
            record["locationNote"] = nil
        }
        record["notified30"] = item.notified30 as CKRecordValue
        record["notified7"] = item.notified7 as CKRecordValue
        record["notified1"] = item.notified1 as CKRecordValue
        record["createdAt"] = item.createdAt as CKRecordValue
        record["updatedAt"] = item.syncTimestamp as CKRecordValue
        if let bagID = item.bag?.id.uuidString {
            record["bagID"] = bagID as CKRecordValue
        } else {
            record["bagID"] = nil
        }
        if let familyID = item.family?.id.uuidString {
            record["familyID"] = familyID as CKRecordValue
        } else {
            record["familyID"] = nil
        }
        return record
    }

    private func mutableRecord(
        _ existingRecord: CKRecord?,
        recordType: String,
        recordID: CKRecord.ID
    ) -> CKRecord {
        if let existingRecord,
           let copy = existingRecord.copy() as? CKRecord {
            return copy
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    private func makeDeletionMarkerRecord(
        from marker: CloudKitDeletionMarker,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
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
        zoneID: CKRecordZone.ID
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
            zoneID: zoneID
        )
    }

    private func familyRecordID(
        for family: Family,
        zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: "family-\(family.id.uuidString)", zoneID: zoneID)
    }

    private func bagRecordID(
        for bag: Bag,
        zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: "bag-\(bag.id.uuidString)", zoneID: zoneID)
    }

    private func itemRecordID(
        for item: Item,
        zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: "item-\(item.id.uuidString)", zoneID: zoneID)
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

    private func shouldAdoptRemoteRecord(
        existingTimestamp: Date,
        existingCreatedAt: Date,
        existingUpdatedAt: Date,
        remoteUpdatedAt: Date,
        isExistingRecord: Bool
    ) -> Bool {
        guard isExistingRecord else { return true }
        if existingTimestamp <= remoteUpdatedAt {
            return true
        }

        // Shared placeholder records created during the first import can end up with
        // local "now" timestamps before the remote payload is applied. Allow the
        // remote snapshot to heal that state on the next sync.
        return existingCreatedAt == existingUpdatedAt && existingCreatedAt > remoteUpdatedAt
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
        async let familyRecords = fetchRecordsAllowingMissingRecordType(
            Constants.familyRecordType,
            in: zoneID,
            scope: scope
        )
        async let bagRecords = fetchRecordsAllowingMissingRecordType(
            Constants.bagRecordType,
            in: zoneID,
            scope: scope
        )
        async let itemRecords = fetchRecordsAllowingMissingRecordType(
            Constants.itemRecordType,
            in: zoneID,
            scope: scope
        )
        async let deletionMarkerRecords = fetchRecordsAllowingMissingRecordType(
            Constants.deletionMarkerRecordType,
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

    private func fetchRecordsAllowingMissingRecordType(
        _ recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        do {
            return try await fetchRecords(
                forRecordType: recordType,
                in: zoneID,
                scope: scope
            )
        } catch {
            guard CloudKitRecordTypeCompatibility.shouldTreatMissingRecordTypeAsEmptyResult(
                recordType: recordType,
                after: error
            ) else {
                throw error
            }

            logger.notice(
                "CloudKit record type unavailable; continuing without records type=\(recordType, privacy: .public) zone=\(zoneID.zoneName, privacy: .public) scope=\(scope.rawValue, privacy: .public)"
            )
            return []
        }
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

    private func fetchRecords(with recordIDs: [CKRecord.ID], scope: FamilyCloudKitDatabaseScope) async throws -> [CKRecord] {
        try await backend.fetchRecords(with: recordIDs, scope: scope)
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

    private func shouldRetryCloudKitUploadVerification(after error: Error) -> Bool {
        if let sharingError = error as? CloudKitSharingError,
           sharingError == .recordNotFound {
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
                return partialErrors.contains { shouldRetryCloudKitUploadVerification(after: $0) }
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
        let revocationKey = "\(family.id.uuidString)::\(family.cloudKitZoneName ?? "-")"
        do {
            let scope = databaseScope(for: family)
            let syncedFamily = try await syncZoneToLocal(
                zoneID: try await readableZoneID(for: family, scope: scope),
                scope: scope
            )
            await Self.sharedAccessRevocationTracker.clear(for: revocationKey)
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
                    let isConfirmed = await Self.sharedAccessRevocationTracker
                        .recordExplicitRevocationFailure(
                            for: revocationKey,
                            confirmationsRequired: 3
                        )
                    return isConfirmed ? .sharedAccessRevoked : .remoteNotReady
                }
                return .remoteNotReady
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

    private func scheduleRemoteCountsDiagnostics(event: String, family: Family) {
        Task { @MainActor in
            await logRemoteCountsForDiagnostics(event: event, family: family)
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
        entries.append(Entry(timestamp: Date(), event: event, details: sanitized(details)))
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

    private static func sanitized(_ details: [String: String]) -> [String: String] {
        #if DEBUG
        details
        #else
        let exactAllowedKeys: Set<String> = [
            "attempt", "ckCode", "databaseScope", "errorType", "operation",
            "scope", "shareState", "status"
        ]
        return details.filter { key, _ in
            exactAllowedKeys.contains(key)
                || key.hasSuffix("Count")
                || key.hasSuffix("Duration")
        }
        #endif
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
    func accountStatus() async throws -> CKAccountStatus
    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws
    func fetchAllRecordZoneIDs(scope: FamilyCloudKitDatabaseScope) async throws -> [CKRecordZone.ID]
    func fetchRecords(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord]
    func fetchRecord(
        with recordID: CKRecord.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> CKRecord
    func fetchRecords(
        with recordIDs: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord]
    func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord]
    func deleteZone(
        with zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws
    func accept(metadata: CKShare.Metadata) async throws -> CKShare

    /// Registers the subscriptions needed for automatic family synchronization.
    /// Test backends may use the default no-op implementation.
    func ensureAutomaticSyncSubscriptions(for families: [Family]) async throws
}

extension CloudKitFamilySharingBackend {
    func ensureAutomaticSyncSubscriptions(for families: [Family]) async throws {}
}

enum CloudKitShareAcceptanceResult {
    static func resolve(
        operationResult: Result<Void, Error>,
        acceptedShare: CKShare?,
        perShareError: Error?
    ) throws -> CKShare {
        if let perShareError {
            throw perShareError
        }

        try operationResult.get()
        guard let acceptedShare else {
            throw CloudKitSharingError.invalidShareMetadata
        }
        return acceptedShare
    }
}

@MainActor
private final class DefaultCloudKitFamilySharingBackend: CloudKitFamilySharingBackend {
    private let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    func ensureAutomaticSyncSubscriptions(for families: [Family]) async throws {
        var subscriptions: [CKSubscription] = []
        var hasSharedFamily = false

        for family in families where family.isCloudKitSharedFamily {
            switch family.cloudKitDatabaseScope {
            case .privateDatabase:
                guard let zoneName = family.cloudKitZoneName else { continue }
                let ownerName = family.cloudKitZoneOwnerName ?? CKCurrentUserDefaultName
                let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
                let subscriptionID = "family-zone-\(family.id.uuidString)"
                let subscription = CKRecordZoneSubscription(
                    zoneID: zoneID,
                    subscriptionID: subscriptionID
                )
                subscription.notificationInfo = Self.silentNotificationInfo()
                subscriptions.append(subscription)
            case .sharedDatabase:
                hasSharedFamily = true
            case .none:
                continue
            }
        }

        if hasSharedFamily {
            let subscription = CKDatabaseSubscription(subscriptionID: "shared-family-data")
            subscription.notificationInfo = Self.silentNotificationInfo()
            subscriptions.append(subscription)
        }

        guard !subscriptions.isEmpty else { return }

        let privateSubscriptions = subscriptions.filter { $0 is CKRecordZoneSubscription }
        let sharedSubscriptions = subscriptions.filter { $0 is CKDatabaseSubscription }

        if !privateSubscriptions.isEmpty {
            try await saveSubscriptions(
                privateSubscriptions,
                to: container.privateCloudDatabase
            )
        }
        if !sharedSubscriptions.isEmpty {
            try await saveSubscriptions(
                sharedSubscriptions,
                to: container.sharedCloudDatabase
            )
        }
    }

    private static func silentNotificationInfo() -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        return info
    }

    private func saveSubscriptions(
        _ subscriptions: [CKSubscription],
        to database: CKDatabase
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifySubscriptionsOperation(
                subscriptionsToSave: subscriptions,
                subscriptionIDsToDelete: nil
            )
            operation.modifySubscriptionsResultBlock = { result in
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

    func fetchAllRecordZoneIDs(scope: FamilyCloudKitDatabaseScope) async throws -> [CKRecordZone.ID] {
        let database = database(for: scope)
        return try await withCheckedThrowingContinuation { continuation in
            database.fetchAllRecordZones { zones, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: zones?.map(\.zoneID) ?? [])
                }
            }
        }
    }

    func fetchRecords(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        do {
            return try await fetchRecordsByQuery(
                recordType: recordType,
                in: zoneID,
                scope: scope
            )
        } catch {
            guard CloudKitRecordQueryCompatibility.shouldFallbackToZoneChanges(after: error) else {
                throw error
            }

            return try await fetchRecordsByZoneChanges(
                recordType: recordType,
                in: zoneID,
                scope: scope
            )
        }
    }

    private func fetchRecordsByQuery(
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

    private func fetchRecordsByZoneChanges(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        let database = database(for: scope)
        let zoneConfiguration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: nil,
            resultsLimit: nil,
            desiredKeys: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            var fetchedRecords: [CKRecord] = []
            var recordErrors: [Error] = []
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: zoneConfiguration]
            )
            operation.fetchAllChanges = true

            if #available(iOS 15.0, *) {
                operation.recordWasChangedBlock = { _, result in
                    switch result {
                    case .success(let record) where record.recordType == recordType:
                        fetchedRecords.append(record)
                    case .success:
                        break
                    case .failure(let error):
                        recordErrors.append(error)
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        if let error = recordErrors.first {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: fetchedRecords)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            } else {
                operation.recordChangedBlock = { record in
                    if record.recordType == recordType {
                        fetchedRecords.append(record)
                    }
                }
                operation.fetchRecordZoneChangesCompletionBlock = { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: fetchedRecords)
                    }
                }
            }

            database.add(operation)
        }
    }

    private func fetchQueryBatch(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        database: CKDatabase,
        cursor: CKQueryOperation.Cursor?
    ) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            var fetchedRecords: [CKRecord] = []
            var recordErrors: [Error] = []
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
                    switch result {
                    case .success(let record):
                        fetchedRecords.append(record)
                    case .failure(let error):
                        recordErrors.append(error)
                    }
                }
                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let nextCursor):
                        if let error = recordErrors.first {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: (fetchedRecords, nextCursor))
                        }
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
        guard let record = try await fetchRecords(with: [recordID], scope: scope).first else {
            throw CloudKitSharingError.recordNotFound
        }
        return record
    }

    func fetchRecords(
        with recordIDs: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        let database = database(for: scope)

        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            var fetchedRecords: [CKRecord] = []
            var fetchErrors: [Error] = []
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record):
                    fetchedRecords.append(record)
                case .failure(let error):
                    fetchErrors.append(error)
                }
            }
            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success:
                    if !fetchErrors.isEmpty,
                       CloudKitMissingRecordCompatibility.areAllRecordsNotFound(fetchErrors) {
                        continuation.resume(throwing: CloudKitSharingError.recordNotFound)
                    } else if let error = fetchErrors.first(
                        where: { !CloudKitMissingRecordCompatibility.isRecordNotFound($0) }
                    ) {
                        continuation.resume(throwing: error)
                    } else if fetchedRecords.count == recordIDs.count {
                        continuation.resume(returning: fetchedRecords)
                    } else {
                        continuation.resume(throwing: CloudKitSharingError.recordNotFound)
                    }
                case .failure(let error):
                    if CloudKitMissingRecordCompatibility.isRecordNotFound(error) {
                        continuation.resume(throwing: CloudKitSharingError.recordNotFound)
                    } else {
                        continuation.resume(throwing: error)
                    }
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
            var saveErrors: [Error] = []
            var deletedRecordIDs: [CKRecord.ID] = []
            var deleteErrors: [Error] = []

            operation.perRecordSaveBlock = { _, result in
                switch result {
                case .success(let record):
                    savedRecords.append(record)
                case .failure(let error):
                    saveErrors.append(error)
                }
            }
            operation.perRecordDeleteBlock = { recordID, result in
                switch result {
                case .success:
                    deletedRecordIDs.append(recordID)
                case .failure(let error):
                    if CloudKitRecordDeletionCompatibility.isAlreadyDeleted(error) {
                        deletedRecordIDs.append(recordID)
                    } else {
                        deleteErrors.append(error)
                    }
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    if let error = saveErrors.first {
                        continuation.resume(throwing: error)
                    } else if let error = deleteErrors.first {
                        continuation.resume(throwing: error)
                    } else if savedRecords.count == recordsToSave.count,
                              deletedRecordIDs.count == recordIDsToDelete.count {
                        continuation.resume(returning: savedRecords)
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

    func deleteZone(
        with zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws {
        let database = database(for: scope)

        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordZonesOperation(
                recordZonesToSave: nil,
                recordZoneIDsToDelete: [zoneID]
            )
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

    func accept(metadata: CKShare.Metadata) async throws -> CKShare {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            var acceptedShare: CKShare?
            var perShareError: Error?

            if #available(iOS 15.0, *) {
                operation.perShareResultBlock = { _, result in
                    switch result {
                    case .success(let share):
                        acceptedShare = share
                    case .failure(let error):
                        perShareError = error
                    }
                }
            }
            operation.acceptSharesResultBlock = { result in
                do {
                    continuation.resume(
                        returning: try CloudKitShareAcceptanceResult.resolve(
                            operationResult: result,
                            acceptedShare: acceptedShare,
                            perShareError: perShareError
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            CKContainer(identifier: metadata.containerIdentifier).add(operation)
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
    case authenticatedAccountRequired(isSimulator: Bool)
    case iCloudStorageQuotaExceeded
    case iCloudAccountTemporarilyUnavailable
    case iCloudAccountRestricted
    case invitationURLUnavailable
    case invalidShareRecord
    case invalidShareMetadata
    case shareOwnerRequired
    case ambiguousSharedZone(zoneName: String)
    case familyRecordNotFound
    case recordNotFound
    case shareDataNotUploaded(detail: String)
    case sharePreparationFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .authenticatedAccountRequired(let isSimulator):
            return isSimulator
                ? L10n.string("iCloud にサインインしてから、もう一度お試しください。シミュレーターでは設定アプリで Apple Account にログインする必要があります。")
                : L10n.string("iCloud にサインインしてから、もう一度お試しください。")
        case .iCloudStorageQuotaExceeded:
            return L10n.string("iCloudストレージの空き容量が不足しているため、共有データを保存できません。設定アプリの「Apple Account」→「iCloud」→「ストレージ」で空き容量を確保してから、もう一度お試しください。端末内のデータは削除されていません。")
        case .iCloudAccountTemporarilyUnavailable:
            return L10n.string("iCloud アカウントの状態を確認できませんでした。しばらくしてからもう一度お試しください。")
        case .iCloudAccountRestricted:
            return L10n.string("このデバイスでは iCloud 共有を利用できません。")
        case .invitationURLUnavailable:
            return L10n.string("招待用の共有リンクを作成できませんでした。")
        case .invalidShareRecord:
            return L10n.string("CloudKit共有レコードの作成に失敗しました。")
        case .invalidShareMetadata:
            return L10n.string("CloudKit共有メタデータの読み取りに失敗しました。")
        case .shareOwnerRequired:
            return L10n.string("共有リンクは家族データのオーナーだけが作成できます。")
        case .ambiguousSharedZone(let zoneName):
            return L10n.format("同じ名前の共有データが複数見つかりました。iCloud共有を開き直してください。(%@)", zoneName)
        case .familyRecordNotFound:
            return L10n.string("共有された家族データが見つかりません。")
        case .recordNotFound:
            return L10n.string("CloudKit上のレコードが見つかりません。")
        case .shareDataNotUploaded(let detail):
            return L10n.format("CloudKit上に共有データを保存できませんでした。%@", detail)
        case .sharePreparationFailed(let detail):
            return L10n.format("共有リンクの再準備に失敗しました。%@", detail)
        }
    }
}

enum CloudKitQuotaCompatibility {
    static func isQuotaExceeded(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }

        if ckError.code == .quotaExceeded {
            return true
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.partialErrorsByItemID?.values {
            return partialErrors.contains(where: isQuotaExceeded)
        }

        return false
    }
}

enum CloudKitRecordQueryCompatibility {
    static func shouldFallbackToZoneChanges(after error: Error) -> Bool {
        if let ckError = error as? CKError,
           ckError.code == .partialFailure,
           let partialErrors = ckError.partialErrorsByItemID?.values {
            return partialErrors.contains { shouldFallbackToZoneChanges(after: $0) }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("field 'recordname' is not marked queryable")
            || description.contains("field \"recordname\" is not marked queryable")
    }
}

enum CloudKitConflictCompatibility {
    static func isServerRecordChanged(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            if ckError.code == .serverRecordChanged {
                return true
            }
            if ckError.code == .partialFailure,
               let partialErrors = ckError.partialErrorsByItemID?.values {
                return partialErrors.contains(where: isServerRecordChanged)
            }
        }
        return false
    }
}

enum CloudKitRecordDeletionCompatibility {
    static func isAlreadyDeleted(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }

        if ckError.code == .unknownItem {
            return true
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.partialErrorsByItemID?.values,
           !partialErrors.isEmpty {
            return partialErrors.allSatisfy(isAlreadyDeleted)
        }

        return false
    }
}

enum CloudKitMissingRecordCompatibility {
    /// CKFetchRecordsOperation はレコード未存在を per-record の CKError(.unknownItem) として返す。
    /// zoneNotFound 等は「未存在」に含めない（ゾーン再作成など別の回復手順が必要なため）。
    static func isRecordNotFound(_ error: Error) -> Bool {
        if let sharingError = error as? CloudKitSharingError,
           sharingError == .recordNotFound {
            return true
        }

        guard let ckError = error as? CKError else {
            return false
        }

        if ckError.code == .unknownItem {
            return true
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.partialErrorsByItemID?.values,
           !partialErrors.isEmpty {
            return partialErrors.allSatisfy(isRecordNotFound)
        }

        return false
    }

    static func areAllRecordsNotFound(_ errors: [Error]) -> Bool {
        !errors.isEmpty && errors.allSatisfy(isRecordNotFound)
    }
}

enum CloudKitRecordTypeCompatibility {
    static func shouldTreatMissingRecordTypeAsEmptyResult(
        recordType: String,
        after error: Error
    ) -> Bool {
        if let ckError = error as? CKError,
           ckError.code == .partialFailure,
           let partialErrors = ckError.partialErrorsByItemID?.values,
           !partialErrors.isEmpty {
            return partialErrors.allSatisfy {
                shouldTreatMissingRecordTypeAsEmptyResult(
                    recordType: recordType,
                    after: $0
                )
            }
        }

        let normalizedRecordType = recordType.lowercased()
        return errorMessages(from: error).contains { message in
            let normalizedMessage = message.lowercased()
            return normalizedMessage.contains("did not find record type")
                && normalizedMessage.contains(normalizedRecordType)
        }
    }

    private static func errorMessages(from error: Error) -> [String] {
        let nsError = error as NSError
        return [
            error.localizedDescription,
            nsError.localizedFailureReason,
            nsError.userInfo[NSDebugDescriptionErrorKey] as? String,
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        ]
        .compactMap { message in
            guard let message else { return nil }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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
