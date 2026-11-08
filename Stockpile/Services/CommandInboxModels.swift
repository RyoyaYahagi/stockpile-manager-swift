import Foundation

// MARK: - コマンド受信箱の定数（docs/command-inbox-v1.md）

/// 仕様書の上限値・ファイル名をまとめた場所。
/// 意味を変えるときは仕様書と合わせて更新する。
enum CommandInboxConstants {
  /// commands.json / command-results.json の `version`
  static let version = 1
  /// ファイル 1MB まで
  static let maxFileBytes = 1_048_576
  /// コマンド 200 件まで
  static let maxCommands = 200
  /// 結果は直近 200 件まで保持する
  static let maxResults = 200
  /// 適用履歴は直近 500 件まで保持する
  static let maxHistory = 500
  /// 処理済み commandId・結果・ファイル単位エラーの保持期間（30 日）
  static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
  /// 発行から 7 日を超えたコマンドは失効
  static let expiryInterval: TimeInterval = 7 * 24 * 60 * 60

  static let commandsFileName = "commands.json"
  static let resultsFileName = "command-results.json"
}

// MARK: - 日時の解釈と出力

/// 受信箱で使う ISO 8601 の解釈と出力。
/// スナップショット v1 と同じく秒までの日時を扱う。
enum CommandInboxDate {
  /// ISO 8601（タイムゾーン付き）を解釈する。小数秒は任意。
  static func parse(_ string: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) {
      return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }

  /// 端末のタイムゾーン付き ISO 8601 を返す（例: 2026-11-08T10:05:00+09:00）。
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }
}

// MARK: - 任意の JSON 値

/// payload の中身を型安全に保持するための値。
/// 未知のフィールドを捨てずに後続（W-03 以降）へ渡せるようにする。
enum CommandJSONValue: Equatable, Sendable {
  case object([String: CommandJSONValue])
  case array([CommandJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  static func from(_ any: Any) -> CommandJSONValue {
    if any is NSNull {
      return .null
    }
    if let dictionary = any as? [String: Any] {
      var result: [String: CommandJSONValue] = [:]
      for (key, value) in dictionary {
        result[key] = from(value)
      }
      return .object(result)
    }
    if let array = any as? [Any] {
      return .array(array.map(from))
    }
    if let string = any as? String {
      return .string(string)
    }
    if let number = any as? NSNumber {
      // JSONSerialization は true/false も NSNumber で返すため、真偽値を先に見分ける
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      return .number(number.doubleValue)
    }
    return .null
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  /// 整数として読める数値だけを返す（1.5 などは nil）
  var integerValue: Int? {
    guard case .number(let value) = self else { return nil }
    guard value.rounded() == value,
      value >= Double(Int.min), value <= Double(Int.max)
    else {
      return nil
    }
    return Int(value)
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  var objectValue: [String: CommandJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
}

// MARK: - コマンドの種類

/// commands.json の `type`。未知の値は受信箱側で `unsupported` にする。
enum CommandInboxCommandType: String, CaseIterable, Sendable {
  case itemAdd = "item.add"
  case itemUpdate = "item.update"
  case itemDelete = "item.delete"
  case bagAdd = "bag.add"
  case bagRename = "bag.rename"
  case bagDelete = "bag.delete"

  /// baseUpdatedAt が必須か（競合検出を行う種類）
  var requiresBaseUpdatedAt: Bool {
    switch self {
    case .itemUpdate, .itemDelete:
      return true
    case .itemAdd, .bagAdd, .bagRename, .bagDelete:
      return false
    }
  }
}

// MARK: - 封筒

/// 検証済みのコマンド封筒（docs/command-inbox-v1.md 3 章）。
struct CommandInboxEnvelope: Equatable, Sendable {
  /// 大文字小文字を区別しない正規化済みの commandId（大文字の UUID 文字列）
  let commandId: String
  let issuedAt: Date
  let origin: String
  let type: String
  let payload: [String: CommandJSONValue]
  let baseUpdatedAt: Date?

  /// 4 章の既知 type かどうか
  var commandType: CommandInboxCommandType? {
    CommandInboxCommandType(rawValue: type)
  }
}

// MARK: - 結果

/// command-results.json の `status`
enum CommandInboxStatus: String, Codable, CaseIterable, Sendable {
  case applied
  case pendingApproval = "pending_approval"
  case rejected
  case conflict
  case expired
  case invalid
  case unsupported
  case error
}

/// command-results.json の `reason`（機械が読むコード）
enum CommandInboxReason: String, Codable, CaseIterable, Sendable {
  case approvalRequired = "approval_required"
  case waitingForEarlier = "waiting_for_earlier"
  case writesDisabled = "writes_disabled"
  case permissionDenied = "permission_denied"
  case deniedByUser = "denied_by_user"
  case notFound = "not_found"
  case bagNotFound = "bag_not_found"
  case bagAmbiguous = "bag_ambiguous"
  case bagExists = "bag_exists"
  case bagNotEmpty = "bag_not_empty"
  case staleBase = "stale_base"
  case expired
  case invalidEnvelope = "invalid_envelope"
  case invalidPayload = "invalid_payload"
  case tooManyCommands = "too_many_commands"
  case unknownType = "unknown_type"
  case malformedFile = "malformed_file"
  case internalError = "internal_error"
}

/// 結果ファイルの 1 行。`nil` の項目は JSON では `null` として書く。
struct CommandInboxResult: Codable, Equatable, Sendable {
  var commandId: String?
  var type: String?
  var origin: String?
  var status: CommandInboxStatus
  var reason: CommandInboxReason?
  var message: String?
  var itemId: String?
  var processedAt: String

  init(
    commandId: String?,
    type: String? = nil,
    origin: String? = nil,
    status: CommandInboxStatus,
    reason: CommandInboxReason? = nil,
    message: String? = nil,
    itemId: String? = nil,
    processedAt: String
  ) {
    self.commandId = commandId
    self.type = type
    self.origin = origin
    self.status = status
    self.reason = reason
    self.message = message
    self.itemId = itemId
    self.processedAt = processedAt
  }

  private enum CodingKeys: String, CodingKey {
    case commandId
    case type
    case origin
    case status
    case reason
    case message
    case itemId
    case processedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    commandId = try container.decodeIfPresent(String.self, forKey: .commandId)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    origin = try container.decodeIfPresent(String.self, forKey: .origin)
    status = try container.decode(CommandInboxStatus.self, forKey: .status)
    reason = try container.decodeIfPresent(CommandInboxReason.self, forKey: .reason)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    itemId = try container.decodeIfPresent(String.self, forKey: .itemId)
    processedAt = try container.decode(String.self, forKey: .processedAt)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try encodeOptional(commandId, forKey: .commandId, into: &container)
    try encodeOptional(type, forKey: .type, into: &container)
    try encodeOptional(origin, forKey: .origin, into: &container)
    try container.encode(status, forKey: .status)
    try encodeOptional(reason?.rawValue, forKey: .reason, into: &container)
    try encodeOptional(message, forKey: .message, into: &container)
    try encodeOptional(itemId, forKey: .itemId, into: &container)
    try container.encode(processedAt, forKey: .processedAt)
  }

  private func encodeOptional(
    _ value: String?, forKey key: CodingKeys, into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    if let value {
      try container.encode(value, forKey: key)
    } else {
      try container.encodeNil(forKey: key)
    }
  }
}

/// command-results.json 全体
struct CommandInboxResultsFile: Codable, Equatable, Sendable {
  var version: Int
  var updatedAt: String?
  var results: [CommandInboxResult]

  init(results: [CommandInboxResult], updatedAt: String?) {
    self.version = CommandInboxConstants.version
    self.updatedAt = updatedAt
    self.results = results
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case updatedAt
    case results
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    results = try container.decode([CommandInboxResult].self, forKey: .results)
  }
}

// MARK: - 端末内の状態

/// 適用履歴の 1 件（8 章）。画面には出さず、後続の確認用に残す。
struct CommandInboxHistoryEntry: Codable, Equatable, Sendable {
  var occurredAt: String
  var origin: String?
  var type: String?
  var status: CommandInboxStatus
  var reason: CommandInboxReason?
  var message: String?
}

/// Application Support 配下の JSON に保存する受信箱の状態。
/// 承認キューは W-04 でこの型に追加する。
struct CommandInboxState: Codable, Equatable, Sendable {
  /// 正規化した commandId → 処理日時（ISO 8601）
  var processedCommandIds: [String: String]
  /// ファイル単位エラーの内容ハッシュ → 記録日時
  var fileErrorHashes: [String: String]
  /// 適用履歴（新しい順・最大 500 件）
  var history: [CommandInboxHistoryEntry]

  init(
    processedCommandIds: [String: String] = [:],
    fileErrorHashes: [String: String] = [:],
    history: [CommandInboxHistoryEntry] = []
  ) {
    self.processedCommandIds = processedCommandIds
    self.fileErrorHashes = fileErrorHashes
    self.history = history
  }

  static let empty = CommandInboxState()

  func isProcessed(_ commandId: String) -> Bool {
    processedCommandIds[commandId] != nil
  }

  mutating func markProcessed(_ commandId: String, at date: Date) {
    processedCommandIds[commandId] = CommandInboxDate.string(from: date)
  }

  mutating func recordFileError(hash: String, at date: Date) {
    fileErrorHashes[hash] = CommandInboxDate.string(from: date)
  }

  func hasRecordedFileError(hash: String) -> Bool {
    fileErrorHashes[hash] != nil
  }

  mutating func appendHistory(_ entry: CommandInboxHistoryEntry) {
    history.insert(entry, at: 0)
    if history.count > CommandInboxConstants.maxHistory {
      history.removeLast(history.count - CommandInboxConstants.maxHistory)
    }
  }

  /// 保持期間を過ぎた記録を落とす（処理済み・ファイル単位エラーとも 30 日）。
  mutating func prune(now: Date) {
    let limit = now.addingTimeInterval(-CommandInboxConstants.retentionInterval)
    processedCommandIds = processedCommandIds.filter { _, value in
      guard let date = CommandInboxDate.parse(value) else { return false }
      return date >= limit
    }
    fileErrorHashes = fileErrorHashes.filter { _, value in
      guard let date = CommandInboxDate.parse(value) else { return false }
      return date >= limit
    }
  }
}
