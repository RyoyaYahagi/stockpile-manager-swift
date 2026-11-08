import Foundation
import SwiftData
import Testing

@testable import Stockpile

// MARK: - テスト用の入れ物

/// 承認キューから実際に適用するテスト用のインメモリ SwiftData。
/// `ItemCommandApplierTests` の入れ物と同じ構成にし、通知の組み直しは止める。
@MainActor
private struct ApprovalTestHarness {
  let container: ModelContainer
  let context: ModelContext

  init() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    container = try ModelContainer(
      for: Family.self,
      User.self,
      Bag.self,
      Item.self,
      CloudKitDeletionMarker.self,
      NotificationSettings.self,
      configurations: configuration
    )
    context = container.mainContext
  }

  @discardableResult
  func makeFamily(name: String = "わが家", selectedAt: Date = Date()) -> Family {
    let family = Family(name: name)
    family.lastSelectedAt = selectedAt
    context.insert(family)
    try? context.save()
    return family
  }

  @discardableResult
  func makeItem(
    name: String = "水 2L",
    quantity: Int = 1,
    family: Family?,
    updatedAt: Date = CommandInboxTestFixture.now
  ) -> Item {
    let item = Item(name: name, quantity: quantity)
    item.family = family
    item.createdAt = updatedAt
    item.markUpdated(at: updatedAt)
    context.insert(item)
    try? context.save()
    return item
  }

  func applier() -> ItemCommandApplier {
    ItemCommandApplier(modelContext: context, reschedulesNotifications: false)
  }

  func allItems() -> [Item] {
    (try? context.fetch(FetchDescriptor<Item>())) ?? []
  }

  func item(named name: String = "水 2L") -> Item? {
    allItems().first { $0.name == name }
  }
}

// MARK: - テスト用の組み立て

private enum ApprovalFixture {
  static let itemId = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"

  static func makeStore() -> (store: CommandInboxStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CommandInboxApprovalTests-\(UUID().uuidString)", isDirectory: true)
    return (CommandInboxStore(fileURL: directory.appendingPathComponent("state.json")), directory)
  }

  static func updateEnvelope(
    id: String = UUID().uuidString,
    itemId: String = itemId,
    quantity: Int,
    baseUpdatedAt: String,
    issuedAt: String = CommandInboxTestFixture.nowString
  ) -> CommandInboxEnvelope {
    CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        id: id,
        issuedAt: issuedAt,
        type: "item.update",
        payload: "{\"id\":\"\(itemId)\",\"quantity\":\(quantity)}",
        baseUpdatedAt: baseUpdatedAt
      )
    )!
  }

  static func policy(
    _ permission: CommandWritePermission,
    writesEnabled: Bool = true
  ) -> CommandWritePermissionPolicy {
    CommandWritePermissionPolicy(
      writesEnabled: writesEnabled,
      permissions: [.itemUpdate: permission]
    )
  }

  static func handler(
    policy: CommandWritePermissionPolicy,
    applier: ItemCommandApplier
  ) -> PermissionedCommandHandler {
    PermissionedCommandHandler(policyProvider: { policy }, applier: applier)
  }

  static func savedState(
    store: CommandInboxStore,
    queue: [CommandInboxPendingApproval]
  ) throws {
    var state = CommandInboxState.empty
    state.pendingApprovals = queue
    try store.save(state)
  }
}

// MARK: - 対象の同一性

struct CommandInboxTargetKeyTests {
  @Test
  func itemIDsAreComparedCaseInsensitively() throws {
    let upper = ApprovalFixture.updateEnvelope(
      itemId: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
      quantity: 2,
      baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
    )
    let lower = ApprovalFixture.updateEnvelope(
      itemId: "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
      quantity: 3,
      baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
    )

    #expect(CommandInboxTargetKey.overlaps(upper, lower))
  }

  @Test
  func bagRenameTargetsBothNames() throws {
    let rename = CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: "bag.rename",
        payload: "{\"name\":\"非常袋\",\"newName\":\"防災袋\"}"
      )
    )!
    let deleteNewName = CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: "bag.delete",
        payload: "{\"name\":\"防災袋\"}"
      )
    )!
    let deleteOldName = CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: "bag.delete",
        payload: "{\"name\":\"非常袋\"}"
      )
    )!

    #expect(CommandInboxTargetKey.overlaps(rename, deleteNewName))
    #expect(CommandInboxTargetKey.overlaps(rename, deleteOldName))
  }

  @Test
  func itemAddHasNoTarget() throws {
    let add = CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(type: "item.add", payload: "{\"name\":\"水 2L\"}")
    )!
    let update = ApprovalFixture.updateEnvelope(
      quantity: 2,
      baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
    )

    #expect(CommandInboxTargetKey.keys(for: add).isEmpty)
    #expect(!CommandInboxTargetKey.overlaps(add, update))
  }
}

// MARK: - キュー投入と順序の保持

@MainActor
struct CommandInboxApprovalQueueingTests {
  @Test
  func approvalRequiredQueuesWithoutTouchingData() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let envelope = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString,
      quantity: 2, baseUpdatedAt: base, issuedAt: CommandInboxDate.string(from: item.updatedAt))
    let policy = ApprovalFixture.policy(.approvalRequired)

    let output = await CommandInboxProcessor.process(
      commandsData: CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(
          id: envelope.commandId,
          type: "item.update",
          payload: "{\"id\":\"\(item.id.uuidString)\",\"quantity\":2}",
          baseUpdatedAt: base
        )
      ]),
      existingResults: nil,
      state: .empty,
      now: CommandInboxTestFixture.now,
      handler: ApprovalFixture.handler(policy: policy, applier: harness.applier())
    )

    let row = try #require(output.results.results.first)
    #expect(row.status == .pendingApproval)
    #expect(row.reason == .approvalRequired)
    #expect(output.state.approvalQueue.count == 1)
    #expect(output.appliedCount == 0)
    #expect(item.quantity == 1)
  }

  @Test
  func allowedLaterCommandWaitsForEarlierApproval() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let first = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let second = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 3, baseUpdatedAt: base)
    let allowed = ApprovalFixture.policy(.allowed)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var state = CommandInboxState.empty
    state.enqueueApproval(first, at: CommandInboxTestFixture.date(-60))
    try store.save(state)

    let output = await CommandInboxProcessor.process(
      commandsData: CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(
          id: second.commandId,
          type: "item.update",
          payload: "{\"id\":\"\(item.id.uuidString)\",\"quantity\":3}",
          baseUpdatedAt: base
        )
      ]),
      existingResults: nil,
      state: state,
      now: CommandInboxTestFixture.now,
      handler: ApprovalFixture.handler(policy: allowed, applier: harness.applier())
    )

    let row = try #require(output.results.results.first)
    #expect(row.status == .pendingApproval)
    #expect(row.reason == .waitingForEarlier)
    #expect(output.state.approvalQueue.count == 2)
    // 自分の権限は「許可」でも、先の承認待ちがある間は適用しない
    #expect(output.appliedCount == 0)
    #expect(item.quantity == 1)
    let queuedSecond = try #require(
      output.state.approvalQueue.first { $0.commandId == second.commandId })
    #expect(CommandInboxTargetKey.isWaitingForEarlier(queuedSecond, in: output.state.approvalQueue))
  }

  @Test
  func denyingEarlierCommandAppliesWaitingLaterCommand() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let first = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let second = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 3, baseUpdatedAt: base)
    let allowed = ApprovalFixture.policy(.allowed)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var state = CommandInboxState.empty
    state.enqueueApproval(first, at: CommandInboxTestFixture.date(-60))
    state.enqueueApproval(second, at: CommandInboxTestFixture.date(-30))
    try store.save(state)

    let outcome = await CommandInboxApprovalCoordinator.deny(
      commandId: first.commandId,
      store: store,
      handler: ApprovalFixture.handler(policy: allowed, applier: harness.applier()),
      now: CommandInboxTestFixture.now
    )

    let denied = try #require(outcome.results.first { $0.commandId == first.commandId })
    #expect(denied.status == .rejected)
    #expect(denied.reason == .deniedByUser)
    #expect(denied.message == "利用者が却下しました")

    let applied = try #require(outcome.results.first { $0.commandId == second.commandId })
    #expect(applied.status == .applied)
    #expect(outcome.appliedCount == 1)
    #expect(item.quantity == 3)
    #expect(store.load().approvalQueue.isEmpty)
  }

  @Test
  func approvingEarlierCommandMakesLaterCommandConflict() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let base = CommandInboxTestFixture.baseUpdatedAt
    let item = harness.makeItem(
      family: family, updatedAt: CommandInboxDate.parse(base)!)
    let first = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let second = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 3, baseUpdatedAt: base)
    let approvalPolicy = ApprovalFixture.policy(.approvalRequired)
    let allowedPolicy = ApprovalFixture.policy(.allowed)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var state = CommandInboxState.empty
    state.enqueueApproval(first, at: CommandInboxTestFixture.date(-60))
    state.enqueueApproval(second, at: CommandInboxTestFixture.date(-30))
    try store.save(state)

    let outcome = await CommandInboxApprovalCoordinator.approve(
      commandId: first.commandId,
      store: store,
      applier: harness.applier(),
      handler: ApprovalFixture.handler(policy: allowedPolicy, applier: harness.applier()),
      policy: approvalPolicy,
      now: CommandInboxTestFixture.now
    )

    #expect(outcome.appliedCount == 1)
    #expect(item.quantity == 2)
    let secondResult = try #require(outcome.results.first { $0.commandId == second.commandId })
    #expect(secondResult.status == .conflict)
    #expect(secondResult.reason == .staleBase)
    #expect(store.load().approvalQueue.isEmpty)
  }

  @Test
  func waitingCommandCannotBeApprovedOrDeniedDirectly() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let first = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let second = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 3, baseUpdatedAt: base)
    let allowed = ApprovalFixture.policy(.allowed)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    var state = CommandInboxState.empty
    state.enqueueApproval(first, at: CommandInboxTestFixture.date(-60))
    state.enqueueApproval(second, at: CommandInboxTestFixture.date(-30))
    try store.save(state)

    let approveOutcome = await CommandInboxApprovalCoordinator.approve(
      commandId: second.commandId,
      store: store,
      applier: harness.applier(),
      handler: ApprovalFixture.handler(policy: allowed, applier: harness.applier()),
      policy: allowed,
      now: CommandInboxTestFixture.now
    )
    let denyOutcome = await CommandInboxApprovalCoordinator.deny(
      commandId: second.commandId,
      store: store,
      handler: ApprovalFixture.handler(policy: allowed, applier: harness.applier()),
      now: CommandInboxTestFixture.now
    )

    #expect(approveOutcome.results.isEmpty)
    #expect(denyOutcome.results.isEmpty)
    #expect(store.load().approvalQueue.count == 2)
    #expect(item.quantity == 1)
  }

  @Test
  func changingPermissionDoesNotProcessReadyQueueAutomatically() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let entry = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let output = await CommandInboxProcessor.process(
      commandsData: CommandInboxParser.emptyCommandsData(),
      existingResults: nil,
      state: {
        var state = CommandInboxState.empty
        state.enqueueApproval(entry, at: CommandInboxTestFixture.date(-60))
        return state
      }(),
      now: CommandInboxTestFixture.now,
      handler: ApprovalFixture.handler(
        policy: ApprovalFixture.policy(.allowed), applier: harness.applier())
    )

    // 権限を「許可」に変えただけでは適用せず、利用者の承認を待つ
    #expect(output.state.approvalQueue.count == 1)
    #expect(output.results.results.isEmpty)
    #expect(output.appliedCount == 0)
    #expect(item.quantity == 1)
  }
}

// MARK: - 許可・却下・失効

@MainActor
struct CommandInboxApprovalActionTests {
  @Test
  func approvingAppliesAndStoresUnsentResult() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let entry = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ApprovalFixture.savedState(store: store, queue: [
      CommandInboxPendingApproval(envelope: entry, queuedAt: CommandInboxTestFixture.now)
    ])

    let outcome = await CommandInboxApprovalCoordinator.approve(
      commandId: entry.commandId,
      store: store,
      applier: harness.applier(),
      handler: ApprovalFixture.handler(
        policy: ApprovalFixture.policy(.approvalRequired), applier: harness.applier()),
      policy: ApprovalFixture.policy(.approvalRequired),
      now: CommandInboxTestFixture.now
    )

    #expect(outcome.appliedCount == 1)
    #expect(item.quantity == 2)
    #expect(store.load().approvalQueue.isEmpty)

    let result = try #require(store.load().unsentResults?.first)
    #expect(result.commandId == entry.commandId)
    #expect(result.status == .applied)
    #expect(result.reason == nil)
    #expect(result.itemId == item.id.uuidString)
    #expect(store.load().history.first?.status == .applied)
  }

  @Test
  func approvingConflictDoesNotApply() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let staleBase = CommandInboxDate.string(
      from: item.syncTimestamp.addingTimeInterval(-1))
    let entry = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: staleBase)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ApprovalFixture.savedState(store: store, queue: [
      CommandInboxPendingApproval(envelope: entry, queuedAt: CommandInboxTestFixture.now)
    ])

    let outcome = await CommandInboxApprovalCoordinator.approve(
      commandId: entry.commandId,
      store: store,
      applier: harness.applier(),
      handler: ApprovalFixture.handler(
        policy: ApprovalFixture.policy(.approvalRequired), applier: harness.applier()),
      policy: ApprovalFixture.policy(.approvalRequired),
      now: CommandInboxTestFixture.now
    )

    #expect(outcome.appliedCount == 0)
    #expect(item.quantity == 1)
    let result = try #require(store.load().unsentResults?.first)
    #expect(result.status == .conflict)
    #expect(result.reason == .staleBase)
  }

  @Test
  func denyingDoesNotApplyAndStoresDeniedByUser() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let entry = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ApprovalFixture.savedState(store: store, queue: [
      CommandInboxPendingApproval(envelope: entry, queuedAt: CommandInboxTestFixture.now)
    ])

    let outcome = await CommandInboxApprovalCoordinator.deny(
      commandId: entry.commandId,
      store: store,
      handler: ApprovalFixture.handler(
        policy: ApprovalFixture.policy(.approvalRequired), applier: harness.applier()),
      now: CommandInboxTestFixture.now
    )

    #expect(outcome.appliedCount == 0)
    #expect(item.quantity == 1)
    #expect(store.load().approvalQueue.isEmpty)
    let result = try #require(store.load().unsentResults?.first)
    #expect(result.status == .rejected)
    #expect(result.reason == .deniedByUser)
    #expect(result.message == "利用者が却下しました")
  }

  @Test
  func approvingWhileWritesDisabledStoresWritesDisabled() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let entry = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ApprovalFixture.savedState(store: store, queue: [
      CommandInboxPendingApproval(envelope: entry, queuedAt: CommandInboxTestFixture.now)
    ])

    let outcome = await CommandInboxApprovalCoordinator.approve(
      commandId: entry.commandId,
      store: store,
      applier: harness.applier(),
      handler: ApprovalFixture.handler(
        policy: ApprovalFixture.policy(.approvalRequired, writesEnabled: false),
        applier: harness.applier()),
      policy: ApprovalFixture.policy(.approvalRequired, writesEnabled: false),
      now: CommandInboxTestFixture.now
    )

    #expect(outcome.appliedCount == 0)
    #expect(item.quantity == 1)
    #expect(store.load().approvalQueue.isEmpty)
    let result = try #require(store.load().unsentResults?.first)
    #expect(result.status == .rejected)
    #expect(result.reason == .writesDisabled)
  }

  @Test
  func expiredApprovalIsRemovedOnNextIngest() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let issuedAt = CommandInboxDate.string(
      from: CommandInboxTestFixture.date(-CommandInboxConstants.expiryInterval - 1))
    let entry = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base, issuedAt: issuedAt)
    var state = CommandInboxState.empty
    state.enqueueApproval(entry, at: CommandInboxTestFixture.date(-60))

    let output = await CommandInboxProcessor.process(
      commandsData: CommandInboxParser.emptyCommandsData(),
      existingResults: nil,
      state: state,
      now: CommandInboxTestFixture.now,
      handler: ApprovalFixture.handler(
        policy: ApprovalFixture.policy(.allowed), applier: harness.applier())
    )

    let row = try #require(output.results.results.first)
    #expect(row.status == .expired)
    #expect(row.reason == .expired)
    #expect(output.state.approvalQueue.isEmpty)
    #expect(output.appliedCount == 0)
    #expect(item.quantity == 1)
  }

  @Test
  func expiredApprovalIsRemovedWhenOpeningScreen() async throws {
    let harness = try ApprovalTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    let base = CommandInboxDate.string(from: item.syncTimestamp)
    let issuedAt = CommandInboxDate.string(
      from: CommandInboxTestFixture.date(-CommandInboxConstants.expiryInterval - 1))
    let entry = ApprovalFixture.updateEnvelope(
      itemId: item.id.uuidString, quantity: 2, baseUpdatedAt: base, issuedAt: issuedAt)
    let (store, directory) = ApprovalFixture.makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ApprovalFixture.savedState(store: store, queue: [
      CommandInboxPendingApproval(envelope: entry, queuedAt: CommandInboxTestFixture.date(-60))
    ])

    let outcome = await CommandInboxApprovalCoordinator.resolvePendingApprovals(
      store: store,
      handler: ApprovalFixture.handler(
        policy: ApprovalFixture.policy(.allowed), applier: harness.applier()),
      now: CommandInboxTestFixture.now
    )

    #expect(outcome.state.approvalQueue.isEmpty)
    #expect(outcome.appliedCount == 0)
    let result = try #require(store.load().unsentResults?.first)
    #expect(result.status == .expired)
    #expect(result.reason == .expired)
    #expect(item.quantity == 1)
  }
}
