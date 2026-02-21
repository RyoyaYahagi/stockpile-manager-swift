import Foundation
import SwiftData
import CloudKit

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
        case authenticationFailed
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .firebaseNotConfigured:
                return "Firebase設定が不足しています。Secrets.plistにFirebaseProjectIdとFirebaseWebAPIKeyを設定してください。"
            case .authenticationFailed:
                return "Firebase匿名認証に失敗しました。"
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

        let client = FirebaseRESTClient(
            projectId: APIConfig.firebaseProjectId,
            webAPIKey: APIConfig.firebaseWebAPIKey
        )
        try await client.migrateFamily(
            family: familySnapshot,
            bags: bagSnapshots,
            items: itemSnapshots
        )
    }
}

private struct FirebaseAuthResponse: Decodable {
    let idToken: String
    let localId: String
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

private final class FirebaseRESTClient {
    enum ClientError: LocalizedError {
        case invalidRequest
        case invalidResponse
        case httpError(code: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "Firebase APIリクエストの生成に失敗しました。"
            case .invalidResponse:
                return "Firebase APIレスポンスの解析に失敗しました。"
            case .httpError(let code, let body):
                return "Firebase APIエラー (\(code)): \(body)"
            }
        }
    }

    private let projectId: String
    private let webAPIKey: String
    private let session: URLSession

    init(projectId: String, webAPIKey: String, session: URLSession = .shared) {
        self.projectId = projectId
        self.webAPIKey = webAPIKey
        self.session = session
    }

    func migrateFamily(family: FamilySnapshot, bags: [BagSnapshot], items: [ItemSnapshot]) async throws {
        let auth = try await signInAnonymously()
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60)

        try await upsertDocument(
            path: "families/\(family.id)",
            fields: [
                "id": firestoreString(family.id),
                "name": firestoreString(family.name),
                "inviteCode": firestoreString(family.inviteCode),
                "createdAt": firestoreTimestamp(family.createdAt),
                "lineGroupId": firestoreOptionalString(family.lineGroupId),
                "migratedAt": firestoreTimestamp(now)
            ],
            idToken: auth.idToken
        )

        try await upsertDocument(
            path: "families/\(family.id)/members/\(auth.localId)",
            fields: [
                "uid": firestoreString(auth.localId),
                "displayName": firestoreString("匿名ユーザー"),
                "createdAt": firestoreTimestamp(now)
            ],
            idToken: auth.idToken
        )

        try await upsertDocument(
            path: "invites/\(family.inviteCode)",
            fields: [
                "familyId": firestoreString(family.id),
                "familyName": firestoreString(family.name),
                "inviteCode": firestoreString(family.inviteCode),
                "createdBy": firestoreString(auth.localId),
                "createdAt": firestoreTimestamp(now),
                "expiresAt": firestoreTimestamp(expiresAt)
            ],
            idToken: auth.idToken
        )

        for bag in bags {
            try await upsertDocument(
                path: "families/\(family.id)/bags/\(bag.id)",
                fields: [
                    "id": firestoreString(bag.id),
                    "familyId": firestoreString(family.id),
                    "name": firestoreString(bag.name),
                    "createdAt": firestoreTimestamp(bag.createdAt)
                ],
                idToken: auth.idToken
            )
        }

        for item in items {
            try await upsertDocument(
                path: "families/\(family.id)/items/\(item.id)",
                fields: [
                    "id": firestoreString(item.id),
                    "familyId": firestoreString(family.id),
                    "name": firestoreString(item.name),
                    "quantity": firestoreInt(item.quantity),
                    "expiryDate": firestoreOptionalTimestamp(item.expiryDate),
                    "bagId": firestoreOptionalString(item.bagId),
                    "locationNote": firestoreOptionalString(item.locationNote),
                    "notified30": firestoreBool(item.notified30),
                    "notified7": firestoreBool(item.notified7),
                    "notified1": firestoreBool(item.notified1),
                    "createdAt": firestoreTimestamp(item.createdAt)
                ],
                idToken: auth.idToken
            )
        }
    }

    private func signInAnonymously() async throws -> FirebaseAuthResponse {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(webAPIKey)") else {
            throw ClientError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["returnSecureToken": true],
            options: []
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpError(code: httpResponse.statusCode, body: body)
        }

        return try JSONDecoder().decode(FirebaseAuthResponse.self, from: data)
    }

    private func upsertDocument(path: String, fields: [String: [String: Any]], idToken: String) async throws {
        guard let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/\(path)") else {
            throw ClientError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["fields": fields],
            options: []
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpError(code: httpResponse.statusCode, body: body)
        }
    }
}

private func firestoreString(_ value: String) -> [String: Any] {
    ["stringValue": value]
}

private func firestoreOptionalString(_ value: String?) -> [String: Any] {
    if let value, !value.isEmpty {
        return ["stringValue": value]
    }
    return ["nullValue": NSNull()]
}

private func firestoreInt(_ value: Int) -> [String: Any] {
    ["integerValue": String(value)]
}

private func firestoreBool(_ value: Bool) -> [String: Any] {
    ["booleanValue": value]
}

private func firestoreTimestamp(_ value: Date) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ["timestampValue": formatter.string(from: value)]
}

private func firestoreOptionalTimestamp(_ value: Date?) -> [String: Any] {
    guard let value else {
        return ["nullValue": NSNull()]
    }
    return firestoreTimestamp(value)
}
