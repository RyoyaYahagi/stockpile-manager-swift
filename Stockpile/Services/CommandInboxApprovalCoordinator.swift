import Foundation

// MARK: - 承認キューの処理結果

/// 承認待ちの並びを解決した結果。
struct CommandInboxQueueResolution {
  /// まだ承認待ちとして残す項目（元の順序を保つ）
  var remaining: [CommandInboxPendingApproval]
  /// 新しく確定した結果行（失効・却下・適用など）
  var results: [CommandInboxResult]
  /// 適用した件数（スナップショット送信の判断に使う）
  var appliedCount: Int
}

/// 承認画面での操作や取り込み時の失効処理の結果。
struct CommandInboxApprovalOutcome {
  var state: CommandInboxState
  var results: [CommandInboxResult]
  var appliedCount: Int

  static func unchanged(_ state: CommandInboxState) -> Self {
    CommandInboxApprovalOutcome(state: state, results: [], appliedCount: 0)
  }
}

// MARK: - 承認キューの処理（仕様 7 章）

/// 承認キュー（W-04）の許可・却下・失効と、順序の保持のための待機解除。
///
/// キューは古い順に並んでいる。同じ対象を指す先行のコマンドが残っている間は、
/// 後続を「先のコマンド待ち」として残す。先行が許可・却下・失効で片付いたときだけ、
/// 待っていた項目を先頭から権限判定し直す。権限設定を「承認制」から変えただけでは
/// 既存のキューを自動処理しない（利用者の操作を待つ）。
enum CommandInboxApprovalCoordinator {
  // MARK: キュー全体の解決（失効・待機解除）

  /// キューを古い順に見て、失効した項目を取り除き、待機が解けた項目だけを
  /// 権限判定し直す。
  ///
  /// - Parameter previousQueue: 操作の直前のキュー。ここから「待っていた項目」を求める。
  ///   許可・却下で 1 件外した後は、外す前のキューを渡すことで、
  ///   その項目待ちだった後続が対象になる。
  static func resolveQueue(
    _ queue: [CommandInboxPendingApproval],
    previousQueue: [CommandInboxPendingApproval],
    handler: any CommandHandler,
    now: Date
  ) async -> CommandInboxQueueResolution {
    let waitingCommandIds = Set(
      previousQueue
        .filter { CommandInboxTargetKey.isWaitingForEarlier($0, in: previousQueue) }
        .map { $0.commandId.uppercased() }
    )

    var remaining: [CommandInboxPendingApproval] = []
    var results: [CommandInboxResult] = []
    var appliedCount = 0

    for entry in queue {
      guard let envelope = entry.envelope else {
        results.append(result(entry, status: .error, reason: .internalError, now: now))
        continue
      }

      // 承認待ちのまま 7 日を超えたものは失効させる。
      if now.timeIntervalSince(envelope.issuedAt) > CommandInboxConstants.expiryInterval {
        results.append(result(entry, status: .expired, reason: .expired, now: now))
        continue
      }

      // まだ同じ対象の先行がキューに残っていれば待ち続ける。
      if remaining.contains(where: { CommandInboxTargetKey.overlaps($0, entry) }) {
        remaining.append(entry)
        continue
      }

      // 待機が解けた項目だけ権限判定からやり直す。
      // 待っていなかった承認待ちは、権限設定が変わっても自動処理しない。
      guard waitingCommandIds.contains(entry.commandId.uppercased()) else {
        remaining.append(entry)
        continue
      }

      let handled = await handler.handle(envelope, now: now)
      if handled.status == .pendingApproval {
        // 承認制のままなら、待ち理由を approval_required に更新して残す。
        remaining.append(entry)
        results.append(
          result(
            entry,
            status: handled.status,
            reason: handled.reason ?? .approvalRequired,
            message: handled.message,
            now: now
          )
        )
      } else {
        results.append(
          result(
            entry,
            status: handled.status,
            reason: handled.reason,
            message: handled.message,
            itemId: handled.itemId,
            now: now
          )
        )
        if handled.status == .applied {
          appliedCount += 1
        }
      }
    }

    return CommandInboxQueueResolution(
      remaining: remaining,
      results: results,
      appliedCount: appliedCount
    )
  }

  // MARK: 許可・却下

  /// 承認画面で「許可」されたコマンドを適用する。
  /// 承認済みなので能力別の権限は見直さず、書き込み連携スイッチだけを確認する。
  static func approve(
    commandId: String,
    store: CommandInboxStore,
    applier: any CommandApplier,
    handler: any CommandHandler,
    policy: CommandWritePermissionPolicy,
    now: Date
  ) async -> CommandInboxApprovalOutcome {
    var state = store.load()
    let previousQueue = state.approvalQueue
    guard
      let index = previousQueue.firstIndex(where: {
        $0.commandId.caseInsensitiveCompare(commandId) == .orderedSame
      })
    else {
      return .unchanged(state)
    }

    let entry = previousQueue[index]
    // 同じ対象の先行が残っている間は、画面と同じく許可できない（順序の保持）。
    guard !CommandInboxTargetKey.isWaitingForEarlier(entry, in: previousQueue) else {
      return .unchanged(state)
    }

    var queue = previousQueue
    queue.remove(at: index)

    var results: [CommandInboxResult] = []
    var appliedCount = 0

    if !policy.writesEnabled {
      results.append(result(entry, status: .rejected, reason: .writesDisabled, now: now))
    } else if let envelope = entry.envelope {
      // 適用時に検証・競合判定をやり直す（ItemCommandApplier が行う）。
      let handled = await applier.apply(envelope, now: now)
      results.append(
        result(
          entry,
          status: handled.status,
          reason: handled.reason,
          message: handled.message,
          itemId: handled.itemId,
          now: now
        )
      )
      if handled.status == .applied {
        appliedCount += 1
      }
    } else {
      results.append(result(entry, status: .error, reason: .internalError, now: now))
    }

    let resolution = await resolveQueue(
      queue, previousQueue: previousQueue, handler: handler, now: now)
    results.append(contentsOf: resolution.results)
    appliedCount += resolution.appliedCount

    commit(
      state: &state,
      remaining: resolution.remaining,
      results: results,
      now: now
    )
    try? store.save(state)

    return CommandInboxApprovalOutcome(
      state: state,
      results: results,
      appliedCount: appliedCount
    )
  }

  /// 承認画面で「却下」されたコマンドを `rejected` / `denied_by_user` にする。
  static func deny(
    commandId: String,
    store: CommandInboxStore,
    handler: any CommandHandler,
    now: Date
  ) async -> CommandInboxApprovalOutcome {
    var state = store.load()
    let previousQueue = state.approvalQueue
    guard
      let index = previousQueue.firstIndex(where: {
        $0.commandId.caseInsensitiveCompare(commandId) == .orderedSame
      })
    else {
      return .unchanged(state)
    }

    let entry = previousQueue[index]
    // 先のコマンドが片付くまでは却下できない（順序の保持）。
    guard !CommandInboxTargetKey.isWaitingForEarlier(entry, in: previousQueue) else {
      return .unchanged(state)
    }

    var queue = previousQueue
    queue.remove(at: index)

    var results = [
      result(entry, status: .rejected, reason: .deniedByUser, now: now)
    ]
    let resolution = await resolveQueue(
      queue, previousQueue: previousQueue, handler: handler, now: now)
    results.append(contentsOf: resolution.results)

    commit(
      state: &state,
      remaining: resolution.remaining,
      results: results,
      now: now
    )
    try? store.save(state)

    return CommandInboxApprovalOutcome(
      state: state,
      results: results,
      appliedCount: resolution.appliedCount
    )
  }

  /// 承認画面を開いたときと取り込み時に呼ぶ。失効と待機解除だけを行う。
  static func resolvePendingApprovals(
    store: CommandInboxStore,
    handler: any CommandHandler,
    now: Date
  ) async -> CommandInboxApprovalOutcome {
    var state = store.load()
    let queue = state.approvalQueue
    guard !queue.isEmpty else {
      return .unchanged(state)
    }

    let resolution = await resolveQueue(
      queue, previousQueue: queue, handler: handler, now: now)
    guard !resolution.results.isEmpty else {
      return .unchanged(state)
    }

    commit(
      state: &state,
      remaining: resolution.remaining,
      results: resolution.results,
      now: now
    )
    try? store.save(state)

    return CommandInboxApprovalOutcome(
      state: state,
      results: resolution.results,
      appliedCount: resolution.appliedCount
    )
  }

  // MARK: 結果と履歴の記録

  private static func commit(
    state: inout CommandInboxState,
    remaining: [CommandInboxPendingApproval],
    results: [CommandInboxResult],
    now: Date
  ) {
    state.pendingApprovals = remaining.isEmpty ? nil : remaining
    state.unsentResults = CommandInboxResultsMerger.merge(
      existing: state.unsentResults ?? [],
      adding: results,
      now: now
    )
    for entry in results {
      state.appendHistory(
        CommandInboxHistoryEntry(
          occurredAt: entry.processedAt,
          origin: entry.origin,
          type: entry.type,
          status: entry.status,
          reason: entry.reason,
          message: entry.message
        )
      )
    }
  }

  private static func result(
    _ entry: CommandInboxPendingApproval,
    status: CommandInboxStatus,
    reason: CommandInboxReason?,
    message: String? = nil,
    itemId: String? = nil,
    now: Date
  ) -> CommandInboxResult {
    CommandInboxResult(
      commandId: entry.commandId,
      type: entry.type,
      origin: entry.origin,
      status: status,
      reason: reason,
      message: message ?? CommandInboxProcessor.message(for: status, reason: reason),
      itemId: itemId,
      processedAt: CommandInboxDate.string(from: now)
    )
  }

  // MARK: キルスイッチ・連携解除（仕様 5 章）

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
