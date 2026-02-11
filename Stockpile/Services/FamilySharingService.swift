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

        let share = try await cloudKitService.createShare(familyInfo: familyInfo)
        _ = try await cloudKitService.createInvite(familyInfo: familyInfo, share: share)

        return share
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
            }
        }
    }
}
