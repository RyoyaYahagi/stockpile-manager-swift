import Foundation

// MARK: - コマンドの説明文（W-03 / W-04）

/// コマンドの内容を人が読める日本語にする（docs/command-inbox-v1.md 6 章の `message`）。
///
/// - `describe(_:items:)` は適用前でも呼べる文（「追加します」）で、W-04 の承認画面で使う。
/// - `appliedMessage(_:items:)` は適用後の結果ファイルに書く文（「追加しました」）。
///
/// どちらも payload の解釈を共有する。対象アイテムは適用と同じ範囲
/// （`SnapshotLinkScope.resolved(items:families:)`）のアイテムを渡す。
/// id が見つからない場合でも落ちず、一般的な説明を返す。
enum CommandDescriber {
  /// 何をするコマンドかを人が読める文で返す（例: 「水 2L を追加します（数量 6）」）。
  static func describe(_ command: CommandInboxEnvelope, items: [Item]) -> String {
    sentence(for: command, items: items, past: false)
  }

  /// 適用後に結果ファイルへ書く文（例: 「水 2L を追加しました（数量 6）」）。
  static func appliedMessage(_ command: CommandInboxEnvelope, items: [Item]) -> String {
    sentence(for: command, items: items, past: true)
  }

  private static func sentence(
    for command: CommandInboxEnvelope,
    items: [Item],
    past: Bool
  ) -> String {
    switch command.commandType {
    case .itemAdd:
      return addSentence(command.payload, past: past)
    case .itemUpdate:
      return updateSentence(command.payload, items: items, past: past)
    case .itemDelete, .bagAdd, .bagRename, .bagDelete, nil:
      // item.delete / bag.* の説明文は W-05 で具体的にする
      return past ? L10n.string("コマンドを適用しました") : L10n.string("コマンドを適用します")
    }
  }

  // MARK: item.add

  private static func addSentence(_ payload: [String: CommandJSONValue], past: Bool) -> String {
    let name = trimmed(payload["name"]?.stringValue) ?? L10n.string("アイテム")
    let quantity = payload["quantity"]?.integerValue ?? 1

    var details = [L10n.format("数量 %@", String(quantity))]
    if let value = payload["expiryDate"], !value.isNull, let expiry = value.stringValue {
      details.append(L10n.format("期限 %@", expiry))
    }
    if let bagName = trimmed(payload["bagName"]?.stringValue) {
      details.append(display(bagName))
    }

    let detailText = details.joined(separator: L10n.string("、"))
    return past
      ? L10n.format("%@ を追加しました（%@）", name, detailText)
      : L10n.format("%@ を追加します（%@）", name, detailText)
  }

  // MARK: item.update

  private static func updateSentence(
    _ payload: [String: CommandJSONValue],
    items: [Item],
    past: Bool
  ) -> String {
    guard let idString = payload["id"]?.stringValue,
      let itemId = UUID(uuidString: idString),
      let item = items.first(where: { $0.id == itemId })
    else {
      return past
        ? L10n.string("アイテムを編集しました")
        : L10n.string("アイテムを編集します")
    }

    var fragments: [String] = []

    if let newName = trimmed(payload["name"]?.stringValue) {
      fragments.append(
        L10n.format("名前を「%@」→「%@」に変更", display(item.name), display(newName)))
    }

    if let value = payload["quantity"], let quantity = value.integerValue {
      fragments.append(
        L10n.format("数量を %@ → %@ に変更", String(item.quantity), String(quantity)))
    }

    if let value = payload["expiryDate"] {
      let current = item.expiryDate.map { SnapshotBuilder.dayString(from: $0) }
        ?? L10n.string("未設定")
      if value.isNull {
        fragments.append(L10n.string("期限を削除"))
      } else if let expiry = value.stringValue {
        fragments.append(L10n.format("期限を %@ → %@ に変更", current, expiry))
      }
    }

    if let value = payload["bagName"] {
      let current = item.bag.map { display($0.name) } ?? L10n.string("未分類")
      if let newBagName = trimmed(value.stringValue) {
        fragments.append(
          L10n.format("しまう場所を「%@」から「%@」に変更", current, display(newBagName)))
      } else {
        // null と空文字は「バッグから外す」
        fragments.append(L10n.format("しまう場所を「%@」から未分類に変更", current))
      }
    }

    if let value = payload["janCode"] {
      let current = item.janCode.map { display($0) } ?? L10n.string("未設定")
      if value.isNull {
        fragments.append(L10n.string("JANコードを削除"))
      } else if let janCode = trimmed(value.stringValue) {
        fragments.append(L10n.format("JANコードを %@ → %@ に変更", current, display(janCode)))
      }
    }

    if let value = payload["locationNote"] {
      let current = item.locationNote.map { display($0) } ?? L10n.string("未設定")
      if value.isNull {
        fragments.append(L10n.string("場所メモを削除"))
      } else if let note = trimmed(value.stringValue) {
        fragments.append(
          L10n.format("場所メモを「%@」→「%@」に変更", current, display(note)))
      } else {
        fragments.append(L10n.string("場所メモを削除"))
      }
    }

    if let value = payload["category"] {
      let current = item.resolvedCategory.displayName
      if value.isNull {
        fragments.append(L10n.format("ジャンルを「%@」から未設定に変更", current))
      } else if let raw = value.stringValue, let category = ItemCategory(rawValue: raw) {
        fragments.append(
          L10n.format("ジャンルを「%@」→「%@」に変更", current, category.displayName))
      }
    }

    guard !fragments.isEmpty else {
      return past
        ? L10n.format("「%@」に変更はありませんでした", display(item.name))
        : L10n.format("「%@」に変更はありません", display(item.name))
    }

    let body = fragments.joined(separator: L10n.string("、"))
    return past
      ? L10n.format("%@ の%@しました", display(item.name), body)
      : L10n.format("%@ の%@します", display(item.name), body)
  }

  // MARK: 表示用の整形

  private static func trimmed(_ text: String?) -> String? {
    guard let text else { return nil }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// 長い品名・メモで結果ファイルや承認画面が埋まらないように切り詰める。
  private static func display(_ text: String, limit: Int = 40) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "…"
  }
}
