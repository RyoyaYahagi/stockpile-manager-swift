import Foundation

// MARK: - 承認キューの後始末（仕様 5 章）

/// キルスイッチ（書き込み連携スイッチの OFF）と連携解除のときに、
/// 承認待ちのコマンドを破棄する処理。
///
/// - キルスイッチ: キュー全件を `rejected` / `writes_disabled` の結果行にして
///   `unsentResults` へ積む（次回の取り込みで結果ファイルへ書き戻す）。
/// - 連携解除: キューと未送信の結果行を捨てる。結果ファイルには書けないため、
///   履歴に `rejected` / `link_removed` だけ残す。
enum CommandInboxApprovalCoordinator {
  /// 書き込み連携スイッチを OFF にしたときの後始末。
  /// 呼び出し側は先に `CommandWritePermissionSettings.writesEnabled = false` にしておく。
  static func killSwitchTurnedOff(
    store: CommandInboxStore = CommandInboxStore(),
    now: Date = Date()
  ) {
    var state = store.load()
    let queue = state.approvalQueue
    guard !queue.isEmpty else { return }

    let processedAt = CommandInboxDate.string(from: now)
    let message = L10n.string("書き込み連携がオフになったため、承認待ちのコマンドを適用しませんでした")

    let results = queue.map { entry in
      CommandInboxResult(
        commandId: entry.commandId,
        type: entry.type,
        origin: entry.origin,
        status: .rejected,
        reason: .writesDisabled,
        message: message,
        processedAt: processedAt
      )
    }
    state.unsentResults = CommandInboxResultsMerger.merge(
      existing: state.unsentResults ?? [],
      adding: results,
      now: now
    )
    // 新しい順に並べるため、キューの後ろから履歴へ入れる。
    for entry in queue.reversed() {
      state.appendHistory(
        CommandInboxHistoryEntry(
          occurredAt: processedAt,
          origin: entry.origin,
          type: entry.type,
          status: .rejected,
          reason: .writesDisabled,
          message: message
        )
      )
    }
    state.removeAllPendingApprovals()
    try? store.save(state)
  }

  /// Drive のサインアウト・送信先の切り替え・連携そのものの無効化で呼ぶ。
  /// 承認キューと未送信の結果を破棄し、キューにあった分だけ履歴へ `link_removed` を残す。
  static func discardForLinkRemoval(
    store: CommandInboxStore = CommandInboxStore(),
    now: Date = Date()
  ) {
    var state = store.load()
    let queue = state.approvalQueue
    let hasUnsentResults = !(state.unsentResults ?? []).isEmpty
    guard !queue.isEmpty || hasUnsentResults else { return }

    let occurredAt = CommandInboxDate.string(from: now)
    let message = L10n.string("連携を解除したため、承認待ちのコマンドを破棄しました")

    for entry in queue.reversed() {
      state.appendHistory(
        CommandInboxHistoryEntry(
          occurredAt: occurredAt,
          origin: entry.origin,
          type: entry.type,
          status: .rejected,
          reason: .linkRemoved,
          message: message
        )
      )
    }
    state.removeAllPendingApprovals()
    state.unsentResults = nil
    try? store.save(state)
  }
}
