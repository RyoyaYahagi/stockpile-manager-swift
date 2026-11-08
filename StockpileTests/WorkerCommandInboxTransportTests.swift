import Foundation
import Testing

@testable import Stockpile

// MARK: - 受信箱 URL の導出

struct WorkerCommandInboxEndpointTests {
  private func endpoints(_ string: String) -> WorkerCommandInboxEndpoints? {
    guard let url = URL(string: string) else { return nil }
    return WorkerCommandInboxEndpoints(snapshotURL: url)
  }

  @Test
  func derivesCommandsAndResultsFromSnapshotURL() throws {
    let endpoints = try #require(endpoints("https://example.workers.dev/v1/snapshot"))

    #expect(endpoints.commands.absoluteString == "https://example.workers.dev/v1/commands")
    #expect(
      endpoints.results.absoluteString == "https://example.workers.dev/v1/command-results")
  }

  @Test
  func acceptsTrailingSlashAndKeepsBasePath() throws {
    let endpoints = try #require(
      endpoints("https://example.workers.dev/stockpile/v1/snapshot/"))

    #expect(endpoints.commands.path == "/stockpile/v1/commands")
    #expect(endpoints.results.path == "/stockpile/v1/command-results")
  }

  @Test
  func keepsQuery() throws {
    let endpoints = try #require(
      endpoints("https://example.workers.dev/v1/snapshot?tenant=abc"))

    #expect(
      endpoints.commands.absoluteString == "https://example.workers.dev/v1/commands?tenant=abc")
    #expect(
      endpoints.results.absoluteString
        == "https://example.workers.dev/v1/command-results?tenant=abc")
  }

  @Test
  func rejectsOtherPaths() {
    #expect(endpoints("https://example.workers.dev/v1/snapshot/extra") == nil)
    #expect(endpoints("https://example.workers.dev/v1") == nil)
    #expect(endpoints("https://example.workers.dev/snapshot") == nil)
    #expect(endpoints("https://example.com/api/stockpile") == nil)
  }

  @Test
  func rejectsHTTP() {
    #expect(endpoints("http://example.workers.dev/v1/snapshot") == nil)
  }
}

// MARK: - Worker transport の送受信

@MainActor
private final class RequestRecorder {
  private(set) var requests: [URLRequest] = []
  var responder: ((URLRequest) throws -> (Data, URLResponse))?

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard let responder else {
      throw URLError(.badServerResponse)
    }
    return try responder(request)
  }
}

private func httpResponse(_ statusCode: Int, url: URL) -> HTTPURLResponse {
  HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

@MainActor
private func makeTransport(
  recorder: RequestRecorder,
  token: String = "test-write-token"
) -> WorkerCommandInboxTransport {
  let endpoints = WorkerCommandInboxEndpoints(
    snapshotURL: URL(string: "https://example.workers.dev/v1/snapshot")!
  )!
  return WorkerCommandInboxTransport(endpoints: endpoints, writeToken: token) { request in
    try await recorder.send(request)
  }
}

@MainActor
struct WorkerCommandInboxTransportTests {
  @Test
  func readsCommandsAndResultsWithWriteToken() async throws {
    let recorder = RequestRecorder()
    recorder.responder = { request in
      let body =
        request.url?.path == "/v1/commands"
        ? Data("{\"version\":1,\"commands\":[]}".utf8)
        : Data("{\"version\":1,\"results\":[]}".utf8)
      return (body, httpResponse(200, url: request.url!))
    }
    let transport = makeTransport(recorder: recorder)

    let commands = try await transport.readCommands()
    let results = try await transport.readResults()

    #expect(commands == Data("{\"version\":1,\"commands\":[]}".utf8))
    #expect(results == Data("{\"version\":1,\"results\":[]}".utf8))
    #expect(recorder.requests.compactMap(\.httpMethod) == ["GET", "GET"])
    #expect(
      recorder.requests.compactMap { $0.url?.path }
        == ["/v1/commands", "/v1/command-results"])
    #expect(
      recorder.requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-write-token"
      })
  }

  @Test
  func writesResultsWithPUT() async throws {
    let recorder = RequestRecorder()
    recorder.responder = { request in
      (Data("{\"ok\":true}".utf8), httpResponse(200, url: request.url!))
    }
    let transport = makeTransport(recorder: recorder)
    let body = Data("{\"version\":1,\"results\":[]}".utf8)

    try await transport.writeResults(body)

    let request = try #require(recorder.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/v1/command-results")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-write-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.httpBody == body)
  }

  @Test
  func ensureFilesDoesNotSendAnything() async throws {
    let recorder = RequestRecorder()
    let transport = makeTransport(recorder: recorder)

    try await transport.ensureFiles()

    #expect(recorder.requests.isEmpty)
  }

  @Test
  func notFoundMeansInboxUnavailable() async {
    let recorder = RequestRecorder()
    recorder.responder = { request in
      (Data("{\"error\":\"not found\"}".utf8), httpResponse(404, url: request.url!))
    }
    let transport = makeTransport(recorder: recorder)

    do {
      _ = try await transport.readCommands()
      Issue.record("404 は受信箱なしとして扱う")
    } catch let error as WorkerCommandInboxError {
      #expect(error == .inboxUnavailable)
    } catch {
      Issue.record("想定外のエラー: \(error)")
    }

    do {
      _ = try await transport.readResults()
      Issue.record("404 は受信箱なしとして扱う")
    } catch let error as WorkerCommandInboxError {
      #expect(error == .inboxUnavailable)
    } catch {
      Issue.record("想定外のエラー: \(error)")
    }
  }

  @Test
  func unauthorizedIsCommunicationFailure() async {
    let recorder = RequestRecorder()
    recorder.responder = { request in
      (Data("{\"error\":\"unauthorized\"}".utf8), httpResponse(401, url: request.url!))
    }
    let transport = makeTransport(recorder: recorder)

    do {
      _ = try await transport.readCommands()
      Issue.record("401 は認証エラーにする")
    } catch let error as SnapshotUploadError {
      guard case .unauthorized = error else {
        Issue.record("想定外のエラー: \(error)")
        return
      }
    } catch {
      Issue.record("想定外のエラー: \(error)")
    }
  }

  @Test
  func serverErrorIncludesStatusCode() async {
    let recorder = RequestRecorder()
    recorder.responder = { request in
      (Data("{\"error\":\"boom\"}".utf8), httpResponse(500, url: request.url!))
    }
    let transport = makeTransport(recorder: recorder)

    do {
      _ = try await transport.readCommands()
      Issue.record("500 は通信失敗にする")
    } catch let error as SnapshotUploadError {
      guard case .server(let statusCode, let message) = error else {
        Issue.record("想定外のエラー: \(error)")
        return
      }
      #expect(statusCode == 500)
      #expect(message == "boom")
    } catch {
      Issue.record("想定外のエラー: \(error)")
    }
  }
}

// MARK: - 送信先に応じた transport の選択

struct CommandInboxTransportSelectorTests {
  private let workerEndpoint = URL(string: "https://example.workers.dev/v1/snapshot")!

  @Test
  func selectsGoogleDriveOnlyWhenSignedIn() {
    #expect(
      CommandInboxTransportSelector.select(
        destination: .googleDrive,
        endpoint: nil,
        hasWriteToken: false,
        hasDriveUser: true) == .googleDrive)
    #expect(
      CommandInboxTransportSelector.select(
        destination: .googleDrive,
        endpoint: nil,
        hasWriteToken: false,
        hasDriveUser: false) == nil)
  }

  @Test
  func selectsWorkerForWorkerSnapshotURL() throws {
    let kind = try #require(
      CommandInboxTransportSelector.select(
        destination: .customURL,
        endpoint: workerEndpoint,
        hasWriteToken: true,
        hasDriveUser: false))

    guard case .worker(let endpoints) = kind else {
      Issue.record("Worker の transport を選ぶ")
      return
    }
    #expect(endpoints.commands.path == "/v1/commands")
    #expect(endpoints.results.path == "/v1/command-results")
  }

  @Test
  func skipsWorkerWithoutTokenOrInboxPath() {
    #expect(
      CommandInboxTransportSelector.select(
        destination: .customURL,
        endpoint: workerEndpoint,
        hasWriteToken: false,
        hasDriveUser: false) == nil)
    #expect(
      CommandInboxTransportSelector.select(
        destination: .customURL,
        endpoint: URL(string: "https://example.workers.dev/v1/other"),
        hasWriteToken: true,
        hasDriveUser: false) == nil)
    #expect(
      CommandInboxTransportSelector.select(
        destination: .customURL,
        endpoint: nil,
        hasWriteToken: true,
        hasDriveUser: false) == nil)
  }
}
