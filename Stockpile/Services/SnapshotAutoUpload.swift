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

  /// 選択中の送信先に応じて振り分ける（G-04）
  static func uploadIfNeeded(items: [Item], familyName: String?) async -> Result {
    switch SnapshotLinkSettings.destination {
    case .customURL:
      return await uploadToCustomURL(items: items, familyName: familyName, force: false)
    case .googleDrive:
      return await uploadToDrive(items: items, familyName: familyName, force: false)
    }
  }

  /// コマンドの適用後にスナップショットを送る（仕様 1 章）。
  /// 自動送信の設定に関係なく、連携が有効なら送る。
  static func uploadAfterCommandApplied(items: [Item], familyName: String?) async -> Result {
    guard SnapshotLinkSettings.isEnabled else { return .skipped }
    switch SnapshotLinkSettings.destination {
    case .customURL:
      return await uploadToCustomURL(items: items, familyName: familyName, force: true)
    case .googleDrive:
      return await uploadToDrive(items: items, familyName: familyName, force: true)
    }
  }

  private static func uploadToCustomURL(
    items: [Item],
    familyName: String?,
    force: Bool
  ) async -> Result {
    let fingerprint = SnapshotFingerprint.compute(items: items, familyName: familyName)
    let endpoint = SnapshotLinkSettings.validatedEndpoint(
      SnapshotLinkSettings.endpointURLString)
    guard let endpoint, let token = SnapshotLinkKeychain.readWriteToken() else {
      return .skipped
    }

    if force {
      guard SnapshotLinkSettings.isEnabled, !fingerprint.isEmpty else { return .skipped }
    } else {
      guard
        SnapshotAutoUploadPolicy.shouldUpload(
          isLinkEnabled: SnapshotLinkSettings.isEnabled,
          isAutoUploadEnabled: SnapshotLinkSettings.autoUploadEnabled,
          endpoint: endpoint,
          hasWriteToken: true,
          fingerprint: fingerprint,
          lastUploadedFingerprint: SnapshotLinkSettings.lastUploadedFingerprint(for: .customURL)
        )
      else {
        return .skipped
      }
    }

    do {
      let data = try SnapshotBuilder.makeJSONData(items: items, familyName: familyName)
      _ = try await SnapshotUploader.upload(data: data, endpoint: endpoint, writeToken: token)
      SnapshotLinkSettings.setLastUploadedFingerprint(fingerprint, for: .customURL)
      SnapshotLinkSettings.setLastSentAt(Date(), for: .customURL)
      return .uploaded(itemCount: items.count)
    } catch {
      return .failed
    }
  }

  private static func uploadToDrive(
    items: [Item],
    familyName: String?,
    force: Bool
  ) async -> Result {
    guard SnapshotLinkSettings.isEnabled, GoogleDriveLinkManager.shared.currentUser != nil else {
      return .skipped
    }
    let fingerprint = SnapshotFingerprint.compute(items: items, familyName: familyName)
    guard !fingerprint.isEmpty else { return .skipped }
    if !force {
      guard
        SnapshotLinkSettings.autoUploadEnabled,
        fingerprint != SnapshotLinkSettings.lastUploadedFingerprint(for: .googleDrive)
      else {
        return .skipped
      }
    }

    do {
      let data = try SnapshotBuilder.makeJSONData(items: items, familyName: familyName)
      // GIDGoogleUser は Sendable ではないため、値を持ち回らずマネージャ経由で送信する
      try await GoogleDriveLinkManager.shared.uploadSnapshot(data: data)
      SnapshotLinkSettings.setLastUploadedFingerprint(fingerprint, for: .googleDrive)
      SnapshotLinkSettings.setLastSentAt(Date(), for: .googleDrive)
      return .uploaded(itemCount: items.count)
    } catch {
      return .failed
    }
  }
}
