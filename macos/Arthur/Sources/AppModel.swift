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

/// Which surface last contributed a user turn to the shared conversation.
enum ConversationSurface: Equatable {
  case desk
  case hallway
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
  /// Stable id for the in-flight Arthur bubble so `.forming` → `.said`
  /// does not remount the cluster (avoids a jump / flash).
  var formingLineId = UUID()
  /// Live ghost for voice turns. `"…"` while listening / Whisper runs;
  /// real words if a `heard` partial ever arrives. Empty when idle.
  var hearingText = ""
  var hearingLineId = UUID()
  var draft = "" {
    didSet {
      if draft != oldValue { persistDraft() }
    }
  }
  var errorText = ""
  var composerFocusToken = 0
  var composerFocused = false
  var conversationId: Int64 = 0
  var turnId = ""
  var micGranted = false
  var settingsOpen = false
  var holding = false
  var inputLevel = 0.0
  /// Live TTS energy (0…1) while Arthur is speaking. Drives the desk ripple.
  var speakLevel = 0.0
  var mcpServers: [McpServer] = []
  var mcpRegistryPath = McpRegistryStore.defaultPath
  var mcpSaveError = ""
  var mcpProbes: [String: McpProbe] = [:]
  var arbiterReachable = false
  var soundOn = true {
    didSet {
      ConfigStore.saveSoundOn(soundOn)
      audio.soundEnabled = soundOn
      if var notice = speakBack {
        notice.muted = !soundOn
        speakBack = notice
      }
    }
  }
  var speakBack: SpeakBackNotice?
  var pttHotkey: PTTHotkey = .optionSpace {
    didSet {
      guard oldValue != pttHotkey else { return }
      pttHotkey.persist()
      DeskAccessory.shared.registerHotkey(pttHotkey)
    }
  }
  /// When on, Space does not start push-to-talk. ⌥Space, the configured
  /// global chord, the mic hold, and the menu bar extra still talk.
  var quietTextMode = false {
    didSet {
      guard oldValue != quietTextMode else { return }
      ConfigStore.saveQuietTextMode(quietTextMode)
    }
  }
  /// Last user-turn surface we can infer: this Mac, or the hallway button
  /// (session `last_turn_id` moved without a local send).
  var lastSurface: ConversationSurface?
  /// Device id echoed on the WebSocket `ready` frame, when present.
  var socketDeviceId = ""

  private let client = IntercomClient()
  private let audio = AudioIO()
  private var healthTimer: Timer?
  private var keyMonitor: Any?
  private var pttStarted: Date?
  private var reconnectWork: DispatchWorkItem?
  private var reconnectAttempt = 0
  private var wantsSocket = false
  private var pcmBytes = 0
  private var expectingReply = false
  private var typedThisTurn = false
  private var started = false
  private var transcriptDeviceId = ""
  private var pttFromKeyboard = false
  private var speakBackDismiss: DispatchWorkItem?
  private var activeObserver: NSObjectProtocol?
  private var lastPolledTurnId = ""

  init() {
    config = ConfigStore.load()
    sessions = ConfigStore.loadSessions(dbPath: config.sessionDb)
    if let match = sessions.first(where: { $0.deviceId == config.deviceId }) {
      conversationId = match.conversationId
    }
    soundOn = ConfigStore.loadSoundOn()
    audio.soundEnabled = soundOn
    pttHotkey = PTTHotkey.load()
    quietTextMode = ConfigStore.loadQuietTextMode()
    transcriptDeviceId = config.deviceId
    discussion = ConfigStore.loadTranscript(deviceId: transcriptDeviceId)
    draft = ConfigStore.loadDraft()
    loadMcpRegistry()
    refreshSessionContinuity(initial: true)
    client.onEvent = { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    audio.onCapture = { [weak self] data in
      self?.client.sendPCM(data)
      let level = AudioIO.pcmLevel(data)
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
    if activeObserver == nil {
      activeObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.clearSpeakBackBadge() }
      }
    }
  }

  func stop() {
    wantsSocket = false
    healthTimer?.invalidate()
    healthTimer = nil
    reconnectWork?.cancel()
    reconnectWork = nil
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    audio.stopCapture()
    audio.stopPlayback()
    client.disconnect()
    persistTranscript()
    persistDraft()
    if let activeObserver {
      NotificationCenter.default.removeObserver(activeObserver)
      self.activeObserver = nil
    }
    speakBackDismiss?.cancel()
    speakBackDismiss = nil
    SpeakBackNotifier.clearBadge()
    started = false
  }

  func connect() {
    reconnectWork?.cancel()
    reconnectWork = nil
    wantsSocket = true
    guard !config.deviceToken.isEmpty else {
      wantsSocket = false
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
      lastSurface = nil
      lastPolledTurnId = ""
    }
    refreshSessionContinuity(initial: true)
    persistMcpRegistry()
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
    refreshSessionContinuity(initial: true)
    loadMcpRegistry()
  }

  func loadMcpRegistry() {
    mcpRegistryPath = McpRegistryStore.defaultPath
    mcpServers = McpRegistryStore.load(from: mcpRegistryPath)
    mcpSaveError = ""
  }

  func persistMcpRegistry() {
    do {
      try McpRegistryStore.save(mcpServers, to: mcpRegistryPath)
      mcpSaveError = ""
    } catch {
      mcpSaveError = "Could not write Arbiter’s MCP registry."
    }
  }

  func upsertMcp(_ server: McpServer) {
    var next = server
    next.name = McpServer.canonicalName(next.name)
    guard !next.name.isEmpty, !next.command.isEmpty else { return }
    if let idx = mcpServers.firstIndex(where: { $0.name == next.name }) {
      mcpServers[idx] = next
    } else {
      mcpServers.append(next)
      mcpServers.sort { $0.name < $1.name }
    }
    persistMcpRegistry()
  }

  func removeMcp(_ name: String) {
    let key = McpServer.canonicalName(name)
    mcpServers.removeAll { $0.name == key }
    var probes = mcpProbes
    probes.removeValue(forKey: key)
    mcpProbes = probes
    persistMcpRegistry()
  }

  func rememberMcpProbe(_ name: String, _ probe: McpProbe) {
    let key = McpServer.canonicalName(name)
    guard !key.isEmpty else { return }
    var probes = mcpProbes
    probes[key] = probe
    mcpProbes = probes
  }

  func setMcpEnabled(_ name: String, _ enabled: Bool) {
    guard let idx = mcpServers.firstIndex(where: { $0.name == name }) else { return }
    mcpServers[idx].enabled = enabled
    persistMcpRegistry()
  }

  func talkPressed() {
    if !holding { pttDown(explicit: true) }
  }

  func talkReleased() {
    if holding { pttUp() }
  }

  func toggleTalk() {
    if holding { pttUp() } else { pttDown(explicit: true) }
  }

  /// Starts push-to-talk. Implicit Space only reaches here when the composer is
  /// unfocused and the draft is empty. Pass `explicit: true` for the mic hold,
  /// menu bar extra, or configured global hotkey — those may run even when
  /// there is typed text, and they never clear `draft`.
  func pttDown(explicit: Bool = false) {
    guard canSend else { return }
    if !explicit && quietTextMode { return }
    if !explicit && hasDraft { return }
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
      beginHearing()
      try audio.startCapture()
      holding = true
      inputLevel = 0.12
      pttStarted = Date()
      become(.listening)
      setWork(.none)
      errorText = ""
      lastSurface = .desk
    } catch {
      clearHearing()
      errorText = error.localizedDescription
    }
  }

  func pttUp() {
    guard holding else { return }
    holding = false
    pttFromKeyboard = false
    inputLevel = 0
    audio.stopCapture()
    let elapsed = Date().timeIntervalSince(pttStarted ?? Date())
    pttStarted = nil
    if elapsed < 0.35 || pcmBytes < 8000 {
      client.sendCancel()
      clearHearing()
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
    clearHearing()
    typedThisTurn = true
    expectingReply = true
    setWork(.findingWords)
    become(.thinking)
    lastSurface = .desk
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

  var hasDraft: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func focusComposer() {
    guard !holding, !settingsOpen else { return }
    composerFocused = true
    composerFocusToken += 1
  }

  func dismissError() {
    errorText = ""
  }

  func dismissSpeakBack() {
    speakBackDismiss?.cancel()
    speakBackDismiss = nil
    speakBack = nil
    SpeakBackNotifier.clearBadge()
  }

  func cancelTurn() {
    guard canCancel else { return }
    client.sendCancel()
    audio.interruptPlayback()
    expectingReply = false
    typedThisTurn = false
    formingText = ""
    clearHearing()
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

  func toggleQuietTextMode() {
    quietTextMode.toggle()
  }

  /// Glanceable session copy (not rendered in the title bar).
  /// Idle + shared device id reads as the hallway conversation.
  var chromeLabel: String {
    switch phase {
    case .disconnected: return "Disconnected"
    case .connecting: return "Reaching intercom…"
    case .listening: return "Listening"
    case .thinking: return "Writing"
    case .speaking: return "Speaking"
    case .idle:
      if sharesHallwayMemory { return "Shared with hallway" }
      return micGranted ? "This Mac" : "Mic off"
    }
  }

  /// Tooltip / VoiceOver detail: device id, conversation, last surface.
  var chromeDetail: String {
    var parts: [String] = [chromeLabel]
    let device = socketDeviceId.isEmpty ? config.deviceId : socketDeviceId
    if !device.isEmpty { parts.append(device) }
    if conversationId > 0 { parts.append("conversation \(conversationId)") }
    if let lastSurface {
      parts.append(lastSurface == .desk ? "last from Mac" : "last from hallway")
    }
    return parts.joined(separator: " · ")
  }

  /// True when this desk session uses the hallway device identity (or the
  /// same Arbiter conversation as a `nano-` / `speaker-` session).
  var sharesHallwayMemory: Bool {
    if Self.deviceLooksLikeHallway(config.deviceId) { return true }
    if Self.deviceLooksLikeHallway(socketDeviceId) { return true }
    guard conversationId > 0 else { return false }
    return sessions.contains {
      Self.deviceLooksLikeHallway($0.deviceId) && $0.conversationId == conversationId
    }
  }

  static func deviceLooksLikeHallway(_ id: String) -> Bool {
    let lower = id.lowercased()
    return lower.hasPrefix("nano-")
      || lower.hasPrefix("speaker-")
      || lower.hasPrefix("hallway")
  }

  private func beginHearing() {
    hearingLineId = UUID()
    hearingText = "…"
  }

  private func clearHearing() {
    hearingText = ""
  }

  /// Voice (and late `turn`) path. Typed sends already appended in `sendDraft`.
  private func commitVoiceTranscript(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    youSaid = trimmed
    if !typedThisTurn {
      appendDiscussion(fromYou: true, text: trimmed, id: hearingLineId)
    }
    clearHearing()
  }

  private func appendDiscussion(fromYou: Bool, text: String, id: UUID? = nil) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let last = discussion.last, last.fromYou == fromYou, last.text == trimmed { return }
    discussion.append(DiscussionLine(fromYou: fromYou, text: trimmed, id: id ?? UUID()))
    if discussion.count > 40 {
      discussion.removeFirst(discussion.count - 40)
    }
    persistTranscript()
  }

  private func persistTranscript(deviceId: String? = nil) {
    ConfigStore.saveTranscript(discussion, deviceId: deviceId ?? transcriptDeviceId)
  }

  private func persistDraft() {
    ConfigStore.saveDraft(draft)
  }

  private func handle(_ event: IntercomEvent) {
    switch event {
    case .ready(_, let deviceId):
      reconnectWork?.cancel()
      reconnectWork = nil
      reconnectAttempt = 0
      if !deviceId.isEmpty { socketDeviceId = deviceId }
      become(.idle)
      healthOK = true
      healthDetail = "connected"
      errorText = ""
      refreshSessionContinuity(initial: lastPolledTurnId.isEmpty)
    case .accept(let id):
      turnId = id
      lastSurface = .desk
      if !id.isEmpty { lastPolledTurnId = id }
    case .pcm(let data):
      if expectingReply || phase == .speaking {
        become(.speaking)
        if work != .speaking { setWork(.speaking) }
        audio.playPCM(data)
        ingestSpeakLevel(AudioIO.pcmLevel(data, gain: 2.4))
      }
    case .heard(let text):
      if !text.isEmpty {
        commitVoiceTranscript(text)
      }
    case .turn(let transcript, let conv, let ok, _):
      if !transcript.isEmpty {
        commitVoiceTranscript(transcript)
      } else {
        clearHearing()
      }
      typedThisTurn = false
      if conv > 0 { conversationId = conv }
      if !ok { errorText = "That turn did not finish cleanly." }
    case .done(let ok, let err, _):
      expectingReply = false
      typedThisTurn = false
      formingText = ""
      clearHearing()
      setWork(.none)
      if !ok, !err.isEmpty { errorText = err }
      become(client.isConnected ? .idle : .disconnected)
      if speakBack?.live == true { finishSpeakBack() }
    case .speak(let kind, let runId, let text):
      expectingReply = true
      become(.speaking)
      setWork(.speaking)
      presentSpeakBack(kind: kind, runId: runId, text: text)
    case .said(let text):
      let id = formingText.isEmpty ? UUID() : formingLineId
      appendDiscussion(fromYou: false, text: text, id: id)
      formingText = ""
      become(.speaking)
      setWork(.speaking)
      if speakBack?.live == true { noteSpeakBackSaid(text) }
    case .forming(let text):
      if formingText.isEmpty {
        formingLineId = UUID()
      }
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
      clearHearing()
    case .disconnected(let msg):
      audio.stopCapture()
      holding = false
      pttFromKeyboard = false
      inputLevel = 0
      expectingReply = false
      typedThisTurn = false
      formingText = ""
      clearHearing()
      if speakBack?.live == true { finishSpeakBack() }
      become(.disconnected)
      healthOK = false
      healthDetail = msg
      socketDeviceId = ""
      guard wantsSocket else { return }
      if reconnectAttempt >= 1, errorText.isEmpty {
        errorText = msg.isEmpty ? "Disconnected from intercom." : msg
      }
      scheduleReconnect()
    }
  }

  private func presentSpeakBack(kind: String, runId: String, text: String) {
    speakBackDismiss?.cancel()
    speakBackDismiss = nil
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let notice = SpeakBackNotice(
      id: UUID(),
      kind: kind.isEmpty ? "schedule" : kind,
      runId: runId,
      spokenText: trimmed,
      muted: !soundOn,
      live: true
    )
    speakBack = notice
    if !trimmed.isEmpty {
      appendDiscussion(fromYou: false, text: trimmed)
    }
    SpeakBackNotifier.announce(notice)
  }

  private func noteSpeakBackSaid(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var notice = speakBack, notice.live else { return }
    if notice.spokenText.isEmpty {
      notice.spokenText = trimmed
    } else if notice.spokenText != trimmed, !notice.spokenText.contains(trimmed) {
      notice.spokenText += " " + trimmed
    } else {
      return
    }
    speakBack = notice
  }

  private func finishSpeakBack() {
    guard var notice = speakBack else { return }
    notice.live = false
    speakBack = notice
    speakBackDismiss?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.speakBack = nil
    }
    speakBackDismiss = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
  }

  private func clearSpeakBackBadge() {
    SpeakBackNotifier.clearBadge()
  }

  private func become(_ p: ArthurPhase) {
    if p == .speaking, phase != .speaking {
      speakLevel = max(speakLevel, 0.34)
    }
    if p != .speaking {
      speakLevel = 0
    }
    phase = p
    if p == .idle || p == .disconnected {
      formingText = ""
      hearingText = ""
    }
  }

  private func ingestSpeakLevel(_ level: Double) {
    speakLevel = min(1, max(level, speakLevel * 0.82))
  }

  private func setWork(_ w: WorkState) {
    work = w
  }

  private func scheduleReconnect() {
    reconnectWork?.cancel()
    let attempt = reconnectAttempt
    reconnectAttempt = min(attempt + 1, 5)
    let delay = min(8.0, 0.4 * pow(2.0, Double(attempt)))
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.wantsSocket else { return }
      self.connect()
    }
    reconnectWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
          if let arb = obj["arbiter"] as? [String: Any] {
            self.arbiterReachable = arb["reachable"] as? Bool ?? false
          }
          if self.phase == .disconnected {
            self.healthDetail = ok ? "http up, socket down" : "intercom not ready"
          }
        } else {
          self.arbiterReachable = false
          if self.phase == .disconnected {
            self.healthOK = false
            self.healthDetail = "intercom not reachable on :\(self.config.httpPort)"
          }
        }
        self.refreshSessionContinuity()
      }
    }.resume()
  }

  /// Keyboard contract (desk window):
  /// - Configured global PTT (default ⌥Space) always talks, even with a draft.
  /// - ⌘L / ⌘K focus Ask Arthur (menu + this monitor).
  /// - Return sends, Shift-Return inserts a newline (single path; not onSubmit).
  /// - Escape calls `cancelTurn()` when `canCancel`.
  /// - Space is PTT only when the composer is unfocused, the draft is empty,
  ///   and quiet text mode is off.
  /// Space is never stolen while typing or in quiet text mode.
  private func installKeys() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self else { return event }

      // Configured chord (menu-bar/global PTT). Consume it so the Space-only
      // in-window path does not also fire.
      if self.pttHotkey.matches(event) {
        if event.type == .keyDown {
          if event.isARepeat { return nil }
          Task { @MainActor in self.talkPressed() }
        } else if event.type == .keyUp {
          Task { @MainActor in self.talkReleased() }
        }
        return nil
      }

      if self.settingsOpen { return event }

      if event.type == .keyDown {
        if self.handleCommandShortcut(event) { return nil }
        if event.keyCode == 53, self.canCancel {
          Task { @MainActor in self.cancelTurn() }
          return nil
        }
        switch self.handleComposerReturn(event) {
        case .ignore:
          break
        case .pass:
          return event
        case .consume:
          return nil
        }
      }

      return self.handlePushToTalk(event)
    }
  }

  @discardableResult
  private func handleCommandShortcut(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.contains(.command) else { return false }
    let extra = event.modifierFlags.intersection([.shift, .option, .control])
    guard extra.isEmpty else { return false }
    let chars = event.charactersIgnoringModifiers?.lowercased()
    if chars == "l" || chars == "k" {
      focusComposer()
      return true
    }
    return false
  }

  private enum KeyResult {
    case ignore
    case pass
    case consume
  }

  /// Return/Enter send when the composer is first responder. Shift-Return
  /// falls through so the field can insert a newline. This is the only send
  /// path — the SwiftUI field must not also use onSubmit/onKeyPress.
  private func handleComposerReturn(_ event: NSEvent) -> KeyResult {
    guard event.keyCode == 36 || event.keyCode == 76 else { return .ignore }
    guard composerFocused else { return .ignore }
    if event.modifierFlags.contains(.shift) { return .pass }
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
      return .pass
    }
    if hasDraft {
      Task { @MainActor in self.sendDraft() }
    }
    return .consume
  }

  private func handlePushToTalk(_ event: NSEvent) -> NSEvent? {
    guard event.keyCode == 49 else { return event }
    // The configured global chord is consumed above so Space-only PTT
    // and the hotkey do not both fire.
    if pttHotkey.matches(event) { return event }
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
      return event
    }

    let option = event.modifierFlags.contains(.option)
    if option {
      return consumePTT(event, explicit: true)
    }

    if quietTextMode { return event }
    if composerFocused { return event }
    if hasDraft { return event }
    return consumePTT(event, explicit: false)
  }

  /// Reload `device_sessions` and infer hallway vs desk when Intercom's
  /// `last_turn_id` moves without a local send. No new protocol — same
  /// SQLite the Settings device picker already reads.
  private func refreshSessionContinuity(initial: Bool = false) {
    sessions = ConfigStore.loadSessions(dbPath: config.sessionDb)
    guard let match = sessions.first(where: { $0.deviceId == config.deviceId }) else {
      return
    }
    if match.conversationId > 0 { conversationId = match.conversationId }
    let remote = match.lastTurnId
    guard !remote.isEmpty else { return }
    if initial {
      lastPolledTurnId = remote
      return
    }
    guard remote != lastPolledTurnId else { return }
    lastPolledTurnId = remote
    if remote == turnId || expectingReply || holding {
      lastSurface = .desk
      return
    }
    lastSurface = .hallway
  }

  private func consumePTT(_ event: NSEvent, explicit: Bool) -> NSEvent? {
    if event.type == .keyDown {
      if event.isARepeat { return nil }
      if holding { return nil }
      Task { @MainActor in
        self.pttFromKeyboard = true
        self.pttDown(explicit: explicit)
      }
      return nil
    }
    if event.type == .keyUp {
      Task { @MainActor in
        guard self.pttFromKeyboard else { return }
        self.pttUp()
      }
      return nil
    }
    return event
  }

}
