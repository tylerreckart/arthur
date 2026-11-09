import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
  func watchFocus() {
    guard !previewCanvas else { return }
    let center = INFocusStatusCenter.default
    switch center.authorizationStatus {
    case .notDetermined:
      // This prompt comes back on every launch if it is called after the
      // user has already answered. Ask only while the choice is still open.
      center.requestAuthorization { _ in
        DispatchQueue.main.async { [weak self] in self?.publishFocus() }
      }
    default:
      publishFocus()
    }
  }

  func publishFocus() {
    guard !previewCanvas else { return }
    let center = INFocusStatusCenter.default
    let focused = center.authorizationStatus == .authorized && center.focusStatus.isFocused == true
    client.sendJSON(["type": "presence", "dnd": focused])
  }

  func ingestSpeakLevel(_ level: Double) {
    speakLevel = min(1, max(level, speakLevel * 0.82))
  }

  func setWork(_ w: WorkState) {
    work = w
  }

  func scheduleReconnect() {
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

  func pollHealth() {
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
        self.publishFocus()
        self.resumeWake()
      }
    }.resume()
  }

  /// Keyboard contract (desk window):
  /// - Configured global PTT (default ⌥Space) always talks, even with a draft.
  /// - ⌘L / ⌘K focus Ask Arthur (menu + this monitor).
  /// - Return sends, Shift-Return inserts a newline (single path; not onSubmit).
  /// - Escape calls `cancelTurn()` when `canCancel`.
  /// - Space is PTT only when the composer is unfocused, the droplet field
  ///   is unfocused, the draft is empty, and quiet text mode is off.
  /// Space is never stolen while typing or in quiet text mode.
  func installKeys() {
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
        if event.keyCode == 53 {
          if self.canCancel {
            Task { @MainActor in self.cancelTurn() }
            return nil
          }
          if DeskAccessory.shared.dismissDroplet() {
            return nil
          }
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
  func handleCommandShortcut(_ event: NSEvent) -> Bool {
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

  enum KeyResult {
    case ignore
    case pass
    case consume
  }

  /// Return/Enter send when the composer is first responder. Shift-Return
  /// falls through so the field can insert a newline. This is the only send
  /// path — the SwiftUI field must not also use onSubmit/onKeyPress.
  func handleComposerReturn(_ event: NSEvent) -> KeyResult {
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

  func handlePushToTalk(_ event: NSEvent) -> NSEvent? {
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
  func refreshSessionContinuity(initial: Bool = false) {
    sessions = ConfigStore.loadSessions(dbPath: config.sessionDb)
    guard let match = sessions.first(where: { $0.deviceId == config.deviceId }) else {
      return
    }
    if match.conversationId > 0 { noteServerConversation(match.conversationId) }
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

  func consumePTT(_ event: NSEvent, explicit: Bool) -> NSEvent? {
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

  func loadLibrary(deviceId: String) {
    let library = ConfigStore.loadLibrary(deviceId: deviceId)
    conversations = library.conversations
    activeConversationId = library.activeId
    discussion = library.conversations.first { $0.id == library.activeId }?.lines ?? []
    if let server = library.conversations.first(where: { $0.id == library.activeId })?.serverConversationId,
       server > 0 {
      conversationId = server
    }
  }

  func captureActiveLines() {
    let title = DeskConversation.title(for: discussion)
    if let idx = conversations.firstIndex(where: { $0.id == activeConversationId }) {
      let changed = conversations[idx].lines != discussion || conversations[idx].title != title
      conversations[idx].lines = discussion
      conversations[idx].title = title
      if changed { conversations[idx].updatedAt = Date() }
      if conversations[idx].serverConversationId == 0, conversationId > 0,
         !conversations[idx].needsFreshServer {
        conversations[idx].serverConversationId = conversationId
      }
      return
    }
    var item = DeskConversation.empty(serverConversationId: conversationId)
    item.id = activeConversationId
    item.title = title
    item.lines = discussion
    conversations.insert(item, at: 0)
  }

  func persistLibrary(deviceId: String? = nil) {
    guard !previewCanvas else { return }
    let library = ConversationLibrary(activeId: activeConversationId, conversations: conversations)
    let device = deviceId ?? transcriptDeviceId
    transcriptQueue.sync {
      ConfigStore.saveLibrary(library, deviceId: device)
    }
  }

  /// Adopt a server id onto the open thread only when that thread is not
  /// waiting on a fresh conversation and does not already name another one.
  func noteServerConversation(_ id: Int64) {
    guard id > 0 else { return }
    guard let idx = conversations.firstIndex(where: { $0.id == activeConversationId }) else {
      conversationId = id
      return
    }
    guard !conversations[idx].needsFreshServer else { return }
    let current = conversations[idx].serverConversationId
    guard current == 0 || current == id else { return }
    conversations[idx].serverConversationId = id
    conversationId = id
  }

  func noteBoundConversation(_ id: Int64, bind: String) {
    guard id > 0, let local = UUID(uuidString: bind),
          let idx = conversations.firstIndex(where: { $0.id == local })
    else { return }
    conversations[idx].serverConversationId = id
    conversations[idx].needsFreshServer = false
    if local == activeConversationId {
      conversationId = id
    }
    persistLibrary()
  }

  func alignServerConversation() {
    guard canStartConversation else { return }
    guard let item = conversations.first(where: { $0.id == activeConversationId }) else { return }
    let bind = item.id.uuidString
    if item.needsFreshServer {
      client.sendNewConversation(bind: bind)
      return
    }
    guard item.serverConversationId > 0 else { return }
    client.sendResumeConversation(item.serverConversationId, bind: bind)
  }

  #if DEBUG
  /// Desk state for Xcode's canvas. Builds a real model, then fills phase,
  /// discussion, and draft without connecting, capturing, or writing disk.
  static func previewCanvas(
    phase: ArthurPhase = .idle,
    discussion: [DiscussionLine] = [],
    draft: String = "",
    history: [DeskConversation] = [],
    sidebarOpen: Bool = false
  ) -> AppModel {
    let model = AppModel()
    model.previewCanvas = true
    model.phase = phase
    model.formingText = ""
    model.hearingText = ""
    model.errorText = ""
    model.holding = false
    model.handsFree = false
    model.quietTextMode = false
    model.micGranted = true
    model.draft = draft
    model.deskLoadState = .loaded
    model.sidebarOpen = sidebarOpen
    if history.isEmpty {
      var item = DeskConversation.empty()
      item.lines = discussion
      item.title = DeskConversation.title(for: discussion)
      model.conversations = [item]
      model.activeConversationId = item.id
      model.discussion = discussion
    } else {
      model.conversations = history
      model.activeConversationId = history[0].id
      model.discussion = history[0].lines
    }
    return model
  }
  #endif
}
