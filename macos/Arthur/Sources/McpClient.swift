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

private extension Dictionary where Key == String, Value == String {
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

enum McpClient {
  static func probeRemote(
    urlString: String,
    headers: [String: String],
    notice: ((McpConnectNotice) -> Void)? = nil
  ) async throws -> McpProbe {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty
    else { throw McpClientError.invalidURL }

    do {
      return try await openSession(url: url, headers: headers)
    } catch let error as McpClientError where error.needsBrowserSignIn {
      guard case .unauthorized(let challenge) = error else { throw error }
      if let token = await McpOAuth.refresh(resource: url) {
        do {
          return try await openSession(url: url, headers: headers.replacingAuthorization(token.authorizationValue))
        } catch let retry as McpClientError where retry.needsBrowserSignIn {
          // The saved grant was rejected. Fall through and open the browser.
        }
      }
      let token = try await McpOAuth.signIn(resource: url, challenge: challenge) { message in
        await MainActor.run { notice?(.status(message)) }
      }
      let value = token.authorizationValue
      await MainActor.run { notice?(.authorization(value)) }
      do {
        return try await openSession(url: url, headers: headers.replacingAuthorization(value))
      } catch let retry as McpClientError where retry.needsBrowserSignIn {
        throw McpClientError.signIn("Signed in, but the server still refused the connection.")
      }
    }
  }

  private static func openSession(url: URL, headers: [String: String]) async throws -> McpProbe {
    let http = HttpMcpTransport(endpoint: url, headers: headers)
    do {
      let probe = try await handshake(http)
      await http.close()
      return probe
    } catch {
      await http.close()
      guard let mcp = error as? McpClientError, mcp.shouldTryLegacy else { throw error }
      let legacy = SseMcpTransport(endpoint: url, headers: headers)
      do {
        let probe = try await handshake(legacy)
        await legacy.close()
        return probe
      } catch let legacyError {
        await legacy.close()
        if case .http(let code, _) = mcp, code == 404 || code == 405 {
          throw legacyError
        }
        throw error
      }
    }
  }

  static func probeLocal(command: String, args: [String], env: [String: String]) async throws -> McpProbe {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw McpClientError.failedToStart("Enter a command to launch.")
    }
    let stdio = StdioMcpTransport(command: trimmed, args: args, env: env)
    do {
      let probe = try await handshake(stdio)
      await stdio.close()
      return probe
    } catch {
      await stdio.close()
      throw error
    }
  }
}

private protocol McpTransport: AnyObject {
  func request(method: String, params: [String: Any]?) async throws -> [String: Any]
  func notify(method: String, params: [String: Any]?) async throws
  func close() async
}

private func handshake(_ transport: McpTransport) async throws -> McpProbe {
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

private func initialize(_ transport: McpTransport) async throws -> [String: Any] {
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

private func isProtocolMismatch(_ error: Error) -> Bool {
  mcpUserMessage(error).lowercased().contains("protocol")
}

private enum LineScan {
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

private func mcpWithTimeout<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
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

private func wrapTransport(_ error: Error) -> Error {
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

private enum McpFraming {
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

private final class HttpMcpTransport: McpTransport {
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

private final class SseMcpTransport: McpTransport {
  private let endpoint: URL
  private let headers: [String: String]
  private let session: URLSession
  private let lock = NSLock()
  private var nextID = 1
  private var waiters: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var timeouts: [Int: Task<Void, Never>] = [:]
  private var endpointWaiter: CheckedContinuation<URL, Error>?
  private var messageURL: URL?
  private var reader: Task<Void, Never>?
  private var started = false
  private var closed = false
  private var protocolVersion = "2025-06-18"

  init(endpoint: URL, headers: [String: String]) {
    self.endpoint = endpoint
    self.headers = headers
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 40
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieAcceptPolicy = .never
    session = URLSession(configuration: config)
  }

  func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
    try await ensureStarted()
    if method == "initialize", let version = params?["protocolVersion"] as? String {
      protocolVersion = version
    }
    let id = allocateID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.store(id, continuation)
        self.armTimeout(id, seconds: 20)
        Task {
          do {
            if let inline = try await self.send(id: id, method: method, params: params) {
              if method == "initialize", let agreed = inline["protocolVersion"] as? String, !agreed.isEmpty {
                self.protocolVersion = agreed
              }
              self.succeed(id, inline)
            }
          } catch {
            self.fail(id, error)
          }
        }
      }
    } onCancel: {
      self.fail(id, CancellationError())
    }
  }

  func notify(method: String, params: [String: Any]?) async throws {
    try await ensureStarted()
    _ = try await send(id: nil, method: method, params: params)
  }

  func close() async {
    let snapshot = takeClosedWaiters()
    for task in snapshot.tasks { task.cancel() }
    reader?.cancel()
    session.invalidateAndCancel()
    for continuation in snapshot.waiters {
      continuation.resume(throwing: CancellationError())
    }
    snapshot.endpoint?.resume(throwing: CancellationError())
  }

  private func takeClosedWaiters() -> (
    waiters: [CheckedContinuation<[String: Any], Error>],
    tasks: [Task<Void, Never>],
    endpoint: CheckedContinuation<URL, Error>?
  ) {
    lock.lock()
    closed = true
    let pending = Array(waiters.values)
    waiters.removeAll()
    let tasks = Array(timeouts.values)
    timeouts.removeAll()
    let waitingEndpoint = endpointWaiter
    endpointWaiter = nil
    lock.unlock()
    return (pending, tasks, waitingEndpoint)
  }

  private func ensureStarted() async throws {
    if started { return }
    try await open()
    started = true
  }

  private func open() async throws {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (key, value) in headers where !key.isEmpty {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch {
      throw wrapTransport(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw McpClientError.transport("The server sent an unexpected response.")
    }
    guard (200...299).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw McpClientError.unauthorized(status: http.statusCode, response: http, detail: "")
      }
      throw McpClientError.http(http.statusCode, "")
    }
    reader = Task { [weak self] in
      guard let self else { return }
      var event = "message"
      var dataLines: [String] = []
      do {
        try await LineScan.forEach(bytes) { line in
          if Task.isCancelled { return true }
          if line.isEmpty {
            let payload = dataLines.joined(separator: "\n")
            let name = event
            dataLines = []
            event = "message"
            if !payload.isEmpty { self.receive(event: name, payload: payload) }
            return false
          }
          if line.hasPrefix(":") { return false }
          if line.hasPrefix("event:") {
            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
          } else if line.hasPrefix("data:") {
            var rest = line.dropFirst(5)
            if rest.first == " " { rest = rest.dropFirst() }
            dataLines.append(String(rest))
            let payload = dataLines.joined(separator: "\n")
            if self.shouldDispatch(event: event, payload: payload) {
              self.receive(event: event, payload: payload)
            }
          }
          return false
        }
      } catch {
        if Task.isCancelled { return }
        self.failAll(wrapTransport(error))
        return
      }
      if Task.isCancelled { return }
      self.failAll(McpClientError.transport("The server closed the connection."))
    }
    _ = try await mcpWithTimeout(seconds: 15) {
      try await self.waitForMessageURL()
    }
  }

  private func waitForMessageURL() async throws -> URL {
    if let messageURL { return messageURL }
    return try await withCheckedThrowingContinuation { continuation in
      self.lock.lock()
      if let messageURL = self.messageURL {
        self.lock.unlock()
        continuation.resume(returning: messageURL)
        return
      }
      if self.closed {
        self.lock.unlock()
        continuation.resume(throwing: CancellationError())
        return
      }
      self.endpointWaiter = continuation
      self.lock.unlock()
    }
  }

  private func shouldDispatch(event: String, payload: String) -> Bool {
    if event == "endpoint" || payload.hasPrefix("/") || payload.hasPrefix("http://") || payload.hasPrefix("https://") {
      return true
    }
    return McpFraming.jsonObject(payload) != nil
  }

  private func receive(event: String, payload: String) {
    if event == "endpoint" || (messageURL == nil && !payload.trimmingCharacters(in: .whitespaces).hasPrefix("{")) {
      guard let url = resolve(payload) else { return }
      lock.lock()
      messageURL = url
      let waiter = endpointWaiter
      endpointWaiter = nil
      lock.unlock()
      waiter?.resume(returning: url)
      return
    }
    guard let object = McpFraming.jsonObject(payload), let id = McpFraming.intValue(object["id"]) else { return }
    do {
      if case .result(let result) = try McpFraming.interpret(object, id: id) {
        if let agreed = result["protocolVersion"] as? String, !agreed.isEmpty {
          protocolVersion = agreed
        }
        succeed(id, result)
      }
    } catch {
      fail(id, error)
    }
  }

  private func resolve(_ payload: String) -> URL? {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed, relativeTo: endpoint)?.absoluteURL,
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return nil }
    return url
  }

  private func send(id: Int?, method: String, params: [String: Any]?) async throws -> [String: Any]? {
    guard let messageURL else {
      throw McpClientError.transport("The server did not provide a message address.")
    }
    var request = URLRequest(url: messageURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    for (key, value) in headers where !key.isEmpty {
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    request.httpBody = try McpFraming.payload(id: id, method: method, params: params)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw wrapTransport(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw McpClientError.transport("The server sent an unexpected response.")
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw McpClientError.unauthorized(status: http.statusCode, response: http, detail: McpFraming.snippet(data))
    }
    if http.statusCode == 202 || data.isEmpty { return nil }
    guard (200...299).contains(http.statusCode) else {
      throw McpClientError.http(http.statusCode, McpFraming.snippet(data))
    }
    guard let id, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if case .result(let result) = try McpFraming.interpret(object, id: id) {
      return result
    }
    return nil
  }

  private func allocateID() -> Int {
    lock.lock()
    defer { lock.unlock() }
    let id = nextID
    nextID += 1
    return id
  }

  private func store(_ id: Int, _ continuation: CheckedContinuation<[String: Any], Error>) {
    lock.lock()
    waiters[id] = continuation
    lock.unlock()
  }

  private func armTimeout(_ id: Int, seconds: Double) {
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      self?.fail(id, McpClientError.timedOut)
    }
    lock.lock()
    timeouts[id] = task
    lock.unlock()
  }

  private func succeed(_ id: Int, _ result: [String: Any]) {
    finish(id)?.resume(returning: result)
  }

  private func fail(_ id: Int, _ error: Error) {
    finish(id)?.resume(throwing: error)
  }

  private func finish(_ id: Int) -> CheckedContinuation<[String: Any], Error>? {
    lock.lock()
    let task = timeouts.removeValue(forKey: id)
    let continuation = waiters.removeValue(forKey: id)
    lock.unlock()
    task?.cancel()
    return continuation
  }

  private func failAll(_ error: Error) {
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    let pending = waiters
    waiters.removeAll()
    let tasks = timeouts
    timeouts.removeAll()
    let waitingEndpoint = endpointWaiter
    endpointWaiter = nil
    lock.unlock()
    for task in tasks.values { task.cancel() }
    for continuation in pending.values {
      continuation.resume(throwing: error)
    }
    waitingEndpoint?.resume(throwing: error)
  }
}

private final class StdioMcpTransport: McpTransport {
  private let command: String
  private let args: [String]
  private let env: [String: String]
  private let process = Process()
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let lock = NSLock()
  private var buffer = Data()
  private var stderrText = ""
  private var nextID = 1
  private var waiters: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var timeouts: [Int: Task<Void, Never>] = [:]
  private var launched = false
  private var closed = false

  init(command: String, args: [String], env: [String: String]) {
    self.command = command
    self.args = args
    self.env = env
  }

  func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
    try startIfNeeded()
    let id = allocateID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.store(id, continuation)
        self.armTimeout(id, seconds: 40)
        do {
          var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
          if let params { object["params"] = params }
          try self.writeLine(object)
        } catch {
          self.fail(id, error)
        }
      }
    } onCancel: {
      self.fail(id, CancellationError())
    }
  }

  func notify(method: String, params: [String: Any]?) async throws {
    try startIfNeeded()
    var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
    if let params { object["params"] = params }
    try writeLine(object)
  }

  func close() async {
    let snapshot = takeClosedWaiters()
    for task in snapshot.tasks { task.cancel() }
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    try? stdinPipe.fileHandleForWriting.close()
    if snapshot.running {
      process.terminate()
      try? await Task.sleep(for: .milliseconds(400))
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }
    for continuation in snapshot.waiters {
      continuation.resume(throwing: CancellationError())
    }
  }

  private func takeClosedWaiters() -> (
    waiters: [CheckedContinuation<[String: Any], Error>],
    tasks: [Task<Void, Never>],
    running: Bool
  ) {
    lock.lock()
    closed = true
    let pending = Array(waiters.values)
    waiters.removeAll()
    let tasks = Array(timeouts.values)
    timeouts.removeAll()
    let running = launched && process.isRunning
    lock.unlock()
    return (pending, tasks, running)
  }

  private func startIfNeeded() throws {
    if launched { return }
    if command.hasPrefix("/") {
      process.executableURL = URL(fileURLWithPath: command)
      process.arguments = args
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [command] + args
    }
    process.environment = launchEnvironment(env)
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.qualityOfService = .userInitiated
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.consumeStdout(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.consumeStderr(handle.availableData)
    }
    process.terminationHandler = { [weak self] proc in
      self?.handleExit(proc.terminationStatus)
    }
    do {
      try process.run()
    } catch {
      throw McpClientError.failedToStart("Could not launch \(command).")
    }
    launched = true
  }

  private func launchEnvironment(_ extra: [String: String]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let prefix = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"].joined(separator: ":")
    let current = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = prefix + ":" + current
    for (key, value) in extra { environment[key] = value }
    return environment
  }

  private func writeLine(_ object: [String: Any]) throws {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw McpClientError.transport("Could not encode the MCP request.")
    }
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    try stdinPipe.fileHandleForWriting.write(contentsOf: data)
  }

  private func consumeStdout(_ data: Data) {
    if data.isEmpty {
      handleExit(process.terminationStatus)
      return
    }
    var lines: [String] = []
    lock.lock()
    buffer.append(data)
    while let range = buffer.firstRange(of: Data([0x0A])) {
      let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
      buffer.removeSubrange(buffer.startIndex...range.lowerBound)
      if let text = String(data: lineData, encoding: .utf8) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(trimmed) }
      }
    }
    lock.unlock()
    for line in lines { handleLine(line) }
  }

  private func consumeStderr(_ data: Data) {
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
    lock.lock()
    stderrText.append(text)
    if stderrText.count > 4_000 {
      stderrText = String(stderrText.suffix(4_000))
    }
    lock.unlock()
  }

  private func handleLine(_ line: String) {
    guard let object = McpFraming.jsonObject(line), let id = McpFraming.intValue(object["id"]) else { return }
    do {
      if case .result(let result) = try McpFraming.interpret(object, id: id) {
        succeed(id, result)
      }
    } catch {
      fail(id, error)
    }
  }

  private func handleExit(_ status: Int32) {
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    let message = stderrSummary(status: status)
    lock.unlock()
    failAll(McpClientError.failedToStart(message))
  }

  private func stderrSummary(status: Int32) -> String {
    let text = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "The local server exited (\(status))." }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let tail = lines.suffix(4).joined(separator: "\n")
    if tail.count > 400 { return String(tail.suffix(400)) }
    return tail
  }

  private func allocateID() -> Int {
    lock.lock()
    defer { lock.unlock() }
    let id = nextID
    nextID += 1
    return id
  }

  private func store(_ id: Int, _ continuation: CheckedContinuation<[String: Any], Error>) {
    lock.lock()
    waiters[id] = continuation
    lock.unlock()
  }

  private func armTimeout(_ id: Int, seconds: Double) {
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      self?.fail(id, McpClientError.timedOut)
    }
    lock.lock()
    timeouts[id] = task
    lock.unlock()
  }

  private func succeed(_ id: Int, _ result: [String: Any]) {
    finish(id)?.resume(returning: result)
  }

  private func fail(_ id: Int, _ error: Error) {
    finish(id)?.resume(throwing: error)
  }

  private func finish(_ id: Int) -> CheckedContinuation<[String: Any], Error>? {
    lock.lock()
    let task = timeouts.removeValue(forKey: id)
    let continuation = waiters.removeValue(forKey: id)
    lock.unlock()
    task?.cancel()
    return continuation
  }

  private func failAll(_ error: Error) {
    lock.lock()
    if closed {
      lock.unlock()
      return
    }
    let pending = waiters
    waiters.removeAll()
    let tasks = timeouts
    timeouts.removeAll()
    lock.unlock()
    for task in tasks.values { task.cancel() }
    for continuation in pending.values {
      continuation.resume(throwing: error)
    }
  }
}
