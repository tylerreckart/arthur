import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
  func start() {
    guard !started else { return }
    started = true
    installKeys()
    refreshMicrophones()
    audio.requestMic { [weak self] ok in
      self?.micGranted = ok
      if !ok { self?.errorText = "Microphone access is off — type instead, or enable it in System Settings." }
      self?.resumeWake()
    }
    do { try audio.startPlayback() } catch {
      errorText = error.localizedDescription
    }
    connect()
    healthTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pollHealth() }
    }
    pollHealth()
    watchFocus()
    applyWake()
    startLocalCalendar()
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
    localMcp?.stop()
    localMcp = nil
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
    guard !previewCanvas else { return }
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
      persistLibrary(deviceId: transcriptDeviceId)
      transcriptDeviceId = config.deviceId
      loadLibrary(deviceId: transcriptDeviceId)
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

  func publishCalendarPolicy() {
    CalendarDesk.configure(sharing: calendarSharing, sessionAllowed: sessionCalendarAllowed)
  }

  var calendarReadyWithoutPrompt: Bool {
    switch calendarSharing {
    case .off:
      return true
    case .always:
      return CalendarDesk.hasAccess
    case .session:
      return sessionCalendarAllowed && CalendarDesk.hasAccess
    case .ask:
      return false
    }
  }

  func immediateCalendarContext() -> DeskContext {
    switch calendarSharing {
    case .off:
      return DeskContext.calendar(CalendarAgenda.unavailable(
        "The user turned calendar sharing off in Arthur's settings."
      ))
    case .always, .session:
      return CalendarDesk.agendaNow()
    case .ask:
      return DeskContext.calendar(CalendarAgenda.unavailable(
        "The user has not shared the calendar for this turn."
      ))
    }
  }

  func publishTurnContext() {
    publishTurnContext(calendar: immediateCalendarContext())
  }

  func publishTurnContext(calendar: DeskContext) {
    client.sendContext(turnContext(calendar: calendar))
    sentToken = stagedToken
  }

  func turnContext(calendar: DeskContext) -> DeskContext {
    var context = calendar
    if seesFront {
      context.sources.append(contentsOf: FrontDesk.sources())
    }
    for file in stagedFiles {
      if let source = file.source { context.sources.append(source) }
      if let image = file.image { context.images.append(image) }
    }
    if let stagedShot {
      // Ahead of dropped files, so the two-image cap cannot discard the shot.
      context.images.insert(stagedShot, at: 0)
      context.sources.append(DeskContext.Source(
        name: "screen",
        text: "A screenshot is attached. They tapped Look. Answer from the image. Do not say you can see the screen live."
      ))
    }
    if calendarSharing != .off, !household.isEmpty,
       let shared = context.sources.first(where: { $0.name == "calendar" }),
       !shared.text.hasPrefix("unavailable") {
      context.sources.append(contentsOf: CalendarDesk.personalSources(people: household))
    }
    if context.images.count > 2 {
      context.images = Array(context.images.prefix(2))
    }
    return context
  }

  func awaitDeskPrep(retry: @escaping () -> Void) -> Bool {
    guard lookInFlight || fileLoads > 0 else { return false }
    deferredSend = retry
    return true
  }

  func resumeDeferred() {
    guard !lookInFlight, fileLoads == 0, let send = deferredSend else { return }
    deferredSend = nil
    send()
  }

  func consumeIfSent() {
    guard !lookInFlight, fileLoads == 0, stagedToken > 0, sentToken == stagedToken else { return }
    stagedFiles = []
    stagedShot = nil
    screenStaged = false
    stagedToken = 0
    sentToken = 0
    LookChrome.hide()
  }
}
