import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
  func reconnect() {
    errorText = ""
    connect()
    pollHealth()
  }

  func performJobAction(_ job: JobItem, primary: Bool) {
    switch job.kind {
    case .approval:
      if primary { resolvePendingWrite() }
      else if let id = pendingWriteId { resolveWrite(id: id, granted: false, via: "card") }
    case .turn: if primary { cancelTurn() }
    case .error:
      if primary {
        if phase == .disconnected || phase == .connecting { reconnect() }
        else { let msg = errorText; errorText = ""; if !msg.isEmpty { deskStatus = "Retried — if it fails again it will appear here." }; reconnect() }
      } else { dismissError() }
    case .schedule:
      guard let id = Int(job.id.dropFirst("schedule-".count)) else { return }
      if primary { finishSchedule(id, status: "completed") } else { finishSchedule(id, status: "canceled") }
    case .todo:
      guard let id = Int(job.id.dropFirst("todo-".count)) else { return }
      if primary { finishTodo(id, status: "completed") } else { finishTodo(id, status: "canceled") }
    case .speakBack: if !primary { dismissSpeakBack() }
    }
  }

  func refreshMicrophones() {
    micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    microphones = AudioIO.availableInputs()
  }

  func requestMicrophoneAccess() {
    guard !previewCanvas else { return }
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .denied || status == .restricted {
      let urls = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
      ]
      for raw in urls {
        guard let url = URL(string: raw) else { continue }
        if NSWorkspace.shared.open(url) { return }
      }
      return
    }
    audio.requestMic { [weak self] ok in
      self?.micGranted = ok
      self?.refreshMicrophones()
    }
  }

  func setMcpEnabled(_ name: String, _ enabled: Bool) {
    guard let idx = mcpServers.firstIndex(where: { $0.name == name }) else { return }
    mcpServers[idx].enabled = enabled
    persistMcpRegistry()
  }

  func talkPressed() {
    if handsFree {
      finishUtterance()
      return
    }
    if !holding { pttDown(explicit: true) }
  }

  func talkReleased() {
    talkPointerDown = false
    // The key-up that follows a tap arms hands-free inside pttUp. A later
    // key-up must not end that open listen.
    if handsFree { return }
    if holding { pttUp() }
  }

  func toggleTalk() {
    if holding { pttUp() } else { pttDown(explicit: true) }
  }

  /// Starts push-to-talk. Implicit Space only reaches here when the composer is
  /// unfocused and the draft is empty. Pass `explicit: true` for the mic hold,
  /// menu-bar droplet, or configured global hotkey — those may run even when
  /// there is typed text, and they never clear `draft`.
  func pttDown(explicit: Bool = false) {
    guard !previewCanvas else { return }
    guard canSend else { return }
    if !explicit && quietTextMode { return }
    if !explicit && hasDraft { return }
    if phase == .speaking || phase == .thinking {
      sendTurnCancel()
      audio.interruptPlayback()
    }
    guard micGranted else {
      errorText = "Microphone access is off."
      return
    }
    guard !preparingTalk else { return }
    talkPointerDown = true
    if calendarReadyWithoutPrompt {
      publishTurnContext()
      beginListening()
      return
    }
    preparingTalk = true
    let sharing = calendarSharing
    let sessionAllowed = sessionCalendarAllowed
    Task {
      let (context, allowSession) = await CalendarDesk.context(
        sharing: sharing,
        sessionAllowed: sessionAllowed,
        interactive: true
      )
      preparingTalk = false
      if allowSession { sessionCalendarAllowed = true }
      guard canSend, micGranted else { return }
      publishTurnContext(calendar: context)
      if talkPointerDown {
        releaseArmsHandsFree = true
        beginListening()
      } else {
        beginListening(handsFree: true)
      }
    }
  }

  func wakeHeard() {
    guard !previewCanvas, wakeWord, !holding, !preparingTalk, canSend, micGranted else { return }
    wakeTurn = true
    if calendarReadyWithoutPrompt {
      publishTurnContext()
      audio.armWakeGate(true)
      beginListening(handsFree: true)
      if !holding {
        wakeTurn = false
        audio.armWakeGate(false)
        resumeWake()
      }
      return
    }
    preparingTalk = true
    let sharing = calendarSharing
    let sessionAllowed = sessionCalendarAllowed
    Task {
      let (context, allowSession) = await CalendarDesk.context(
        sharing: sharing,
        sessionAllowed: sessionAllowed,
        interactive: true
      )
      preparingTalk = false
      if allowSession { sessionCalendarAllowed = true }
      guard canSend, micGranted, !holding else {
        wakeTurn = false
        resumeWake()
        return
      }
      publishTurnContext(calendar: context)
      audio.armWakeGate(true)
      beginListening(handsFree: true)
      if !holding {
        wakeTurn = false
        audio.armWakeGate(false)
        resumeWake()
      }
    }
  }

  func beginListening(handsFree open: Bool = false) {
    audio.armWakeGate(true)
    do {
      pcmBytes = 0
      handsFree = open
      endpoint.reset()
      expectingReply = false
      typedThisTurn = false
      formingText = ""
      resetSpeechSync()
      resetArthurReplyKey()
      beginHearing()
      try audio.startCapture()
      turnModality = .utterance
      holding = true
      inputLevel = 0.12
      pttStarted = Date()
      become(.listening)
      setWork(.none)
      errorText = ""
      lastSurface = .desk
    } catch {
      audio.armWakeGate(false)
      wakeTurn = false
      clearHearing()
      errorText = error.localizedDescription
    }
  }

  func pttUp() {
    talkPointerDown = false
    guard holding else { return }
    if releaseArmsHandsFree {
      releaseArmsHandsFree = false
      handsFree = true
      return
    }
    let elapsed = Date().timeIntervalSince(pttStarted ?? Date())
    if handsFree {
      finishUtterance()
      return
    }
    // A short press starts hands-free listening. Holding through the
    // threshold keeps the existing release-to-send path.
    if elapsed < 0.28 {
      handsFree = true
      return
    }
    finishUtterance()
  }

  func finishUtterance() {
    guard holding else { return }
    let wasHandsFree = handsFree
    holding = false
    handsFree = false
    pttFromKeyboard = false
    inputLevel = 0
    audio.stopCapture()
    audio.armWakeGate(false)
    endpoint.reset()
    let elapsed = Date().timeIntervalSince(pttStarted ?? Date())
    pttStarted = nil
    if audio.capturePeak < 0.001 {
      if wakeTurn { noteFalseWake() }
      client.sendCancel()
      clearHearing()
      become(client.isConnected ? .idle : .disconnected)
      errorText = "I didn't hear the \(audio.activeDeviceName)."
      return
    }
    let tooShort = wasHandsFree ? pcmBytes < 8000 : (elapsed < 0.35 || pcmBytes < 8000)
    if tooShort {
      if wakeTurn { noteFalseWake() }
      client.sendCancel()
      clearHearing()
      become(client.isConnected ? .idle : .disconnected)
      errorText = wasHandsFree ? "Too short." : "Too short — hold a little longer."
      return
    }
    wakeTurn = false
    if awaitDeskPrep(retry: { [weak self] in self?.sendEndedUtterance() }) { return }
    sendEndedUtterance()
  }

  func sendEndedUtterance() {
    let refresh = stagedToken != sentToken
    if refresh { publishTurnContext() }
    expectingReply = true
    setWork(.findingWords)
    become(.thinking)
    // Repeat a staged shot on the end frame so the utterance still has the
    // pixels if the earlier context frame left before the grab finished.
    // An Ask-calendar turn already published its agenda; leave that frame
    // in place when it already includes this shot.
    if stagedShot != nil, calendarSharing != .ask || refresh {
      client.sendEnd(context: turnContext(calendar: immediateCalendarContext()))
    } else {
      client.sendEnd()
    }
    consumeIfSent()
  }

  /// The server already started the turn from trailing silence. Stop the mic
  /// without sending a second end.
  func stopCaptureForServer() {
    holding = false
    handsFree = false
    pttFromKeyboard = false
    inputLevel = 0
    audio.stopCapture()
    audio.armWakeGate(false)
    endpoint.reset()
    pttStarted = nil
    if !expectingReply {
      expectingReply = true
      setWork(.findingWords)
      if phase == .listening { become(.thinking) }
    }
  }

  func sendDraft() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if phase == .disconnected || phase == .connecting {
      errorText = "Arthur is offline — your message was not sent. Reconnect, then send again."
      return
    }
    if phase == .speaking || phase == .thinking {
      sendTurnCancel()
      audio.interruptPlayback()
    }
    guard canSend else { return }
    guard !preparingTalk else { return }
    if awaitDeskPrep(retry: { [weak self] in self?.sendDraft() }) { return }
    if calendarReadyWithoutPrompt {
      commitDraft(text, context: immediateCalendarContext())
      return
    }
    preparingTalk = true
    let sharing = calendarSharing
    let sessionAllowed = sessionCalendarAllowed
    Task {
      let (context, allowSession) = await CalendarDesk.context(
        sharing: sharing,
        sessionAllowed: sessionAllowed,
        interactive: true
      )
      preparingTalk = false
      if allowSession { sessionCalendarAllowed = true }
      commitDraft(text, context: context)
    }
  }

  func commitDraft(_ text: String, context: DeskContext) {
    guard canSend else {
      if errorText.isEmpty { errorText = "Arthur can't send right now — check the connection in Activity." }
      return
    }
    let context = turnContext(calendar: context)
    sentToken = stagedToken
    turnModality = .text
    youSaid = text
    appendDiscussion(fromYou: true, text: text)
    if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
      draft = ""
    }
    formingText = ""
    resetSpeechSync()
    resetArthurReplyKey()
    clearHearing()
    typedThisTurn = true
    expectingReply = true
    setWork(.findingWords)
    become(.thinking)
    lastSurface = .desk
    client.sendText(text, context: context)
    consumeIfSent()
  }

  /// Send a line from the droplet without discarding a draft sitting in the window.
  func sendTypedLine(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let preserved = draft
    draft = trimmed
    sendDraft()
    if draft.isEmpty {
      if !preserved.isEmpty, preserved != trimmed {
        draft = preserved
      }
    } else {
      draft = preserved
    }
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
    sendTurnCancel()
    audio.interruptPlayback()
    expectingReply = false
    typedThisTurn = false
    formingText = ""
    resetSpeechSync()
    pendingSurfaces.removeAll()
    resetArthurReplyKey()
    clearHearing()
    setWork(.none)
    become(client.isConnected ? .idle : .disconnected)
    flushTranscriptSave()
  }

  func sendTurnCancel() {
    client.sendCancel(
      turnId: turnId,
      host: config.host,
      httpPort: config.httpPort,
      token: config.deviceToken,
      deviceId: config.deviceId
    )
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

  /// Glanceable session copy, shown in Activity.
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

  func beginHearing() {
    pendingSpeaker = ""
    hearingLineId = UUID()
    hearingText = "…"
  }

  func clearHearing() {
    hearingText = ""
  }
}
