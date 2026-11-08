import Foundation

// MARK: - 端末内の状態の保存

/// 受信箱の状態（処理済み commandId・ファイル単位エラーのハッシュ・適用履歴）を
/// Application Support 配下の JSON に保存する。SwiftData の @Model は追加しない（仕様 8 章）。
struct CommandInboxStore: Sendable {
  /// 保存先ファイル（テストでは一時ディレクトリを渡す）
  let fileURL: URL

  init(fileURL: URL = CommandInboxStore.defaultFileURL) {
    self.fileURL = fileURL
  }

  /// 既定の保存先。Application Support/CommandInbox/state.json
  static var defaultFileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return
      base
      .appendingPathComponent("CommandInbox", isDirectory: true)
      .appendingPathComponent("state.json", isDirectory: false)
  }

  /// 保存済みの状態を読む。壊れている・なければ空の状態を返す。
  func load() -> CommandInboxState {
    guard let data = try? Data(contentsOf: fileURL) else {
      return .empty
    }
    return (try? JSONDecoder().decode(CommandInboxState.self, from: data)) ?? .empty
  }

  /// 状態を保存する（一時ファイル経由の原子的な書き込み）。
  func save(_ state: CommandInboxState) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(state)
    try data.write(to: fileURL, options: .atomic)
  }
}
