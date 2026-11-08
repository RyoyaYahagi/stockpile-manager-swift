import Foundation

// MARK: - 受信箱 URL の導出

/// スナップショットの送信先 URL から、Worker のコマンド受信箱の URL を求める。
///
/// アプリが設定するのはスナップショットの URL（例:
/// `https://example.workers.dev/v1/snapshot`）。パスが `/v1/snapshot`
/// （末尾スラッシュ可）で終わるときだけ、その部分を `/v1/commands` と
/// `/v1/command-results` に置き換える。それ以外の形の URL は Worker 以外の
/// 自前サーバーとみなし、受信箱非対応として nil を返す。
struct WorkerCommandInboxEndpoints: Equatable, Sendable {
  let commands: URL
  let results: URL

  private static let snapshotSuffix = "/v1/snapshot"
  private static let snapshotSuffixWithSlash = "/v1/snapshot/"

  init?(snapshotURL: URL) {
    guard snapshotURL.scheme?.lowercased() == "https", snapshotURL.host != nil else {
      return nil
    }

    let path = snapshotURL.path
    let suffix: String
    if path.hasSuffix(Self.snapshotSuffix) {
      suffix = Self.snapshotSuffix
    } else if path.hasSuffix(Self.snapshotSuffixWithSlash) {
      suffix = Self.snapshotSuffixWithSlash
    } else {
      return nil
    }

    let basePath = String(path.dropLast(suffix.count))
    guard
      let commands = Self.url(snapshotURL, replacingPathWith: basePath + "/v1/commands"),
      let results = Self.url(snapshotURL, replacingPathWith: basePath + "/v1/command-results")
    else {
      return nil
    }
    self.commands = commands
    self.results = results
  }

  private static func url(_ url: URL, replacingPathWith path: String) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = path
    return components.url
  }
}

// MARK: - Worker 実装

/// Worker のコマンド受信箱を読み書きする。
///
/// - `GET /v1/commands` と `GET /v1/command-results` で読み、`PUT /v1/command-results`
///   で書き戻す。認証はアプリの書き込みトークン（Keychain の `WRITE_TOKEN`）。
/// - Worker は未保存のファイルの GET に初期内容を 200 で返すため、`ensureFiles` は
///   何もしない。
/// - `COMMANDS_TOKEN` 未設定の Worker は 4 つの端点すべてを 404 にする。これは
///   機能オフであって通信の失敗ではないため、`inboxUnavailable` として伝える。
@MainActor
final class WorkerCommandInboxTransport: CommandInboxTransport {
  typealias Sender = @MainActor (URLRequest) async throws -> (Data, URLResponse)

  private let endpoints: WorkerCommandInboxEndpoints
  private let writeToken: String
  private let sender: Sender

  init(
    endpoints: WorkerCommandInboxEndpoints,
    writeToken: String,
    sender: @escaping Sender = { request in
      try await URLSession.shared.data(for: request)
    }
  ) {
    self.endpoints = endpoints
    self.writeToken = writeToken
    self.sender = sender
  }

  func ensureFiles() async throws {
    // Worker は未保存でも GET が初期内容を返すため、ファイルを作る必要はない。
  }

  func readCommands() async throws -> Data? {
    try await get(endpoints.commands)
  }

  func readResults() async throws -> Data? {
    try await get(endpoints.results)
  }

  func writeResults(_ data: Data) async throws {
    var request = makeRequest(url: endpoints.results, method: "PUT")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    _ = try await send(request)
  }

  // MARK: 内部

  private func get(_ url: URL) async throws -> Data? {
    try await send(makeRequest(url: url, method: "GET"))
  }

  private func makeRequest(url: URL, method: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(writeToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await sender(request)
    } catch {
      throw SnapshotUploadError.network(error)
    }

    guard let http = response as? HTTPURLResponse else {
      throw SnapshotUploadError.network(URLError(.badServerResponse))
    }

    switch http.statusCode {
    case 200:
      return data
    case 401:
      throw SnapshotUploadError.unauthorized
    case 404 where request.httpMethod == "GET":
      throw WorkerCommandInboxError.inboxUnavailable
    default:
      let message =
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
      throw SnapshotUploadError.server(statusCode: http.statusCode, message: message)
    }
  }
}

/// Worker の受信箱が機能オフ（`COMMANDS_TOKEN` 未設定）で 404 を返したことを表す。
/// 通信の失敗ではないため、取り込み側はエラーにせず「受信箱なし」として扱う。
enum WorkerCommandInboxError: Error, Equatable, LocalizedError {
  case inboxUnavailable

  var errorDescription: String? {
    switch self {
    case .inboxUnavailable:
      return L10n.string("コマンド受信箱が有効になっていません")
    }
  }
}
