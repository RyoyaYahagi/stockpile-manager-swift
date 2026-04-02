import CloudKit
import SwiftData
import XCTest
@testable import Stockpile

@MainActor
final class CloudKitFamilySharingServiceTests: XCTestCase {
    func testPrepareShareSeedsPrivateZoneAndMarksBaseline() async throws {
        let harness = try TestHarness()
        let family = Family(name: "防災")
        let bag = Bag(name: "非常袋")
        let item = Item(name: "水", quantity: 3)
        bag.family = family
        item.family = family
        item.bag = bag
        harness.context.insert(family)
        harness.context.insert(bag)
        harness.context.insert(item)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordHandler = { _, _ in
            throw CloudKitSharingError.recordNotFound
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.prepareShare(for: family)

        XCTAssertEqual(backend.ensuredZoneIDs.count, 1)
        XCTAssertTrue(
            backend.modifyCalls.contains { call in
                call.scope == .privateDatabase
                    && Set(call.recordTypes).isSuperset(of: ["Family", "Bag", "Item"])
            }
        )
        XCTAssertFalse(family.cloudKitPendingSync)
        XCTAssertTrue(family.cloudKitHasRemoteBaseline)
    }

    func testSyncFamilyStateMarksBaselineWhenRemoteSnapshotIsAvailable() async throws {
        let harness = try TestHarness()
        let family = Family(name: "ローカル")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"
        harness.context.insert(family)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: family.id, name: "共有家族", zoneID: zoneID)]
            case "Bag", "Item":
                return []
            default:
                return []
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: family)

        XCTAssertEqual(family.name, "共有家族")
        XCTAssertFalse(family.cloudKitPendingSync)
        XCTAssertTrue(family.cloudKitHasRemoteBaseline)
    }

    func testSyncFamilyStateDoesNotDeleteLocalDataWhenOwnerRemoteIsNotReady() async throws {
        let harness = try TestHarness()
        let family = Family(name: "家族")
        family.cloudKitDatabaseScope = .privateDatabase
        family.cloudKitPendingSync = true
        family.cloudKitZoneName = "private-zone"
        family.cloudKitZoneOwnerName = CKCurrentUserDefaultName

        let bag = Bag(name: "倉庫")
        let item = Item(name: "乾電池", quantity: 8)
        bag.family = family
        item.family = family
        item.bag = bag

        harness.context.insert(family)
        harness.context.insert(bag)
        harness.context.insert(item)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, _, scope in
            if scope == .privateDatabase, recordType == "Family", backend.privateFamilyFetchFailureCount == 0 {
                backend.privateFamilyFetchFailureCount += 1
                throw CKError(.zoneNotFound)
            }
            return []
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: family)

        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Bag>()).count, 1)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Item>()).count, 1)
        XCTAssertTrue(
            backend.modifyCalls.contains { call in
                call.scope == .privateDatabase
                    && Set(call.recordTypes).isSuperset(of: ["Family", "Bag", "Item"])
            }
        )
    }

    func testSyncAcceptedShareCreatesPendingFamilyWhenSharedFamilyRecordIsNotReady() async throws {
        let harness = try TestHarness()
        let localFamily = Family(name: "ローカル家族")
        let localItem = Item(name: "懐中電灯", quantity: 1)
        localItem.family = localFamily
        harness.context.insert(localFamily)
        harness.context.insert(localItem)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, _, scope in
            if scope == .sharedDatabase, recordType == "Family" {
                return []
            }
            return []
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)
        let zoneID = CKRecordZone.ID(zoneName: "accepted-zone", ownerName: "owner")

        do {
            _ = try await service.syncAcceptedShare(
                zoneID: zoneID,
                fallbackName: "共有中の家族",
                resolvedFamilyID: nil,
                retryIntervalsInNanoseconds: [0]
            )
            XCTFail("Expected accepted share sync to fail while remote family record is unavailable")
        } catch let error as CloudKitSharingError {
            XCTAssertEqual(error, .familyRecordNotFound)
        }

        let families = try harness.context.fetch(FetchDescriptor<Family>())
        XCTAssertEqual(families.count, 2)

        let pendingFamily = try XCTUnwrap(
            families.first(where: { $0.cloudKitZoneName == "accepted-zone" && $0.cloudKitDatabaseScope == .sharedDatabase })
        )
        XCTAssertEqual(pendingFamily.name, "共有中の家族")
        XCTAssertTrue(pendingFamily.cloudKitPendingSync)
        XCTAssertFalse(pendingFamily.cloudKitHasRemoteBaseline)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Item>()).count, 1)
    }

    func testSyncFamilyStateClearsLocalDataOnlyAfterBaselineIsEstablished() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"

        let bag = Bag(name: "共有袋")
        let item = Item(name: "ラジオ", quantity: 1)
        bag.family = family
        item.family = family
        item.bag = bag

        harness.context.insert(family)
        harness.context.insert(bag)
        harness.context.insert(item)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, _, scope in
            if scope == .sharedDatabase, recordType == "Family" {
                return []
            }
            return []
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: family)

        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Bag>()).count, 0)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Item>()).count, 0)
    }

    func testCurrentFamilyResolverPrefersDataBackedLocalFamilyOverEmptyPendingSharedFamily() {
        let localFamily = Family(name: "ローカル家族")
        let bag = Bag(name: "押入れ")
        bag.family = localFamily

        let sharedFamily = Family(name: "共有家族")
        sharedFamily.cloudKitDatabaseScope = .sharedDatabase
        sharedFamily.cloudKitPendingSync = true
        sharedFamily.cloudKitZoneName = "shared-zone"
        sharedFamily.cloudKitZoneOwnerName = "owner"

        XCTAssertFalse(sharedFamily.prefersStrictCloudKitScoping)
        XCTAssertEqual(CurrentFamilyResolver.currentFamily(from: [sharedFamily, localFamily])?.id, localFamily.id)
    }

    private static func makeFamilyRecord(id: UUID, name: String, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: "Family",
            recordID: CKRecord.ID(recordName: "family-\(id.uuidString)", zoneID: zoneID)
        )
        record["id"] = id.uuidString as CKRecordValue
        record["name"] = name as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        return record
    }
}

@MainActor
private struct TestHarness {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Family.self,
            User.self,
            Bag.self,
            Item.self,
            NotificationSettings.self,
            configurations: configuration
        )
        context = ModelContext(container)
    }
}

@MainActor
private final class FakeCloudKitFamilySharingBackend: CloudKitFamilySharingBackend {
    struct ModifyCall {
        let recordTypes: [String]
        let deletedRecordNames: [String]
        let scope: FamilyCloudKitDatabaseScope
    }

    var ensuredZoneIDs: [CKRecordZone.ID] = []
    var modifyCalls: [ModifyCall] = []
    var privateFamilyFetchFailureCount = 0
    var fetchRecordsHandler: ((String, CKRecordZone.ID, FamilyCloudKitDatabaseScope) throws -> [CKRecord])?
    var fetchRecordHandler: ((CKRecord.ID, FamilyCloudKitDatabaseScope) throws -> CKRecord)?
    var modifyHandler: (([CKRecord], [CKRecord.ID], FamilyCloudKitDatabaseScope) throws -> [CKRecord])?

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
        ensuredZoneIDs.append(zoneID)
    }

    func fetchRecords(
        recordType: String,
        in zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        try fetchRecordsHandler?(recordType, zoneID, scope) ?? []
    }

    func fetchRecord(
        with recordID: CKRecord.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> CKRecord {
        if let fetchRecordHandler {
            return try fetchRecordHandler(recordID, scope)
        }
        throw CloudKitSharingError.recordNotFound
    }

    func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        modifyCalls.append(
            ModifyCall(
                recordTypes: recordsToSave.map(\.recordType),
                deletedRecordNames: recordIDsToDelete.map(\.recordName),
                scope: scope
            )
        )

        if let modifyHandler {
            return try modifyHandler(recordsToSave, recordIDsToDelete, scope)
        }
        return recordsToSave
    }

    func accept(metadata: CKShare.Metadata) async throws -> CKShare {
        XCTFail("accept(metadata:) should not be used in these tests")
        throw CloudKitSharingError.invalidShareMetadata
    }
}
