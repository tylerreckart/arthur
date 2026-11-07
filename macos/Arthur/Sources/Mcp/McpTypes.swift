import Darwin
import Foundation

struct McpToolInfo: Identifiable, Equatable {
  var name: String
  var summary: String
  var id: String { name }
}

struct McpProbe: Equatable {
  var ok: Bool
  var serverName: String
  var serverVersion: String
  var protocolVersion: String
  var tools: [McpToolInfo]
  var message: String

  var summary: String {
    if !ok { return message }
    let count = tools.count
    let noun = count == 1 ? "tool" : "tools"
    let label = serverName.isEmpty ? "server" : serverName
    return "Connected to \(label) · \(count) \(noun)"
  }

  static func success(
    serverName: String,
    serverVersion: String,
    protocolVersion: String,
    tools: [McpToolInfo]
  ) -> McpProbe {
    McpProbe(
      ok: true,
      serverName: serverName,
      serverVersion: serverVersion,
      protocolVersion: protocolVersion,
      tools: tools,
      message: ""
    )
  }

  static func failure(_ message: String) -> McpProbe {
    McpProbe(
      ok: false,
      serverName: "",
      serverVersion: "",
      protocolVersion: "",
      tools: [],
      message: message
    )
  }
}

struct McpAuthChallenge: Equatable, Sendable {
  var status: Int
  var wwwAuthenticate: String
  var detail: String
}

enum McpConnectNotice: Sendable {
  case status(String)
  case authorization(String)
}

enum McpClientError: LocalizedError {
  case invalidURL
  case unauthorized(McpAuthChallenge)
  case signIn(String)
  case http(Int, String)
  case rpc(String)
  case transport(String)
  case timedOut
  case failedToStart(String)

  var needsBrowserSignIn: Bool {
    guard case .unauthorized(let challenge) = self else { return false }
    if challenge.status == 401 { return true }
    let header = challenge.wwwAuthenticate.lowercased()
    return header.contains("bearer") || header.contains("resource_metadata")
  }

  static func unauthorized(status: Int, response: HTTPURLResponse, detail: String) -> McpClientError {
    McpClientError.unauthorized(
      McpAuthChallenge(
        status: status,
        wwwAuthenticate: response.value(forHTTPHeaderField: "WWW-Authenticate") ?? "",
        detail: detail
      )
    )
  }

  var shouldTryLegacy: Bool {
    switch self {
    case .http(let code, _):
      return code == 400 || code == 404 || code == 405
    case .transport(let message):
      let text = message.lowercased()
      return text.contains("did not return json") || text.contains("empty response")
    default:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Enter a full http or https URL."
    case .unauthorized(let challenge):
      if challenge.detail.isEmpty {
        return "The server refused the connection."
      }
      return challenge.detail
    case .signIn(let message):
      return message
    case .http(let code, let detail):
      if detail.isEmpty { return "The server returned HTTP \(code)." }
      return "The server returned HTTP \(code). \(detail)"
    case .rpc(let message):
      return message.isEmpty ? "The server rejected the request." : message
    case .transport(let message):
      return message
    case .timedOut:
      return "The server did not answer in time."
    case .failedToStart(let message):
      return message
    }
  }
}

extension Dictionary where Key == String, Value == String {
  func replacingAuthorization(_ value: String) -> [String: String] {
    var next = self
    let existing = keys.first { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
    if let existing { next.removeValue(forKey: existing) }
    next["Authorization"] = value
    return next
  }
}

func mcpUserMessage(_ error: Error) -> String {
  if let mcp = error as? McpClientError, let text = mcp.errorDescription { return text }
  if error is CancellationError { return "" }
  return error.localizedDescription
}
