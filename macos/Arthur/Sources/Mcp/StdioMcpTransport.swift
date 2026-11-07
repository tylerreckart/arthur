import Darwin
import Foundation

final class StdioMcpTransport: McpTransport {
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
