import Foundation

// MARK: - 受信箱の読み書き先

/// コマンド受信箱の読み書き先を抽象化したもの。
/// W-01 は Google Drive 実装だけを持つ。W-06 で Worker（カスタム URL）実装を足す。
/// GIDGoogleUser を扱う Drive 実装に合わせて MainActor に寄せている。
@MainActor
protocol CommandInboxTransport {
  /// 受信箱のファイルを用意する（存在するファイルは書き換えない）。
  /// drive.file ではアプリが作ったファイルしか読めないため、初回にアプリが作る必要がある。
  func ensureFiles() async throws

  /// commands.json を読む。ファイルがなければ nil。
  func readCommands() async throws -> Data?

  /// command-results.json を読む。ファイルがなければ nil。
  func readResults() async throws -> Data?

  /// command-results.json を書く。
  func writeResults(_ data: Data) async throws
}
