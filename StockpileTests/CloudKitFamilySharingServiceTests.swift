import CloudKit
import SwiftData
import XCTest
@testable import Stockpile

@MainActor
final class CloudKitFamilySharingServiceTests: XCTestCase {
    func testReleaseEntitlementsAllowInProcessOneTimeShareLinks() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = repositoryRootURL
            .appendingPathComponent("Stockpile")
            .appendingPathComponent("StockpileRelease.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let extendedShareAccess = try XCTUnwrap(
            plist["com.apple.developer.icloud-extended-share-access"] as? [String]
        )

        XCTAssertTrue(extendedShareAccess.contains("InProcessOneTimeLinks"))
    }

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
        backend.fetchRecordHandler = { recordID, _ in
            switch recordID.recordName {
            case CKRecordNameZoneWideShare:
                throw CloudKitSharingError.recordNotFound
            case "family-\(family.id.uuidString)":
                return Self.makeFamilyRecord(id: family.id, name: family.name, zoneID: recordID.zoneID)
            case "bag-\(bag.id.uuidString)":
                return Self.makeBagRecord(id: bag.id, name: bag.name, familyID: family.id, zoneID: recordID.zoneID)
            case "item-\(item.id.uuidString)":
                return Self.makeItemRecord(
                    id: item.id,
                    name: item.name,
                    familyID: family.id,
                    bagID: bag.id,
                    zoneID: recordID.zoneID
                )
            default:
                throw CloudKitSharingError.recordNotFound
            }
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

    func testPrepareShareKeepsPrivateSharePermission() async throws {
        let harness = try TestHarness()
        let family = Family(name: "防災")
        harness.context.insert(family)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordHandler = { recordID, _ in
            switch recordID.recordName {
            case CKRecordNameZoneWideShare:
                throw CloudKitSharingError.recordNotFound
            case "family-\(family.id.uuidString)":
                return Self.makeFamilyRecord(id: family.id, name: family.name, zoneID: recordID.zoneID)
            default:
                throw CloudKitSharingError.recordNotFound
            }
        }

        var capturedSharePermission: CKShare.ParticipantPermission?
        backend.modifyHandler = { recordsToSave, _, _ in
            if let share = recordsToSave.compactMap({ $0 as? CKShare }).first {
                capturedSharePermission = share.publicPermission
            }
            return recordsToSave
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.prepareShare(for: family)

        XCTAssertEqual(capturedSharePermission, CKShare.ParticipantPermission.none)
    }

    func testPrepareShareReturnsExistingShareFastPathWhenRemoteBaselineIsVerified() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有済み")
        family.cloudKitDatabaseScope = .privateDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitShareURL = URL(string: "https://www.icloud.com/share/example")
        family.cloudKitZoneName = "existing-zone"
        family.cloudKitZoneOwnerName = CKCurrentUserDefaultName
        harness.context.insert(family)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordCallCount = 0
        backend.fetchRecordHandler = { recordID, scope in
            XCTAssertEqual(scope, .privateDatabase)
            backend.fetchRecordCallCount += 1

            if recordID.recordName == CKRecordNameZoneWideShare {
                return CKShare(recordZoneID: recordID.zoneID)
            }

            throw CloudKitSharingError.recordNotFound
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.prepareShare(for: family)

        XCTAssertTrue(backend.modifyCalls.isEmpty)
        XCTAssertFalse(family.cloudKitPendingSync)
        XCTAssertTrue(family.cloudKitHasRemoteBaseline)
    }

    func testPrepareShareDoesNotRepeatFullSyncAfterShareIsSaved() async throws {
        CloudKitSharingDiagnostics.clear()
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
        backend.fetchRecordHandler = { recordID, _ in
            switch recordID.recordName {
            case CKRecordNameZoneWideShare:
                throw CloudKitSharingError.recordNotFound
            case "family-\(family.id.uuidString)":
                return Self.makeFamilyRecord(id: family.id, name: family.name, zoneID: recordID.zoneID)
            case "bag-\(bag.id.uuidString)":
                return Self.makeBagRecord(id: bag.id, name: bag.name, familyID: family.id, zoneID: recordID.zoneID)
            case "item-\(item.id.uuidString)":
                return Self.makeItemRecord(
                    id: item.id,
                    name: item.name,
                    familyID: family.id,
                    bagID: bag.id,
                    zoneID: recordID.zoneID
                )
            default:
                throw CloudKitSharingError.recordNotFound
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.prepareShare(for: family)

        let zoneSyncCalls = backend.modifyCalls.filter { call in
            call.scope == .privateDatabase
                && Set(call.recordTypes).isSuperset(of: ["Family", "Bag", "Item"])
        }
        XCTAssertEqual(zoneSyncCalls.count, 1)

        CloudKitSharingDiagnostics.clear()
    }

    func testPrepareShareFailsWhenOwnerUploadCannotBeVerified() async throws {
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

        await XCTAssertThrowsErrorAsync(try await service.prepareShare(for: family)) { error in
            guard case let CloudKitSharingError.shareDataNotUploaded(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("CloudKit上のレコードが見つかりません"))
        }

        XCTAssertTrue(family.cloudKitPendingSync)
        XCTAssertFalse(family.cloudKitHasRemoteBaseline)
    }

    func testPrepareShareFailsWithActionableMessageWhenICloudAccountIsMissing() async throws {
        let harness = try TestHarness()
        let family = Family(name: "防災")
        harness.context.insert(family)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.accountStatusValue = .noAccount
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        await XCTAssertThrowsErrorAsync(try await service.prepareShare(for: family)) { error in
            guard case let CloudKitSharingError.authenticatedAccountRequired(isSimulator) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(isSimulator)
        }
    }

    func testPrepareShareCanReturnPendingShareWhenVerificationIsDeferred() async throws {
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
        let service = CloudKitFamilySharingService(
            modelContext: harness.context,
            backend: backend,
            sharePreparationVerificationPolicy: .allowPendingUpload
        )

        _ = try await service.prepareShare(for: family)

        XCTAssertTrue(family.cloudKitPendingSync)
        XCTAssertFalse(family.cloudKitHasRemoteBaseline)
    }

    func testPrepareShareRequiresUploadVerificationOnTestFlightBuild() async throws {
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
        let service = CloudKitFamilySharingService(
            modelContext: harness.context,
            backend: backend,
            sharePreparationRuntime: CloudKitSharePreparationRuntime(
                isSimulatorApp: false,
                isTestFlightBuild: true
            )
        )

        await XCTAssertThrowsErrorAsync(try await service.prepareShare(for: family)) { error in
            guard case CloudKitSharingError.shareDataNotUploaded = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(family.cloudKitPendingSync)
        XCTAssertFalse(family.cloudKitHasRemoteBaseline)
    }

    func testVerifyCloudKitUploadUsesCurrentFamilyDatabaseScope() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"
        family.cloudKitPendingSync = false

        let bag = Bag(name: "非常袋")
        let item = Item(name: "水", quantity: 2)
        bag.family = family
        item.family = family
        item.bag = bag

        harness.context.insert(family)
        harness.context.insert(bag)
        harness.context.insert(item)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        var fetchedScopes: [FamilyCloudKitDatabaseScope] = []
        backend.fetchRecordsByIDHandler = { recordIDs, scope in
            fetchedScopes.append(scope)
            return try recordIDs.map { recordID in
                switch recordID.recordName {
                case "family-\(family.id.uuidString)":
                    return Self.makeFamilyRecord(id: family.id, name: family.name, zoneID: recordID.zoneID)
                case "bag-\(bag.id.uuidString)":
                    return Self.makeBagRecord(id: bag.id, name: bag.name, familyID: family.id, zoneID: recordID.zoneID)
                case "item-\(item.id.uuidString)":
                    return Self.makeItemRecord(
                        id: item.id,
                        name: item.name,
                        familyID: family.id,
                        bagID: bag.id,
                        zoneID: recordID.zoneID
                    )
                default:
                    throw CloudKitSharingError.recordNotFound
                }
            }
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.verifyCloudKitUpload(for: family)

        XCTAssertEqual(fetchedScopes, [.sharedDatabase])
    }

    func testSharedFamilyRefreshResolvesZoneIDFromSharedDatabaseZones() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "stale-owner"
        family.cloudKitPendingSync = true
        family.cloudKitHasRemoteBaseline = false
        harness.context.insert(family)
        try harness.context.save()

        let resolvedZoneID = CKRecordZone.ID(zoneName: "shared-zone", ownerName: "actual-owner")
        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchAllRecordZoneIDsHandler = { scope in
            XCTAssertEqual(scope, .sharedDatabase)
            return [resolvedZoneID]
        }

        var fetchedZoneIDs: [CKRecordZone.ID] = []
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            fetchedZoneIDs.append(zoneID)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: family.id, name: family.name, zoneID: zoneID)]
            case "Bag", "Item", "DeletionMarker":
                return []
            default:
                return []
            }
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: family)

        XCTAssertEqual(backend.fetchAllRecordZoneIDsScopes, [.sharedDatabase])
        XCTAssertTrue(fetchedZoneIDs.allSatisfy { $0 == resolvedZoneID })
        XCTAssertEqual(family.cloudKitZoneOwnerName, "actual-owner")
        XCTAssertFalse(family.cloudKitPendingSync)
        XCTAssertTrue(family.cloudKitHasRemoteBaseline)
    }

    func testCloudKitRecordQueryCompatibilityFallsBackForRecordNameQueryableError() {
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Field 'recordName' is not marked queryable"
            ]
        )

        XCTAssertTrue(CloudKitRecordQueryCompatibility.shouldFallbackToZoneChanges(after: error))
    }

    func testCloudKitRecordQueryCompatibilityFallsBackForPartialFailureWrappingQueryableError() {
        let underlyingError = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Field 'recordName' is not marked queryable"
            ]
        )
        let partialFailure = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "family"): underlyingError]]
        )

        XCTAssertTrue(CloudKitRecordQueryCompatibility.shouldFallbackToZoneChanges(after: partialFailure))
    }

    func testPrepareShareIgnoresMissingDeletionMarkerRecordType() async throws {
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
        backend.fetchRecordsHandler = { recordType, zoneID, _ in
            if recordType == "DeletionMarker" {
                throw Self.makeMissingRecordTypePartialFailure(
                    recordType: recordType,
                    zoneID: zoneID
                )
            }
            return []
        }
        backend.fetchRecordHandler = { recordID, _ in
            switch recordID.recordName {
            case CKRecordNameZoneWideShare:
                throw CloudKitSharingError.recordNotFound
            case "family-\(family.id.uuidString)":
                return Self.makeFamilyRecord(id: family.id, name: family.name, zoneID: recordID.zoneID)
            case "bag-\(bag.id.uuidString)":
                return Self.makeBagRecord(id: bag.id, name: bag.name, familyID: family.id, zoneID: recordID.zoneID)
            case "item-\(item.id.uuidString)":
                return Self.makeItemRecord(
                    id: item.id,
                    name: item.name,
                    familyID: family.id,
                    bagID: bag.id,
                    zoneID: recordID.zoneID
                )
            default:
                throw CloudKitSharingError.recordNotFound
            }
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.prepareShare(for: family)

        XCTAssertFalse(family.cloudKitPendingSync)
        XCTAssertTrue(family.cloudKitHasRemoteBaseline)
    }

    func testPrepareShareIgnoresMissingPrimaryRecordTypesDuringInitialProductionSchemaWarmup() async throws {
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
        backend.fetchRecordsHandler = { recordType, zoneID, _ in
            throw Self.makeMissingRecordTypePartialFailure(
                recordType: recordType,
                zoneID: zoneID
            )
        }
        backend.fetchRecordHandler = { recordID, _ in
            switch recordID.recordName {
            case CKRecordNameZoneWideShare:
                throw CloudKitSharingError.recordNotFound
            case "family-\(family.id.uuidString)":
                return Self.makeFamilyRecord(id: family.id, name: family.name, zoneID: recordID.zoneID)
            case "bag-\(bag.id.uuidString)":
                return Self.makeBagRecord(id: bag.id, name: bag.name, familyID: family.id, zoneID: recordID.zoneID)
            case "item-\(item.id.uuidString)":
                return Self.makeItemRecord(
                    id: item.id,
                    name: item.name,
                    familyID: family.id,
                    bagID: bag.id,
                    zoneID: recordID.zoneID
                )
            default:
                throw CloudKitSharingError.recordNotFound
            }
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.prepareShare(for: family)

        XCTAssertFalse(family.cloudKitPendingSync)
        XCTAssertTrue(family.cloudKitHasRemoteBaseline)
        XCTAssertTrue(
            backend.modifyCalls.contains { call in
                Set(call.recordTypes).isSuperset(of: ["Family", "Bag", "Item"])
            }
        )
    }

    func testPrepareShareDoesNotOverwriteNewerRemoteFamilyRecordDuringEnsureStep() async throws {
        let harness = try TestHarness()
        let family = Family(name: "ローカル")
        family.updatedAt = Date(timeIntervalSince1970: 100)
        harness.context.insert(family)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, _ in
            switch recordType {
            case "Family":
                return [
                    Self.makeFamilyRecord(
                        id: family.id,
                        name: "リモート",
                        zoneID: zoneID,
                        createdAt: Date(timeIntervalSince1970: 10),
                        updatedAt: Date(timeIntervalSince1970: 200)
                    )
                ]
            case "Bag", "Item", "DeletionMarker":
                return []
            default:
                return []
            }
        }
        backend.fetchRecordHandler = { recordID, _ in
            switch recordID.recordName {
            case CKRecordNameZoneWideShare:
                throw CloudKitSharingError.recordNotFound
            case "family-\(family.id.uuidString)":
                return Self.makeFamilyRecord(
                    id: family.id,
                    name: "リモート",
                    zoneID: recordID.zoneID,
                    createdAt: Date(timeIntervalSince1970: 10),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            default:
                throw CloudKitSharingError.recordNotFound
            }
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.prepareShare(for: family)

        XCTAssertFalse(
            backend.modifyCalls.contains { call in
                call.recordTypes == ["Family"]
            }
        )
    }

    func testLeaveFamilyDeletesSharedZoneBeforeRemovingLocalFamily() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "saved-owner"
        family.cloudKitHasRemoteBaseline = true
        harness.context.insert(family)
        try harness.context.save()

        let resolvedZoneID = CKRecordZone.ID(zoneName: "shared-zone", ownerName: "actual-owner")
        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchAllRecordZoneIDsHandler = { scope in
            XCTAssertEqual(scope, .sharedDatabase)
            return [resolvedZoneID]
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.leaveFamily(family)

        XCTAssertEqual(backend.deletedZoneIDs.count, 1)
        XCTAssertEqual(backend.deletedZoneIDs.first?.zoneID, resolvedZoneID)
        XCTAssertEqual(backend.deletedZoneIDs.first?.scope, .sharedDatabase)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Family>()).count, 0)
    }

    func testSyncFamilyStateIgnoresMissingDeletionMarkerRecordType() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有準備中")
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
            case "DeletionMarker":
                throw Self.makeMissingRecordTypePartialFailure(
                    recordType: recordType,
                    zoneID: zoneID
                )
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

    func testSyncFamilyStateRepairsPlaceholderSharedItemUsingRemoteExpiryDate() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"

        let remoteItemID = UUID()
        let placeholderCreatedAt = Date(timeIntervalSince1970: 1_000)
        let placeholderItem = Item(name: "保存水", quantity: 1)
        placeholderItem.id = remoteItemID
        placeholderItem.family = family
        placeholderItem.createdAt = placeholderCreatedAt
        placeholderItem.updatedAt = placeholderCreatedAt
        placeholderItem.expiryDate = nil

        harness.context.insert(family)
        harness.context.insert(placeholderItem)
        try harness.context.save()

        let remoteCreatedAt = Date(timeIntervalSince1970: 30)
        let remoteExpiryDate = Date(timeIntervalSince1970: 60)
        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: family.id, name: "共有家族", zoneID: zoneID)]
            case "Item":
                return [
                    Self.makeItemRecord(
                        id: remoteItemID,
                        name: "保存水",
                        familyID: family.id,
                        bagID: nil,
                        zoneID: zoneID,
                        quantity: 6,
                        expiryDate: remoteExpiryDate,
                        createdAt: remoteCreatedAt,
                        updatedAt: remoteCreatedAt
                    )
                ]
            case "Bag", "DeletionMarker":
                return []
            default:
                return []
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: family)

        let items = try harness.context.fetch(FetchDescriptor<Item>())
        XCTAssertEqual(items.count, 1)
        let repairedItem = try XCTUnwrap(items.first)
        XCTAssertEqual(repairedItem.id, remoteItemID)
        XCTAssertEqual(repairedItem.quantity, 6)
        XCTAssertEqual(repairedItem.expiryDate, remoteExpiryDate)
        XCTAssertEqual(repairedItem.createdAt, remoteCreatedAt)
        XCTAssertEqual(repairedItem.updatedAt, remoteCreatedAt)
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

    func testSyncAcceptedShareReturnsPendingFamilyWhenSharedFamilyRecordIsNotReady() async throws {
        let harness = try TestHarness()
        let localFamily = Family(name: "ローカル家族")
        localFamily.lastSelectedAt = Date(timeIntervalSince1970: 100)
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

        let acceptedFamily = try await service.syncAcceptedShare(
            zoneID: zoneID,
            fallbackName: "共有中の家族",
            resolvedFamilyID: nil,
            retryIntervalsInNanoseconds: [0]
        )

        let families = try harness.context.fetch(FetchDescriptor<Family>())
        XCTAssertEqual(families.count, 2)

        let pendingFamily = try XCTUnwrap(
            families.first(where: { $0.cloudKitZoneName == "accepted-zone" && $0.cloudKitDatabaseScope == .sharedDatabase })
        )
        XCTAssertEqual(acceptedFamily.id, pendingFamily.id)
        XCTAssertEqual(pendingFamily.name, "共有中の家族")
        XCTAssertTrue(pendingFamily.cloudKitPendingSync)
        XCTAssertFalse(pendingFamily.cloudKitHasRemoteBaseline)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Item>()).count, 1)
        XCTAssertEqual(CurrentFamilyResolver.currentFamily(from: families)?.id, localFamily.id)
    }

    func testSyncAcceptedShareMarksAcceptedFamilyAsCurrent() async throws {
        let harness = try TestHarness()
        let localFamily = Family(name: "ローカル家族")
        localFamily.lastSelectedAt = Date(timeIntervalSince1970: 100)
        let localItem = Item(name: "保存水", quantity: 6)
        localItem.family = localFamily
        harness.context.insert(localFamily)
        harness.context.insert(localItem)
        try harness.context.save()

        let acceptedFamilyID = UUID()
        let zoneID = CKRecordZone.ID(zoneName: "accepted-zone", ownerName: "owner")
        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, requestedZoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            XCTAssertEqual(requestedZoneID, zoneID)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: acceptedFamilyID, name: "共有家族", zoneID: zoneID)]
            case "Bag", "Item", "DeletionMarker":
                return []
            default:
                return []
            }
        }

        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        let acceptedFamily = try await service.syncAcceptedShare(
            zoneID: zoneID,
            fallbackName: "共有家族",
            resolvedFamilyID: acceptedFamilyID,
            retryIntervalsInNanoseconds: [0]
        )

        let families = try harness.context.fetch(FetchDescriptor<Family>())
        XCTAssertEqual(acceptedFamily.id, acceptedFamilyID)
        XCTAssertNotNil(acceptedFamily.lastSelectedAt)
        XCTAssertEqual(CurrentFamilyResolver.currentFamily(from: families)?.id, acceptedFamilyID)
        XCTAssertEqual(localFamily.lastSelectedAt, Date(timeIntervalSince1970: 100))
    }

    func testSyncFamilyStateClearsRevokedSharedMetadataAfterBaselineIsEstablished() async throws {
        let harness = try TestHarness()
        let localFamily = Family(name: "ローカル家族")
        localFamily.lastSelectedAt = Date(timeIntervalSince1970: 100)
        let localItem = Item(name: "保存食", quantity: 2)
        localItem.family = localFamily

        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"
        family.lastSelectedAt = Date(timeIntervalSince1970: 200)

        let bag = Bag(name: "共有袋")
        let item = Item(name: "ラジオ", quantity: 1)
        bag.family = family
        item.family = family
        item.bag = bag

        harness.context.insert(localFamily)
        harness.context.insert(localItem)
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
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Item>()).count, 1)
        XCTAssertEqual(family.shareState, .localOnly)
        XCTAssertNil(family.cloudKitDatabaseScope)
        XCTAssertNil(family.cloudKitZoneName)
        XCTAssertNil(family.cloudKitZoneOwnerName)
        XCTAssertNil(family.cloudKitShareURL)
        XCTAssertFalse(family.cloudKitPendingSync)
        XCTAssertFalse(family.cloudKitHasRemoteBaseline)
        XCTAssertNil(family.lastSelectedAt)
        let families = try harness.context.fetch(FetchDescriptor<Family>())
        XCTAssertEqual(CurrentFamilyResolver.currentFamily(from: families)?.id, localFamily.id)
    }

    func testSyncPendingSharedFamilyKeepsMetadataWhileSharedZoneIsStillUnavailable() async throws {
        let harness = try TestHarness()
        let localFamily = Family(name: "ローカル家族")
        localFamily.lastSelectedAt = Date(timeIntervalSince1970: 100)
        let localItem = Item(name: "懐中電灯", quantity: 1)
        localItem.family = localFamily

        let pendingSharedFamily = Family(name: "共有準備中")
        pendingSharedFamily.cloudKitDatabaseScope = .sharedDatabase
        pendingSharedFamily.cloudKitPendingSync = true
        pendingSharedFamily.cloudKitHasRemoteBaseline = false
        pendingSharedFamily.cloudKitZoneName = "shared-zone"
        pendingSharedFamily.cloudKitZoneOwnerName = "owner"

        harness.context.insert(localFamily)
        harness.context.insert(localItem)
        harness.context.insert(pendingSharedFamily)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, _, scope in
            if scope == .sharedDatabase, recordType == "Family" {
                throw CKError(.zoneNotFound)
            }
            return []
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: pendingSharedFamily)

        XCTAssertEqual(pendingSharedFamily.shareState, .preparing)
        XCTAssertEqual(pendingSharedFamily.cloudKitDatabaseScope, .sharedDatabase)
        XCTAssertEqual(pendingSharedFamily.cloudKitZoneName, "shared-zone")
        XCTAssertEqual(pendingSharedFamily.cloudKitZoneOwnerName, "owner")
        XCTAssertNil(pendingSharedFamily.cloudKitShareURL)
        XCTAssertTrue(pendingSharedFamily.cloudKitPendingSync)
        XCTAssertFalse(pendingSharedFamily.cloudKitHasRemoteBaseline)
        XCTAssertNil(pendingSharedFamily.lastSelectedAt)
        let families = try harness.context.fetch(FetchDescriptor<Family>())
        XCTAssertEqual(CurrentFamilyResolver.currentFamily(from: families)?.id, localFamily.id)
    }

    func testSyncPendingSharedFamilyMarksItCurrentWhenRemoteSnapshotBecomesAvailable() async throws {
        let harness = try TestHarness()
        let localFamily = Family(name: "ローカル家族")
        localFamily.lastSelectedAt = Date(timeIntervalSince1970: 100)
        let localItem = Item(name: "懐中電灯", quantity: 1)
        localItem.family = localFamily

        let pendingSharedFamily = Family(name: "共有準備中")
        pendingSharedFamily.cloudKitDatabaseScope = .sharedDatabase
        pendingSharedFamily.cloudKitPendingSync = true
        pendingSharedFamily.cloudKitHasRemoteBaseline = false
        pendingSharedFamily.cloudKitZoneName = "shared-zone"
        pendingSharedFamily.cloudKitZoneOwnerName = "owner"

        harness.context.insert(localFamily)
        harness.context.insert(localItem)
        harness.context.insert(pendingSharedFamily)
        try harness.context.save()

        let remoteItemID = UUID()
        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: pendingSharedFamily.id, name: "共有家族", zoneID: zoneID)]
            case "Item":
                return [
                    Self.makeItemRecord(
                        id: remoteItemID,
                        name: "保存水",
                        familyID: pendingSharedFamily.id,
                        bagID: nil,
                        zoneID: zoneID
                    )
                ]
            case "Bag", "DeletionMarker":
                return []
            default:
                return []
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: pendingSharedFamily)

        XCTAssertEqual(pendingSharedFamily.name, "共有家族")
        XCTAssertFalse(pendingSharedFamily.cloudKitPendingSync)
        XCTAssertTrue(pendingSharedFamily.cloudKitHasRemoteBaseline)
        XCTAssertNotNil(pendingSharedFamily.lastSelectedAt)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Item>()).count, 2)
        let families = try harness.context.fetch(FetchDescriptor<Family>())
        XCTAssertEqual(CurrentFamilyResolver.currentFamily(from: families)?.id, pendingSharedFamily.id)
    }

    func testSyncFamilyDataDoesNotDeleteRemoteRecordsWhenLocalIsEmpty() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"
        harness.context.insert(family)
        try harness.context.save()

        let remoteBagID = UUID()
        let remoteItemID = UUID()
        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: family.id, name: "共有家族", zoneID: zoneID)]
            case "Bag":
                return [Self.makeBagRecord(id: remoteBagID, name: "非常袋", familyID: family.id, zoneID: zoneID)]
            case "Item":
                return [
                    Self.makeItemRecord(
                        id: remoteItemID,
                        name: "保存水",
                        familyID: family.id,
                        bagID: remoteBagID,
                        zoneID: zoneID
                    )
                ]
            case "DeletionMarker":
                return []
            default:
                return []
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyDataToCloudKit(for: family)

        XCTAssertTrue(backend.modifyCalls.allSatisfy { $0.deletedRecordNames.isEmpty })
    }

    func testSyncFamilyDataUploadsDeletionMarkerForExplicitItemDelete() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"

        let item = Item(name: "保存水", quantity: 6)
        item.family = family

        harness.context.insert(family)
        harness.context.insert(item)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: family.id, name: "共有家族", zoneID: zoneID)]
            case "Item":
                return [Self.makeItemRecord(id: item.id, name: "保存水", familyID: family.id, bagID: nil, zoneID: zoneID)]
            case "Bag", "DeletionMarker":
                return []
            default:
                return []
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try service.deleteItemLocally(item, in: family)
        try harness.context.save()
        try await service.syncFamilyDataToCloudKit(for: family)

        let markers = try harness.context.fetch(FetchDescriptor<CloudKitDeletionMarker>())
        XCTAssertEqual(markers.count, 1)
        XCTAssertFalse(try XCTUnwrap(markers.first).isPendingUpload)
        XCTAssertTrue(
            backend.modifyCalls.contains { call in
                call.recordTypes.contains("DeletionMarker")
                    && call.deletedRecordNames.contains("item-\(item.id.uuidString)")
            }
        )
    }

    func testSyncFamilyStateDeletesLocalItemWhenRemoteDeletionMarkerIsNewer() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"

        let item = Item(name: "ラジオ", quantity: 1)
        item.family = family
        item.updatedAt = Date(timeIntervalSince1970: 100)

        harness.context.insert(family)
        harness.context.insert(item)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: family.id, name: "共有家族", zoneID: zoneID)]
            case "Item", "Bag":
                return []
            case "DeletionMarker":
                return [
                    Self.makeDeletionMarkerRecord(
                        familyID: family.id,
                        entityType: .item,
                        targetRecordID: item.id.uuidString,
                        deletedAt: Date(timeIntervalSince1970: 200),
                        zoneID: zoneID
                    )
                ]
            default:
                return []
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: family)

        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<Item>()).count, 0)
    }

    func testSyncFamilyStateKeepsLocalItemWhenLocalUpdateIsNewerThanRemoteDeletionMarker() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .sharedDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "shared-zone"
        family.cloudKitZoneOwnerName = "owner"

        let item = Item(name: "ラジオ", quantity: 1)
        item.family = family
        item.updatedAt = Date(timeIntervalSince1970: 300)

        harness.context.insert(family)
        harness.context.insert(item)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordsHandler = { recordType, zoneID, scope in
            XCTAssertEqual(scope, .sharedDatabase)
            switch recordType {
            case "Family":
                return [Self.makeFamilyRecord(id: family.id, name: "共有家族", zoneID: zoneID)]
            case "Item", "Bag":
                return []
            case "DeletionMarker":
                return [
                    Self.makeDeletionMarkerRecord(
                        familyID: family.id,
                        entityType: .item,
                        targetRecordID: item.id.uuidString,
                        deletedAt: Date(timeIntervalSince1970: 200),
                        zoneID: zoneID
                    )
                ]
            default:
                return []
            }
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        try await service.syncFamilyStateFromCloudKit(for: family)

        let remainingItems = try harness.context.fetch(FetchDescriptor<Item>())
        XCTAssertEqual(remainingItems.count, 1)
        XCTAssertEqual(remainingItems.first?.id, item.id)
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

    func testCurrentFamilyResolverPrefersMostRecentlySelectedFamily() {
        let sharedFamily = Family(name: "共有家族")
        sharedFamily.cloudKitDatabaseScope = .sharedDatabase
        sharedFamily.cloudKitShareURL = URL(string: "https://example.com/share")
        sharedFamily.cloudKitHasRemoteBaseline = true
        sharedFamily.lastSelectedAt = Date(timeIntervalSince1970: 10)

        let localFamily = Family(name: "ローカル復元")
        let item = Item(name: "保存水", quantity: 6)
        item.family = localFamily
        localFamily.lastSelectedAt = Date(timeIntervalSince1970: 20)

        XCTAssertEqual(CurrentFamilyResolver.currentFamily(from: [sharedFamily, localFamily])?.id, localFamily.id)
    }

    func testFetchShareParticipantsUsesCachedResultWithinTTL() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .privateDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "cache-zone"
        family.cloudKitZoneOwnerName = CKCurrentUserDefaultName
        family.cloudKitShareURL = URL(string: "https://example.com/share")
        harness.context.insert(family)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordCallCount = 0
        backend.fetchRecordHandler = { recordID, scope in
            XCTAssertEqual(scope, .privateDatabase)
            backend.fetchRecordCallCount += 1
            return CKShare(recordZoneID: recordID.zoneID)
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.fetchShareParticipants(for: family)
        _ = try await service.fetchShareParticipants(for: family)

        XCTAssertEqual(backend.fetchRecordCallCount, 1)
    }

    func testFetchShareParticipantsForceRefreshBypassesCache() async throws {
        let harness = try TestHarness()
        let family = Family(name: "共有家族")
        family.cloudKitDatabaseScope = .privateDatabase
        family.cloudKitPendingSync = false
        family.cloudKitHasRemoteBaseline = true
        family.cloudKitZoneName = "force-refresh-zone"
        family.cloudKitZoneOwnerName = CKCurrentUserDefaultName
        family.cloudKitShareURL = URL(string: "https://example.com/share")
        harness.context.insert(family)
        try harness.context.save()

        let backend = FakeCloudKitFamilySharingBackend()
        backend.fetchRecordCallCount = 0
        backend.fetchRecordHandler = { recordID, scope in
            XCTAssertEqual(scope, .privateDatabase)
            backend.fetchRecordCallCount += 1
            return CKShare(recordZoneID: recordID.zoneID)
        }
        let service = CloudKitFamilySharingService(modelContext: harness.context, backend: backend)

        _ = try await service.fetchShareParticipants(for: family)
        _ = try await service.fetchShareParticipants(for: family, forceRefresh: true)

        XCTAssertEqual(backend.fetchRecordCallCount, 2)
    }

    func testCloudKitSharingDiagnosticsReportIncludesFamiliesAndRecentEvents() throws {
        CloudKitSharingDiagnostics.clear()
        let harness = try TestHarness()

        let localFamily = Family(name: "ローカル家族")
        localFamily.lastSelectedAt = Date(timeIntervalSince1970: 100)

        let sharedFamily = Family(name: "共有家族")
        sharedFamily.cloudKitDatabaseScope = .sharedDatabase
        sharedFamily.cloudKitZoneName = "shared-zone"
        sharedFamily.cloudKitZoneOwnerName = "owner"
        sharedFamily.cloudKitHasRemoteBaseline = true

        let bag = Bag(name: "非常袋")
        bag.family = sharedFamily
        let item = Item(name: "保存水", quantity: 6)
        item.family = sharedFamily
        item.bag = bag

        harness.context.insert(localFamily)
        harness.context.insert(sharedFamily)
        harness.context.insert(bag)
        harness.context.insert(item)
        try harness.context.save()

        CloudKitSharingDiagnostics.log(
            event: "共有受理成功",
            details: [
                "familyID": sharedFamily.id.uuidString,
                "zoneIdentity": sharedFamily.cloudKitZoneIdentity ?? "-"
            ]
        )

        let report = CloudKitSharingDiagnostics.makeReport(modelContext: harness.context)

        XCTAssertTrue(report.contains("CloudKit共有診断レポート"))
        XCTAssertTrue(report.contains(localFamily.id.uuidString))
        XCTAssertTrue(report.contains(sharedFamily.id.uuidString))
        XCTAssertTrue(report.contains("name=共有家族"))
        XCTAssertTrue(report.contains("zone=owner::shared-zone"))
        XCTAssertTrue(report.contains("bags=1"))
        XCTAssertTrue(report.contains("items=1"))
        XCTAssertTrue(report.contains("共有受理成功"))

        CloudKitSharingDiagnostics.clear()
    }

    private static func makeFamilyRecord(
        id: UUID,
        name: String,
        zoneID: CKRecordZone.ID,
        createdAt: Date = Date(timeIntervalSince1970: 10),
        updatedAt: Date = Date(timeIntervalSince1970: 10)
    ) -> CKRecord {
        let record = CKRecord(
            recordType: "Family",
            recordID: CKRecord.ID(recordName: "family-\(id.uuidString)", zoneID: zoneID)
        )
        record["id"] = id.uuidString as CKRecordValue
        record["name"] = name as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        return record
    }

    private static func makeBagRecord(
        id: UUID,
        name: String,
        familyID: UUID,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: "Bag",
            recordID: CKRecord.ID(recordName: "bag-\(id.uuidString)", zoneID: zoneID)
        )
        let createdAt = Date(timeIntervalSince1970: 20)
        record["id"] = id.uuidString as CKRecordValue
        record["name"] = name as CKRecordValue
        record["familyID"] = familyID.uuidString as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        record["updatedAt"] = createdAt as CKRecordValue
        return record
    }

    private static func makeItemRecord(
        id: UUID,
        name: String,
        familyID: UUID,
        bagID: UUID?,
        zoneID: CKRecordZone.ID,
        quantity: Int = 1,
        expiryDate: Date? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 30),
        updatedAt: Date? = nil
    ) -> CKRecord {
        let record = CKRecord(
            recordType: "Item",
            recordID: CKRecord.ID(recordName: "item-\(id.uuidString)", zoneID: zoneID)
        )
        record["id"] = id.uuidString as CKRecordValue
        record["name"] = name as CKRecordValue
        record["familyID"] = familyID.uuidString as CKRecordValue
        record["quantity"] = quantity as CKRecordValue
        if let expiryDate {
            record["expiryDate"] = expiryDate as CKRecordValue
        }
        record["createdAt"] = createdAt as CKRecordValue
        record["updatedAt"] = (updatedAt ?? createdAt) as CKRecordValue
        if let bagID {
            record["bagID"] = bagID.uuidString as CKRecordValue
        }
        return record
    }

    private static func makeDeletionMarkerRecord(
        familyID: UUID,
        entityType: CloudKitDeletionMarkerEntityType,
        targetRecordID: String,
        deletedAt: Date,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let markerID = UUID()
        let record = CKRecord(
            recordType: "DeletionMarker",
            recordID: CKRecord.ID(recordName: "deletion-\(markerID.uuidString)", zoneID: zoneID)
        )
        record["id"] = markerID.uuidString as CKRecordValue
        record["familyID"] = familyID.uuidString as CKRecordValue
        record["entityType"] = entityType.rawValue as CKRecordValue
        record["targetRecordID"] = targetRecordID as CKRecordValue
        record["deletedAt"] = deletedAt as CKRecordValue
        return record
    }

    private static func makeMissingRecordTypePartialFailure(
        recordType: String,
        zoneID: CKRecordZone.ID
    ) -> CKError {
        let underlyingError = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Did not find record type: \(recordType)"
            ]
        )
        return CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    CKRecord.ID(recordName: "missing-\(recordType)", zoneID: zoneID): underlyingError
                ]
            ]
        )
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw an error", file: file, line: line)
    } catch {
        errorHandler(error)
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
            CloudKitDeletionMarker.self,
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
    var deletedZoneIDs: [(zoneID: CKRecordZone.ID, scope: FamilyCloudKitDatabaseScope)] = []
    var modifyCalls: [ModifyCall] = []
    var fetchAllRecordZoneIDsScopes: [FamilyCloudKitDatabaseScope] = []
    var privateFamilyFetchFailureCount = 0
    var fetchRecordCallCount = 0
    var accountStatusValue: CKAccountStatus = .available
    var accountStatusError: Error?
    var fetchAllRecordZoneIDsHandler: ((FamilyCloudKitDatabaseScope) throws -> [CKRecordZone.ID])?
    var fetchRecordsHandler: ((String, CKRecordZone.ID, FamilyCloudKitDatabaseScope) throws -> [CKRecord])?
    var fetchRecordHandler: ((CKRecord.ID, FamilyCloudKitDatabaseScope) throws -> CKRecord)?
    var fetchRecordsByIDHandler: (([CKRecord.ID], FamilyCloudKitDatabaseScope) throws -> [CKRecord])?
    var modifyHandler: (([CKRecord], [CKRecord.ID], FamilyCloudKitDatabaseScope) throws -> [CKRecord])?
    var deleteZoneHandler: ((CKRecordZone.ID, FamilyCloudKitDatabaseScope) throws -> Void)?
    var acceptHandler: ((CKShare.Metadata) throws -> CKShare)?

    func accountStatus() async throws -> CKAccountStatus {
        if let accountStatusError {
            throw accountStatusError
        }
        return accountStatusValue
    }

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
        ensuredZoneIDs.append(zoneID)
    }

    func fetchAllRecordZoneIDs(scope: FamilyCloudKitDatabaseScope) async throws -> [CKRecordZone.ID] {
        fetchAllRecordZoneIDsScopes.append(scope)
        if let fetchAllRecordZoneIDsHandler {
            return try fetchAllRecordZoneIDsHandler(scope)
        }
        return []
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
        if let fetchRecordsByIDHandler {
            guard let record = try fetchRecordsByIDHandler([recordID], scope).first else {
                throw CloudKitSharingError.recordNotFound
            }
            return record
        }
        if let fetchRecordHandler {
            return try fetchRecordHandler(recordID, scope)
        }
        throw CloudKitSharingError.recordNotFound
    }

    func fetchRecords(
        with recordIDs: [CKRecord.ID],
        scope: FamilyCloudKitDatabaseScope
    ) async throws -> [CKRecord] {
        fetchRecordCallCount += 1
        if let fetchRecordsByIDHandler {
            return try fetchRecordsByIDHandler(recordIDs, scope)
        }
        return try recordIDs.map { recordID in
            if let fetchRecordHandler {
                return try fetchRecordHandler(recordID, scope)
            }
            throw CloudKitSharingError.recordNotFound
        }
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

    func deleteZone(
        with zoneID: CKRecordZone.ID,
        scope: FamilyCloudKitDatabaseScope
    ) async throws {
        deletedZoneIDs.append((zoneID, scope))
        try deleteZoneHandler?(zoneID, scope)
    }

    func accept(metadata: CKShare.Metadata) async throws -> CKShare {
        if let acceptHandler {
            return try acceptHandler(metadata)
        }
        XCTFail("accept(metadata:) should not be used in these tests")
        throw CloudKitSharingError.invalidShareMetadata
    }
}
