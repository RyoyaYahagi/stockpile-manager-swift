import Foundation
import Testing
import UIKit

@testable import Stockpile

// MARK: - ペイロードの判定

struct CommandInboxWakePushTests {
  @Test
  func matchesCommandInboxWake() {
    let userInfo: [AnyHashable: Any] = [
      "aps": ["content-available": 1],
      "stockpile": ["wake": "commandInbox"],
    ]

    #expect(CommandInboxWakePush.matches(userInfo))
  }

  @Test
  func rejectsCloudKitPush() {
    let userInfo: [AnyHashable: Any] = [
      "ck": ["cid": "iCloud.example"],
      "stockpile": ["wake": "commandInbox"],
    ]

    #expect(!CommandInboxWakePush.matches(userInfo))
  }

  @Test
  func rejectsPayloadWithoutStockpileKey() {
    let userInfo: [AnyHashable: Any] = [
      "aps": ["content-available": 1]
    ]

    #expect(!CommandInboxWakePush.matches(userInfo))
  }

  @Test
  func rejectsDifferentWakeValue() {
    let userInfo: [AnyHashable: Any] = [
      "stockpile": ["wake": "snapshot"]
    ]

    #expect(!CommandInboxWakePush.matches(userInfo))
  }

  @Test
  func rejectsNonStringWakeValue() {
    let userInfo: [AnyHashable: Any] = [
      "stockpile": ["wake": 1]
    ]

    #expect(!CommandInboxWakePush.matches(userInfo))
  }

  @Test
  func rejectsNonDictionaryStockpileValue() {
    let userInfo: [AnyHashable: Any] = [
      "stockpile": "commandInbox"
    ]

    #expect(!CommandInboxWakePush.matches(userInfo))
  }
}

// MARK: - 取り込みの前提条件

struct CommandInboxReadinessTests {
  @Test
  func requiresConfiguredHandler() {
    #expect(!CommandInboxService.canProcess(handlerConfigured: false))
    #expect(CommandInboxService.canProcess(handlerConfigured: true))
  }

  @Test
  @MainActor
  func unconfiguredServiceSkipsWithoutRunning() async {
    let service = CommandInboxService()
    let outcome = await service.processIfNeeded()

    #expect(outcome.didRun == false)
    #expect(outcome.appliedCount == 0)
    #expect(outcome.wroteResults == false)
    #expect(outcome.errorMessage == nil)
  }
}

// MARK: - バックグラウンド取得結果への対応

struct CommandInboxFetchResultTests {
  @Test
  func skippedMeansNoData() {
    #expect(CommandInboxRunner.fetchResult(for: .skipped) == .noData)
  }

  @Test
  func appliedCommandMeansNewData() {
    let outcome = CommandInboxService.RunOutcome(
      didRun: true, appliedCount: 1, wroteResults: false, errorMessage: nil)

    #expect(CommandInboxRunner.fetchResult(for: outcome) == .newData)
  }

  @Test
  func writtenResultsMeanNewData() {
    let outcome = CommandInboxService.RunOutcome(
      didRun: true, appliedCount: 0, wroteResults: true, errorMessage: nil)

    #expect(CommandInboxRunner.fetchResult(for: outcome) == .newData)
  }

  @Test
  func communicationFailureMeansFailed() {
    let outcome = CommandInboxService.RunOutcome(
      didRun: true, appliedCount: 0, wroteResults: false, errorMessage: "通信に失敗しました")

    #expect(CommandInboxRunner.fetchResult(for: outcome) == .failed)
  }

  @Test
  func appliedCommandWinsOverWriteFailure() {
    let outcome = CommandInboxService.RunOutcome(
      didRun: true, appliedCount: 1, wroteResults: false, errorMessage: "書き戻しに失敗しました")

    #expect(CommandInboxRunner.fetchResult(for: outcome) == .newData)
  }

  @Test
  func nothingHappenedMeansNoData() {
    let outcome = CommandInboxService.RunOutcome(
      didRun: true, appliedCount: 0, wroteResults: false, errorMessage: nil)

    #expect(CommandInboxRunner.fetchResult(for: outcome) == .noData)
  }
}
