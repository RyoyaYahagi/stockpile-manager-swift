import Foundation
import GoogleSignIn

// MARK: - Google Drive 実装

/// アプリ名フォルダ直下の `commands.json` / `command-results.json` を読み書きする。
/// 参照するのはこのアプリが作ったファイルだけ（drive.file）。
/// `commands.json` は作成時以外に書き換えない（Muse の書き込みと競合させないため）。
@MainActor
final class GoogleDriveCommandInboxTransport: CommandInboxTransport {
  private let user: GIDGoogleUser
  private var cachedFolderID: String?

  init(user: GIDGoogleUser) {
    self.user = user
  }

  func ensureFiles() async throws {
    try await GoogleDriveREST.withUnauthorizedRetry(user: user) { token in
      let folderID = try await resolvedFolderID(accessToken: token)
      try await createIfMissing(
        named: CommandInboxConstants.commandsFileName,
        folderID: folderID,
        accessToken: token,
        data: CommandInboxParser.emptyCommandsData()
      )
      try await createIfMissing(
        named: CommandInboxConstants.resultsFileName,
        folderID: folderID,
        accessToken: token,
        data: CommandInboxParser.emptyResultsData()
      )
    }
  }

  func readCommands() async throws -> Data? {
    try await readFile(named: CommandInboxConstants.commandsFileName)
  }

  func readResults() async throws -> Data? {
    try await readFile(named: CommandInboxConstants.resultsFileName)
  }

  func writeResults(_ data: Data) async throws {
    try await GoogleDriveREST.withUnauthorizedRetry(user: user) { token in
      let folderID = try await resolvedFolderID(accessToken: token)
      if let fileID = try await GoogleDriveREST.findFile(
        accessToken: token,
        folderID: folderID,
        name: CommandInboxConstants.resultsFileName
      ) {
        try await GoogleDriveREST.replaceContent(
          accessToken: token, fileID: fileID, data: data)
      } else {
        try await GoogleDriveREST.createFile(
          accessToken: token,
          folderID: folderID,
          name: CommandInboxConstants.resultsFileName,
          data: data
        )
      }
    }
  }

  // MARK: 内部

  private func resolvedFolderID(accessToken: String) async throws -> String {
    if let cachedFolderID {
      return cachedFolderID
    }
    let id = try await GoogleDriveREST.ensureFolder(accessToken: accessToken)
    cachedFolderID = id
    return id
  }

  private func readFile(named name: String) async throws -> Data? {
    try await GoogleDriveREST.withUnauthorizedRetry(user: user) { token in
      let folderID = try await resolvedFolderID(accessToken: token)
      guard
        let fileID = try await GoogleDriveREST.findFile(
          accessToken: token, folderID: folderID, name: name)
      else {
        return nil
      }
      return try await GoogleDriveREST.downloadFile(accessToken: token, fileID: fileID)
    }
  }

  private func createIfMissing(
    named name: String,
    folderID: String,
    accessToken: String,
    data: Data
  ) async throws {
    guard
      try await GoogleDriveREST.findFile(
        accessToken: accessToken, folderID: folderID, name: name) == nil
    else {
      return
    }
    try await GoogleDriveREST.createFile(
      accessToken: accessToken, folderID: folderID, name: name, data: data)
  }
}

// MARK: - サインイン完了時のファイル作成

/// Drive 連携のサインイン完了時に、受信箱の 2 ファイルを作る（仕様 2 章）。
/// 失敗してもサインイン自体は成功として扱う（次の取り込み時に作り直す）。
@MainActor
enum CommandInboxFileBootstrap {
  static func ensureFiles(for user: GIDGoogleUser) async {
    do {
      try await GoogleDriveCommandInboxTransport(user: user).ensureFiles()
    } catch {
      // 通信エラー等は次の取り込み時に再試行する
    }
  }
}
