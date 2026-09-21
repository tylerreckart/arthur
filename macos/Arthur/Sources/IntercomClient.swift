import Foundation

enum IntercomEvent {
  case ready(sampleRate: Int, deviceId: String)
  case accept(turnId: String)
  case pcm(Data)
  case turn(transcript: String, conversationId: Int64, ok: Bool, fastPath: Bool)
  case done(ok: Bool, error: String, turnId: String)
  case speak(kind: String)
  case said(String)
  case forming(String)
  case working(String)
  case status(String)
  case error(String)
  case disconnected(String)
}

final class IntercomClient: NSObject, URLSessionWebSocketDelegate {
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var pingTimer: Timer?
  private let callbackQueue = DispatchQueue(label: "run.intercom.arthur.ws")
  var onEvent: ((IntercomEvent) -> Void)?

  var isConnected: Bool { task != nil }

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
    request.timeoutInterval = 15

    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    task = session?.webSocketTask(with: request)
    task?.resume()
    listen()
    startPing()
  }

  func disconnect() {
    pingTimer?.invalidate()
    pingTimer = nil
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    session?.invalidateAndCancel()
    session = nil
  }

  func sendPCM(_ data: Data) {
    guard !data.isEmpty else { return }
    task?.send(.data(data)) { [weak self] error in
      if let error {
        self?.emit(.error("send pcm: \(error.localizedDescription)"))
      }
    }
  }

  func sendJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8)
    else { return }
    task?.send(.string(text)) { [weak self] error in
      if let error {
        self?.emit(.error("send: \(error.localizedDescription)"))
      }
    }
  }

  func sendEnd() { sendJSON(["type": "end"]) }
  func sendCancel() { sendJSON(["type": "cancel"]) }
  func sendText(_ text: String) { sendJSON(["type": "text", "text": text]) }

  private func startPing() {
    pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      self?.task?.sendPing { error in
        if let error {
          self?.emit(.disconnected("ping: \(error.localizedDescription)"))
        }
      }
    }
    RunLoop.main.add(pingTimer!, forMode: .common)
  }

  private func listen() {
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.emit(.disconnected(error.localizedDescription))
      case .success(let message):
        self.handle(message)
        self.listen()
      }
    }
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
        transcript: json["transcript"] as? String ?? "",
        conversationId: int64Value(json["conversation_id"]),
        ok: json["ok"] as? Bool ?? true,
        fastPath: json["fast_path"] as? Bool ?? false
      ))
    case "done":
      emit(.done(
        ok: json["ok"] as? Bool ?? true,
        error: json["error"] as? String ?? "",
        turnId: json["turn_id"] as? String ?? ""
      ))
    case "speak":
      emit(.speak(kind: json["kind"] as? String ?? "schedule"))
    case "said":
      emit(.said(json["text"] as? String ?? ""))
    case "forming":
      emit(.forming(json["text"] as? String ?? ""))
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

  private func emit(_ event: IntercomEvent) {
    DispatchQueue.main.async { self.onEvent?(event) }
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didOpenWithProtocol protocol: String?) {}

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    emit(.disconnected("socket closed"))
  }
}
