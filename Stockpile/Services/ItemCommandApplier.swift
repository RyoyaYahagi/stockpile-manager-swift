import Foundation
import SwiftData

// MARK: - 適用処理の入口（W-03）

/// `item.add` / `item.update` を SwiftData のデータへ適用する `CommandApplier`。
///
/// `ModelContext` は Sendable ではないため、MainActor に閉じ込めた
/// `ItemCommandApplierHost` を介して受け取る。`apply` は MainActor へ移ってから
/// 適用し、Sendable な結果だけを返す。
///
/// 承認画面（W-04）で再検証して適用するときも、この型をそのまま使う。
/// `apply` は payload の検証・競合検出をやり直してから適用する。
struct ItemCommandApplier: CommandApplier {
  private let host: ItemCommandApplierHost

  /// - Parameter reschedulesNotifications: 保存後に期限通知を組み直すか。
  ///   通知の組み直しは非同期で後から ModelContext を読むため、
  ///   すぐ破棄するインメモリのコンテナを使うテストでは false にする。
  @MainActor
  init(modelContext: ModelContext, reschedulesNotifications: Bool = true) {
    self.host = ItemCommandApplierHost(
      modelContext: modelContext, reschedulesNotifications: reschedulesNotifications)
  }

  func apply(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult {
    await host.apply(command, now: now)
  }
}

/// MainActor 上で `ModelContext` を保持する箱。
@MainActor
final class ItemCommandApplierHost {
  private let modelContext: ModelContext
  private let reschedulesNotifications: Bool

  init(modelContext: ModelContext, reschedulesNotifications: Bool = true) {
    self.modelContext = modelContext
    self.reschedulesNotifications = reschedulesNotifications
  }

  func apply(_ command: CommandInboxEnvelope, now: Date) -> CommandInboxHandlingResult {
    ItemCommandApplication.apply(
      command, now: now, modelContext: modelContext,
      reschedulesNotifications: reschedulesNotifications)
  }
}

// MARK: - 適用ロジック

/// 検証済みコマンドを SwiftData へ適用する本体（MainActor）。
///
/// 対象はスナップショットで Muse に見せている範囲（`SnapshotLinkScope`）の
/// アイテムとバッグだけ。範囲外の id は `not_found`、範囲外のバッグ名は
/// `bag_not_found` として扱う。バッグは作らない。
@MainActor
enum ItemCommandApplication {
  static func apply(
    _ command: CommandInboxEnvelope,
    now: Date,
    modelContext: ModelContext,
    reschedulesNotifications: Bool = true
  ) -> CommandInboxHandlingResult {
    // 承認画面（W-04）から直接呼ばれた場合に備えて、検証をやり直す
    guard CommandInboxPayloadValidator.validate(command) else {
      return invalidPayload()
    }

    switch command.commandType {
    case .itemAdd:
      return applyAdd(
        command, now: now, modelContext: modelContext,
        reschedulesNotifications: reschedulesNotifications)
    case .itemUpdate:
      return applyUpdate(
        command, now: now, modelContext: modelContext,
        reschedulesNotifications: reschedulesNotifications)
    default:
      // item.delete / bag.* は W-05 で実装する
      return .unsupported(
        reason: .unknownType,
        message: L10n.string("このアプリの版ではまだ適用できません")
      )
    }
  }

  // MARK: 対象範囲の読み出し

  /// 一度の適用で読み出すデータの範囲。
  private struct Scope {
    /// スナップショットで見せているアイテム
    let items: [Item]
    /// スナップショットのバッグ名解決に使うバッグ
    let bags: [Bag]
    /// 画面から追加するときと同じ規則で決めた現在の Family
    let family: Family?
    /// 同じ id の二重追加を防ぐため、範囲を絞らずに見る全アイテム
    let allItems: [Item]
  }

  private static func loadScope(_ modelContext: ModelContext) throws -> Scope {
    let families = try modelContext.fetch(
      FetchDescriptor<Family>(sortBy: [SortDescriptor(\Family.createdAt, order: .reverse)]))
    let allItems = try modelContext.fetch(FetchDescriptor<Item>())
    let allBags = try modelContext.fetch(FetchDescriptor<Bag>())
    let resolved = SnapshotLinkScope.resolved(items: allItems, families: families)
    return Scope(
      items: resolved.items,
      bags: InventoryStore.scopedBags(allBags, family: resolved.family),
      family: resolved.family,
      allItems: allItems
    )
  }

  // MARK: item.add

  private static func applyAdd(
    _ command: CommandInboxEnvelope,
    now: Date,
    modelContext: ModelContext,
    reschedulesNotifications: Bool
  ) -> CommandInboxHandlingResult {
    let payload = command.payload
    guard let itemId = UUID(uuidString: command.commandId),
      let rawName = payload["name"]?.stringValue
    else {
      return invalidPayload()
    }
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return invalidPayload() }

    let scope: Scope
    do {
      scope = try loadScope(modelContext)
    } catch {
      return internalError()
    }

    // 別の端末が先に適用したコマンドが CloudKit で同期済みなら、作り直さない
    if let existing = scope.allItems.first(where: { $0.id == itemId }) {
      return .applied(
        message: L10n.format(
          "「%@」は同じ id で既に登録されているため、追加しませんでした", display(existing.name)),
        itemId: existing.id.uuidString
      )
    }

    let expiryDate: Date?
    if let value = payload["expiryDate"], !value.isNull {
      guard let string = value.stringValue,
        let date = SnapshotBuilder.date(fromDayString: string)
      else {
        return invalidPayload()
      }
      expiryDate = date
    } else {
      expiryDate = nil
    }

    let bag: Bag?
    switch resolveBagName(payload["bagName"], in: scope.bags) {
    case .success(let resolved):
      bag = resolved
    case .failure(let error):
      return result(for: error)
    }

    let category: ItemCategory?
    if let value = payload["category"], !value.isNull {
      guard let raw = value.stringValue, let parsed = ItemCategory(rawValue: raw) else {
        return invalidPayload()
      }
      category = parsed
    } else {
      // 画面からの追加と同じく、品名から推定する（ItemFormSheet）
      category = ItemCategoryInference.category(forName: name)
    }

    let item = Item(
      name: name,
      janCode: normalizedText(payload["janCode"]?.stringValue),
      quantity: payload["quantity"]?.integerValue ?? 1,
      expiryDate: expiryDate,
      locationNote: normalizedText(payload["locationNote"]?.stringValue),
      category: category?.rawValue
    )
    item.id = itemId
    item.bag = bag
    item.family = scope.family
    item.createdAt = now
    item.markUpdated(at: now)
    modelContext.insert(item)

    guard InventoryStore.saveAndSync(
        modelContext, family: scope.family,
        needsNotificationReschedule: reschedulesNotifications) else {
      modelContext.rollback()
      return internalError()
    }

    return .applied(
      message: CommandDescriber.appliedMessage(command, items: scope.items),
      itemId: itemId.uuidString
    )
  }

  // MARK: item.update

  private static func applyUpdate(
    _ command: CommandInboxEnvelope,
    now: Date,
    modelContext: ModelContext,
    reschedulesNotifications: Bool
  ) -> CommandInboxHandlingResult {
    let payload = command.payload
    guard let idString = payload["id"]?.stringValue,
      let itemId = UUID(uuidString: idString),
      let baseUpdatedAt = command.baseUpdatedAt
    else {
      return invalidPayload()
    }

    let scope: Scope
    do {
      scope = try loadScope(modelContext)
    } catch {
      return internalError()
    }

    guard let item = scope.items.first(where: { $0.id == itemId }) else {
      return .rejected(
        reason: .notFound,
        message: L10n.string("対象のアイテムが見つからないため、適用しませんでした")
      )
    }

    // 競合検出: 秒単位に切り捨てて比べる（仕様 3 章）
    guard seconds(baseUpdatedAt) == seconds(item.syncTimestamp) else {
      return .conflict(
        message: L10n.format(
          "「%@」はアプリ側で先に変更されていたため、適用しませんでした", display(item.name))
      )
    }

    // 途中で失敗したときに半分だけ変えないよう、変更内容を先に組み立てる
    let plan: UpdatePlan
    do {
      plan = try makeUpdatePlan(payload, bags: scope.bags)
    } catch let error as ApplicationError {
      return result(for: error)
    } catch {
      return internalError()
    }

    // 変更前の値で説明文を作る
    let message = CommandDescriber.appliedMessage(command, items: scope.items)

    plan.apply(to: item)
    item.markUpdated(at: now)

    guard InventoryStore.saveAndSync(
        modelContext, family: scope.family,
        needsNotificationReschedule: reschedulesNotifications) else {
      modelContext.rollback()
      return internalError()
    }

    return .applied(message: message, itemId: item.id.uuidString)
  }

  /// 省略は「変更なし」、`null` は「空にする」を表す項目の変更。
  private enum FieldChange<Value> {
    case unchanged
    case set(Value)
    case cleared
  }

  private struct UpdatePlan {
    var name: String?
    var janCode: FieldChange<String> = .unchanged
    var quantity: Int?
    var expiryDate: FieldChange<Date> = .unchanged
    var bag: FieldChange<Bag> = .unchanged
    var locationNote: FieldChange<String> = .unchanged
    var category: FieldChange<String> = .unchanged

    func apply(to item: Item) {
      if let name {
        item.name = name
      }
      switch janCode {
      case .unchanged:
        break
      case .set(let value):
        item.janCode = value
      case .cleared:
        item.janCode = nil
      }
      if let quantity {
        item.quantity = quantity
      }
      switch expiryDate {
      case .unchanged:
        break
      case .set(let value):
        item.expiryDate = value
      case .cleared:
        item.expiryDate = nil
      }
      switch bag {
      case .unchanged:
        break
      case .set(let value):
        item.bag = value
      case .cleared:
        item.bag = nil
      }
      switch locationNote {
      case .unchanged:
        break
      case .set(let value):
        item.locationNote = value
      case .cleared:
        item.locationNote = nil
      }
      switch category {
      case .unchanged:
        break
      case .set(let value):
        item.category = value
      case .cleared:
        item.category = nil
      }
    }
  }

  private static func makeUpdatePlan(
    _ payload: [String: CommandJSONValue],
    bags: [Bag]
  ) throws -> UpdatePlan {
    var plan = UpdatePlan()

    if let value = payload["name"] {
      guard let string = value.stringValue else { throw ApplicationError.invalidPayload }
      let name = string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw ApplicationError.invalidPayload }
      plan.name = name
    }
    if let value = payload["janCode"] {
      plan.janCode = try textChange(value)
    }
    if let value = payload["quantity"] {
      guard let quantity = value.integerValue, (1...999_999).contains(quantity) else {
        throw ApplicationError.invalidPayload
      }
      plan.quantity = quantity
    }
    if let value = payload["expiryDate"] {
      if value.isNull {
        plan.expiryDate = .cleared
      } else {
        guard let string = value.stringValue,
          let date = SnapshotBuilder.date(fromDayString: string)
        else {
          throw ApplicationError.invalidPayload
        }
        plan.expiryDate = .set(date)
      }
    }
    if let value = payload["bagName"] {
      plan.bag = try bagChange(value, bags: bags)
    }
    if let value = payload["locationNote"] {
      plan.locationNote = try textChange(value)
    }
    if let value = payload["category"] {
      if value.isNull {
        plan.category = .cleared
      } else {
        guard let raw = value.stringValue, ItemCategory(rawValue: raw) != nil else {
          throw ApplicationError.invalidPayload
        }
        plan.category = .set(raw)
      }
    }

    return plan
  }

  /// バッグは名前で既存のものに解決する（仕様 4 章）。同じ名前が 2 つ以上なら曖昧。
  private static func bagChange(
    _ value: CommandJSONValue,
    bags: [Bag]
  ) throws -> FieldChange<Bag> {
    if value.isNull {
      return .cleared
    }
    guard let raw = value.stringValue else { throw ApplicationError.invalidPayload }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .cleared }

    let matches = bags.filter { $0.name == name }
    switch matches.count {
    case 0:
      throw ApplicationError.bagNotFound(name)
    case 1:
      return .set(matches[0])
    default:
      throw ApplicationError.bagAmbiguous(name)
    }
  }

  /// バッグ名の解決。省略・null・空文字は「バッグなし」。
  private static func resolveBagName(
    _ value: CommandJSONValue?,
    in bags: [Bag]
  ) -> Result<Bag?, ApplicationError> {
    do {
      guard let value, !value.isNull else { return .success(nil) }
      switch try bagChange(value, bags: bags) {
      case .set(let bag):
        return .success(bag)
      case .cleared, .unchanged:
        return .success(nil)
      }
    } catch let error as ApplicationError {
      return .failure(error)
    } catch {
      return .failure(.invalidPayload)
    }
  }

  private static func textChange(_ value: CommandJSONValue) throws -> FieldChange<String> {
    if value.isNull {
      return .cleared
    }
    guard let string = value.stringValue else { throw ApplicationError.invalidPayload }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? .cleared : .set(trimmed)
  }

  // MARK: 結果の組み立て

  private enum ApplicationError: Error {
    case invalidPayload
    case bagNotFound(String)
    case bagAmbiguous(String)
  }

  private static func result(for error: ApplicationError) -> CommandInboxHandlingResult {
    switch error {
    case .invalidPayload:
      return invalidPayload()
    case .bagNotFound(let name):
      return .rejected(
        reason: .bagNotFound,
        message: L10n.format("バッグ「%@」が見つからないため、適用しませんでした", display(name))
      )
    case .bagAmbiguous(let name):
      return .rejected(
        reason: .bagAmbiguous,
        message: L10n.format("バッグ「%@」が複数あるため、適用しませんでした", display(name))
      )
    }
  }

  private static func invalidPayload() -> CommandInboxHandlingResult {
    CommandInboxHandlingResult(
      status: .invalid,
      reason: .invalidPayload,
      message: L10n.string("コマンドの内容が正しくないため、適用しませんでした")
    )
  }

  private static func internalError() -> CommandInboxHandlingResult {
    .failed(message: L10n.string("内部エラーのため、適用できませんでした"))
  }

  // MARK: 小さなヘルパー

  private static func seconds(_ date: Date) -> Int {
    Int(date.timeIntervalSince1970.rounded(.down))
  }

  private static func normalizedText(_ text: String?) -> String? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func display(_ text: String, limit: Int = 40) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "…"
  }
}
