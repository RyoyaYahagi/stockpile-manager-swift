import CryptoKit
import Foundation

// MARK: - スナップショットのフィンガープリント（変更検知）

/// generatedAt を除いたスナップショット内容の指紋。
/// 同じ内容なら同じ値になり、アイテムの追加・変更・削除で変わる。
/// 自動送信の「未送信の変更があるか」の判定に使う。
enum SnapshotFingerprint {
  static func compute(items: [Item], familyName: String?) -> String {
    // generatedAt はフィンガープリントに影響させないため固定値で生成する
    let snapshot = SnapshotBuilder.makeSnapshot(
      items: items,
      familyName: familyName,
      generatedAt: Date(timeIntervalSince1970: 0),
      appVersion: nil
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(snapshot) else { return "" }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - 自動送信の要否判定（純粋関数・テスト対象）

enum SnapshotAutoUploadPolicy {
  static func shouldUpload(
    isLinkEnabled: Bool,
    isAutoUploadEnabled: Bool,
    endpoint: URL?,
    hasWriteToken: Bool,
    fingerprint: String,
    lastUploadedFingerprint: String?
  ) -> Bool {
    guard isLinkEnabled, isAutoUploadEnabled else { return false }
    guard endpoint != nil, hasWriteToken else { return false }
    guard !fingerprint.isEmpty else { return false }
    return fingerprint != lastUploadedFingerprint
  }
}

// MARK: - 自動送信の実行

/// 変更検知つきの自動送信（S-05）。
/// 呼び出し側（ContentView）が起動時・復帰時・内容変化時に呼ぶ。
/// デバウンスは呼び出し側の .task(id:) の再起動に任せ、ここでは
/// フィンガープリント比較で「送るべき変更がある時だけ」送る。
/// 失敗してもフィンガープリントを更新しないため、次回の呼び出しで再試行される
/// （連続リトライはしない）。
@MainActor
enum SnapshotAutoUploader {
  enum Result {
    case uploaded(itemCount: Int)
    case skipped
    case failed
  }

  static func uploadIfNeeded(items: [Item], familyName: String?) async -> Result {
    // 送信先が Google Drive の間は URL 送信を行わない（Drive 送信は G-04 で統合する）
    guard SnapshotLinkSettings.destination == .customURL else { return .skipped }
    let fingerprint = SnapshotFingerprint.compute(items: items, familyName: familyName)
    let endpoint = SnapshotLinkSettings.validatedEndpoint(
      SnapshotLinkSettings.endpointURLString)
    let token = SnapshotLinkKeychain.readWriteToken()

    guard
      SnapshotAutoUploadPolicy.shouldUpload(
        isLinkEnabled: SnapshotLinkSettings.isEnabled,
        isAutoUploadEnabled: SnapshotLinkSettings.autoUploadEnabled,
        endpoint: endpoint,
        hasWriteToken: token != nil,
        fingerprint: fingerprint,
        lastUploadedFingerprint: SnapshotLinkSettings.lastUploadedFingerprint
      ), let endpoint, let token
    else {
      return .skipped
    }

    do {
      let data = try SnapshotBuilder.makeJSONData(items: items, familyName: familyName)
      _ = try await SnapshotUploader.upload(data: data, endpoint: endpoint, writeToken: token)
      SnapshotLinkSettings.lastUploadedFingerprint = fingerprint
      SnapshotLinkSettings.lastSentAt = Date()
      return .uploaded(itemCount: items.count)
    } catch {
      return .failed
    }
  }
}
