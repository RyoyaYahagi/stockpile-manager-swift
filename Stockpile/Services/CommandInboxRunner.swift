import Foundation
import SwiftData
import UIKit

/// コマンド受信箱の取り込みと、適用後のスナップショット送信をまとめた入口。
///
/// `ContentView.processCommandInboxIfNeeded()` と同じ処理を、画面を経由しない
/// サイレントプッシュの経路からも使えるように切り出したもの。
/// `ContentView.swift` は別の担当が変更中のため、いまは処理が重複している。
/// PR で後から `ContentView` 側をこの型へ寄せる。
@MainActor
enum CommandInboxRunner {
  typealias RunOutcome = CommandInboxService.RunOutcome

  /// 受信箱を取り込み、1 件以上適用したらスナップショットを送る。
  static func processAndUploadIfNeeded(modelContext: ModelContext) async -> RunOutcome {
    guard !ScreenshotMode.isActive else { return .skipped }
    CommandInboxService.shared.configure(modelContext: modelContext)
    let outcome = await CommandInboxService.shared.processIfNeeded()
    guard outcome.appliedCount > 0 else { return outcome }

    // 取り込みの直前に描画されていた state ではなく、保存済みの最新状態を送る
    let storedItems = (try? modelContext.fetch(FetchDescriptor<Item>())) ?? []
    let storedFamilies = (try? modelContext.fetch(FetchDescriptor<Family>())) ?? []
    let scoped = SnapshotLinkScope.resolved(items: storedItems, families: storedFamilies)
    _ = await SnapshotAutoUploader.uploadAfterCommandApplied(
      items: scoped.items,
      familyName: scoped.family?.name
    )
    return outcome
  }

  /// 取り込み結果を iOS のバックグラウンド取得結果へ対応づける。
  /// 1 件以上適用したか結果を書き戻したら `.newData`、通信に失敗したら `.failed`、
  /// 何も起きていなければ `.noData`。
  nonisolated static func fetchResult(for outcome: RunOutcome) -> UIBackgroundFetchResult {
    if outcome.appliedCount > 0 || outcome.wroteResults {
      return .newData
    }
    if outcome.errorMessage != nil {
      return .failed
    }
    return .noData
  }
}

/// 受信箱のサイレントプッシュを受け取り、取り込みを実行する。
///
/// バックグラウンド起動では `ContentView` が表示されないことがあるため、
/// コンテナを用意できなければ作り直してから取り込む。
@MainActor
enum CommandInboxPushReceiver {
  static func handle(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
    guard CommandInboxWakePush.matches(userInfo) else { return .noData }
    guard !ScreenshotMode.isActive else { return .noData }

    let startup = ModelContainerStartup.shared
    if startup.container == nil {
      startup.retry()
    }
    guard let container = startup.container else {
      return .failed
    }

    let outcome = await CommandInboxRunner.processAndUploadIfNeeded(
      modelContext: container.mainContext)
    return CommandInboxRunner.fetchResult(for: outcome)
  }
}

/// `completionHandler` を 1 回だけ呼ぶためのゲート。
/// 取り込みが 30 秒の制限を超えそうなときは `.failed` で先に完了させる。
final class BackgroundFetchCompletionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var didComplete = false
  private let handler: (UIBackgroundFetchResult) -> Void

  init(handler: @escaping (UIBackgroundFetchResult) -> Void) {
    self.handler = handler
  }

  func complete(_ result: UIBackgroundFetchResult) {
    lock.lock()
    guard !didComplete else {
      lock.unlock()
      return
    }
    didComplete = true
    lock.unlock()
    handler(result)
  }
}
