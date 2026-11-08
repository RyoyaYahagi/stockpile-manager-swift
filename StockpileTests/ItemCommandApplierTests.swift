import Foundation
import SwiftData
import Testing

@testable import Stockpile

// MARK: - テスト用の入れ物

/// インメモリの SwiftData で `ItemCommandApplier` を動かすための入れ物。
@MainActor
private struct ItemCommandTestHarness {
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
  func makeBag(_ name: String, family: Family?) -> Bag {
    let bag = Bag(name: name)
    bag.family = family
    context.insert(bag)
    try? context.save()
    return bag
  }

  @discardableResult
  func makeItem(
    name: String = "水 2L",
    quantity: Int = 1,
    family: Family?,
    bag: Bag? = nil,
    updatedAt: Date = CommandInboxTestFixture.now
  ) -> Item {
    let item = Item(name: name, quantity: quantity)
    item.family = family
    item.bag = bag
    item.createdAt = updatedAt
    item.markUpdated(at: updatedAt)
    context.insert(item)
    try? context.save()
    return item
  }

  func applier() -> ItemCommandApplier {
    ItemCommandApplier(modelContext: context)
  }

  func allItems() -> [Item] {
    (try? context.fetch(FetchDescriptor<Item>())) ?? []
  }

  func item(named name: String) -> Item? {
    allItems().first { $0.name == name }
  }

  func itemCount() -> Int {
    allItems().count
  }
}

// MARK: - コマンドの組み立て

private enum ItemCommandFixture {
  static func add(
    id: String = UUID().uuidString,
    payload: String
  ) -> CommandInboxEnvelope {
    CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(id: id, type: "item.add", payload: payload)
    )!
  }

  static func update(
    item: Item,
    fields: String,
    baseUpdatedAt: String? = nil,
    id: String = UUID().uuidString
  ) -> CommandInboxEnvelope {
    let payload = "{\"id\":\"\(item.id.uuidString)\",\(fields)}"
    return CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        id: id,
        type: "item.update",
        payload: payload,
        baseUpdatedAt: baseUpdatedAt ?? CommandInboxDate.string(from: item.syncTimestamp)
      )
    )!
  }

  static func other(
    type: String,
    payload: String,
    baseUpdatedAt: String? = nil
  ) -> CommandInboxEnvelope {
    CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: type,
        payload: payload,
        baseUpdatedAt: baseUpdatedAt
      )
    )!
  }
}

// MARK: - item.add

@MainActor
struct ItemCommandAddTests {
  @Test
  func addCreatesItemWithEveryField() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let bag = harness.makeBag("非常袋", family: family)
    let envelope = ItemCommandFixture.add(
      payload: """
        {"name":"水 2L","janCode":"4901234567894","quantity":6,
         "expiryDate":"2027-03-31","bagName":"非常袋","locationNote":"押し入れ",
         "category":"waterDrink"}
        """)

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    #expect(result.reason == nil)
    #expect(result.itemId == envelope.commandId)
    let item = try #require(harness.allItems().first)
    #expect(item.id == UUID(uuidString: envelope.commandId))
    #expect(item.name == "水 2L")
    #expect(item.janCode == "4901234567894")
    #expect(item.quantity == 6)
    #expect(item.expiryDate.map { SnapshotBuilder.dayString(from: $0) } == "2027-03-31")
    #expect(item.bag?.id == bag.id)
    #expect(item.locationNote == "押し入れ")
    #expect(item.category == ItemCategory.waterDrink.rawValue)
    #expect(item.family?.id == family.id)
    #expect(item.createdAt == CommandInboxTestFixture.now)
    #expect(item.updatedAt == CommandInboxTestFixture.now)
  }

  @Test
  func addUsesDefaultsAndInfersCategoryFromName() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let envelope = ItemCommandFixture.add(payload: "{\"name\":\"ミネラルウォーター\"}")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    let item = try #require(harness.allItems().first)
    #expect(item.quantity == 1)
    #expect(item.expiryDate == nil)
    #expect(item.bag == nil)
    #expect(item.janCode == nil)
    #expect(item.locationNote == nil)
    #expect(item.category == ItemCategory.waterDrink.rawValue)
    #expect(item.family?.id == family.id)
  }

  @Test
  func addTreatsNullQuantityAsDefault() async throws {
    let harness = try ItemCommandTestHarness()
    let envelope = ItemCommandFixture.add(
      payload: "{\"name\":\"水 2L\",\"quantity\":null,\"category\":\"other\"}")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    #expect(harness.allItems().first?.quantity == 1)
  }

  @Test
  func addResolvesBagNameToExistingBag() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let bag = harness.makeBag("車載ボックス", family: family)
    let envelope = ItemCommandFixture.add(
      payload: "{\"name\":\"水 2L\",\"bagName\":\"車載ボックス\"}")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    #expect(harness.allItems().first?.bag?.id == bag.id)
  }

  @Test
  func addRejectsUnknownBagWithoutCreatingItem() async throws {
    let harness = try ItemCommandTestHarness()
    harness.makeFamily()
    let envelope = ItemCommandFixture.add(
      payload: "{\"name\":\"水 2L\",\"bagName\":\"存在しない場所\"}")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .rejected)
    #expect(result.reason == .bagNotFound)
    #expect(harness.itemCount() == 0)
    // バッグは作らない
    let bags = (try? harness.context.fetch(FetchDescriptor<Bag>())) ?? []
    #expect(bags.isEmpty)
  }

  @Test
  func addRejectsAmbiguousBagName() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    harness.makeBag("非常袋", family: family)
    harness.makeBag("非常袋", family: family)
    let envelope = ItemCommandFixture.add(
      payload: "{\"name\":\"水 2L\",\"bagName\":\"非常袋\"}")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .rejected)
    #expect(result.reason == .bagAmbiguous)
    #expect(harness.itemCount() == 0)
  }

  @Test
  func addingSameCommandIdTwiceDoesNotDuplicate() async throws {
    let harness = try ItemCommandTestHarness()
    harness.makeFamily()
    let commandId = UUID().uuidString
    let envelope = ItemCommandFixture.add(
      id: commandId, payload: "{\"name\":\"水 2L\",\"quantity\":6}")

    let first = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)
    let second = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(first.status == .applied)
    #expect(second.status == .applied)
    #expect(second.itemId == envelope.commandId)
    #expect(second.message?.contains("既に登録") == true)
    #expect(harness.itemCount() == 1)
  }

  @Test
  func addWithoutFamilyLeavesItemUnscoped() async throws {
    let harness = try ItemCommandTestHarness()
    let envelope = ItemCommandFixture.add(payload: "{\"name\":\"水 2L\"}")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    #expect(harness.allItems().first?.family == nil)
  }

  @Test
  func addRejectsPayloadThatFailsValidation() async throws {
    let harness = try ItemCommandTestHarness()
    let envelope = ItemCommandFixture.add(
      payload: "{\"name\":\"水 2L\",\"quantity\":0}")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .invalid)
    #expect(result.reason == .invalidPayload)
    #expect(harness.itemCount() == 0)
  }
}

// MARK: - item.update

@MainActor
struct ItemCommandUpdateTests {
  @Test
  func updateChangesEveryField() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let oldBag = harness.makeBag("非常袋", family: family)
    let newBag = harness.makeBag("車載ボックス", family: family)
    let item = harness.makeItem(family: family, bag: oldBag)
    item.janCode = "111"
    item.expiryDate = CommandInboxDate.parse("2027-01-01T00:00:00+09:00")
    item.locationNote = "押し入れ"
    item.category = ItemCategory.other.rawValue
    item.markUpdated(at: CommandInboxTestFixture.now)
    try harness.context.save()

    let envelope = ItemCommandFixture.update(
      item: item,
      fields: """
        "name":"水 2L（箱）","janCode":"222","quantity":3,
        "expiryDate":"2027-12-31","bagName":"車載ボックス",
        "locationNote":"物置","category":"waterDrink"
        """)

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    #expect(result.itemId == item.id.uuidString)
    let updated = try #require(harness.item(named: "水 2L（箱）"))
    #expect(updated.id == item.id)
    #expect(updated.janCode == "222")
    #expect(updated.quantity == 3)
    #expect(updated.expiryDate.map { SnapshotBuilder.dayString(from: $0) } == "2027-12-31")
    #expect(updated.bag?.id == newBag.id)
    #expect(updated.locationNote == "物置")
    #expect(updated.category == ItemCategory.waterDrink.rawValue)
    #expect(updated.updatedAt == CommandInboxTestFixture.now)
  }

  @Test
  func updateClearsNullableFieldsWithNull() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let bag = harness.makeBag("非常袋", family: family)
    let item = harness.makeItem(family: family, bag: bag)
    item.janCode = "111"
    item.expiryDate = CommandInboxDate.parse("2027-01-01T00:00:00+09:00")
    item.locationNote = "押し入れ"
    item.category = ItemCategory.other.rawValue
    item.markUpdated(at: CommandInboxTestFixture.now)
    try harness.context.save()

    let envelope = ItemCommandFixture.update(
      item: item,
      fields: """
        "janCode":null,"expiryDate":null,"bagName":null,
        "locationNote":null,"category":null
        """)

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    let updated = try #require(harness.allItems().first)
    #expect(updated.janCode == nil)
    #expect(updated.expiryDate == nil)
    #expect(updated.bag == nil)
    #expect(updated.locationNote == nil)
    #expect(updated.category == nil)
    // name / quantity は省略したので変わらない
    #expect(updated.name == "水 2L")
    #expect(updated.quantity == 1)
  }

  @Test
  func updateLeavesOmittedFieldsUnchanged() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let bag = harness.makeBag("非常袋", family: family)
    let item = harness.makeItem(family: family, bag: bag)
    item.janCode = "111"
    item.expiryDate = CommandInboxDate.parse("2027-01-01T00:00:00+09:00")
    item.locationNote = "押し入れ"
    item.category = ItemCategory.other.rawValue
    item.markUpdated(at: CommandInboxTestFixture.now)
    try harness.context.save()

    let envelope = ItemCommandFixture.update(item: item, fields: "\"quantity\":5")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    let updated = try #require(harness.allItems().first)
    #expect(updated.quantity == 5)
    #expect(updated.name == "水 2L")
    #expect(updated.janCode == "111")
    #expect(updated.bag?.id == bag.id)
    #expect(updated.locationNote == "押し入れ")
    #expect(updated.category == ItemCategory.other.rawValue)
  }

  @Test
  func updateRejectsItemOutsideSnapshotScope() async throws {
    let harness = try ItemCommandTestHarness()
    let currentFamily = harness.makeFamily(
      name: "いまの家族", selectedAt: CommandInboxTestFixture.now)
    let otherFamily = harness.makeFamily(
      name: "別の家族", selectedAt: CommandInboxTestFixture.date(-86_400))
    let item = harness.makeItem(name: "別家族の水", family: otherFamily)
    try harness.context.save()

    let envelope = ItemCommandFixture.update(item: item, fields: "\"quantity\":9")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .rejected)
    #expect(result.reason == .notFound)
    #expect(item.quantity == 1)
    #expect(currentFamily.id != otherFamily.id)
  }

  @Test
  func updateWithUnknownIdReturnsNotFound() async throws {
    let harness = try ItemCommandTestHarness()
    harness.makeFamily()
    let item = harness.makeItem(family: nil)
    let envelope = CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: "item.update",
        payload: "{\"id\":\"\(UUID().uuidString)\",\"quantity\":2}",
        baseUpdatedAt: CommandInboxDate.string(from: item.syncTimestamp)
      )
    )!

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .rejected)
    #expect(result.reason == .notFound)
  }

  @Test
  func updateWithUnknownBagChangesNothing() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    try harness.context.save()

    let envelope = ItemCommandFixture.update(
      item: item, fields: "\"quantity\":4,\"bagName\":\"存在しない場所\"")

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .rejected)
    #expect(result.reason == .bagNotFound)
    #expect(item.quantity == 1)
    #expect(item.bag == nil)
  }

  @Test
  func unsupportedTypesAreStillReported() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    try harness.context.save()

    let delete = ItemCommandFixture.other(
      type: "item.delete",
      payload: "{\"id\":\"\(item.id.uuidString)\"}",
      baseUpdatedAt: CommandInboxDate.string(from: item.syncTimestamp)
    )
    let bagAdd = ItemCommandFixture.other(
      type: "bag.add", payload: "{\"name\":\"新しい場所\"}")

    let deleteResult = await harness.applier().apply(delete, now: CommandInboxTestFixture.now)
    let bagResult = await harness.applier().apply(bagAdd, now: CommandInboxTestFixture.now)

    #expect(deleteResult.status == .unsupported)
    #expect(deleteResult.reason == .unknownType)
    #expect(bagResult.status == .unsupported)
    #expect(harness.itemCount() == 1)
  }
}

// MARK: - 競合検出（仕様 3 章）

@MainActor
struct ItemCommandConflictTests {
  private static let baseUpdatedAt = CommandInboxDate.parse("2026-11-01T10:15:00+09:00")!

  @Test
  func conflictWhenBaseUpdatedAtDiffersBySecondsChangesNothing() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(name: "水 2L", family: family, updatedAt: Self.baseUpdatedAt)
    try harness.context.save()

    let envelope = ItemCommandFixture.update(
      item: item,
      fields: "\"name\":\"書き換え\",\"quantity\":9",
      baseUpdatedAt: CommandInboxDate.string(
        from: Self.baseUpdatedAt.addingTimeInterval(-1))
    )

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .conflict)
    #expect(result.reason == .staleBase)
    #expect(item.name == "水 2L")
    #expect(item.quantity == 1)
    #expect(item.updatedAt == Self.baseUpdatedAt)
  }

  @Test
  func sameSecondWithDifferentMillisecondsIsApplied() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(name: "水 2L", family: family, updatedAt: Self.baseUpdatedAt)
    try harness.context.save()

    let envelope = ItemCommandFixture.update(
      item: item,
      fields: "\"quantity\":2",
      // 同じ秒・ミリ秒だけ違う値
      baseUpdatedAt: "2026-11-01T10:15:00.900+09:00"
    )

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    #expect(item.quantity == 2)
  }

  @Test
  func missingBaseUpdatedAtIsInvalidPayload() async throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(family: family)
    try harness.context.save()

    let envelope = CommandInboxTestFixture.envelope(
      CommandInboxTestFixture.command(
        type: "item.update",
        payload: "{\"id\":\"\(item.id.uuidString)\",\"quantity\":2}"
      )
    )!

    let result = await harness.applier().apply(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .invalid)
    #expect(result.reason == .invalidPayload)
    #expect(item.quantity == 1)
  }
}

// MARK: - 権限（W-02 経由）

@MainActor
struct ItemCommandPermissionTests {
  private func policy(
    permission: CommandWritePermission
  ) -> CommandWritePermissionPolicy {
    CommandWritePermissionPolicy(
      writesEnabled: true,
      permissions: [.itemAdd: permission]
    )
  }

  @Test
  func deniedCapabilityDoesNotApplyThroughHandler() async throws {
    let harness = try ItemCommandTestHarness()
    harness.makeFamily()
    let policy = self.policy(permission: .denied)
    let handler = PermissionedCommandHandler(
      policyProvider: { policy },
      applier: harness.applier()
    )
    let envelope = ItemCommandFixture.add(payload: "{\"name\":\"水 2L\"}")

    let result = await handler.handle(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .rejected)
    #expect(result.reason == .permissionDenied)
    #expect(harness.itemCount() == 0)
  }

  @Test
  func approvalRequiredCapabilityDoesNotApplyThroughHandler() async throws {
    let harness = try ItemCommandTestHarness()
    harness.makeFamily()
    let policy = self.policy(permission: .approvalRequired)
    let handler = PermissionedCommandHandler(
      policyProvider: { policy },
      applier: harness.applier()
    )
    let envelope = ItemCommandFixture.add(payload: "{\"name\":\"水 2L\"}")

    let result = await handler.handle(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .pendingApproval)
    #expect(harness.itemCount() == 0)
  }

  @Test
  func allowedCapabilityAppliesThroughHandler() async throws {
    let harness = try ItemCommandTestHarness()
    harness.makeFamily()
    let policy = self.policy(permission: .allowed)
    let handler = PermissionedCommandHandler(
      policyProvider: { policy },
      applier: harness.applier()
    )
    let envelope = ItemCommandFixture.add(payload: "{\"name\":\"水 2L\",\"quantity\":6}")

    let result = await handler.handle(envelope, now: CommandInboxTestFixture.now)

    #expect(result.status == .applied)
    #expect(harness.itemCount() == 1)
    #expect(harness.allItems().first?.quantity == 6)
  }
}

// MARK: - 受信箱から適用までの通し（W-01 + W-02 + W-03）

@MainActor
struct ItemCommandProcessingIntegrationTests {
  @Test
  func appliedCountDrivesPostApplySnapshotUpload() async throws {
    let harness = try ItemCommandTestHarness()
    harness.makeFamily()
    let policy = CommandWritePermissionPolicy(
      writesEnabled: true,
      permissions: [.itemAdd: .allowed]
    )
    let handler = PermissionedCommandHandler(
      policyProvider: { policy },
      applier: harness.applier()
    )
    let commands = CommandInboxTestFixture.commandsData([
      CommandInboxTestFixture.command(payload: "{\"name\":\"水 2L\",\"quantity\":6}")
    ])

    let output = await CommandInboxProcessor.process(
      commandsData: commands,
      existingResults: nil,
      state: .empty,
      now: CommandInboxTestFixture.now,
      handler: handler
    )

    // ContentView は appliedCount > 0 で適用後のスナップショットを送る
    #expect(output.appliedCount == 1)
    let row = try #require(output.results.results.first)
    #expect(row.status == .applied)
    #expect(row.itemId != nil)
    #expect(harness.itemCount() == 1)
  }
}

// MARK: - 説明文（W-04 と共有）

@MainActor
struct CommandDescriberTests {
  @Test
  func describesItemAdd() throws {
    let envelope = ItemCommandFixture.add(
      payload: "{\"name\":\"水 2L\",\"quantity\":6}")

    #expect(
      CommandDescriber.describe(envelope, items: [])
        == "水 2L を追加します（数量 6）")
    #expect(
      CommandDescriber.appliedMessage(envelope, items: [])
        == "水 2L を追加しました（数量 6）")
  }

  @Test
  func describesItemUpdateWithBeforeAndAfterValues() throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(name: "水 2L", quantity: 1, family: family)
    let envelope = ItemCommandFixture.update(item: item, fields: "\"quantity\":2")

    #expect(
      CommandDescriber.describe(envelope, items: [item])
        == "水 2L の数量を 1 → 2 に変更します")
    #expect(
      CommandDescriber.appliedMessage(envelope, items: [item])
        == "水 2L の数量を 1 → 2 に変更しました")
  }

  @Test
  func describesMultipleFieldChanges() throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let bag = harness.makeBag("非常袋", family: family)
    let item = harness.makeItem(name: "水 2L", quantity: 1, family: family)
    item.bag = bag
    let envelope = ItemCommandFixture.update(
      item: item, fields: "\"quantity\":2,\"bagName\":null")

    let message = CommandDescriber.appliedMessage(envelope, items: [item])

    #expect(message.contains("数量を 1 → 2 に変更"))
    #expect(message.contains("しまう場所を「非常袋」から未分類に変更"))
  }

  @Test
  func describesDeletionWithNull() throws {
    let harness = try ItemCommandTestHarness()
    let family = harness.makeFamily()
    let item = harness.makeItem(name: "水 2L", family: family)
    item.expiryDate = CommandInboxDate.parse("2027-01-01T00:00:00+09:00")
    let envelope = ItemCommandFixture.update(item: item, fields: "\"expiryDate\":null")

    #expect(
      CommandDescriber.appliedMessage(envelope, items: [item])
        == "水 2L の期限を削除しました")
  }

  @Test
  func describesNoChange() throws {
    let harness = try ItemCommandTestHarness()
    let item = harness.makeItem(name: "水 2L", family: nil)
    let envelope = ItemCommandFixture.update(item: item, fields: "\"unknown\":1")

    #expect(
      CommandDescriber.appliedMessage(envelope, items: [item])
        == "「水 2L」に変更はありませんでした")
  }
}
