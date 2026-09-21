import AppKit
import Foundation
import SwiftUI

enum ArthurPhase: Equatable {
  case disconnected
  case connecting
  case idle
  case listening
  case thinking
  case speaking
}

@MainActor
@Observable
final class AppModel {
  var config: ClientConfig
  var sessions: [DeviceSession] = []
  var phase: ArthurPhase = .disconnected
  var healthOK = false
  var healthDetail = "not connected"
  var discussion: [DiscussionLine] = []
  var work: WorkState = .none
  var youSaid = ""
  var formingText = ""
  var draft = ""
  var errorText = ""
  var conversationId: Int64 = 0
  var turnId = ""
  var micGranted = false
  var settingsOpen = false
  var holding = false
  var inputLevel = 0.0
  var soundOn = true {
    didSet {
      ConfigStore.saveSoundOn(soundOn)
      audio.soundEnabled = soundOn
    }
  }

  private let client = IntercomClient()
  private let audio = AudioIO()
  private var healthTimer: Timer?
  private var keyMonitor: Any?
  private var pttStarted: Date?
  private var reconnectWork: DispatchWorkItem?
  private var pcmBytes = 0
  private var expectingReply = false
  private var typedThisTurn = false
  private var started = false
  private var transcriptDeviceId = ""

  init() {
    config = ConfigStore.load()
    sessions = ConfigStore.loadSessions(dbPath: config.sessionDb)
    if let match = sessions.first(where: { $0.deviceId == config.deviceId }) {
      conversationId = match.conversationId
    }
    soundOn = ConfigStore.loadSoundOn()
    audio.soundEnabled = soundOn
    transcriptDeviceId = config.deviceId
    discussion = ConfigStore.loadTranscript(deviceId: transcriptDeviceId)
    client.onEvent = { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    audio.onCapture = { [weak self] data in
      self?.client.sendPCM(data)
      let level = Self.captureLevel(data)
      DispatchQueue.main.async {
        guard let self else { return }
        self.pcmBytes += data.count
        if self.holding {
          self.inputLevel = min(1, max(level, self.inputLevel * 0.68))
        }
      }
    }
  }

  func start() {
    guard !started else { return }
    started = true
    installKeys()
    audio.requestMic { [weak self] ok in
      self?.micGranted = ok
      if !ok { self?.errorText = "Microphone access is off — type instead, or enable it in System Settings." }
    }
    do { try audio.startPlayback() } catch {
      errorText = error.localizedDescription
    }
    connect()
    healthTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pollHealth() }
    }
    pollHealth()
  }

  func stop() {
    healthTimer?.invalidate()
    healthTimer = nil
    reconnectWork?.cancel()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    audio.stopCapture()
    audio.stopPlayback()
    client.disconnect()
    persistTranscript()
    started = false
  }

  func connect() {
    reconnectWork?.cancel()
    guard !config.deviceToken.isEmpty else {
      become(.disconnected)
      healthDetail = "missing device_token in intercom.json"
      if errorText.isEmpty { errorText = healthDetail }
      return
    }
    become(.connecting)
    client.connect(
      host: config.host,
      port: config.wsPort,
      token: config.deviceToken,
      deviceId: config.deviceId
    )
  }

  func applySettings() {
    persistTranscript()
    ConfigStore.saveDeviceId(config.deviceId)
    ConfigStore.saveHost(config.host)
    ConfigStore.saveConfigPath(config.configPath)
    sessions = ConfigStore.loadSessions(dbPath: config.sessionDb)
    if config.deviceId != transcriptDeviceId {
      transcriptDeviceId = config.deviceId
      discussion = ConfigStore.loadTranscript(deviceId: transcriptDeviceId)
    }
    audio.interruptPlayback()
    connect()
  }

  func reloadFromDisk() {
    let keepId = config.deviceId
    let keepHost = config.host
    config = ConfigStore.load()
    if !keepId.isEmpty { config.deviceId = keepId }
    if !keepHost.isEmpty { config.host = keepHost }
    sessions = ConfigStore.loadSessions(dbPath: config.sessionDb)
  }

  func pttDown() {
    guard canSend else { return }
    if phase == .speaking || phase == .thinking {
      client.sendCancel()
      audio.interruptPlayback()
    }
    guard micGranted else {
      errorText = "Microphone access is off."
      return
    }
    do {
      pcmBytes = 0
      expectingReply = false
      typedThisTurn = false
      formingText = ""
      try audio.startCapture()
      holding = true
      inputLevel = 0.12
      pttStarted = Date()
      become(.listening)
      setWork(.none)
      errorText = ""
    } catch {
      errorText = error.localizedDescription
    }
  }

  func pttUp() {
    guard holding else { return }
    holding = false
    inputLevel = 0
    audio.stopCapture()
    let elapsed = Date().timeIntervalSince(pttStarted ?? Date())
    pttStarted = nil
    if elapsed < 0.35 || pcmBytes < 8000 {
      client.sendCancel()
      become(client.isConnected ? .idle : .disconnected)
      errorText = "Too short — hold a little longer."
      return
    }
    expectingReply = true
    setWork(.findingWords)
    become(.thinking)
    client.sendEnd()
  }

  func sendDraft() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if phase == .speaking || phase == .thinking {
      client.sendCancel()
      audio.interruptPlayback()
    }
    guard canSend else { return }
    youSaid = text
    appendDiscussion(fromYou: true, text: text)
    draft = ""
    formingText = ""
    typedThisTurn = true
    expectingReply = true
    setWork(.findingWords)
    become(.thinking)
    client.sendText(text)
  }

  var canSend: Bool {
    phase == .idle || phase == .speaking || phase == .thinking
  }

  var canTalk: Bool {
    phase != .disconnected && phase != .connecting
  }

  var canCancel: Bool {
    phase == .speaking || phase == .thinking
  }

  var phaseLabel: String {
    switch phase {
    case .disconnected: return "Disconnected"
    case .connecting: return "Reaching intercom…"
    case .idle: return micGranted ? "Connected" : "Mic off"
    case .listening: return "Listening"
    case .thinking: return "Writing"
    case .speaking: return "Speaking"
    }
  }

  func dismissError() {
    errorText = ""
  }

  func cancelTurn() {
    guard canCancel else { return }
    client.sendCancel()
    audio.interruptPlayback()
    expectingReply = false
    typedThisTurn = false
    formingText = ""
    setWork(.none)
    become(client.isConnected ? .idle : .disconnected)
  }

  func prefillDraft(_ text: String) {
    draft = text
  }

  func applyStarter(_ text: String, send: Bool) {
    draft = text
    if send { sendDraft() }
  }

  private func appendDiscussion(fromYou: Bool, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let last = discussion.last, last.fromYou == fromYou, last.text == trimmed { return }
    discussion.append(DiscussionLine(fromYou: fromYou, text: trimmed))
    if discussion.count > 40 {
      discussion.removeFirst(discussion.count - 40)
    }
    persistTranscript()
  }

  private func persistTranscript(deviceId: String? = nil) {
    ConfigStore.saveTranscript(discussion, deviceId: deviceId ?? transcriptDeviceId)
  }

  private func handle(_ event: IntercomEvent) {
    switch event {
    case .ready:
      become(.idle)
      healthOK = true
      healthDetail = "connected"
      errorText = ""
    case .accept(let id):
      turnId = id
    case .pcm(let data):
      if expectingReply || phase == .speaking {
        become(.speaking)
        if work != .speaking { setWork(.speaking) }
        audio.playPCM(data)
      }
    case .turn(let transcript, let conv, let ok, _):
      if !transcript.isEmpty {
        youSaid = transcript
        if !typedThisTurn {
          appendDiscussion(fromYou: true, text: transcript)
        }
      }
      typedThisTurn = false
      if conv > 0 { conversationId = conv }
      if !ok { errorText = "That turn did not finish cleanly." }
    case .done(let ok, let err, _):
      expectingReply = false
      typedThisTurn = false
      formingText = ""
      setWork(.none)
      if !ok, !err.isEmpty { errorText = err }
      become(client.isConnected ? .idle : .disconnected)
    case .speak:
      expectingReply = true
      become(.speaking)
      setWork(.speaking)
    case .said(let text):
      appendDiscussion(fromYou: false, text: text)
      formingText = ""
      become(.speaking)
      setWork(.speaking)
    case .forming(let text):
      formingText = text
      if phase != .speaking, phase != .listening {
        become(.thinking)
      }
    case .working(let tool):
      setWork(.tool(tool))
      if phase == .idle { become(.thinking) }
    case .status(let value):
      if value == "thinking", phase != .speaking, phase != .listening {
        become(.thinking)
        if work == .none { setWork(.findingWords) }
      }
    case .error(let msg):
      errorText = msg
    case .disconnected(let msg):
      audio.stopCapture()
      holding = false
      inputLevel = 0
      expectingReply = false
      typedThisTurn = false
      formingText = ""
      become(.disconnected)
      healthOK = false
      healthDetail = msg
      if errorText.isEmpty {
        errorText = msg.isEmpty ? "Disconnected from intercom." : msg
      }
      scheduleReconnect()
    }
  }

  private func become(_ p: ArthurPhase) {
    phase = p
    if p == .idle || p == .disconnected {
      formingText = ""
    }
  }

  private func setWork(_ w: WorkState) {
    work = w
  }

  private func scheduleReconnect() {
    reconnectWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.connect()
    }
    reconnectWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
  }

  private func pollHealth() {
    guard let url = URL(string: "http://\(config.host):\(config.httpPort)/health") else { return }
    var req = URLRequest(url: url)
    req.timeoutInterval = 2
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
      Task { @MainActor in
        guard let self else { return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, let data,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          let ok = obj["ok"] as? Bool ?? false
          self.healthOK = ok || self.phase != .disconnected
          if self.phase == .disconnected {
            self.healthDetail = ok ? "http up, socket down" : "intercom not ready"
          }
        } else if self.phase == .disconnected {
          self.healthOK = false
          self.healthDetail = "intercom not reachable on :\(self.config.httpPort)"
        }
      }
    }.resume()
  }

  private func installKeys() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self else { return event }
      guard event.keyCode == 49 else { return event }
      if self.textFieldFocused { return event }
      if event.type == .keyDown {
        if event.isARepeat { return nil }
        Task { @MainActor in self.pttDown() }
        return nil
      }
      if event.type == .keyUp {
        Task { @MainActor in self.pttUp() }
        return nil
      }
      return event
    }
  }

  private var textFieldFocused: Bool {
    NSApp.keyWindow?.firstResponder is NSTextView
  }

  private static func captureLevel(_ data: Data) -> Double {
    let count = data.count / 2
    guard count > 0 else { return 0 }
    return data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      var sum = 0.0
      for i in 0..<count {
        let x = Double(samples[i]) / 32768.0
        sum += x * x
      }
      min(1, sqrt(sum / Double(count)) * 3.4)
    }
  }
}
