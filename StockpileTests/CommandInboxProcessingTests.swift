import Foundation
import Testing

@testable import Stockpile

// MARK: - テスト用のハンドラ

private struct StubCommandHandler: CommandHandler {
  let result: CommandInboxHandlingResult

  func handle(_ command: CommandInboxEnvelope, now: Date) async -> CommandInboxHandlingResult {
    result
  }
}

// MARK: - 処理ループ

struct CommandInboxProcessingTests {
  private func run(
    _ commands: Data,
    existing: CommandInboxResultsFile? = nil,
    state: CommandInboxState = .empty,
    now: Date = CommandInboxTestFixture.now,
    handler: any CommandHandler = WritesDisabledCommandHandler()
  ) async -> CommandInboxProcessingOutput {
    await CommandInboxProcessor.process(
      commandsData: commands,
      existingResults: existing,
      state: state,
      now: now,
      handler: handler
    )
  }

  @Test
  func emptyCommandsDoNothing() async {
    let output = await run(CommandInboxParser.emptyCommandsData())

    #expect(output.handledCount == 0)
    #expect(output.appliedCount == 0)
    #expect(output.resultsChanged == false)
    #expect(output.results.results.isEmpty)
    #expect(output.state == .empty)
  }

  @Test
  func emptyCommandsKeepExistingResults() async {
    let existing = CommandInboxTestFixture.resultsFile([
      CommandInboxTestFixture.result(id: "KEEP", status: .applied, at: CommandInboxTestFixture.date(-60))
    ])
    let output = await run(CommandInboxParser.emptyCommandsData(), existing: existing)

    #expect(output.resultsChanged == false)
    #expect(output.results.results.map(\.commandId) == ["KEEP"])
  }

  @Test
  func defaultHandlerRejectsEveryKnownCommand() async throws {
    let output = await run(
      CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(),
        CommandInboxTestFixture.command(
          type: "bag.add", payload: "{\"name\":\"非常袋\"}"),
      ]))

    #expect(output.handledCount == 2)
    #expect(output.appliedCount == 0)
    #expect(output.resultsChanged)
    let results = output.results.results
    #expect(results.count == 2)
    #expect(results.allSatisfy { $0.status == .rejected })
    #expect(results.allSatisfy { $0.reason == .writesDisabled })
    #expect(results.allSatisfy { $0.type != nil })
  }

  @Test
  func appliedHandlerCountsApplied() async throws {
    let id = "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10"
    let handler = StubCommandHandler(
      result: .applied(message: "適用しました", itemId: id))
    let output = await run(
      CommandInboxTestFixture.commandsData([CommandInboxTestFixture.command(id: id)]),
      handler: handler
    )

    #expect(output.appliedCount == 1)
    let entry = try #require(output.results.results.first)
    #expect(entry.commandId == id)
    #expect(entry.status == .applied)
    #expect(entry.reason == nil)
    #expect(entry.itemId == id)
    #expect(entry.message == "適用しました")
  }

  // MARK: 冪等性

  @Test
  func duplicateCommandIdIsHandledOnce() async {
    let id = "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10"
    let output = await run(
      CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(id: id, payload: "{\"name\":\"水\"}"),
        CommandInboxTestFixture.command(id: id.lowercased(), payload: "{\"name\":\"茶\"}"),
      ]))

    #expect(output.handledCount == 1)
    #expect(output.results.results.count == 1)
    #expect(output.results.results.first?.commandId == id)
  }

  @Test
  func secondRunSkipsProcessedCommands() async {
    let data = CommandInboxTestFixture.commandsData([
      CommandInboxTestFixture.command()
    ])
    let first = await run(data)
    #expect(first.handledCount == 1)

    let second = await run(data, existing: first.results, state: first.state)
    #expect(second.handledCount == 0)
    #expect(second.resultsChanged == false)
    #expect(second.results == first.results)
  }

  @Test
  func finalStatusInResultsCountsAsProcessed() async {
    let id = "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10"
    let existing = CommandInboxTestFixture.resultsFile([
      CommandInboxTestFixture.result(id: id.lowercased(), status: .rejected)
    ])
    let output = await run(
      CommandInboxTestFixture.commandsData([CommandInboxTestFixture.command(id: id)]),
      existing: existing
    )

    #expect(output.handledCount == 0)
    #expect(output.resultsChanged == false)
  }

  @Test
  func pendingApprovalInResultsIsReprocessed() async {
    let id = "6B1F5C1E-1F1A-4C55-9E57-0B3F2F7D9A10"
    let existing = CommandInboxTestFixture.resultsFile([
      CommandInboxTestFixture.result(id: id, status: .pendingApproval)
    ])
    let output = await run(
      CommandInboxTestFixture.commandsData([CommandInboxTestFixture.command(id: id)]),
      existing: existing
    )

    // pending_approval は最終状態ではないため、処理済みとして扱わない（仕様 7 章）
    #expect(output.handledCount == 1)
    #expect(output.results.results.count == 1)
    #expect(output.results.results.first?.status == .rejected)
  }

  // MARK: 失効

  @Test
  func expiresOnlyAfterSevenDays() async throws {
    let issuedAtSevenDaysAgo = CommandInboxDate.string(
      from: CommandInboxTestFixture.date(-CommandInboxConstants.expiryInterval))
    let justWithin = CommandInboxDate.string(
      from: CommandInboxTestFixture.date(-CommandInboxConstants.expiryInterval + 1))
    let justOver = CommandInboxDate.string(
      from: CommandInboxTestFixture.date(-CommandInboxConstants.expiryInterval - 1))

    let exact = await run(
      CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(issuedAt: issuedAtSevenDaysAgo)
      ]))
    let exactEntry = try #require(exact.results.results.first)
    #expect(exactEntry.status == .rejected)

    let within = await run(
      CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(issuedAt: justWithin)
      ]))
    #expect(within.results.results.first?.status == .rejected)

    let over = await run(
      CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(issuedAt: justOver)
      ]))
    let overEntry = try #require(over.results.results.first)
    #expect(overEntry.status == .expired)
    #expect(overEntry.reason == .expired)
  }

  // MARK: 未知 type・検証失敗

  @Test
  func unknownTypeIsUnsupported() async throws {
    let output = await run(
      CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(type: "item.archive", payload: "{}")
      ]))
    let entry = try #require(output.results.results.first)
    #expect(entry.status == .unsupported)
    #expect(entry.reason == .unknownType)
  }

  @Test
  func invalidPayloadIsReported() async throws {
    let output = await run(
      CommandInboxTestFixture.commandsData([
        CommandInboxTestFixture.command(payload: "{\"quantity\":0}")
      ]))
    let entry = try #require(output.results.results.first)
    #expect(entry.status == .invalid)
    #expect(entry.reason == .invalidPayload)
  }

  @Test
  func invalidEnvelopeKeepsCommandIdAndIsNotRetried() async throws {
    let rawId = "not-a-uuid"
    let data = CommandInboxTestFixture.commandsData([
      CommandInboxTestFixture.command(id: rawId)
    ])
    let first = await run(data)
    let entry = try #require(first.results.results.first)
    #expect(entry.commandId == rawId)
    #expect(entry.status == .invalid)
    #expect(entry.reason == .invalidEnvelope)

    let second = await run(data, existing: first.results, state: first.state)
    #expect(second.handledCount == 0)
  }

  @Test
  func malformedFileIsReportedOnce() async throws {
    let data = Data("{broken".utf8)
    let first = await run(data)
    #expect(first.handledCount == 1)
    let entry = try #require(first.results.results.first)
    #expect(entry.commandId == nil)
    #expect(entry.status == .invalid)
    #expect(entry.reason == .malformedFile)

    let second = await run(data, existing: first.results, state: first.state)
    #expect(second.handledCount == 0)
    #expect(second.resultsChanged == false)
    #expect(second.results.results.count == 1)
  }

  @Test
  func tooManyCommandsIsReportedAsFileError() async throws {
    let commands = (0..<201).map { _ in CommandInboxTestFixture.command() }
    let output = await run(CommandInboxTestFixture.commandsData(commands))

    let entry = try #require(output.results.results.first)
    #expect(output.results.results.count == 1)
    #expect(entry.commandId == nil)
    #expect(entry.status == .invalid)
    #expect(entry.reason == .tooManyCommands)
  }

  // MARK: 状態の保持

  @Test
  func prunesProcessedCommandIdsAfterThirtyDays() {
    var state = CommandInboxState.empty
    state.markProcessed(
      "OLD", at: CommandInboxTestFixture.date(-CommandInboxConstants.retentionInterval - 1))
    state.markProcessed(
      "NEW", at: CommandInboxTestFixture.date(-CommandInboxConstants.retentionInterval + 1))

    state.prune(now: CommandInboxTestFixture.now)

    #expect(state.processedCommandIds.keys.sorted() == ["NEW"])
  }

  @Test
  func storeRoundTripsState() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CommandInboxTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = CommandInboxStore(fileURL: directory.appendingPathComponent("state.json"))
    var state = CommandInboxState.empty
    state.markProcessed("ABC", at: CommandInboxTestFixture.now)
    state.recordFileError(hash: "hash", at: CommandInboxTestFixture.now)
    state.appendHistory(
      CommandInboxHistoryEntry(
        occurredAt: CommandInboxTestFixture.nowString,
        origin: "muse",
        type: "item.add",
        status: .rejected,
        reason: .writesDisabled,
        message: "オフ"
      ))

    try store.save(state)
    #expect(store.load() == state)
  }
}

// MARK: - 結果のマージ

struct CommandInboxResultsMergerTests {
  @Test
  func keepsLatestRowPerCommandId() {
    let old = CommandInboxTestFixture.result(
      id: "abc", status: .pendingApproval, at: CommandInboxTestFixture.date(-60))
    let new = CommandInboxTestFixture.result(
      id: "ABC", status: .applied, at: CommandInboxTestFixture.now)

    let merged = CommandInboxResultsMerger.merge(
      existing: [old], adding: [new], now: CommandInboxTestFixture.now)

    #expect(merged.count == 1)
    #expect(merged.first?.status == .applied)
    #expect(merged.first?.commandId == "ABC")
  }

  @Test
  func keepsOnlyLatestTwoHundredResults() {
    let entries = (0..<250).map { index in
      CommandInboxTestFixture.result(
        id: "ID-\(index)",
        status: .rejected,
        at: CommandInboxTestFixture.date(-Double(index))
      )
    }

    let merged = CommandInboxResultsMerger.merge(
      existing: [], adding: entries, now: CommandInboxTestFixture.now)

    #expect(merged.count == CommandInboxConstants.maxResults)
    #expect(merged.first?.commandId == "ID-0")
    #expect(merged.contains { $0.commandId == "ID-199" })
    #expect(!merged.contains { $0.commandId == "ID-200" })
  }

  @Test
  func dropsResultsOlderThanThirtyDays() {
    let old = CommandInboxTestFixture.result(
      id: "OLD",
      status: .applied,
      at: CommandInboxTestFixture.date(-CommandInboxConstants.retentionInterval - 1)
    )
    let fresh = CommandInboxTestFixture.result(
      id: "NEW",
      status: .applied,
      at: CommandInboxTestFixture.date(-CommandInboxConstants.retentionInterval + 1)
    )

    let merged = CommandInboxResultsMerger.merge(
      existing: [old, fresh], adding: [], now: CommandInboxTestFixture.now)

    #expect(merged.map(\.commandId) == ["NEW"])
  }

  @Test
  func keepsSingleFileLevelError() {
    let older = CommandInboxTestFixture.result(
      id: nil, status: .invalid, reason: .malformedFile, at: CommandInboxTestFixture.date(-60))
    let newer = CommandInboxTestFixture.result(
      id: nil, status: .invalid, reason: .tooManyCommands, at: CommandInboxTestFixture.now)

    let merged = CommandInboxResultsMerger.merge(
      existing: [older], adding: [newer], now: CommandInboxTestFixture.now)

    #expect(merged.count == 1)
    #expect(merged.first?.reason == .tooManyCommands)
  }

  @Test
  func carriedUnsentResultsAreTreatedAsAlreadyReported() async throws {
    // 前回書き戻せなかった applied 行は、結果ファイルに載っているものとして扱い再処理しない
    let carried = CommandInboxTestFixture.result(
      id: "CARRIED", status: .applied, at: CommandInboxTestFixture.date(-60))
    let combined = CommandInboxService.combine(
      remote: nil, carried: [carried], now: CommandInboxTestFixture.now)

    #expect(combined?.results.map(\.commandId) == ["CARRIED"])
    #expect(
      CommandInboxService.combine(remote: nil, carried: [], now: CommandInboxTestFixture.now)
        == nil)
  }

  @Test
  func unsentResultsSurviveStateRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CommandInboxStore(fileURL: directory.appendingPathComponent("state.json"))
    let row = CommandInboxTestFixture.result(
      id: "UNSENT", status: .applied, at: CommandInboxTestFixture.now)

    try store.save(CommandInboxState(unsentResults: [row]))

    #expect(store.load().unsentResults?.map(\.commandId) == ["UNSENT"])
  }
}
