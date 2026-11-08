import Foundation

// MARK: - コマンドの処理結果（ハンドラの戻り値）

/// 1 コマンドを処理した結果。受信箱はこれをそのまま結果ファイルの行にする。
struct CommandInboxHandlingResult: Equatable, Sendable {
  var status: CommandInboxStatus
  var reason: CommandInboxReason?
  var message: String?
  var itemId: String?

  static func applied(message: String? = nil, itemId: String? = nil) -> Self {
    CommandInboxHandlingResult(status: .applied, message: message, itemId: itemId)
  }

  static func rejected(reason: CommandInboxReason, message: String) -> Self {
    CommandInboxHandlingResult(status: .rejected, reason: reason, message: message)
  }

  static func conflict(message: String) -> Self {
    CommandInboxHandlingResult(status: .conflict, reason: .staleBase, message: message)
  }

  static func pendingApproval(reason: CommandInboxReason, message: String) -> Self {
    CommandInboxHandlingResult(status: .pendingApproval, reason: reason, message: message)
  }

  static func failed(message: String) -> Self {
    CommandInboxHandlingResult(status: .error, reason: .internalError, message: message)
  }
}

// MARK: - 差し替え口

/// 検証・処理済み判定・失効判定を通ったコマンドを受け取り、適用可否を決める処理部。
///
/// - W-01（本 Issue）の既定実装は `WritesDisabledCommandHandler`。
///   権限判定がまだないため、既知の type はすべて `rejected` / `writes_disabled` を返す。
/// - W-02 は権限判定（書き込み連携スイッチ・能力ごとの設定・承認キュー）を、
///   W-03 以降は実際のデータ適用をこのプロトコルの実装として足す。
///   受信箱の処理ループは `CommandInboxService` にハンドラを注入して差し替える。
protocol CommandHandler: Sendable {
  /// - Parameters:
  ///   - command: 検証済みの封筒。payload は `CommandJSONValue` で保持している。
  ///   - now: 処理時刻（テストで注入できるように引数で受け取る）
  func handle(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult
}

/// 書き込み連携が無効なときの既定ハンドラ（仕様 5 章の既定状態）。
/// データには一切触れず、すべてのコマンドを `rejected` / `writes_disabled` にする。
struct WritesDisabledCommandHandler: CommandHandler {
  func handle(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult {
    .rejected(
      reason: .writesDisabled,
      message: L10n.string("書き込み連携がオフのため、このコマンドは適用していません")
    )
  }
}
