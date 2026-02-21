import Foundation
import SwiftData
import CloudKit
import FirebaseAuth
import FirebaseFirestore

/// 家族共有サービス
/// 招待コードの生成・検証、家族への参加・離脱を管理
@MainActor
final class FamilySharingService {
    private let modelContext: ModelContext
    private let cloudKitService: CloudKitSharingService

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.cloudKitService = CloudKitSharingService()
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
    func startSharing(family: Family) async throws -> CKShare {
#if targetEnvironment(simulator)
        throw SharingError.cloudKitUnavailableOnSimulator
#else
        let status = try await cloudKitService.checkAccountStatus()
        guard status == .available else {
            throw SharingError.notSignedIn
        }

        let familyInfo = CloudKitSharingService.FamilyInfo(
            id: family.id,
            name: family.name,
            inviteCode: family.inviteCode,
            createdAt: family.createdAt
        )

        do {
            let share = try await cloudKitService.createShare(familyInfo: familyInfo)
            _ = try await cloudKitService.createInvite(familyInfo: familyInfo, share: share)
            return share
        } catch {
            throw mapCloudKitError(error)
        }
#endif
    }

    /// 招待コードの有効期限を延長
    func refreshInviteCode(for family: Family) async throws {
        try await cloudKitService.refreshInvite(familyId: family.id)
    }

    /// 招待コードで家族を検索（ローカル）
    func findFamilyLocally(byInviteCode code: String) -> Family? {
        let descriptor = FetchDescriptor<Family>(
            predicate: #Predicate { $0.inviteCode == code }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// 招待コードで家族を検索（CloudKit）
    func findFamilyInCloud(byInviteCode code: String) async throws -> CloudKitSharingService.InviteInfo? {
        try await cloudKitService.findInvite(byCode: code)
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

        guard let shareURL = inviteInfo.shareURL else {
            return .error(SharingError.invalidShareURL)
        }

        do {
            let metadata = try await cloudKitService.fetchShareMetadata(from: shareURL)
            try await cloudKitService.acceptShare(metadata: metadata)

            // CloudKit同期待ち
            for _ in 0..<5 {
                try await Task.sleep(for: .seconds(1))
                if let syncedFamily = findFamilyLocally(byInviteCode: normalizedCode) {
                    return .success(syncedFamily)
                }
            }

            // 同期反映前でもローカルの家族レコードを作成して参加状態を成立させる
            let family = Family(name: inviteInfo.familyName, inviteCode: normalizedCode)
            modelContext.insert(family)
            try modelContext.save()
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
        for member in family.members {
            member.family = nil
        }

        try await cloudKitService.deleteInvite(familyId: family.id)
    }

    /// 期限切れの招待を削除
    func cleanupExpiredInvites() async throws {
        try await cloudKitService.deleteExpiredInvites()
    }

    /// 初回家族作成時にローカルデータをFirebaseへ移行
    func migrateInitialDataToFirebaseIfNeeded(for family: Family) async throws {
        let migrationService = FirebaseMigrationService(modelContext: modelContext)
        try await migrationService.migrateIfNeeded(for: family)
    }

    /// 失敗中のFirebase初回移行を再試行
    func retryInitialFirebaseMigration(for family: Family) async throws {
        let migrationService = FirebaseMigrationService(modelContext: modelContext)
        try await migrationService.retryMigration(for: family)
    }

    /// Firebase初回移行の状態を取得
    func firebaseMigrationStatus(for family: Family) -> FirebaseMigrationService.MigrationStatus {
        let migrationService = FirebaseMigrationService(modelContext: modelContext)
        return migrationService.status(for: family)
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
        case notSignedIn
        case invalidInviteCode
        case invalidShareURL
        case familyNotFound
        case alreadyInFamily
        case cloudKitUnavailableOnSimulator
        case invalidContainerConfiguration
        case cloudKitFailure(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "iCloudにサインインしてください"
            case .invalidInviteCode:
                return "無効な招待コードです"
            case .invalidShareURL:
                return "共有URLが無効です"
            case .familyNotFound:
                return "家族が見つかりません"
            case .alreadyInFamily:
                return "既にこの家族に参加しています"
            case .cloudKitUnavailableOnSimulator:
                return "シミュレータではCloudKit共有を開始できません。実機で確認してください。"
            case .invalidContainerConfiguration:
                return "CloudKitコンテナ設定が不一致です。Bundle IDとiCloudコンテナの紐づけを確認してください。"
            case .cloudKitFailure(let detail):
                return "CloudKitエラー: \(detail)"
            }
        }
    }
    
    private func mapCloudKitError(_ error: Error) -> SharingError {
        if let sharingError = error as? SharingError {
            return sharingError
        }
        
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return .notSignedIn
            case .badContainer, .permissionFailure:
                return .invalidContainerConfiguration
            default:
                break
            }
        }
        
        let message = (error as NSError).localizedDescription
        if message.localizedCaseInsensitiveContains("Invalid bundle ID for container") {
            return .invalidContainerConfiguration
        }
        
        return .cloudKitFailure(message)
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
                return "Firebase設定が不足しています。GoogleService-Info.plistをターゲットに追加し、Firebase初期化を確認してください。"
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
        guard APIConfig.isFirebaseConfigured else {
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
        guard APIConfig.isFirebaseConfigured else {
            throw MigrationError.firebaseNotConfigured
        }

        if isCompleted(for: family.id) {
            return
        }

        do {
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
        guard APIConfig.isFirebaseConfigured else {
            throw MigrationError.firebaseNotConfigured
        }

        do {
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
            bag.family = family
        }

        for item in orphanItems {
            item.family = family
        }
    }

    private func uploadFamilySnapshot(_ family: Family) async throws {
        let allBags = try modelContext.fetch(FetchDescriptor<Bag>())
        let allItems = try modelContext.fetch(FetchDescriptor<Item>())
        let bagSnapshots = allBags
            .filter { $0.family?.id == family.id }
            .map { bag in
                BagSnapshot(
                    id: bag.id.uuidString,
                    name: bag.name,
                    createdAt: bag.createdAt
                )
            }
        let itemSnapshots = allItems
            .filter { $0.family?.id == family.id }
            .map { item in
                ItemSnapshot(
                    id: item.id.uuidString,
                    name: item.name,
                    quantity: item.quantity,
                    expiryDate: item.expiryDate,
                    bagId: item.bag?.id.uuidString,
                    locationNote: item.locationNote,
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

        let client = FirebaseSDKClient()
        try await client.migrateFamily(
            family: familySnapshot,
            bags: bagSnapshots,
            items: itemSnapshots
        )
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

private struct FirestoreWriteOperation {
    let path: String
    let data: [String: Any]
}

private final class FirebaseSDKClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case missingUser

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Firebaseが初期化されていません。"
            case .missingUser:
                return "Firebaseユーザー情報を取得できませんでした。"
            }
        }
    }

    private let auth: Auth
    private let firestore: Firestore

    init(auth: Auth = Auth.auth(), firestore: Firestore = Firestore.firestore()) {
        self.auth = auth
        self.firestore = firestore
    }

    func migrateFamily(family: FamilySnapshot, bags: [BagSnapshot], items: [ItemSnapshot]) async throws {
        guard APIConfig.isFirebaseConfigured else {
            throw ClientError.notConfigured
        }

        let uid = try await ensureAnonymousUser()
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60)

        var operations: [FirestoreWriteOperation] = []
        operations.reserveCapacity(3 + bags.count + items.count)

        operations.append(
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
            )
        )

        operations.append(
            FirestoreWriteOperation(
                path: "families/\(family.id)/members/\(uid)",
                data: [
                    "uid": uid,
                    "displayName": "匿名ユーザー",
                    "createdAt": now
                ]
            )
        )

        operations.append(
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
        )

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
