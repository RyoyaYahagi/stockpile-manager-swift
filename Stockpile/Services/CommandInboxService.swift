import Foundation
import GoogleSignIn
import SwiftData

// MARK: - 受信箱の取り込み（W-01）

/// 起動時・フォアグラウンド復帰時・スナップショット送信成功後に呼ばれる取り込み処理。
/// 連携が有効・送信先が Google Drive・サインイン済みのときだけ動き、
/// 同時に 2 つ以上の取り込みを走らせない（仕様 1 章）。
@MainActor
final class CommandInboxService {
  static let shared = CommandInboxService()

  struct RunOutcome {
    /// 取り込みを実行したか（前提条件を満たさない・実行中は false）
    var didRun: Bool
    /// 適用したコマンド数（1 件以上ならスナップショット送信のきっかけにする）
    var appliedCount: Int
    /// 結果ファイルを書き戻したか
    var wroteResults: Bool
    /// 通信・保存の失敗（画面には出さず、次の機会に再試行する）
    var errorMessage: String?

    static let skipped = RunOutcome(
      didRun: false, appliedCount: 0, wroteResults: false, errorMessage: nil)
  }

  struct ApprovalQueueRefresh {
    var queue: [CommandInboxPendingApproval]
    /// 失効・待機解除・取り込みで適用した件数（1 件以上ならスナップショットを送る）
    var appliedCount: Int
  }

  private let store: CommandInboxStore
  private var handler: any CommandHandler
  /// 承認画面から直接適用するときに使う。`configure(modelContext:)` で差し替える。
  private var applier: any CommandApplier
  private let now: () -> Date
  /// 取り込み・承認・却下のうち、状態ファイルを読み書きする処理を 1 つに絞る。
  private var isRunning = false
  /// 実行中の処理が終わるのを待っている呼び出し（承認画面の操作）。
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  /// `configure(modelContext:)` か、テストからのハンドラ注入で適用処理が決まっているか。
  private var handlerIsConfigured: Bool

  init(
    store: CommandInboxStore = CommandInboxStore(),
    handler: (any CommandHandler)? = nil,
    applier: any CommandApplier = UnavailableCommandApplier(),
    now: @escaping () -> Date = Date.init
  ) {
    self.store = store
    self.handler = handler ?? PermissionedCommandHandler()
    self.handlerIsConfigured = handler != nil
    self.applier = applier
    self.now = now
  }

  /// 取り込みを始められる状態か。
  ///
  /// 適用処理が未設定のまま取り込むと、権限が「許可」のコマンドを
  /// `UnavailableCommandApplier` が「この版ではまだ適用できません」として
  /// 処理済みにしてしまう。バックグラウンド起動で `configure` が呼ばれない
  /// 場合にそれを防ぐため、前提条件として判定する。
  nonisolated static func canProcess(handlerConfigured: Bool) -> Bool {
    handlerConfigured
  }

  /// アプリの `ModelContext` を渡し、アイテム系コマンドを実データへ適用できるようにする。
  /// 画面の `processCommandInboxIfNeeded()` から、取り込みのたびに呼ぶ。
  /// 渡さない間は既定の `UnavailableCommandApplier` のまま（データには触れない）。
  func configure(modelContext: ModelContext) {
    let applier = ItemCommandApplier(modelContext: modelContext)
    self.applier = applier
    handler = PermissionedCommandHandler(applier: applier)
    handlerIsConfigured = true
  }

  /// 承認画面の件数表示用。状態ファイルを読むだけで、失効判定はしない。
  func pendingApprovals() -> [CommandInboxPendingApproval] {
    store.load().approvalQueue
  }

  /// 結果ファイルの中身に、前回書き戻せなかった結果行を重ねる。
  nonisolated static func combine(
    remote: CommandInboxResultsFile?,
    carried: [CommandInboxResult],
    now: Date
  ) -> CommandInboxResultsFile? {
    guard !carried.isEmpty else { return remote }
    let merged = CommandInboxResultsMerger.merge(
      existing: remote?.results ?? [], adding: carried, now: now)
    return CommandInboxResultsFile(results: merged, updatedAt: remote?.updatedAt)
  }

  /// 取り込み中に頼まれた状態の後始末。取り込みは通信の前後で状態を読み書きするため、
  /// 途中で別に保存すると取り込みの保存で上書きされる。終わってから順に実行する。
  private var deferredMaintenance: [() -> Void] = []

  /// 書き込み連携スイッチを OFF にしたときの後始末（キルスイッチ）。
  func killSwitchTurnedOff() {
    performMaintenance { [store, now] in
      CommandInboxApprovalCoordinator.killSwitchTurnedOff(store: store, now: now())
    }
  }

  /// 連携解除時の後始末（承認キューと未送信の結果を破棄）。
  func discardForLinkRemoval() {
    performMaintenance { [store, now] in
      CommandInboxApprovalCoordinator.discardForLinkRemoval(store: store, now: now())
    }
  }

  private func performMaintenance(_ action: @escaping () -> Void) {
    if isRunning {
      deferredMaintenance.append(action)
    } else {
      action()
    }
  }

  /// 実行中の処理が終わるまで待つ。待っている間は MainActor を手放す。
  private func waitUntilIdle() async {
    while isRunning {
      await withCheckedContinuation { continuation in
        idleWaiters.append(continuation)
      }
    }
  }

  /// 状態を読み書きする処理を 1 つだけ実行する。
  private func withExclusive<T>(_ operation: () async -> T) async -> T {
    await waitUntilIdle()
    isRunning = true
    defer { finishExclusive() }
    return await operation()
  }

  /// 実行を終え、取り込み中に頼まれた後始末を済ませてから待ち手を起こす。
  private func finishExclusive() {
    isRunning = false
    let actions = deferredMaintenance
    deferredMaintenance = []
    actions.forEach { $0() }
    let waiters = idleWaiters
    idleWaiters = []
    waiters.forEach { $0.resume() }
  }

  // MARK: 承認キュー（W-04）

  /// 承認画面を開いたときの失効判定と待機解除。
  /// 終わったら結果ファイルへの書き戻しを 1 回試す（送れなければ unsentResults に残る）。
  func refreshApprovalQueue(modelContext: ModelContext) async -> ApprovalQueueRefresh {
    let outcome = await withExclusive {
      // 取り込み中に差し替えないよう、実行を確保してから ModelContext を渡す。
      configure(modelContext: modelContext)
      return await CommandInboxApprovalCoordinator.resolvePendingApprovals(
        store: store, handler: handler, now: now())
    }

    var appliedCount = outcome.appliedCount
    if !outcome.results.isEmpty {
      // 失効した結果を書き戻す。取り込みで適用された分も件数に足す。
      appliedCount += await processIfNeeded().appliedCount
    }
    return ApprovalQueueRefresh(
      queue: store.load().approvalQueue,
      appliedCount: appliedCount
    )
  }

  /// 承認画面で「許可」されたコマンドを適用する。
  func approve(commandId: String) async -> CommandInboxApprovalOutcome {
    await withExclusive {
      await CommandInboxApprovalCoordinator.approve(
        commandId: commandId,
        store: store,
        applier: applier,
        handler: handler,
        policy: CommandWritePermissionSettings.policy(),
        now: now()
      )
    }
  }

  /// 承認画面で「却下」されたコマンドを `denied_by_user` にする。
  func deny(commandId: String) async -> CommandInboxApprovalOutcome {
    await withExclusive {
      await CommandInboxApprovalCoordinator.deny(
        commandId: commandId,
        store: store,
        handler: handler,
        now: now()
      )
    }
  }

  /// 受信箱を 1 回取り込む。
  func processIfNeeded() async -> RunOutcome {
    guard !isRunning else { return .skipped }
    guard Self.canProcess(handlerConfigured: handlerIsConfigured) else { return .skipped }
    guard SnapshotLinkSettings.isEnabled else { return .skipped }
    guard case .googleDrive = SnapshotLinkSettings.destination else { return .skipped }
    guard let user = GoogleDriveLinkManager.shared.currentUser else { return .skipped }

    isRunning = true
    defer { finishExclusive() }

    do {
      let transport = GoogleDriveCommandInboxTransport(user: user)
      var commandsData = try await transport.readCommands()
      var resultsData = try await transport.readResults()

      // ファイルが見つからないときはアプリが作る（仕様 2 章）。
      // commands.json は作成時以外に書き換えない。
      if commandsData == nil || resultsData == nil {
        try await transport.ensureFiles()
        if commandsData == nil {
          commandsData = CommandInboxParser.emptyCommandsData()
        }
        if resultsData == nil {
          resultsData = CommandInboxParser.emptyResultsData()
        }
      }

      let now = self.now()
      let remoteResults = resultsData.flatMap(CommandInboxParser.parseResultsFile)
      var initialState = store.load()
      let carried = initialState.unsentResults ?? []
      initialState.unsentResults = nil
      // 前回書き戻せなかった結果行を、結果ファイルに載っているものとして扱う
      let existingResults = Self.combine(remote: remoteResults, carried: carried, now: now)
      let output = await CommandInboxProcessor.process(
        commandsData: commandsData ?? CommandInboxParser.emptyCommandsData(),
        existingResults: existingResults,
        state: initialState,
        now: now,
        handler: handler
      )

      // 処理済みの記録を先に保存する。書き戻しが失敗しても、適用済みのコマンドを
      // 次回もう一度適用しないため。書き戻す内容は unsentResults に残しておく。
      let needsWrite = output.resultsChanged || !carried.isEmpty
      var state = output.state
      state.unsentResults = needsWrite ? output.results.results : nil
      try store.save(state)

      var writeError: String?
      if needsWrite {
        do {
          try await transport.writeResults(
            CommandInboxParser.encodeResultsFile(output.results))
          state.unsentResults = nil
          try? store.save(state)
        } catch {
          writeError = error.localizedDescription
        }
      }

      // 書き戻しに失敗しても適用は済んでいるので、適用件数はそのまま返す
      // （スナップショット送信はデータの実態に合わせて行う）。
      return RunOutcome(
        didRun: true,
        appliedCount: output.appliedCount,
        wroteResults: needsWrite && writeError == nil,
        errorMessage: writeError
      )
    } catch {
      return RunOutcome(
        didRun: true,
        appliedCount: 0,
        wroteResults: false,
        errorMessage: error.localizedDescription
      )
    }
  }
}
