import Foundation

enum IntercomEvent {
  case ready(sampleRate: Int, deviceId: String)
  case accept(turnId: String)
  case pcm(Data)
  case turn(turnId: String, transcript: String, conversationId: Int64, ok: Bool, fastPath: Bool)
  case conversation(conversationId: Int64, fresh: Bool, bind: String)
  case done(ok: Bool, error: String, turnId: String)
  case speak(kind: String, runId: String, text: String)
  case heard(String, partial: Bool)
  case speaker(id: String, name: String, confident: Bool)
  case said(String)
  case forming(String)
  case surface(turnId: String, surface: ChatSurface)
  case approval(id: String, granted: Bool)
  case working(String)
  case status(String)
  case error(String)
  case disconnected(String)
}

private struct Outbound {
  var message: URLSessionWebSocketTask.Message
  var failure: String
  var generation: Int
  var task: URLSessionWebSocketTask
}

final class IntercomClient: NSObject, URLSessionWebSocketDelegate {
  private let lock = NSLock()
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var pingTimer: DispatchSourceTimer?
  private var generation = 0
  private let callbackQueue = DispatchQueue(label: "run.intercom.arthur.ws")
  /// Outbound frames. Completed in order so a context frame stays ahead of
  /// the PCM that follows it, without blocking on the session callback.
  private var outbound: [Outbound] = []
  private var outboundActive = false
  var onEvent: ((IntercomEvent) -> Void)?

  var isConnected: Bool {
    lock.lock()
    defer { lock.unlock() }
    return task != nil
  }

  func connect(host: String, port: Int, token: String, deviceId: String) {
    disconnect()
    var components = URLComponents()
    components.scheme = "ws"
    components.host = host
    components.port = port
    components.path = "/v1/stream"
    components.queryItems = [
      URLQueryItem(name: "token", value: token),
      URLQueryItem(name: "device_id", value: deviceId),
    ]
    guard let url = components.url else {
      emit(.error("invalid websocket url"))
      return
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
    request.timeoutInterval = 30

    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = 300
    config.timeoutIntervalForResource = 24 * 60 * 60
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    let task = session.webSocketTask(with: request)

    lock.lock()
    let gen = generation
    self.session = session
    self.task = task
    lock.unlock()

    task.resume()
    listen(gen)
    startPing(gen)
  }

  func disconnect() {
    lock.lock()
    generation += 1
    outbound.removeAll()
    outboundActive = false
    let oldTask = task
    let oldSession = session
    task = nil
    session = nil
    let timer = pingTimer
    pingTimer = nil
    lock.unlock()
    timer?.cancel()
    oldTask?.cancel(with: .goingAway, reason: nil)
    oldSession?.invalidateAndCancel()
  }

  func sendPCM(_ data: Data) {
    guard !data.isEmpty else { return }
    send(.data(data), failure: "send pcm")
  }

  func sendJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8)
    else { return }
    send(.string(text), failure: "send")
  }

  func sendEnd() { sendJSON(["type": "end"]) }
  func sendContext(_ context: DeskContext) {
    guard !context.isEmpty else { return }
    sendJSON(["type": "context", "context": context.wire])
  }
  func sendCancel() { sendJSON(["type": "cancel"]) }
  func sendArmApproval(id: String) {
    guard !id.isEmpty else { return }
    sendJSON(["type": "arm_approval", "id": id])
  }
  func sendClearApproval() { sendJSON(["type": "clear_approval"]) }
  func sendCancel(
    turnId: String,
    host: String,
    httpPort: Int,
    token: String,
    deviceId: String
  ) {
    sendCancel()
    guard !turnId.isEmpty else { return }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = httpPort
    components.path = "/v1/turns/\(turnId)/cancel"
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
    request.timeoutInterval = 2
    URLSession.shared.dataTask(with: request).resume()
  }
  func sendText(_ text: String, context: DeskContext? = nil) {
    var object: [String: Any] = ["type": "text", "text": text]
    if let context, !context.isEmpty {
      object["context"] = context.wire
    }
    sendJSON(object)
  }

  func sendNewConversation(bind: String) {
    sendJSON(["type": "new_conversation", "bind": bind])
  }

  func sendResumeConversation(_ id: Int64, bind: String) {
    sendJSON([
      "type": "resume_conversation",
      "conversation_id": NSNumber(value: id),
      "bind": bind,
    ])
  }

  private func send(_ message: URLSessionWebSocketTask.Message, failure: String) {
    lock.lock()
    let gen = generation
    guard let task else {
      lock.unlock()
      return
    }
    outbound.append(Outbound(message: message, failure: failure, generation: gen, task: task))
    let start = !outboundActive
    if start { outboundActive = true }
    lock.unlock()
    if start { writeNext(generation: gen) }
  }

  /// Writes the next frame only after the previous send finishes, so frames
  /// stay ordered. The session callback resumes the chain instead of a
  /// higher-priority thread waiting on it. A stale callback, from a socket
  /// that already failed, does not touch the new chain.
  private func writeNext(generation expected: Int) {
    lock.lock()
    guard expected == generation else {
      lock.unlock()
      return
    }
    guard !outbound.isEmpty else {
      outboundActive = false
      lock.unlock()
      return
    }
    let item = outbound.removeFirst()
    lock.unlock()
    item.task.send(item.message) { [weak self] error in
      if let self, let error, !self.isCancellation(error) {
        self.fail(item.generation, "\(item.failure): \(error.localizedDescription)")
      }
      self?.writeNext(generation: expected)
    }
  }

  private func startPing(_ gen: Int) {
    let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
    timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(1))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let task = self.generation == gen ? self.task : nil
      self.lock.unlock()
      task?.sendPing { [weak self] error in
        guard let self, let error, !self.isCancellation(error) else { return }
        self.fail(gen, "ping: \(error.localizedDescription)")
      }
    }
    lock.lock()
    guard generation == gen else {
      lock.unlock()
      timer.cancel()
      return
    }
    pingTimer = timer
    lock.unlock()
    timer.resume()
  }

  private func listen(_ gen: Int) {
    lock.lock()
    let task = generation == gen ? self.task : nil
    lock.unlock()
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        if self.isCancellation(error) { return }
        self.fail(gen, error.localizedDescription)
      case .success(let message):
        self.lock.lock()
        let current = self.generation == gen
        self.lock.unlock()
        guard current else { return }
        self.handle(message)
        self.listen(gen)
      }
    }
  }

  private func fail(_ gen: Int, _ message: String) {
    lock.lock()
    guard generation == gen else {
      lock.unlock()
      return
    }
    generation += 1
    outbound.removeAll()
    outboundActive = false
    let oldTask = task
    let oldSession = session
    task = nil
    session = nil
    let timer = pingTimer
    pingTimer = nil
    lock.unlock()
    timer?.cancel()
    oldTask?.cancel(with: .goingAway, reason: nil)
    if let oldSession {
      DispatchQueue.global(qos: .utility).async {
        oldSession.invalidateAndCancel()
      }
    }
    emit(.disconnected(message))
  }

  private func isCancellation(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
  }

  private func handle(_ message: URLSessionWebSocketTask.Message) {
    switch message {
    case .data(let data):
      if !data.isEmpty { emit(.pcm(data)) }
    case .string(let text):
      parseJSON(text)
    @unknown default:
      break
    }
  }

  private func parseJSON(_ text: String) {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let json = obj as? [String: Any]
    else { return }
    let type = json["type"] as? String ?? ""
    switch type {
    case "ready":
      emit(.ready(
        sampleRate: intValue(json["sample_rate"], 24000),
        deviceId: json["device_id"] as? String ?? ""
      ))
    case "accept":
      emit(.accept(turnId: json["turn_id"] as? String ?? ""))
    case "turn":
      emit(.turn(
        turnId: json["turn_id"] as? String ?? "",
        transcript: json["transcript"] as? String ?? "",
        conversationId: int64Value(json["conversation_id"]),
        ok: json["ok"] as? Bool ?? true,
        fastPath: json["fast_path"] as? Bool ?? false
      ))
    case "conversation":
      emit(.conversation(
        conversationId: int64Value(json["conversation_id"]),
        fresh: json["fresh"] as? Bool ?? false,
        bind: json["bind"] as? String ?? ""
      ))
    case "done":
      emit(.done(
        ok: json["ok"] as? Bool ?? true,
        error: json["error"] as? String ?? "",
        turnId: json["turn_id"] as? String ?? ""
      ))
    case "speak":
      emit(.speak(
        kind: json["kind"] as? String ?? "schedule",
        runId: stringValue(json["run_id"]),
        text: json["text"] as? String ?? ""
      ))
    case "heard":
      emit(.heard(
        json["text"] as? String ?? json["transcript"] as? String ?? "",
        partial: json["partial"] as? Bool ?? false
      ))
    case "speaker":
      emit(.speaker(
        id: json["id"] as? String ?? "",
        name: json["name"] as? String ?? "",
        confident: json["confident"] as? Bool ?? false
      ))
    case "said":
      emit(.said(json["text"] as? String ?? ""))
    case "forming":
      emit(.forming(json["text"] as? String ?? ""))
    case "surface":
      if let decoded = ChatSurface.decodeEvent(json) {
        emit(.surface(turnId: decoded.turnId, surface: decoded.surface))
      }
    case "approval":
      emit(.approval(
        id: json["id"] as? String ?? "",
        granted: json["granted"] as? Bool ?? false
      ))
    case "working":
      emit(.working(json["tool"] as? String ?? json["text"] as? String ?? ""))
    case "status":
      emit(.status(json["phase"] as? String ?? json["text"] as? String ?? ""))
    case "error":
      emit(.error(json["error"] as? String ?? text))
    default:
      break
    }
  }

  private func intValue(_ raw: Any?, _ fallback: Int) -> Int {
    if let n = raw as? Int { return n }
    if let n = raw as? NSNumber { return n.intValue }
    return fallback
  }

  private func int64Value(_ raw: Any?) -> Int64 {
    if let n = raw as? Int64 { return n }
    if let n = raw as? Int { return Int64(n) }
    if let n = raw as? NSNumber { return n.int64Value }
    return 0
  }

  private func stringValue(_ raw: Any?) -> String {
    if let s = raw as? String { return s }
    if let n = raw as? Int { return String(n) }
    if let n = raw as? Int64 { return String(n) }
    if let n = raw as? NSNumber { return n.stringValue }
    return ""
  }

  private func emit(_ event: IntercomEvent) {
    DispatchQueue.main.async { self.onEvent?(event) }
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didOpenWithProtocol protocol: String?) {}

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    lock.lock()
    let current = webSocketTask === task
    let gen = generation
    lock.unlock()
    guard current else { return }
    fail(gen, "socket closed")
  }
}
