import Foundation
import CloudKit

/// CloudKit共有サービス
/// パブリックデータベースでの招待コード管理とCKShareによる家族データ共有
final class CloudKitSharingService: @unchecked Sendable {
    private let container: CKContainer
    private let publicDatabase: CKDatabase
    private let privateDatabase: CKDatabase

    /// 招待レコードのタイプ名
    private static let inviteRecordType = "FamilyInvite"

    /// 招待コードの有効期限（24時間）
    private static let inviteExpiration: TimeInterval = 24 * 60 * 60
    
    /// CloudKitコンテナID（Info.plistに明示設定されている場合のみ使用）
    private static var configuredContainerIdentifier: String? {
        guard let rawIdentifier = Bundle.main.object(forInfoDictionaryKey: "CK_CONTAINER_IDENTIFIER") as? String else {
            return nil
        }
        
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            return nil
        }
        
        // ビルド設定が未展開の文字列や不正値を除外して、起動時クラッシュを回避する
        guard !identifier.contains("$("), identifier.hasPrefix("iCloud.") else {
            return nil
        }
        
        return identifier
    }

    init() {
        if let containerIdentifier = Self.configuredContainerIdentifier {
            self.container = CKContainer(identifier: containerIdentifier)
        } else {
            self.container = CKContainer.default()
        }
        self.publicDatabase = container.publicCloudDatabase
        self.privateDatabase = container.privateCloudDatabase
    }

    /// 招待コードをパブリックデータベースに登録
    func createInvite(familyInfo: FamilyInfo, share: CKShare) async throws -> String {
        let record = CKRecord(recordType: Self.inviteRecordType)
        record["inviteCode"] = familyInfo.inviteCode
        record["familyName"] = familyInfo.name
        record["familyId"] = familyInfo.id.uuidString
        record["shareURL"] = share.url?.absoluteString ?? ""
        record["createdAt"] = Date()
        record["expiresAt"] = Date().addingTimeInterval(Self.inviteExpiration)

        if let userRecordID = try? await container.userRecordID() {
            record["ownerRecordID"] = userRecordID.recordName
        }

        try await publicDatabase.save(record)
        return familyInfo.inviteCode
    }

    /// 招待コードを更新（期限延長）
    func refreshInvite(familyId: UUID) async throws {
        let predicate = NSPredicate(format: "familyId == %@", familyId.uuidString)
        let query = CKQuery(recordType: Self.inviteRecordType, predicate: predicate)

        let (results, _) = try await publicDatabase.records(matching: query)

        for (_, result) in results {
            if case .success(let record) = result {
                record["expiresAt"] = Date().addingTimeInterval(Self.inviteExpiration)
                try await publicDatabase.save(record)
            }
        }
    }

    /// 招待コードで招待情報を検索
    func findInvite(byCode code: String) async throws -> InviteInfo? {
        let normalizedCode = code.uppercased()
        let predicate = NSPredicate(format: "inviteCode == %@", normalizedCode)
        let query = CKQuery(recordType: Self.inviteRecordType, predicate: predicate)

        let (results, _) = try await publicDatabase.records(matching: query)

        for (_, result) in results {
            if case .success(let record) = result,
               let expiresAt = record["expiresAt"] as? Date,
               expiresAt > Date() {
                return InviteInfo(
                    inviteCode: record["inviteCode"] as? String ?? "",
                    familyName: record["familyName"] as? String ?? "",
                    familyId: record["familyId"] as? String ?? "",
                    shareURLString: record["shareURL"] as? String ?? "",
                    expiresAt: expiresAt
                )
            }
        }

        return nil
    }

    /// 期限切れの招待を削除
    func deleteExpiredInvites() async throws {
        let predicate = NSPredicate(format: "expiresAt < %@", Date() as NSDate)
        let query = CKQuery(recordType: Self.inviteRecordType, predicate: predicate)

        let (results, _) = try await publicDatabase.records(matching: query)

        for (recordID, _) in results {
            try await publicDatabase.deleteRecord(withID: recordID)
        }
    }

    /// 家族の招待を削除
    func deleteInvite(familyId: UUID) async throws {
        let predicate = NSPredicate(format: "familyId == %@", familyId.uuidString)
        let query = CKQuery(recordType: Self.inviteRecordType, predicate: predicate)

        let (results, _) = try await publicDatabase.records(matching: query)

        for (recordID, _) in results {
            try await publicDatabase.deleteRecord(withID: recordID)
        }
    }

    /// 家族データのCKShareを作成
    func createShare(familyInfo: FamilyInfo) async throws -> CKShare {
        let familyRecordID = CKRecord.ID(recordName: familyInfo.id.uuidString)

        let familyRecord: CKRecord
        do {
            familyRecord = try await privateDatabase.record(for: familyRecordID)
        } catch {
            let newRecord = CKRecord(recordType: "Family", recordID: familyRecordID)
            newRecord["name"] = familyInfo.name
            newRecord["inviteCode"] = familyInfo.inviteCode
            newRecord["createdAt"] = familyInfo.createdAt
            familyRecord = try await privateDatabase.save(newRecord)
        }

        let share = CKShare(rootRecord: familyRecord)
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = familyInfo.name

        let modifyOperation = CKModifyRecordsOperation(
            recordsToSave: [familyRecord, share],
            recordIDsToDelete: nil
        )
        modifyOperation.savePolicy = .changedKeys

        return try await withCheckedThrowingContinuation { continuation in
            modifyOperation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: share)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            privateDatabase.add(modifyOperation)
        }
    }

    /// 共有URLからCKShareメタデータを取得
    func fetchShareMetadata(from url: URL) async throws -> CKShare.Metadata {
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])

            operation.perShareMetadataResultBlock = { _, result in
                switch result {
                case .success(let metadata):
                    continuation.resume(returning: metadata)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            container.add(operation)
        }
    }

    /// 共有を承諾
    func acceptShare(metadata: CKShare.Metadata) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])

            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            container.add(operation)
        }
    }

    /// 現在のユーザーのiCloudアカウント状態を確認
    func checkAccountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    struct FamilyInfo: Sendable {
        let id: UUID
        let name: String
        let inviteCode: String
        let createdAt: Date
    }

    struct InviteInfo: Sendable {
        let inviteCode: String
        let familyName: String
        let familyId: String
        let shareURLString: String
        let expiresAt: Date

        var shareURL: URL? {
            URL(string: shareURLString)
        }

        var isExpired: Bool {
            expiresAt < Date()
        }
    }

    enum SharingError: LocalizedError {
        case notSignedIn
        case inviteNotFound
        case inviteExpired
        case invalidShareURL

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "iCloudにサインインしてください"
            case .inviteNotFound:
                return "招待コードが見つかりません"
            case .inviteExpired:
                return "招待コードの有効期限が切れています"
            case .invalidShareURL:
                return "共有URLが無効です"
            }
        }
    }
}
