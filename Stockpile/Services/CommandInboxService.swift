import Foundation
import GoogleSignIn

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

  private let store: CommandInboxStore
  private let handler: any CommandHandler
  private let now: () -> Date
  private var isRunning = false

  init(
    store: CommandInboxStore = CommandInboxStore(),
    handler: any CommandHandler = PermissionedCommandHandler(),
    now: @escaping () -> Date = Date.init
  ) {
    self.store = store
    self.handler = handler
    self.now = now
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

  /// 受信箱を 1 回取り込む。
  func processIfNeeded() async -> RunOutcome {
    guard !isRunning else { return .skipped }
    guard SnapshotLinkSettings.isEnabled else { return .skipped }
    guard case .googleDrive = SnapshotLinkSettings.destination else { return .skipped }
    guard let user = GoogleDriveLinkManager.shared.currentUser else { return .skipped }

    isRunning = true
    defer {
      isRunning = false
      let actions = deferredMaintenance
      deferredMaintenance = []
      actions.forEach { $0() }
    }

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
