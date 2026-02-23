import Foundation
import SwiftData
import FirebaseAuth
import FirebaseFirestore
import Network

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
        guard APIConfig.isFirebaseConfigured else {
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
        guard APIConfig.isFirebaseConfigured else {
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
        for member in family.members {
            member.family = nil
        }
        try modelContext.save()

        guard APIConfig.isFirebaseConfigured else {
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
        guard APIConfig.isFirebaseConfigured else {
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
        guard APIConfig.isFirebaseConfigured else {
            throw SharingError.firebaseNotConfigured
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
        guard APIConfig.isFirebaseConfigured else {
            throw SharingError.firebaseNotConfigured
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
        guard APIConfig.isFirebaseConfigured else {
            throw SharingError.firebaseNotConfigured
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
        let allBags = try modelContext.fetch(FetchDescriptor<Bag>())
        let allItems = try modelContext.fetch(FetchDescriptor<Item>())
        let localFamilyBags = allBags.filter { $0.family?.id == family.id }
        let localFamilyItems = allItems.filter { $0.family?.id == family.id }

        var bagById = Dictionary(
            uniqueKeysWithValues: localFamilyBags.map { ($0.id.uuidString, $0) }
        )
        for remoteBag in remoteBags {
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
        for remoteItem in remoteItems {
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

        let remoteItemIDs = Set(remoteItems.map(\.id))
        for localItem in localFamilyItems where !remoteItemIDs.contains(localItem.id.uuidString) {
            modelContext.delete(localItem)
        }

        let remoteBagIDs = Set(remoteBags.map(\.id))
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
        if let existing = family.members.first(where: { $0.lineUserId == uid }) {
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
                return "Firebase設定が不足しています。GoogleService-Info.plistを確認してください。"
            case .firebaseFailure(let detail):
                return "Firebaseエラー: \(detail)"
            }
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
        guard APIConfig.isFirebaseConfigured else {
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
            bag.family = family
        }

        for item in orphanItems {
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

                    let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedName = (name?.isEmpty == false) ? name! : "収納場所"
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

                    let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedName = (name?.isEmpty == false) ? name! : "備蓄品"
                    let quantity = max(1, self.intValue(from: data["quantity"]) ?? 1)
                    let expiryDate = self.dateValue(from: data["expiryDate"])
                    let bagID = self.stringValue(from: data["bagId"])
                    let locationNote = self.stringValue(from: data["locationNote"])
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
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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
