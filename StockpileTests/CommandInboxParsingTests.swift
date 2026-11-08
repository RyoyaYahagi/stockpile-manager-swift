import Foundation
import Testing

@testable import Stockpile

// MARK: - テスト用の組み立て

enum CommandInboxTestFixture {
  /// テストの基準時刻（2026-11-08 10:00 JST）
  static let nowString = "2026-11-08T10:00:00+09:00"
  /// 競合検出に使う基準日時
  static let baseUpdatedAt = "2026-11-01T10:15:00+09:00"

  static var now: Date {
    CommandInboxDate.parse(nowString)!
  }

  static func date(_ offset: TimeInterval) -> Date {
    now.addingTimeInterval(offset)
  }

  static func commandsData(_ commands: [String]) -> Data {
    Data("{\"version\":1,\"commands\":[\(commands.joined(separator: ","))]}".utf8)
  }

  static func command(
    id: String = UUID().uuidString,
    issuedAt: String = nowString,
    origin: String = "muse",
    type: String = "item.add",
    payload: String = "{\"name\":\"水 2L\"}",
    baseUpdatedAt: String? = nil
  ) -> String {
    var fields = [
      "\"commandId\":\"\(id)\"",
      "\"issuedAt\":\"\(issuedAt)\"",
      "\"origin\":\"\(origin)\"",
      "\"type\":\"\(type)\"",
      "\"payload\":\(payload)",
    ]
    if let baseUpdatedAt {
      fields.append("\"baseUpdatedAt\":\"\(baseUpdatedAt)\"")
    }
    return "{\(fields.joined(separator: ","))}"
  }

  static func resultsFile(_ results: [CommandInboxResult]) -> CommandInboxResultsFile {
    CommandInboxResultsFile(results: results, updatedAt: nowString)
  }

  static func result(
    id: String?,
    status: CommandInboxStatus,
    reason: CommandInboxReason? = nil,
    at date: Date? = nil
  ) -> CommandInboxResult {
    CommandInboxResult(
      commandId: id,
      type: "item.add",
      origin: "muse",
      status: status,
      reason: reason,
      message: nil,
      processedAt: CommandInboxDate.string(from: date ?? now)
    )
  }

  static func rawCommands(_ data: Data) -> [CommandInboxRawCommand]? {
    guard case .commands(let commands) = CommandInboxParser.parseCommandsFile(data) else {
      return nil
    }
    return commands
  }

  static func envelope(_ commandJSON: String) -> CommandInboxEnvelope? {
    guard let raw = rawCommands(commandsData([commandJSON]))?.first else { return nil }
    return CommandInboxParser.parseEnvelope(raw)
  }

  static func violatesPayloadRules(_ commandJSON: String) -> Bool {
    guard let envelope = envelope(commandJSON) else { return true }
    return !CommandInboxPayloadValidator.validate(envelope)
  }
}

// MARK: - 封筒とファイルのパース

struct CommandInboxParsingTests {
  @Test
  func parsesValidEnvelope() throws {
    let id = "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10"
    let envelope = try #require(
      CommandInboxTestFixture.envelope(
        CommandInboxTestFixture.command(
          id: id,
          type: "item.update",
          payload: "{\"id\":\"3F2504E0-4F89-41D3-9A0C-0305E82C3301\",\"quantity\":2}",
          baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
        )
      )
    )

    #expect(envelope.commandId == id)
    #expect(envelope.origin == "muse")
    #expect(envelope.type == "item.update")
    #expect(envelope.commandType == .itemUpdate)
    #expect(envelope.payload["quantity"]?.integerValue == 2)
    #expect(envelope.baseUpdatedAt != nil)
    #expect(
      envelope.issuedAt == CommandInboxDate.parse(CommandInboxTestFixture.nowString))
  }

  @Test
  func normalizesCommandIdCase() throws {
    let envelope = try #require(
      CommandInboxTestFixture.envelope(
        CommandInboxTestFixture.command(id: "6b1f5c1e-1f1a-4c55-9e57-0b3f2f7d9a10")
      )
    )
    #expect(envelope.commandId == "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10")
  }

  @Test
  func rejectsMissingRequiredFields() throws {
    let id = "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10"
    let issuedAt = CommandInboxTestFixture.nowString
    let variants = [
      // commandId なし
      "{\"issuedAt\":\"\(issuedAt)\",\"origin\":\"muse\",\"type\":\"item.add\",\"payload\":{\"name\":\"水\"}}",
      // issuedAt なし
      "{\"commandId\":\"\(id)\",\"origin\":\"muse\",\"type\":\"item.add\",\"payload\":{\"name\":\"水\"}}",
      // origin なし
      "{\"commandId\":\"\(id)\",\"issuedAt\":\"\(issuedAt)\",\"type\":\"item.add\",\"payload\":{\"name\":\"水\"}}",
      // type なし
      "{\"commandId\":\"\(id)\",\"issuedAt\":\"\(issuedAt)\",\"origin\":\"muse\",\"payload\":{\"name\":\"水\"}}",
      // payload なし
      "{\"commandId\":\"\(id)\",\"issuedAt\":\"\(issuedAt)\",\"origin\":\"muse\",\"type\":\"item.add\"}",
      // issuedAt が ISO 8601 でない
      "{\"commandId\":\"\(id)\",\"issuedAt\":\"2026/11/08\",\"origin\":\"muse\",\"type\":\"item.add\",\"payload\":{\"name\":\"水\"}}",
      // origin が 101 文字
      "{\"commandId\":\"\(id)\",\"issuedAt\":\"\(issuedAt)\",\"origin\":\"\(String(repeating: "a", count: 101))\",\"type\":\"item.add\",\"payload\":{\"name\":\"水\"}}",
      // payload がオブジェクトでない
      "{\"commandId\":\"\(id)\",\"issuedAt\":\"\(issuedAt)\",\"origin\":\"muse\",\"type\":\"item.add\",\"payload\":\"水\"}",
    ]

    for variant in variants {
      #expect(
        CommandInboxTestFixture.envelope(variant) == nil,
        "必須項目が欠けた封筒を受理してはいけない: \(variant)"
      )
    }
  }

  @Test
  func rejectsNonUUIDCommandId() {
    #expect(
      CommandInboxTestFixture.envelope(
        CommandInboxTestFixture.command(id: "not-a-uuid")
      ) == nil
    )
  }

  @Test
  func rejectsBrokenJSON() {
    let result = CommandInboxParser.parseCommandsFile(Data("{not json".utf8))
    guard case .fileError(let reason, _) = result else {
      Issue.record("壊れた JSON はファイル単位のエラーにする")
      return
    }
    #expect(reason == .malformedFile)
  }

  @Test
  func rejectsVersionMismatch() {
    let result = CommandInboxParser.parseCommandsFile(
      Data("{\"version\":2,\"commands\":[]}".utf8))
    guard case .fileError(let reason, _) = result else {
      Issue.record("version 不一致はファイル単位のエラーにする")
      return
    }
    #expect(reason == .malformedFile)
  }

  @Test
  func rejectsMissingCommandsArray() {
    let result = CommandInboxParser.parseCommandsFile(Data("{\"version\":1}".utf8))
    guard case .fileError(let reason, _) = result else {
      Issue.record("commands 配列がないファイルはファイル単位のエラーにする")
      return
    }
    #expect(reason == .malformedFile)
  }

  @Test
  func rejectsTooManyCommands() {
    let commands = (0..<201).map { _ in CommandInboxTestFixture.command() }
    let result = CommandInboxParser.parseCommandsFile(
      CommandInboxTestFixture.commandsData(commands))
    guard case .fileError(let reason, _) = result else {
      Issue.record("200 件を超えたファイルはファイル単位のエラーにする")
      return
    }
    #expect(reason == .tooManyCommands)
  }

  @Test
  func rejectsFileLargerThanOneMegabyte() {
    let padding = String(repeating: "a", count: CommandInboxConstants.maxFileBytes + 1)
    let result = CommandInboxParser.parseCommandsFile(
      Data("{\"version\":1,\"commands\":[],\"padding\":\"\(padding)\"}".utf8))
    guard case .fileError(let reason, _) = result else {
      Issue.record("1MB を超えたファイルはファイル単位のエラーにする")
      return
    }
    #expect(reason == .malformedFile)
  }

  @Test
  func computesStableContentHashForSameFileError() {
    let data = Data("{broken".utf8)
    let first = CommandInboxParser.parseCommandsFile(data)
    let second = CommandInboxParser.parseCommandsFile(data)
    guard case .fileError(_, let firstHash) = first,
      case .fileError(_, let secondHash) = second
    else {
      Issue.record("壊れた JSON はファイル単位のエラーにする")
      return
    }
    #expect(firstHash == secondHash)
  }

  @Test
  func emptyCommandsFileParsesAsEmptyList() throws {
    let raws = try #require(
      CommandInboxTestFixture.rawCommands(CommandInboxParser.emptyCommandsData()))
    #expect(raws.isEmpty)
  }

  @Test
  func parsesResultsFile() throws {
    let file = CommandInboxTestFixture.resultsFile([
      CommandInboxTestFixture.result(id: "ABC", status: .applied)
    ])
    let decoded = try #require(
      CommandInboxParser.parseResultsFile(CommandInboxParser.encodeResultsFile(file)))
    #expect(decoded.version == 1)
    #expect(decoded.results.count == 1)
    #expect(decoded.results.first?.status == .applied)
  }

  @Test
  func rejectsResultsFileWithUnknownVersion() {
    let data = Data("{\"version\":9,\"results\":[]}".utf8)
    #expect(CommandInboxParser.parseResultsFile(data) == nil)
  }

  // MARK: payload の検証

  @Test
  func rejectsInvalidItemAddPayloads() {
    let id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    let invalidPayloads = [
      "{}",
      "{\"name\":\"\"}",
      "{\"name\":\"   \"}",
      "{\"name\":\"\(String(repeating: "a", count: 201))\"}",
      "{\"name\":\"水\",\"quantity\":0}",
      "{\"name\":\"水\",\"quantity\":1000000}",
      "{\"name\":\"水\",\"quantity\":1.5}",
      "{\"name\":\"水\",\"quantity\":\"2\"}",
      "{\"name\":\"水\",\"janCode\":\"\(String(repeating: "9", count: 33))\"}",
      "{\"name\":\"水\",\"expiryDate\":\"2027/03/31\"}",
      "{\"name\":\"水\",\"expiryDate\":\"2027-02-30\"}",
      "{\"name\":\"水\",\"locationNote\":\"\(String(repeating: "a", count: 2001))\"}",
      "{\"name\":\"水\",\"category\":\"unknown\"}",
    ]
    for payload in invalidPayloads {
      #expect(
        CommandInboxTestFixture.violatesPayloadRules(
          CommandInboxTestFixture.command(id: id, payload: payload)
        ),
        "不正な payload を受理してはいけない: \(payload)"
      )
    }
  }

  @Test
  func acceptsUnknownFieldsAndNulls() {
    let payload = """
      {"name":"水 2L","janCode":null,"quantity":null,"expiryDate":null,
       "bagName":null,"locationNote":null,"category":null,"futureField":true}
      """
    #expect(
      !CommandInboxTestFixture.violatesPayloadRules(
        CommandInboxTestFixture.command(payload: payload)
      )
    )
  }

  @Test
  func requiresItemIdentifierAndBaseUpdatedAt() {
    let itemID = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    // id がない item.update
    #expect(
      CommandInboxTestFixture.violatesPayloadRules(
        CommandInboxTestFixture.command(
          type: "item.update",
          payload: "{\"quantity\":2}",
          baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
        )
      )
    )
    // baseUpdatedAt がない item.delete
    #expect(
      CommandInboxTestFixture.violatesPayloadRules(
        CommandInboxTestFixture.command(
          type: "item.delete", payload: "{\"id\":\"\(itemID)\"}")
      )
    )
    // name / quantity は null 不可
    #expect(
      CommandInboxTestFixture.violatesPayloadRules(
        CommandInboxTestFixture.command(
          type: "item.update",
          payload: "{\"id\":\"\(itemID)\",\"name\":null}",
          baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
        )
      )
    )
    #expect(
      CommandInboxTestFixture.violatesPayloadRules(
        CommandInboxTestFixture.command(
          type: "item.update",
          payload: "{\"id\":\"\(itemID)\",\"quantity\":null}",
          baseUpdatedAt: CommandInboxTestFixture.baseUpdatedAt
        )
      )
    )
  }

  @Test
  func acceptsValidPayloadsForEveryCommandType() {
    let itemID = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    let base = CommandInboxTestFixture.baseUpdatedAt
    let valid = [
      CommandInboxTestFixture.command(payload: "{\"name\":\"水\",\"quantity\":2}"),
      CommandInboxTestFixture.command(
        type: "item.update",
        payload: "{\"id\":\"\(itemID)\",\"locationNote\":null,\"category\":\"waterDrink\"}",
        baseUpdatedAt: base
      ),
      CommandInboxTestFixture.command(
        type: "item.delete", payload: "{\"id\":\"\(itemID)\"}", baseUpdatedAt: base),
      CommandInboxTestFixture.command(type: "bag.add", payload: "{\"name\":\"非常袋\"}"),
      CommandInboxTestFixture.command(
        type: "bag.rename", payload: "{\"name\":\"非常袋\",\"newName\":\"防災袋\"}"),
      CommandInboxTestFixture.command(type: "bag.delete", payload: "{\"name\":\"非常袋\"}"),
    ]
    for json in valid {
      #expect(
        CommandInboxTestFixture.envelope(json) != nil, "封筒として受理されるべき: \(json)")
      #expect(
        !CommandInboxTestFixture.violatesPayloadRules(json),
        "payload が妥当と判定されるべき: \(json)"
      )
    }
  }
}
