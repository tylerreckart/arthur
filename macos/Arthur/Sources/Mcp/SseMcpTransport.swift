import Darwin
import Foundation

final class SseMcpTransport: McpTransport {
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
