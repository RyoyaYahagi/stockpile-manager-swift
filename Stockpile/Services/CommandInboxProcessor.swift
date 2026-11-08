import Foundation

// MARK: - 結果のマージ

/// command-results.json のマージ規則（仕様 6 章）。
/// 1 commandId 1 行・直近 200 件・30 日以内・新しい順。
enum CommandInboxResultsMerger {
  /// 既存の結果に新しい結果を重ね、保持上限に切り詰めた配列を返す。
  /// 同じ commandId は新しい行で置き換える（`pending_approval` の解決も同じ経路で行える）。
  static func merge(
    existing: [CommandInboxResult],
    adding: [CommandInboxResult],
    now: Date
  ) -> [CommandInboxResult] {
    var byCommandId: [String: CommandInboxResult] = [:]
    var fileLevel: CommandInboxResult?

    for entry in existing + adding {
      if let commandId = entry.commandId,
        !commandId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let key = commandId.uppercased()
        if let current = byCommandId[key] {
          if isNewer(entry, than: current) {
            byCommandId[key] = entry
          }
        } else {
          byCommandId[key] = entry
        }
      } else if let current = fileLevel {
        if isNewer(entry, than: current) {
          fileLevel = entry
        }
      } else {
        fileLevel = entry
      }
    }

    let retentionLimit = now.addingTimeInterval(-CommandInboxConstants.retentionInterval)
    var results = byCommandId.values.filter { entry in
      guard let date = CommandInboxDate.parse(entry.processedAt) else { return false }
      return date >= retentionLimit
    }
    if let fileLevel,
      let date = CommandInboxDate.parse(fileLevel.processedAt),
      date >= retentionLimit
    {
      results.append(fileLevel)
    }

    results.sort { left, right in
      let leftDate = CommandInboxDate.parse(left.processedAt) ?? .distantPast
      let rightDate = CommandInboxDate.parse(right.processedAt) ?? .distantPast
      if leftDate == rightDate {
        return (left.commandId ?? "") < (right.commandId ?? "")
      }
      return leftDate > rightDate
    }

    if results.count > CommandInboxConstants.maxResults {
      results.removeLast(results.count - CommandInboxConstants.maxResults)
    }
    return results
  }

  private static func isNewer(_ left: CommandInboxResult, than right: CommandInboxResult) -> Bool {
    let leftDate = CommandInboxDate.parse(left.processedAt) ?? .distantPast
    let rightDate = CommandInboxDate.parse(right.processedAt) ?? .distantPast
    return leftDate >= rightDate
  }
}

// MARK: - 処理ループの出力

struct CommandInboxProcessingOutput: Sendable {
  /// 書き戻す結果ファイル
  let results: CommandInboxResultsFile
  /// 更新後の端末内の状態
  let state: CommandInboxState
  /// 結果ファイルの中身が変わったか（変わらなければ書き戻さない）
  let resultsChanged: Bool
  /// 適用した件数（1 件以上ならスナップショット送信のきっかけにする）
  let appliedCount: Int
  /// 今回の実行で結果を返したコマンド数
  let handledCount: Int
}

// MARK: - 処理ループ

/// 「検証 → 処理済み判定 → 失効判定 → 権限判定 → 適用」を順に行う純粋な処理。
/// ネットワーク・SwiftData には触れず、時刻とハンドラを外から受け取る。
enum CommandInboxProcessor {
  static func process(
    commandsData: Data,
    existingResults: CommandInboxResultsFile?,
    state initialState: CommandInboxState,
    now: Date,
    handler: any CommandHandler
  ) async -> CommandInboxProcessingOutput {
    var state = initialState
    state.prune(now: now)

    let existingEntries = existingResults?.results ?? []
    let processedAt = CommandInboxDate.string(from: now)
    let alreadyHandled = Set(
      existingEntries
        .filter { $0.status != .pendingApproval }
        .compactMap { $0.commandId?.uppercased() }
    )

    var newEntries: [CommandInboxResult] = []
    var appliedCount = 0

    func record(_ entry: CommandInboxResult, historyFor raw: CommandInboxRawCommand?) {
      newEntries.append(entry)
      if entry.status == .applied {
        appliedCount += 1
      }
      state.appendHistory(
        CommandInboxHistoryEntry(
          occurredAt: entry.processedAt,
          origin: entry.origin ?? raw?.fields?["origin"]?.stringValue,
          type: entry.type ?? raw?.fields?["type"]?.stringValue,
          status: entry.status,
          reason: entry.reason,
          message: entry.message
        )
      )
    }

    switch CommandInboxParser.parseCommandsFile(commandsData) {
    case .fileError(let reason, let dedupeHash):
      if !state.hasRecordedFileError(hash: dedupeHash) {
        // ファイル単位のエラーは 1 行だけ残す（過去のファイル単位エラーは置き換える）
        let entry = CommandInboxResult(
          commandId: nil,
          status: .invalid,
          reason: reason,
          message: message(for: .invalid, reason: reason),
          processedAt: processedAt
        )
        record(entry, historyFor: nil)
        state.recordFileError(hash: dedupeHash, at: now)
      }

    case .commands(let rawCommands):
      for raw in rawCommands {
        let key = CommandInboxParser.dedupeKey(for: raw)
        // 処理済み判定: 端末内の記録と、結果ファイルの最終状態の両方を見る
        if state.isProcessed(key) || alreadyHandled.contains(key) {
          continue
        }
        guard let envelope = CommandInboxParser.parseEnvelope(raw) else {
          record(
            invalidResult(for: raw, reason: .invalidEnvelope, processedAt: processedAt),
            historyFor: raw
          )
          state.markProcessed(key, at: now)
          continue
        }
        guard envelope.commandType != nil else {
          record(
            result(
              for: envelope,
              status: .unsupported,
              reason: .unknownType,
              processedAt: processedAt
            ),
            historyFor: raw
          )
          state.markProcessed(key, at: now)
          continue
        }

        // 検証（payload）
        guard CommandInboxPayloadValidator.validate(envelope) else {
          record(
            result(
              for: envelope,
              status: .invalid,
              reason: .invalidPayload,
              processedAt: processedAt
            ),
            historyFor: raw
          )
          state.markProcessed(key, at: now)
          continue
        }

        // 失効判定: 発行から 7 日を超えていれば適用しない（ちょうど 7 日は失効しない）
        if now.timeIntervalSince(envelope.issuedAt) > CommandInboxConstants.expiryInterval {
          record(
            result(for: envelope, status: .expired, reason: .expired, processedAt: processedAt),
            historyFor: raw
          )
          state.markProcessed(key, at: now)
          continue
        }

        // 適用可否はハンドラが決める（W-02 で能力ごとの判定に使う）
        let handled = await handler.handle(envelope, now: now)
        // 承認制: データには触れず、封筒をキューへ入れる（仕様 7 章）。
        // キューの一覧・許可・却下・順序保持は W-04 が担う。
        if handled.status == .pendingApproval,
          (handled.reason == .approvalRequired || handled.reason == .waitingForEarlier)
        {
          state.enqueueApproval(envelope, at: now)
        }
        record(
          result(
            for: envelope,
            status: handled.status,
            reason: handled.reason,
            message: handled.message,
            itemId: handled.itemId,
            processedAt: processedAt
          ),
          historyFor: raw
        )
        // 承認待ちも「処理済み」として記録する（キューの管理は W-04）。
        // 結果ファイル側は pending_approval を処理済みとみなさないため、別端末では再評価される。
        state.markProcessed(key, at: now)
      }
    }

    let merged = CommandInboxResultsMerger.merge(
      existing: existingEntries, adding: newEntries, now: now)
    let resultsChanged = merged != existingEntries
    let resultsFile = CommandInboxResultsFile(results: merged, updatedAt: processedAt)

    return CommandInboxProcessingOutput(
      results: resultsFile,
      state: state,
      resultsChanged: resultsChanged,
      appliedCount: appliedCount,
      handledCount: newEntries.count
    )
  }

  // MARK: 結果行の組み立て

  private static func result(
    for envelope: CommandInboxEnvelope,
    status: CommandInboxStatus,
    reason: CommandInboxReason?,
    message: String? = nil,
    itemId: String? = nil,
    processedAt: String
  ) -> CommandInboxResult {
    CommandInboxResult(
      commandId: envelope.commandId,
      type: envelope.type,
      origin: envelope.origin,
      status: status,
      reason: reason,
      message: message ?? Self.message(for: status, reason: reason),
      itemId: itemId,
      processedAt: processedAt
    )
  }

  private static func invalidResult(
    for raw: CommandInboxRawCommand,
    reason: CommandInboxReason,
    processedAt: String
  ) -> CommandInboxResult {
    CommandInboxResult(
      commandId: CommandInboxParser.resultCommandId(for: raw),
      type: raw.fields?["type"]?.stringValue,
      origin: raw.fields?["origin"]?.stringValue,
      status: .invalid,
      reason: reason,
      message: message(for: .invalid, reason: reason),
      processedAt: processedAt
    )
  }

  /// 画面や履歴に出す既定の日本語メッセージ。ハンドラが message を返したらそちらを優先する。
  static func message(for status: CommandInboxStatus, reason: CommandInboxReason?) -> String {
    switch (status, reason) {
    case (.applied, _):
      return L10n.string("コマンドを適用しました")
    case (.conflict, _):
      return L10n.string("アプリ側で先に変更されていたため、適用しませんでした")
    case (.expired, _):
      return L10n.string("発行から7日を超えたため、失効しました")
    case (.invalid, .malformedFile):
      return L10n.string("コマンドファイルを読み取れませんでした")
    case (.invalid, .tooManyCommands):
      return L10n.string("コマンドが多すぎるため、読み取りませんでした")
    case (.invalid, .invalidPayload):
      return L10n.string("コマンドの内容が正しくないため、適用しませんでした")
    case (.invalid, _):
      return L10n.string("コマンドの形式が正しくないため、適用しませんでした")
    case (.unsupported, _):
      return L10n.string("対応していない種類のコマンドのため、適用しませんでした")
    case (.rejected, .writesDisabled):
      return L10n.string("書き込み連携がオフのため、このコマンドは適用していません")
    case (.rejected, .permissionDenied):
      return L10n.string("この操作は許可されていないため、適用しませんでした")
    case (.pendingApproval, _):
      return L10n.string("承認待ちです")
    case (.error, _):
      return L10n.string("内部エラーのため、適用できませんでした")
    case (.rejected, _):
      return L10n.string("このコマンドは適用しませんでした")
    }
  }
}
