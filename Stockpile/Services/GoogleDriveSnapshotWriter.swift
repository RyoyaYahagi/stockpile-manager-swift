import Foundation
import GoogleSignIn

// MARK: - Google Drive へのスナップショット書き込み（G-03）

/// Drive API の共通処理（`GoogleDriveREST`）を使い、スナップショットを
/// アプリ名フォルダ直下の `snapshot.json` に書くだけの担当。
/// スコープは drive.file のため、ここから見えるのはこのアプリが作ったファイルだけ。
/// 送信タイミングの制御（手動・自動の振り分け）は G-04 が担う。
@MainActor
enum GoogleDriveSnapshotWriter {
  /// フォルダ名はアプリの表示名（CFBundleDisplayName のローカライズ解決値）。
  static var folderName: String { GoogleDriveREST.folderName }
  static let fileName = "snapshot.json"

  /// スナップショットを Drive に保存する。
  /// 401 の場合はトークンを更新してもう1回だけ再試行する（`GoogleDriveREST` が担う）。
  static func upload(data: Data, user: GIDGoogleUser) async throws {
    try await GoogleDriveREST.withUnauthorizedRetry(user: user) { token in
      try await uploadOnce(data: data, accessToken: token)
    }
  }

  private static func uploadOnce(data: Data, accessToken: String) async throws {
    let folderID = try await GoogleDriveREST.ensureFolder(accessToken: accessToken)
    if let fileID = try await GoogleDriveREST.findFile(
      accessToken: accessToken, folderID: folderID, name: fileName)
    {
      try await GoogleDriveREST.replaceContent(
        accessToken: accessToken, fileID: fileID, data: data)
    } else {
      try await GoogleDriveREST.createFile(
        accessToken: accessToken, folderID: folderID, name: fileName, data: data)
    }
  }
}
