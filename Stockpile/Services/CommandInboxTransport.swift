import Foundation

// MARK: - 受信箱の読み書き先

/// コマンド受信箱の読み書き先を抽象化したもの。
/// Google Drive と Worker（カスタム URL）の実装を持つ。
/// GIDGoogleUser を扱う Drive 実装に合わせて MainActor に寄せている。
@MainActor
protocol CommandInboxTransport {
  /// 受信箱のファイルを用意する（存在するファイルは書き換えない）。
  /// drive.file ではアプリが作ったファイルしか読めないため、Drive では初回に
  /// アプリが作る必要がある。Worker は未保存でも GET が初期内容を返すため何もしない。
  func ensureFiles() async throws

  /// commands.json を読む。ファイルがなければ nil。
  func readCommands() async throws -> Data?

  /// command-results.json を読む。ファイルがなければ nil。
  func readResults() async throws -> Data?

  /// command-results.json を書く。
  func writeResults(_ data: Data) async throws
}
