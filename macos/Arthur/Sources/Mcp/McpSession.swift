import Darwin
import Foundation

protocol McpTransport: AnyObject {
  func request(method: String, params: [String: Any]?) async throws -> [String: Any]
  func notify(method: String, params: [String: Any]?) async throws
  func close() async
}

func handshake(_ transport: McpTransport) async throws -> McpProbe {
  let initialized = try await initialize(transport)
  try await transport.notify(method: "notifications/initialized", params: [:])
  var tools: [McpToolInfo] = []
  var cursor: String?
  for _ in 0..<8 {
    var params: [String: Any] = [:]
    if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
    let page = try await transport.request(method: "tools/list", params: params)
    tools.append(contentsOf: McpFraming.tools(from: page))
    guard let next = page["nextCursor"] as? String, !next.isEmpty, next != cursor else { break }
    cursor = next
  }
  let info = initialized["serverInfo"] as? [String: Any] ?? [:]
  return McpProbe.success(
    serverName: info["name"] as? String ?? "",
    serverVersion: info["version"] as? String ?? "",
    protocolVersion: initialized["protocolVersion"] as? String ?? "",
    tools: tools
  )
}

func initialize(_ transport: McpTransport) async throws -> [String: Any] {
  let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]
  var last: Error = McpClientError.transport("Could not start the MCP session.")
  for (index, version) in versions.enumerated() {
    do {
      return try await transport.request(
        method: "initialize",
        params: [
          "protocolVersion": version,
          "capabilities": [:] as [String: Any],
          "clientInfo": ["name": "Arthur", "version": "1.0"],
        ]
      )
    } catch {
      last = error
      let retry = index + 1 < versions.count && isProtocolMismatch(error)
      if !retry { throw error }
    }
  }
  throw last
}

func isProtocolMismatch(_ error: Error) -> Bool {
  mcpUserMessage(error).lowercased().contains("protocol")
}

enum LineScan {
  /// `bytes.lines` can sit on the blank line that ends an SSE event until the
  /// socket closes. Split the bytes ourselves so that line is visible immediately.
  static func forEach(_ bytes: URLSession.AsyncBytes, _ handle: (String) throws -> Bool) async throws {
    var pending = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      if byte != 10 {
        pending.append(byte)
        if pending.count > 1_000_000 {
          throw McpClientError.transport("The server sent too much data.")
        }
        continue
      }
      if pending.last == 13 { pending.removeLast() }
      let line = String(decoding: pending, as: UTF8.self)
      pending.removeAll(keepingCapacity: true)
      if try handle(line) { return }
    }
  }
}

func mcpWithTimeout<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw McpClientError.timedOut
    }
    guard let value = try await group.next() else { throw McpClientError.timedOut }
    group.cancelAll()
    return value
  }
}

func wrapTransport(_ error: Error) -> Error {
  if error is McpClientError || error is CancellationError { return error }
  guard let url = error as? URLError else {
    return McpClientError.transport(error.localizedDescription)
  }
  if url.code == .cancelled { return CancellationError() }
  switch url.code {
  case .timedOut:
    return McpClientError.timedOut
  case .cannotFindHost, .dnsLookupFailed:
    return McpClientError.transport("Could not find that host.")
  case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
    return McpClientError.transport("Could not open a connection to that server.")
  case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected:
    return McpClientError.transport("Could not open a secure connection to that host.")
  case .appTransportSecurityRequiresSecureConnection:
    return McpClientError.transport("That address has to be https, unless it is on your local network.")
  default:
    return McpClientError.transport("Could not reach that server.")
  }
}

enum McpFraming {
  static func payload(id: Int?, method: String, params: [String: Any]?) throws -> Data {
    var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
    if let id { object["id"] = id }
    if let params { object["params"] = params }
    guard JSONSerialization.isValidJSONObject(object) else {
      throw McpClientError.transport("Could not encode the MCP request.")
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
  }

  static func intValue(_ raw: Any?) -> Int? {
    switch raw {
    case let value as Int:
      return value
    case let value as NSNumber:
      return value.intValue
    case let value as String:
      return Int(value)
    default:
      return nil
    }
  }

  enum Hit {
    case result([String: Any])
    case ignore
  }

  static func interpret(_ object: [String: Any], id: Int) throws -> Hit {
    guard let messageID = intValue(object["id"]) else { return .ignore }
    guard messageID == id else { return .ignore }
    if let error = object["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "The server rejected the request."
      throw McpClientError.rpc(message)
    }
    if let result = object["result"] as? [String: Any] { return .result(result) }
    if object["result"] == nil || object["result"] is NSNull { return .result([:]) }
    throw McpClientError.transport("The server sent a result Arthur could not read.")
  }

  static func readResult(bytes: URLSession.AsyncBytes, contentType: String, id: Int) async throws -> [String: Any] {
    if contentType.lowercased().contains("text/event-stream") {
      return try await readEventStream(bytes, id: id)
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      data.append(byte)
      if data.count > 1_000_000 {
        throw McpClientError.transport("The server sent too much data.")
      }
    }
    if data.isEmpty {
      throw McpClientError.transport("The server returned an empty response.")
    }
    if let text = String(data: data, encoding: .utf8) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.contains("\ndata:") || trimmed.hasPrefix("data:") || trimmed.hasPrefix("event:") {
        return try resultFromEvents(text, id: id)
      }
    }
    return try resultFromJSON(data, id: id)
  }

  static func snippet(_ data: Data) -> String {
    guard let text = String(data: data, encoding: .utf8) else { return "" }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.hasPrefix("<") { return "" }
    if let object = jsonObject(trimmed), let message = object["message"] as? String, !message.isEmpty {
      return clip(message, limit: 180)
    }
    if let object = jsonObject(trimmed),
       let error = object["error"] as? [String: Any],
       let message = error["message"] as? String {
      return clip(message, limit: 180)
    }
    return clip(trimmed.replacingOccurrences(of: "\n", with: " "), limit: 180)
  }

  static func textContent(from result: [String: Any]) -> String {
    let chunks = result["content"] as? [[String: Any]] ?? []
    return chunks.compactMap { item -> String? in
      guard (item["type"] as? String) == "text" else { return nil }
      return item["text"] as? String
    }.joined(separator: "\n")
  }

  static func tools(from result: [String: Any]) -> [McpToolInfo] {
    guard let list = result["tools"] as? [[String: Any]] else { return [] }
    let tools: [McpToolInfo] = list.compactMap { item in
      guard let name = item["name"] as? String else { return nil }
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let description = item["description"] as? String ?? ""
      let first = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      return McpToolInfo(name: trimmed, summary: clip(first, limit: 160))
    }
    return tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private static func clip(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit - 1)) + "…"
  }

  private static func readEventStream(_ bytes: URLSession.AsyncBytes, id: Int) async throws -> [String: Any] {
    var event = "message"
    var dataLines: [String] = []
    var found: [String: Any]?
    try await LineScan.forEach(bytes) { line in
      if line.isEmpty {
        if let result = try resultIfMatch(event: event, dataLines: dataLines, id: id) {
          found = result
          return true
        }
        event = "message"
        dataLines = []
        return false
      }
      if line.hasPrefix(":") { return false }
      if line.hasPrefix("event:") {
        event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("data:") {
        var rest = line.dropFirst(5)
        if rest.first == " " { rest = rest.dropFirst() }
        dataLines.append(String(rest))
        if let result = try resultIfMatch(event: event, dataLines: dataLines, id: id) {
          found = result
          return true
        }
      }
      return false
    }
    if let found { return found }
    if let result = try resultIfMatch(event: event, dataLines: dataLines, id: id) {
      return result
    }
    throw McpClientError.transport("The server closed the stream before answering.")
  }

  private static func resultFromEvents(_ text: String, id: Int) throws -> [String: Any] {
    var event = "message"
    var dataLines: [String] = []
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    for line in lines {
      if line.isEmpty {
        if let result = try resultIfMatch(event: event, dataLines: dataLines, id: id) {
          return result
        }
        event = "message"
        dataLines = []
        continue
      }
      if line.hasPrefix(":") { continue }
      if line.hasPrefix("event:") {
        event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("data:") {
        var rest = line.dropFirst(5)
        if rest.first == " " { rest = rest.dropFirst() }
        dataLines.append(String(rest))
      }
    }
    if let result = try resultIfMatch(event: event, dataLines: dataLines, id: id) {
      return result
    }
    throw McpClientError.transport("The server did not return JSON.")
  }

  private static func resultIfMatch(event: String, dataLines: [String], id: Int) throws -> [String: Any]? {
    guard !dataLines.isEmpty else { return nil }
    if event != "message" && event != "" { return nil }
    guard let object = jsonObject(dataLines.joined(separator: "\n")) else { return nil }
    switch try interpret(object, id: id) {
    case .result(let result):
      return result
    case .ignore:
      return nil
    }
  }

  private static func resultFromJSON(_ data: Data, id: Int) throws -> [String: Any] {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw McpClientError.transport("The server did not return JSON.")
    }
    if let object = parsed as? [String: Any] {
      switch try interpret(object, id: id) {
      case .result(let result):
        return result
      case .ignore:
        throw McpClientError.transport("The server answered a different request.")
      }
    }
    if let list = parsed as? [[String: Any]] {
      for object in list {
        if case .result(let result) = try interpret(object, id: id) { return result }
      }
    }
    throw McpClientError.transport("The server did not return JSON.")
  }
}
