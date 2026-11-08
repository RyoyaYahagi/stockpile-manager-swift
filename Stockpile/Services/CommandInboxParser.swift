import CryptoKit
import Foundation

// MARK: - 生のコマンド（パース済み・未検証）

/// commands.json の commands[] の 1 要素。
/// 検証は `CommandInboxParser.parseEnvelope` と `CommandInboxPayloadValidator` が行う。
struct CommandInboxRawCommand: Equatable, Sendable {
  /// 要素が JSON オブジェクトでなければ nil
  let fields: [String: CommandJSONValue]?
  /// 生の commandId（型が String でない場合は nil）
  let rawCommandId: String?
  /// 要素の内容ハッシュ（commandId がない要素の重複抑止に使う）
  let contentHash: String
}

/// commands.json の読み取り結果
enum CommandInboxFileParseResult: Equatable, Sendable {
  case commands([CommandInboxRawCommand])
  /// ファイル全体を処理しないエラー（6 章）。dedupeHash で同じ内容の繰り返しを抑止する。
  case fileError(reason: CommandInboxReason, dedupeHash: String)
}

// MARK: - ファイルのパース

/// commands.json / command-results.json の読み書き。
/// ネットワークにも SwiftData にも依存しない純粋な処理。
enum CommandInboxParser {
  private struct EmptyCommandsFile: Encodable {
    let version = CommandInboxConstants.version
    let commands: [String] = []
  }

  private struct EmptyResultsFile: Encodable {
    let version = CommandInboxConstants.version
    let results: [String] = []
  }

  /// アプリが作る commands.json の初期内容（Muse が上書きするまで空）
  static func emptyCommandsData() -> Data {
    encode(EmptyCommandsFile())
  }

  /// アプリが作る command-results.json の初期内容
  static func emptyResultsData() -> Data {
    encode(EmptyResultsFile())
  }

  /// commands.json を読む。壊れていても落ちず、ファイル単位のエラーとして返す。
  static func parseCommandsFile(_ data: Data) -> CommandInboxFileParseResult {
    let hash = contentHash(of: data)
    guard data.count <= CommandInboxConstants.maxFileBytes else {
      return .fileError(reason: .malformedFile, dedupeHash: hash)
    }
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return .fileError(reason: .malformedFile, dedupeHash: hash)
    }
    guard let version = object["version"] as? Int, version == CommandInboxConstants.version else {
      return .fileError(reason: .malformedFile, dedupeHash: hash)
    }
    guard let rawCommands = object["commands"] as? [Any] else {
      return .fileError(reason: .malformedFile, dedupeHash: hash)
    }
    guard rawCommands.count <= CommandInboxConstants.maxCommands else {
      // 上限を超えたファイルは一部だけ適用せず、ファイル単位で拒否する
      return .fileError(reason: .tooManyCommands, dedupeHash: hash)
    }

    let commands = rawCommands.map { element -> CommandInboxRawCommand in
      let fields = (element as? [String: Any])?.mapValues(CommandJSONValue.from)
      let rawCommandId = (element as? [String: Any])?["commandId"] as? String
      return CommandInboxRawCommand(
        fields: fields,
        rawCommandId: rawCommandId,
        contentHash: contentHash(of: element)
      )
    }
    return .commands(commands)
  }

  /// command-results.json を読む。壊れている・版が違う場合は nil（空として扱う）。
  static func parseResultsFile(_ data: Data) -> CommandInboxResultsFile? {
    guard let file = try? JSONDecoder().decode(CommandInboxResultsFile.self, from: data) else {
      return nil
    }
    guard file.version == CommandInboxConstants.version else { return nil }
    return file
  }

  /// command-results.json を書き出す
  static func encodeResultsFile(_ file: CommandInboxResultsFile) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(file)) ?? emptyResultsData()
  }

  // MARK: 封筒の検証

  /// 封筒（全コマンド共通の必須項目）を検証して返す。失敗は `invalid_envelope`。
  static func parseEnvelope(_ raw: CommandInboxRawCommand) -> CommandInboxEnvelope? {
    guard let fields = raw.fields else { return nil }
    guard
      let idString = fields["commandId"]?.stringValue,
      let uuid = UUID(uuidString: idString)
    else {
      return nil
    }
    guard
      let issuedAtString = fields["issuedAt"]?.stringValue,
      let issuedAt = CommandInboxDate.parse(issuedAtString)
    else {
      return nil
    }
    guard let origin = fields["origin"]?.stringValue, (1...100).contains(origin.count) else {
      return nil
    }
    guard let type = fields["type"]?.stringValue, !type.isEmpty else {
      return nil
    }
    guard let payload = fields["payload"]?.objectValue else {
      return nil
    }

    var baseUpdatedAt: Date?
    if let baseValue = fields["baseUpdatedAt"], !baseValue.isNull {
      guard
        let baseString = baseValue.stringValue,
        let parsed = CommandInboxDate.parse(baseString)
      else {
        return nil
      }
      baseUpdatedAt = parsed
    }

    return CommandInboxEnvelope(
      commandId: uuid.uuidString,
      issuedAt: issuedAt,
      origin: origin,
      type: type,
      payload: payload,
      baseUpdatedAt: baseUpdatedAt
    )
  }

  /// 冪等キー。UUID は大文字小文字を区別しないため大文字に正規化する。
  /// commandId がない壊れた要素は内容ハッシュで代用する。
  static func dedupeKey(for raw: CommandInboxRawCommand) -> String {
    if let rawCommandId = raw.rawCommandId,
      !rawCommandId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return rawCommandId.uppercased()
    }
    return "sha256:\(raw.contentHash)"
  }

  /// 結果に載せる commandId。壊れた要素でも書けるなら元の文字列を残す。
  static func resultCommandId(for raw: CommandInboxRawCommand) -> String? {
    guard let rawCommandId = raw.rawCommandId,
      !rawCommandId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return rawCommandId
  }

  // MARK: ハッシュ

  static func contentHash(of data: Data) -> String {
    sha256Hex(data)
  }

  static func contentHash(of json: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    return sha256Hex(data)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func encode<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)) ?? Data()
  }
}

// MARK: - payload の検証

/// 4 章の payload 制約を検証する。失敗は `invalid_payload`。
enum CommandInboxPayloadValidator {
  static func validate(_ envelope: CommandInboxEnvelope) -> Bool {
    guard let type = envelope.commandType else { return true }
    let payload = envelope.payload
    switch type {
    case .itemAdd:
      return validateItemAdd(payload)
    case .itemUpdate:
      guard envelope.baseUpdatedAt != nil else { return false }
      return validateItemUpdate(payload)
    case .itemDelete:
      guard envelope.baseUpdatedAt != nil else { return false }
      return isUUID(payload["id"])
    case .bagAdd:
      return isName(payload["name"])
    case .bagRename:
      return isName(payload["name"]) && isName(payload["newName"])
    case .bagDelete:
      return isName(payload["name"])
    }
  }

  private static func validateItemAdd(_ payload: [String: CommandJSONValue]) -> Bool {
    guard isName(payload["name"]) else { return false }
    guard isOptionalString(payload["janCode"], maxLength: 32) else { return false }
    // item.add の quantity は省略時 1。null は省略と同じ扱いにする。
    if let quantity = payload["quantity"], !quantity.isNull {
      guard isQuantity(quantity) else { return false }
    }
    guard isOptionalDay(payload["expiryDate"]) else { return false }
    guard isOptionalString(payload["bagName"], maxLength: nil) else { return false }
    guard isOptionalString(payload["locationNote"], maxLength: 2_000) else { return false }
    guard isOptionalCategory(payload["category"]) else { return false }
    return true
  }

  private static func validateItemUpdate(_ payload: [String: CommandJSONValue]) -> Bool {
    guard isUUID(payload["id"]) else { return false }
    if let name = payload["name"] {
      // name は null 不可（空にする操作はできない）
      guard name.stringValue != nil, isName(name) else { return false }
    }
    guard isOptionalString(payload["janCode"], maxLength: 32) else { return false }
    if let quantity = payload["quantity"] {
      // quantity も null 不可
      guard quantity.stringValue == nil, isQuantity(quantity) else { return false }
    }
    guard isOptionalDay(payload["expiryDate"]) else { return false }
    guard isOptionalString(payload["bagName"], maxLength: nil) else { return false }
    guard isOptionalString(payload["locationNote"], maxLength: 2_000) else { return false }
    guard isOptionalCategory(payload["category"]) else { return false }
    return true
  }

  // MARK: 項目ごとの判定

  /// 品名・バッグ名（1〜200 文字、空白のみは不可）
  private static func isName(_ value: CommandJSONValue?) -> Bool {
    guard let string = value?.stringValue else { return false }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && string.count <= 200
  }

  private static func isUUID(_ value: CommandJSONValue?) -> Bool {
    guard let string = value?.stringValue else { return false }
    return UUID(uuidString: string) != nil
  }

  /// 省略または null を許す文字列。null は「空にする」を意味する。
  private static func isOptionalString(_ value: CommandJSONValue?, maxLength: Int?) -> Bool {
    guard let value else { return true }
    if value.isNull { return true }
    guard let string = value.stringValue else { return false }
    if let maxLength, string.count > maxLength { return false }
    return true
  }

  private static func isOptionalDay(_ value: CommandJSONValue?) -> Bool {
    guard let value else { return true }
    if value.isNull { return true }
    guard let string = value.stringValue else { return false }
    // DateFormatter は "2027/03/31" や "2027-3-31" も解釈するため、形を先に固定する
    guard
      string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    else {
      return false
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: string) else { return false }
    return formatter.string(from: date) == string
  }

  private static func isQuantity(_ value: CommandJSONValue?) -> Bool {
    guard let quantity = value?.integerValue else { return false }
    return (1...999_999).contains(quantity)
  }

  private static func isOptionalCategory(_ value: CommandJSONValue?) -> Bool {
    guard let value else { return true }
    if value.isNull { return true }
    guard let string = value.stringValue else { return false }
    return ItemCategory(rawValue: string) != nil
  }
}
