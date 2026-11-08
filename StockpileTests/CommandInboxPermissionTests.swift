import Foundation
import Testing

@testable import Stockpile

// MARK: - テスト用の適用処理

/// 呼ばれた回数と内容を記録する適用処理。承認制・不可のときに呼ばれないことを確かめる。
private actor RecordingCommandApplier: CommandApplier {
  private var commands: [CommandInboxEnvelope] = []

  func apply(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult {
    commands.append(command)
    return .applied(message: "適用しました", itemId: command.commandId)
  }

  func recordedCommands() -> [CommandInboxEnvelope] {
    commands
  }
}

// MARK: - 権限判定

struct CommandWritePermissionJudgeTests {
  private func envelope(type: String) -> CommandInboxEnvelope {
    CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(type: type, payload: "{}")
    )!
  }

  private func commandType(for capability: CommandWriteCapability) -> String {
    switch capability {
    case .itemAdd: return "item.add"
    case .itemUpdate: return "item.update"
    case .itemDelete: return "item.delete"
    case .bagOperation: return "bag.add"
    }
  }

  /// 能力 4 つ × 権限 3 段階 × スイッチ ON/OFF の全組み合わせ。
  @Test
  func everyCapabilityPermissionAndSwitchCombination() {
    for capability in CommandWriteCapability.allCases {
      for permission in CommandWritePermission.allCases {
        for writesEnabled in [false, true] {
          let policy = CommandWritePermissionPolicy(
            writesEnabled: writesEnabled,
            permissions: [capability: permission]
          )
          let decision = CommandWritePermissionJudge.decide(
            envelope(type: commandType(for: capability)),
            policy: policy
          )

          if !writesEnabled {
            #expect(decision == .rejected(.writesDisabled))
          } else {
            switch permission {
            case .denied:
              #expect(decision == .rejected(.permissionDenied))
            case .approvalRequired:
              #expect(decision == .approvalRequired)
            case .allowed:
              #expect(decision == .allowed)
            }
          }
        }
      }
    }
  }

  @Test
  func mapsCommandTypesToCapabilities() {
    let expected: [CommandInboxCommandType: CommandWriteCapability] = [
      .itemAdd: .itemAdd,
      .itemUpdate: .itemUpdate,
      .itemDelete: .itemDelete,
      .bagAdd: .bagOperation,
      .bagRename: .bagOperation,
      .bagDelete: .bagOperation,
    ]

    for (commandType, capability) in expected {
      #expect(commandType.writeCapability == capability)
    }
    #expect(CommandInboxCommandType.allCases.count == expected.count)
  }
}

// MARK: - 設定の既定値と保存

struct CommandWritePermissionSettingsTests {
  private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "CommandInboxPermissionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }

  @Test
  func defaultIsOffAndOnlyDeleteRequiresApproval() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let policy = CommandWritePermissionSettings.policy(defaults: defaults)

    #expect(policy.writesEnabled == false)
    #expect(policy.permission(for: .itemAdd) == .denied)
    #expect(policy.permission(for: .itemUpdate) == .denied)
    #expect(policy.permission(for: .itemDelete) == .approvalRequired)
    #expect(policy.permission(for: .bagOperation) == .denied)
    #expect(CommandWritePermissionPolicy.default == policy)
  }

  @Test
  func persistsSwitchAndPermissionsPerCapability() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    CommandWritePermissionSettings.setWritesEnabled(true, defaults: defaults)
    CommandWritePermissionSettings.setPermission(.allowed, for: .itemAdd, defaults: defaults)
    CommandWritePermissionSettings.setPermission(
      .approvalRequired, for: .bagOperation, defaults: defaults)

    let policy = CommandWritePermissionSettings.policy(defaults: defaults)

    #expect(policy.writesEnabled)
    #expect(policy.permission(for: .itemAdd) == .allowed)
    #expect(policy.permission(for: .itemUpdate) == .denied)
    #expect(policy.permission(for: .itemDelete) == .approvalRequired)
    #expect(policy.permission(for: .bagOperation) == .approvalRequired)
  }
}

// MARK: - 権限つきハンドラと処理ループ

struct PermissionedCommandHandlerTests {
  private func makeStore() -> (store: CommandInboxStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CommandInboxPermissionTests-\(UUID().uuidString)", isDirectory: true)
    return (CommandInboxStore(fileURL: directory.appendingPathComponent("state.json")), directory)
  }

  private func run(
    _ commands: [String],
    handler: any CommandHandler,
    state: CommandInboxState = .empty
  ) async -> CommandInboxProcessingOutput {
    await CommandInboxProcessor.process(
      commandsData: CommandInboxTestFixture.commandsData(commands),
      existingResults: nil,
      state: state,
      now: CommandInboxTestFixture.now,
      handler: handler
    )
  }

  @Test
  func defaultStateRejectsEveryKnownCommandAsWritesDisabled() async {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let applier = RecordingCommandApplier()
    let policy = CommandWritePermissionSettings.policy(defaults: defaults)
    let handler = PermissionedCommandHandler(
      policyProvider: { policy },
      applier: applier
    )
    let id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    let output = await run(
      [
        CommandInboxTestFixture.command(type: "item.add", payload: "{\"name\":\"水\"}"),
        CommandInboxTestFixture.command(
          type: "item.update",
          payload: "{\"id\":\"\(id)\",\"quantity\":2}",
          baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
        ),
        CommandInboxTestFixture.command(
          type: "item.delete",
          payload: "{\"id\":\"\(id)\"}",
          baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
        ),
        CommandInboxTestFixture.command(type: "bag.add", payload: "{\"name\":\"非常袋\"}"),
        CommandInboxTestFixture.command(
          type: "bag.rename", payload: "{\"name\":\"非常袋\",\"newName\":\"防災袋\"}"),
        CommandInboxTestFixture.command(type: "bag.delete", payload: "{\"name\":\"非常袋\"}"),
      ],
      handler: handler
    )

    #expect(output.handledCount == 6)
    #expect(output.appliedCount == 0)
    #expect(output.results.results.count == 6)
    #expect(output.results.results.allSatisfy { $0.status == .rejected })
    #expect(output.results.results.allSatisfy { $0.reason == .writesDisabled })
    #expect(output.state.approvalQueue.isEmpty)
    let recorded = await applier.recordedCommands()
    #expect(recorded.isEmpty)
  }

  @Test
  func approvalRequiredQueuesEnvelopeWithoutTouchingData() async throws {
    let id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    let policy = CommandWritePermissionPolicy(
      writesEnabled: true,
      permissions: [.itemDelete: .approvalRequired]
    )
    let applier = RecordingCommandApplier()
    let output = await run(
      [
        CommandInboxTestFixture.command(
          id: id,
          type: "item.delete",
          payload: "{\"id\":\"\(id)\"}",
          baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
        )
      ],
      handler: PermissionedCommandHandler(policyProvider: { policy }, applier: applier)
    )

    let recordedAtApproval = await applier.recordedCommands()
    #expect(recordedAtApproval.isEmpty)
    #expect(output.appliedCount == 0)
    let row = try #require(output.results.results.first)
    #expect(row.status == .pendingApproval)
    #expect(row.reason == .approvalRequired)
    #expect(row.type == "item.delete")
    #expect(row.origin == "muse")

    let queue = output.state.approvalQueue
    let entry = try #require(queue.first)
    #expect(queue.count == 1)
    #expect(entry.commandId == id)
    #expect(entry.type == "item.delete")
    #expect(entry.origin == "muse")
    #expect(entry.envelope?.payload["id"]?.stringValue == id)
  }

  @Test
  func allowedPermissionDelegatesToApplier() async throws {
    let policy = CommandWritePermissionPolicy(
      writesEnabled: true,
      permissions: [.itemAdd: .allowed]
    )
    let applier = RecordingCommandApplier()
    let id = UUID().uuidString
    let output = await run(
      [CommandInboxTestFixture.command(id: id, type: "item.add", payload: "{\"name\":\"水\"}")],
      handler: PermissionedCommandHandler(policyProvider: { policy }, applier: applier)
    )

    let recorded = await applier.recordedCommands()
    #expect(recorded.map(\.commandId) == [id])
    #expect(output.appliedCount == 1)
    #expect(output.results.results.first?.status == .applied)
  }

  @Test
  func defaultApplierReportsUnsupportedWithoutApplying() async throws {
    let policy = CommandWritePermissionPolicy(
      writesEnabled: true,
      permissions: [.itemAdd: .allowed]
    )
    let output = await run(
      [CommandInboxTestFixture.command(type: "item.add", payload: "{\"name\":\"水\"}")],
      handler: PermissionedCommandHandler(policyProvider: { policy })
    )

    let row = try #require(output.results.results.first)
    #expect(row.status == .unsupported)
    #expect(row.reason == .unknownType)
    #expect(row.message == "このアプリの版ではまだ適用できません")
    #expect(output.appliedCount == 0)
  }

  private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "CommandInboxPermissionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}

// MARK: - キルスイッチと連携解除

struct CommandInboxApprovalCoordinatorTests {
  private func makeStore() -> (store: CommandInboxStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CommandInboxApprovalTests-\(UUID().uuidString)", isDirectory: true)
    return (CommandInboxStore(fileURL: directory.appendingPathComponent("state.json")), directory)
  }

  private func envelope(type: String = "item.delete") -> CommandInboxEnvelope {
    CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: type,
        payload: "{\"id\":\"3F2504E0-4F89-41D3-9A0C-0305E82C3301\"}",
        baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
      )
    )!
  }

  @Test
  func killSwitchRejectsEveryQueuedApprovalAndKeepsUnsentResults() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var state = CommandInboxState.empty
    state.enqueueApproval(envelope(), at: CommandInboxTestFixture.date(-60))
    state.enqueueApproval(
      envelope(type: "bag.add"), at: CommandInboxTestFixture.date(-30))
    let carried = CommandInboxTestFixture.result(
      id: "CARRIED", status: .applied, at: CommandInboxTestFixture.date(-120))
    state.unsentResults = [carried]
    try store.save(state)

    CommandInboxApprovalCoordinator.killSwitchTurnedOff(
      store: store, now: CommandInboxTestFixture.now)

    let saved = store.load()
    #expect(saved.approvalQueue.isEmpty)
    #expect(saved.pendingApprovals == nil)

    let unsent = try #require(saved.unsentResults)
    #expect(unsent.count == 3)
    #expect(unsent.contains { $0.commandId == "CARRIED" && $0.status == .applied })
    let rejected = unsent.filter { $0.reason == .writesDisabled }
    #expect(rejected.count == 2)
    #expect(rejected.allSatisfy { $0.status == .rejected })
    #expect(rejected.allSatisfy { $0.type != nil })
    #expect(rejected.allSatisfy { $0.origin == "muse" })
    #expect(
      rejected.allSatisfy {
        $0.processedAt == CommandInboxDate.string(from: CommandInboxTestFixture.now)
      })

    #expect(saved.history.count == 2)
    #expect(saved.history.allSatisfy { $0.status == .rejected })
    #expect(saved.history.allSatisfy { $0.reason == .writesDisabled })
  }

  @Test
  func linkRemovalDiscardsQueueAndUnsentResultsAndRecordsHistory() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var state = CommandInboxState.empty
    state.enqueueApproval(envelope(), at: CommandInboxTestFixture.date(-60))
    state.enqueueApproval(
      envelope(type: "bag.add"), at: CommandInboxTestFixture.date(-30))
    state.unsentResults = [
      CommandInboxTestFixture.result(
        id: "UNSENT", status: .rejected, reason: .writesDisabled,
        at: CommandInboxTestFixture.date(-10))
    ]
    try store.save(state)

    CommandInboxApprovalCoordinator.discardForLinkRemoval(
      store: store, now: CommandInboxTestFixture.now)

    let saved = store.load()
    #expect(saved.approvalQueue.isEmpty)
    #expect(saved.pendingApprovals == nil)
    #expect(saved.unsentResults == nil)

    #expect(saved.history.count == 2)
    #expect(saved.history.allSatisfy { $0.status == .rejected })
    #expect(saved.history.allSatisfy { $0.reason == .linkRemoved })
    #expect(Set(saved.history.compactMap(\.type)) == ["item.delete", "bag.add"])
  }

  @Test
  func linkRemovalWithOnlyUnsentResultsClearsThem() throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var state = CommandInboxState.empty
    state.unsentResults = [
      CommandInboxTestFixture.result(
        id: "UNSENT", status: .applied, at: CommandInboxTestFixture.now)
    ]
    try store.save(state)

    CommandInboxApprovalCoordinator.discardForLinkRemoval(
      store: store, now: CommandInboxTestFixture.now)

    #expect(store.load().unsentResults == nil)
    #expect(store.load().history.isEmpty)
  }
}

// MARK: - 状態ファイルの互換性

struct CommandInboxStateCompatibilityTests {
  @Test
  func decodesStateFileWithoutPendingApprovals() throws {
    let json = """
      {
        "processedCommandIds": {"ABC": "2026-11-08T10:00:00+09:00"},
        "fileErrorHashes": {},
        "history": []
      }
      """
    let state = try JSONDecoder().decode(CommandInboxState.self, from: Data(json.utf8))

    #expect(state.pendingApprovals == nil)
    #expect(state.approvalQueue.isEmpty)
    #expect(state.isProcessed("ABC"))
  }

  @Test
  func queueSurvivesStoreRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CommandInboxQueueTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CommandInboxStore(fileURL: directory.appendingPathComponent("state.json"))

    var state = CommandInboxState.empty
    let command = CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: "item.add",
        payload: "{\"name\":\"水 2L\",\"quantity\":3,\"bagName\":null}"
      )
    )!
    state.enqueueApproval(command, at: CommandInboxTestFixture.now)
    try store.save(state)

    let loaded = store.load()
    let entry = try #require(loaded.approvalQueue.first)
    #expect(entry.commandId == command.commandId)
    #expect(entry.type == "item.add")
    #expect(entry.payload["name"]?.stringValue == "水 2L")
    #expect(entry.payload["quantity"]?.integerValue == 3)
    #expect(entry.payload["bagName"]?.isNull == true)
    #expect(entry.envelope == command)
  }
}
