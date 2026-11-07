import Foundation
import Security
import SwiftData

// MARK: - スナップショット（スキーマ v1）

/// Muse連携用スナップショット。形式の正は docs/snapshot-schema-v1.md。
/// バックアップ書き出しとは別形式で、id と生成日時を持つ。
struct StockpileSnapshot: Codable {
  var schemaVersion: Int
  var generatedAt: String
  var appVersion: String?
  var familyName: String?
  var items: [SnapshotItem]

  struct SnapshotItem: Codable {
    var id: String
    var name: String
    var janCode: String?
    var quantity: Int
    var expiryDate: String?
    var bagName: String?
    var locationNote: String?
    var updatedAt: String
  }
}

enum SnapshotBuilder {
  static let schemaVersion = 1

  private static var dayFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  private static var dateTimeFormatter: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone.current
    return formatter
  }

  static func makeSnapshot(
    items: [Item],
    familyName: String?,
    generatedAt: Date = Date(),
    appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  ) -> StockpileSnapshot {
    let dateTime = dateTimeFormatter
    let day = dayFormatter
    return StockpileSnapshot(
      schemaVersion: schemaVersion,
      generatedAt: dateTime.string(from: generatedAt),
      appVersion: appVersion,
      familyName: familyName,
      items: items.map { item in
        StockpileSnapshot.SnapshotItem(
          id: item.id.uuidString,
          name: item.name,
          janCode: item.janCode,
          quantity: item.quantity,
          expiryDate: item.expiryDate.map { day.string(from: $0) },
          bagName: item.bag?.name,
          locationNote: item.locationNote,
          updatedAt: dateTime.string(from: item.syncTimestamp)
        )
      }
    )
  }

  static func makeJSONData(
    items: [Item],
    familyName: String?,
    generatedAt: Date = Date()
  ) throws -> Data {
    let snapshot = makeSnapshot(items: items, familyName: familyName, generatedAt: generatedAt)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(snapshot)
  }
}

// MARK: - 連携設定の保存（URL・有効状態は UserDefaults、トークンは Keychain）

/// 送信先の種類（G-02）。自分の送信先URL（Cloudflare Worker 等）と
/// Google Drive は併存し、利用者がどちらか一方を選ぶ。
enum SnapshotDestination: String {
  case customURL
  case googleDrive
}

enum SnapshotLinkSettings {
  private static let enabledKey = "snapshotLink.enabled"
  private static let endpointKey = "snapshotLink.endpointURL"
  private static let destinationKey = "snapshotLink.destination"
  private static let lastSentAtKey = "snapshotLink.lastSentAt"
  private static let autoUploadEnabledKey = "snapshotLink.autoUploadEnabled"
  private static let lastUploadedFingerprintKey = "snapshotLink.lastUploadedFingerprint"

  /// 選択中の送信先。未設定時は従来どおりカスタムURL。
  static var destination: SnapshotDestination {
    get {
      SnapshotDestination(
        rawValue: UserDefaults.standard.string(forKey: destinationKey) ?? "") ?? .customURL
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: destinationKey) }
  }

  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  /// 自動送信（S-05）の ON/OFF。手動送信とは別に切り替える。デフォルト OFF。
  static var autoUploadEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: autoUploadEnabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: autoUploadEnabledKey) }
  }

  /// 最後に送信成功したスナップショットのフィンガープリント（変更検知用）
  static var lastUploadedFingerprint: String? {
    get { UserDefaults.standard.string(forKey: lastUploadedFingerprintKey) }
    set { UserDefaults.standard.set(newValue, forKey: lastUploadedFingerprintKey) }
  }

  static var endpointURLString: String {
    get { UserDefaults.standard.string(forKey: endpointKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: endpointKey) }
  }

  static var lastSentAt: Date? {
    get { UserDefaults.standard.object(forKey: lastSentAtKey) as? Date }
    set { UserDefaults.standard.set(newValue, forKey: lastSentAtKey) }
  }

  // MARK: 送信先ごとの送信記録（G-04）

  private static let driveLastSentAtKey = "snapshotLink.drive.lastSentAt"
  private static let driveLastUploadedFingerprintKey =
    "snapshotLink.drive.lastUploadedFingerprint"

  /// 送信先ごとの最終送信日時。カスタムURLは従来キー、Drive は専用キーで分けて保持する
  /// （送信先を切り替えた時に、もう一方の記録で「送信済み」と誤判定しないため）。
  static func lastSentAt(for destination: SnapshotDestination) -> Date? {
    switch destination {
    case .customURL:
      return lastSentAt
    case .googleDrive:
      return UserDefaults.standard.object(forKey: driveLastSentAtKey) as? Date
    }
  }

  static func setLastSentAt(_ date: Date?, for destination: SnapshotDestination) {
    switch destination {
    case .customURL:
      lastSentAt = date
    case .googleDrive:
      UserDefaults.standard.set(date, forKey: driveLastSentAtKey)
    }
  }

  /// 送信先ごとの最終フィンガープリント（変更検知用）
  static func lastUploadedFingerprint(for destination: SnapshotDestination) -> String? {
    switch destination {
    case .customURL:
      return lastUploadedFingerprint
    case .googleDrive:
      return UserDefaults.standard.string(forKey: driveLastUploadedFingerprintKey)
    }
  }

  static func setLastUploadedFingerprint(
    _ value: String?, for destination: SnapshotDestination
  ) {
    switch destination {
    case .customURL:
      lastUploadedFingerprint = value
    case .googleDrive:
      UserDefaults.standard.set(value, forKey: driveLastUploadedFingerprintKey)
    }
  }

  /// 送信先として妥当な HTTPS URL かどうか
  static func validatedEndpoint(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else {
      return nil
    }
    return url
  }
}

// MARK: - 送信対象のスコープ（バックアップ書き出しと同じ規則）

enum SnapshotLinkScope {
  /// 現在のファミリーに属するアイテムと、そのファミリーを返す。
  /// 設定画面と自動送信で同じ規則を使うための共通化。
  static func resolved(items: [Item], families: [Family]) -> (items: [Item], family: Family?) {
    let family = CurrentFamilyResolver.currentFamily(from: families)
    guard let family else {
      return (items.filter { $0.family == nil }, nil)
    }
    let familyItems = items.filter { $0.family?.id == family.id }
    if !familyItems.isEmpty || family.prefersStrictCloudKitScoping {
      return (familyItems, family)
    }
    return (items.filter { $0.family == nil }, family)
  }
}

// MARK: - 書き込みトークンの Keychain 保存

/// 書き込みトークンは UserDefaults や Info.plist に置かず、Keychain にだけ保存する。
/// 読み取りトークンは端末に保存しない（AI 側にだけ渡す）。
enum SnapshotLinkKeychain {
  private static let service = (Bundle.main.bundleIdentifier ?? "Stockpile") + ".snapshot-link"
  private static let account = "writeToken"

  static func saveWriteToken(_ token: String) {
    let data = Data(token.utf8)
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    guard !token.isEmpty else { return }
    var attributes = base
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(attributes as CFDictionary, nil)
  }

  static func readWriteToken() -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
      let data = result as? Data,
      let token = String(data: data, encoding: .utf8),
      !token.isEmpty
    else {
      return nil
    }
    return token
  }
}

// MARK: - 送信

enum SnapshotUploadError: Error, LocalizedError {
  case notConfigured
  case invalidEndpoint
  case unauthorized
  case server(statusCode: Int, message: String?)
  case network(Error)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return L10n.string("送信先URLとトークンを設定してください")
    case .invalidEndpoint:
      return L10n.string("送信先URLが正しくありません（HTTPSのURLを入力してください）")
    case .unauthorized:
      return L10n.string("認証に失敗しました。書き込みトークンが正しいか確認してください")
    case .server(let statusCode, let message):
      if let message, !message.isEmpty {
        return L10n.format("送信先がエラーを返しました（%@）: %@", String(statusCode), message)
      }
      return L10n.format("送信先がエラーを返しました（%@）", String(statusCode))
    case .network(let error):
      return L10n.format("通信エラー: %@", error.localizedDescription)
    }
  }
}

enum SnapshotUploader {
  /// スナップショットを PUT で送信する。成功時はサーバーの応答JSONを返す。
  static func upload(data: Data, endpoint: URL, writeToken: String) async throws -> [String: Any] {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "PUT"
    request.setValue("Bearer \(writeToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data

    let responseData: Data
    let response: URLResponse
    do {
      (responseData, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw SnapshotUploadError.network(error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw SnapshotUploadError.network(URLError(.badServerResponse))
    }

    switch http.statusCode {
    case 200:
      let object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
      return object ?? [:]
    case 401:
      throw SnapshotUploadError.unauthorized
    default:
      let message =
        ((try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any])?["error"]
        as? String
      throw SnapshotUploadError.server(statusCode: http.statusCode, message: message)
    }
  }
}

// MARK: - セットアッププロンプト（アプリ内に表示する連携依頼文）

/// 利用者が自分の AI アシスタント（Muse）に貼るためのセットアップ依頼文。
/// 文面の正はプロジェクト側の setup-prompt 文案（stockpile-link-prompt v1）。
/// トークンはこの文に含めない。URL だけを差し込む。
enum SnapshotLinkPrompt {
  static let promptVersion = "stockpile-link-prompt v1"

  static func makePrompt(snapshotURLString: String) -> String {
    let url = snapshotURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    let urlText = url.isEmpty ? "（設定した送信先URL）" : url
    return """
      私の防災備蓄アプリ「Stockpile」との読み取り専用連携を設定してください。
      （\(promptVersion) / スナップショットスキーマ v1）


      - 私の備蓄スナップショット（JSON）は次の URL から取得できます:
      \(urlText)
      - 形式はスキーマ v1 です: 先頭に schemaVersion / generatedAt を持ち、items に
      name / janCode / quantity / expiryDate(yyyy-MM-dd) / bagName / locationNote /
      id / updatedAt が入っています。
      - 読み取りトークンが必要です。トークンはこのチャットには貼りません。
      あなたの安全な入力方法（API アクセス設定）で別途渡すので、その手順を案内してください。


      1. 読み取り専用のカスタムコネクタ（custom.stockpile）と CLI:
      - status: 生成日時・件数・情報の鮮さ
      - items: 在庫一覧（保管場所で絞り込み可）
      - expiring: 期限が近い順の一覧
      - get: 1件の詳細
      書き込み系の機能は作らないでください。
      2. 世帯設定のヒアリングと保存:
      - 世帯人数と、備蓄の目標日数を私に聞いて、あなた側の設定に保存してください
      （アプリ側にはこの設定はありません）。
      - 充足の目安は、前提を明示した上で使ってください（例: 飲料水 3L/人/日）。
      内容量が分からない品目は概算であることを分けて書いてください。
      3. 月1回の定期チェック:
      - 期限切れ・7日以内の期限・30日以上スナップショットが更新されていない時だけ
      知らせてください。条件に当たらない月は何も送らないでください。


      - 在庫について答える時は、必ず generatedAt（いつの情報か）を添えてください。
      - 期限の区分はアプリに合わせて「7日以内」「30日以内」でお願いします。
      - 補充の提案はリスト作成と価格比較までで、注文や購入は行わないでください。
      - この連携は読み取り専用です。アプリのデータを変更しようとしないでください。

      まず、トークンの安全な受け渡し手順から始めてください。
      """
  }
}
