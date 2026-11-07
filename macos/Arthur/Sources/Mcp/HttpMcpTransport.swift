import Darwin
import Foundation

final class HttpMcpTransport: McpTransport {
  let endpoint: URL
  private let headers: [String: String]
  private let session: URLSession
  private var sessionID: String?
  private var protocolVersion = "2025-06-18"
  private var nextID = 1

  init(endpoint: URL, headers: [String: String]) {
    self.endpoint = endpoint
    self.headers = headers
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 30
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieAcceptPolicy = .never
    session = URLSession(configuration: config)
  }

  func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
    if method == "initialize" { sessionID = nil }
    let id = nextID
    nextID += 1
    if method == "initialize", let version = params?["protocolVersion"] as? String {
      protocolVersion = version
    }
    let result = try await post(
      id: id,
      method: method,
      params: params,
      expectResult: true
    )
    if method == "initialize", let agreed = result["protocolVersion"] as? String, !agreed.isEmpty {
      protocolVersion = agreed
    }
    return result
  }

  func notify(method: String, params: [String: Any]?) async throws {
    _ = try await post(id: nil, method: method, params: params, expectResult: false)
  }

  func close() async {
    if let sessionID {
      var request = URLRequest(url: endpoint)
      request.httpMethod = "DELETE"
      request.timeoutInterval = 5
      apply(&request, protocolVersion: protocolVersion, includeJSON: false)
      request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
      _ = try? await session.data(for: request)
    }
    session.invalidateAndCancel()
  }

  private func post(
    id: Int?,
    method: String,
    params: [String: Any]?,
    expectResult: Bool
  ) async throws -> [String: Any] {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 25
    apply(&request, protocolVersion: protocolVersion, includeJSON: true)
    if let sessionID {
      request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }
    request.httpBody = try McpFraming.payload(id: id, method: method, params: params)

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch {
      throw wrapTransport(error)
    }

    guard let http = response as? HTTPURLResponse else {
      bytes.task.cancel()
      throw McpClientError.transport("The server sent an unexpected response.")
    }
    if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
      sessionID = sid
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      let detail = await readSnippet(bytes)
      bytes.task.cancel()
      throw McpClientError.unauthorized(status: http.statusCode, response: http, detail: detail)
    }
    if !expectResult {
      bytes.task.cancel()
      guard (200...299).contains(http.statusCode) || http.statusCode == 202 else {
        throw McpClientError.http(http.statusCode, "")
      }
      return [:]
    }
    guard (200...299).contains(http.statusCode) else {
      let detail = await readSnippet(bytes)
      bytes.task.cancel()
      throw McpClientError.http(http.statusCode, detail)
    }

    let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
    do {
      let result = try await mcpWithTimeout(seconds: 20) {
        try await McpFraming.readResult(bytes: bytes, contentType: type, id: id ?? -1)
      }
      bytes.task.cancel()
      return result
    } catch {
      bytes.task.cancel()
      throw wrapTransport(error)
    }
  }

  private func apply(_ request: inout URLRequest, protocolVersion: String, includeJSON: Bool) {
    for (key, value) in headers where !key.isEmpty {
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    request.setValue("close", forHTTPHeaderField: "Connection")
    if includeJSON {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    }
  }

  private func readSnippet(_ bytes: URLSession.AsyncBytes) async -> String {
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 512 { break }
      }
    } catch {
      return McpFraming.snippet(data)
    }
    return McpFraming.snippet(data)
  }
}
