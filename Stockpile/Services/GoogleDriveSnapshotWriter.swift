import Foundation
import GoogleSignIn

// MARK: - Google Drive への書き込みエラー

enum GoogleDriveUploadError: Error, LocalizedError {
  case notSignedIn
  case unauthorized
  case server(statusCode: Int, message: String?)
  case invalidResponse
  case network(Error)

  var errorDescription: String? {
    switch self {
    case .notSignedIn:
      return L10n.string("Google Driveと連携していません")
    case .unauthorized:
      return L10n.string("Google Driveの認証が切れています。連携し直してください")
    case .server(let statusCode, let message):
      if let message, !message.isEmpty {
        return L10n.format("Google Driveがエラーを返しました（%@）: %@", String(statusCode), message)
      }
      return L10n.format("Google Driveがエラーを返しました（%@）", String(statusCode))
    case .invalidResponse:
      return L10n.string("Google Driveからの応答が正しくありませんでした")
    case .network(let error):
      return L10n.format("通信エラー: %@", error.localizedDescription)
    }
  }
}

// MARK: - Google Drive へのスナップショット書き込み（G-03）

/// Drive API v3 を REST で直接叩く書き込み担当。専用クライアントライブラリは使わない。
/// 配置先は「Stockpile」フォルダ直下の `snapshot.json` 固定（Gシリーズの決定事項）。
/// スコープは drive.file のため、ここから見えるのはこのアプリが作ったファイルだけ。
/// 送信タイミングの制御（手動・自動の振り分け）は G-04 が担い、ここは書き込みだけを行う。
enum GoogleDriveSnapshotWriter {
  static let folderName = "Stockpile"
  static let fileName = "snapshot.json"

  private static let folderMimeType = "application/vnd.google-apps.folder"
  private static let filesBase = "https://www.googleapis.com/drive/v3/files"
  private static let uploadBase = "https://www.googleapis.com/upload/drive/v3/files"

  /// スナップショットを Drive に保存する。
  /// 401 の場合はトークンを更新してもう1回だけ再試行する（それ以上は繰り返さない）。
  static func upload(data: Data, user: GIDGoogleUser) async throws {
    do {
      try await uploadOnce(data: data, user: user)
    } catch GoogleDriveUploadError.unauthorized {
      _ = try? await user.refreshTokensIfNeeded()
      try await uploadOnce(data: data, user: user)
    }
  }

  private static func uploadOnce(data: Data, user: GIDGoogleUser) async throws {
    let refreshedUser = try await user.refreshTokensIfNeeded()
    let token = refreshedUser.accessToken.tokenString
    let folderID = try await ensureFolder(accessToken: token)
    if let fileID = try await findSnapshotFile(accessToken: token, folderID: folderID) {
      try await updateFile(accessToken: token, fileID: fileID, data: data)
    } else {
      try await createFile(accessToken: token, folderID: folderID, data: data)
    }
  }

  // MARK: フォルダ・ファイルの解決

  /// 「Stockpile」フォルダの id を返す。なければ作る（同名が複数ある場合は最初の1つを使う）。
  private static func ensureFolder(accessToken: String) async throws -> String {
    if let id = try await findFile(
      accessToken: accessToken,
      query: "name = '\(folderName)' and mimeType = '\(folderMimeType)' and trashed = false"
    ) {
      return id
    }
    let metadata: [String: Any] = ["name": folderName, "mimeType": folderMimeType]
    let body = try JSONSerialization.data(withJSONObject: metadata)
    let object = try await requestJSON(
      accessToken: accessToken, method: "POST", url: URL(string: filesBase)!,
      body: body, contentType: "application/json")
    guard let id = object["id"] as? String else {
      throw GoogleDriveUploadError.invalidResponse
    }
    return id
  }

  private static func findSnapshotFile(accessToken: String, folderID: String) async throws
    -> String?
  {
    try await findFile(
      accessToken: accessToken,
      query: "name = '\(fileName)' and '\(folderID)' in parents and trashed = false")
  }

  /// クエリに一致する最初のファイルの id（なければ nil）
  private static func findFile(accessToken: String, query: String) async throws -> String? {
    var components = URLComponents(string: filesBase)!
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "fields", value: "files(id)"),
      URLQueryItem(name: "pageSize", value: "1"),
    ]
    let object = try await requestJSON(accessToken: accessToken, method: "GET", url: components.url!)
    let files = object["files"] as? [[String: Any]] ?? []
    return files.first?["id"] as? String
  }

  // MARK: アップロード

  /// 既存ファイルの中身を差し替える（uploadType=media）
  private static func updateFile(accessToken: String, fileID: String, data: Data) async throws {
    var components = URLComponents(string: "\(uploadBase)/\(fileID)")!
    components.queryItems = [URLQueryItem(name: "uploadType", value: "media")]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "PATCH"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    let (responseData, response) = try await send(request)
    try checkStatus(response, data: responseData)
  }

  /// 新規ファイルを作る（uploadType=multipart。名前と親フォルダをメタデータで渡す）
  private static func createFile(accessToken: String, folderID: String, data: Data) async throws {
    var components = URLComponents(string: uploadBase)!
    components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]
    let metadata: [String: Any] = ["name": fileName, "parents": [folderID]]
    let metadataData = try JSONSerialization.data(withJSONObject: metadata)
    let boundary = "StockpileBoundary-\(UUID().uuidString)"
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartBody(metadata: metadataData, media: data, boundary: boundary)
    let (responseData, response) = try await send(request)
    try checkStatus(response, data: responseData)
  }

  /// multipart/related のボディ組み立て（Drive の multipart アップロード形式）
  static func multipartBody(metadata: Data, media: Data, boundary: String) -> Data {
    var body = Data()
    body.append(utf8("--\(boundary)\r\n"))
    body.append(utf8("Content-Type: application/json; charset=UTF-8\r\n\r\n"))
    body.append(metadata)
    body.append(utf8("\r\n--\(boundary)\r\n"))
    body.append(utf8("Content-Type: application/json\r\n\r\n"))
    body.append(media)
    body.append(utf8("\r\n--\(boundary)--\r\n"))
    return body
  }

  // MARK: HTTP 共通

  /// JSON を返す Drive API 呼び出し。ステータス判定まで共通化する。
  private static func requestJSON(
    accessToken: String, method: String, url: URL, body: Data? = nil, contentType: String? = nil
  ) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if let body { request.httpBody = body }
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await send(request)
    try checkStatus(response, data: data)
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw GoogleDriveUploadError.invalidResponse
    }
    return object
  }

  private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw GoogleDriveUploadError.network(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw GoogleDriveUploadError.network(URLError(.badServerResponse))
    }
    return (data, http)
  }

  private static func checkStatus(_ response: HTTPURLResponse, data: Data) throws {
    switch response.statusCode {
    case 200...299:
      return
    case 401:
      throw GoogleDriveUploadError.unauthorized
    default:
      let message =
        (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"]
        as? [String: Any])?["message"] as? String
      throw GoogleDriveUploadError.server(statusCode: response.statusCode, message: message)
    }
  }

  private static func utf8(_ string: String) -> Data {
    Data(string.utf8)
  }
}
