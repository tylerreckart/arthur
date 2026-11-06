import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

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

/// Voice versus typed. The droplet only grows a listening tail for utterance.
enum TurnModality: Equatable {
  case none
  case utterance
  case text
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
  /// The part of Arthur's reply the voice has reached. Empty until audio starts.
  var spokenReveal = ""
  /// True from the first words of a reply until those words have been spoken.
  var pacingReply = false
  /// Stable id for the in-flight Arthur bubble so `.forming` → `.said`
  /// does not remount the cluster (avoids a jump / flash).
  var formingLineId = UUID()
  /// Shared by every Arthur `said` in the current turn (or live speak-back)
  /// so later `accept` ids do not split one reply into two bubbles.
  private var arthurReplyKey = ""
  var liveArthurTurnId: String { arthurReplyKey }
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
  /// The droplet card's field is first responder. Space must type.
  var deskFieldFocused = false
  var turnModality: TurnModality = .none
  var conversationId: Int64 = 0
  var conversations: [DeskConversation] = []
  var activeConversationId = UUID()
  /// Sidebar column. The desk starts on the transcript; the toolbar opens this.
  var sidebarOpen = false
  var turnId = ""
  var micGranted = false
  var settingsOpen = false
  var holding = false
  /// Tap-to-talk. Capture stays open until trailing silence or the server
  /// accepts the utterance. Hold-to-talk still ends on release.
  var handsFree = false
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
  /// global chord, the mic hold, and the menu-bar droplet still talk.
  var quietTextMode = false {
    didSet {
      guard oldValue != quietTextMode else { return }
      guard !previewCanvas else { return }
      ConfigStore.saveQuietTextMode(quietTextMode)
    }
  }
  /// Off until the user opts in. The session choice lives only in memory.
  var calendarSharing: CalendarSharing = .off {
    didSet {
      guard oldValue != calendarSharing else { return }
      guard !previewCanvas else { return }
      ConfigStore.saveCalendarSharing(calendarSharing)
      publishCalendarPolicy()
    }
  }
  /// Frontmost app, window title, and selection. Off until the user opts in.
  var seesFront = false {
    didSet {
      guard oldValue != seesFront else { return }
      guard !previewCanvas else { return }
      ConfigStore.saveSeesFront(seesFront)
      if seesFront, presenceReady { FrontDesk.prompt() }
    }
  }
  /// The Look button. Off until the user opts in. A capture still waits for the tap.
  var screenLook = false {
    didSet {
      guard oldValue != screenLook else { return }
      guard !previewCanvas else { return }
      ConfigStore.saveScreenLook(screenLook)
      if screenLook, presenceReady {
        ScreenLook.requestAccess()
      } else if !screenLook {
        clearScreen()
      }
    }
  }
  /// Hands-free "Arthur". Off until the user opts in. Hardware mute keeps it quiet.
  var wakeWord = false {
    didSet {
      guard oldValue != wakeWord else { return }
      guard !previewCanvas else { return }
      ConfigStore.saveWakeWord(wakeWord)
      if presenceReady { applyWake() }
    }
  }
  /// True while Wake word is on and the input device is hardware-muted.
  var wakeMuted = false
  var household: [HouseholdRoster.Person] = []
  var teachName = ""
  var teachCalendar = ""
  var teaching = false
  var teachPhrase = 0
  var householdStatus = ""
  private var pendingSpeaker = ""
  /// Reminders list, Finder, Mail drafts, and opening a page or app.
  var macTools = false {
    didSet {
      guard oldValue != macTools else { return }
      guard !previewCanvas else { return }
      ConfigStore.saveMacTools(macTools)
      MacDesk.configure(toolsOn: macTools)
    }
  }
  var stagedFiles: [StagedFile] = []
  var screenStaged = false
  var deskCue: String {
    if screenStaged { return "Looking at your screen" }
    if stagedFiles.count == 1 { return "A file is attached" }
    if stagedFiles.count > 1 { return "\(stagedFiles.count) files are attached" }
    return ""
  }
  private var stagedShot: DeskContext.Image?
  private var stagedToken = 0
  private var sentToken = 0
  private var lookInFlight = false
  private var fileLoads = 0
  private var deferredSend: (() -> Void)?
  private var presenceReady = false
  /// This listen was opened by the wake word. An empty result counts as a false accept.
  private var wakeTurn = false
  private var pendingWriteId: String?
  private var pendingWritePhase = ""
  var pendingWriteLabel: String {
    switch pendingWritePhase {
    case "approve": return "Approve"
    case "undo": return "Undo"
    default: return ""
    }
  }
  /// Empty follows the system default microphone.
  var microphoneID = "" {
    didSet {
      guard oldValue != microphoneID else { return }
      ConfigStore.saveMicrophoneID(microphoneID)
      audio.preferredDeviceID = microphoneID
    }
  }
  var microphones: [MicInput] = []
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
  private var endpoint = UtteranceEndpoint()
  private var expectingReply = false
  private var typedThisTurn = false
  private var pendingSpeech: String?
  private var speechSpans: [SpeechSpan] = []
  private var speechTick: Timer?
  private var started = false
  private var transcriptDeviceId = ""
  private var pttFromKeyboard = false
  private var speakBackDismiss: DispatchWorkItem?
  private var activeObserver: NSObjectProtocol?
  private var lastPolledTurnId = ""
  /// Surfaces that arrived before the matching Arthur `said` line.
  private var pendingSurfaces: [(turnId: String, surface: ChatSurface)] = []
  /// Set only by `previewCanvas`. Skips notebook, draft, and quiet-mode writes
  /// so the Xcode canvas cannot clobber the running desk.
  private var previewCanvas = false
  private var sessionCalendarAllowed = false {
    didSet {
      guard oldValue != sessionCalendarAllowed else { return }
      publishCalendarPolicy()
    }
  }
  /// A calendar confirm dialog is up. A second press must not start another one.
  private var preparingTalk = false
  /// True from the press that opened a confirm dialog until that press releases.
  private var talkPointerDown = false
  /// The release after a dialog arms hands-free instead of sending a truncated turn.
  private var releaseArmsHandsFree = false
  private var localMcp: LocalMcpServer?

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
    calendarSharing = ConfigStore.loadCalendarSharing()
    seesFront = ConfigStore.loadSeesFront()
    screenLook = ConfigStore.loadScreenLook()
    macTools = ConfigStore.loadMacTools()
    wakeWord = ConfigStore.loadWakeWord()
    presenceReady = true
    microphoneID = ConfigStore.loadMicrophoneID()
    audio.preferredDeviceID = microphoneID
    transcriptDeviceId = config.deviceId
    loadLibrary(deviceId: transcriptDeviceId)
    draft = ConfigStore.loadDraft()
    loadMcpRegistry()
    publishCalendarPolicy()
    loadHousehold()
    refreshSessionContinuity(initial: true)
    client.onEvent = { [weak self] event in
      // Already on the main queue. A MainActor task does not run during
      // scroll tracking, which froze the live reply after the first letters.
      MainActor.assumeIsolated {
        self?.handle(event)
      }
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
        if self.handsFree, self.endpoint.push(data) {
          self.finishUtterance()
        }
      }
    }
  }

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

  private func publishCalendarPolicy() {
    CalendarDesk.configure(sharing: calendarSharing, sessionAllowed: sessionCalendarAllowed)
  }

  private var calendarReadyWithoutPrompt: Bool {
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

  private func immediateCalendarContext() -> DeskContext {
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

  private func publishTurnContext() {
    publishTurnContext(calendar: immediateCalendarContext())
  }

  private func publishTurnContext(calendar: DeskContext) {
    client.sendContext(turnContext(calendar: calendar))
    sentToken = stagedToken
  }

  private func turnContext(calendar: DeskContext) -> DeskContext {
    var context = calendar
    if seesFront {
      context.sources.append(contentsOf: FrontDesk.sources())
    }
    for file in stagedFiles {
      if let source = file.source { context.sources.append(source) }
      if let image = file.image { context.images.append(image) }
    }
    if let stagedShot {
      context.images.append(stagedShot)
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

  private func awaitDeskPrep(retry: @escaping () -> Void) -> Bool {
    guard lookInFlight || fileLoads > 0 else { return false }
    deferredSend = retry
    return true
  }

  private func resumeDeferred() {
    guard !lookInFlight, fileLoads == 0, let send = deferredSend else { return }
    deferredSend = nil
    send()
  }

  private func consumeIfSent() {
    guard !lookInFlight, fileLoads == 0, stagedToken > 0, sentToken == stagedToken else { return }
    stagedFiles = []
    stagedShot = nil
    screenStaged = false
    stagedToken = 0
    sentToken = 0
    LookChrome.hide()
  }

  func lookAtScreen() {
    guard screenLook, !previewCanvas, !lookInFlight else { return }
    lookInFlight = true
    screenStaged = true
    LookChrome.show()
    Task {
      let image = await ScreenLook.capture()
      lookInFlight = false
      if let image {
        stagedShot = image
        stagedToken += 1
        if holding { publishTurnContext() }
      } else if stagedShot == nil {
        screenStaged = false
        LookChrome.hide()
        errorText = "I couldn't see the screen."
      }
      resumeDeferred()
    }
  }

  func clearScreen() {
    guard screenStaged || stagedShot != nil else { return }
    stagedShot = nil
    screenStaged = false
    LookChrome.hide()
    stagedToken += 1
    if holding { publishTurnContext() }
  }

  func removeStaged(_ id: UUID) {
    guard stagedFiles.contains(where: { $0.id == id }) else { return }
    stagedFiles.removeAll { $0.id == id }
    stagedToken += 1
    if holding { publishTurnContext() }
  }

  func takeDroppedProviders(_ providers: [NSItemProvider]) {
    let fileProviders = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
    let imageProviders = fileProviders.isEmpty
      ? providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
      : []
    guard !fileProviders.isEmpty || !imageProviders.isEmpty else { return }
    fileLoads += 1
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    var images: [NSImage] = []
    for provider in fileProviders {
      group.enter()
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
        defer { group.leave() }
        let url: URL?
        if let item = item as? URL {
          url = item
        } else if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else {
          url = nil
        }
        guard let url else { return }
        lock.lock()
        urls.append(url)
        lock.unlock()
      }
    }
    for provider in imageProviders {
      group.enter()
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        defer { group.leave() }
        guard let data, let image = NSImage(data: data) else { return }
        lock.lock()
        images.append(image)
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      let loadedURLs = urls
      let loadedImages = images
      Task { @MainActor in
        guard let self else { return }
        self.fileLoads = max(0, self.fileLoads - 1)
        var staged: [StagedFile] = []
        for url in loadedURLs.prefix(3) {
          if let file = FileInbox.load(url: url) { staged.append(file) }
        }
        if staged.isEmpty {
          for image in loadedImages.prefix(2) {
            if let file = FileInbox.loadImage(image, label: "Pasted image") { staged.append(file) }
          }
        }
        self.addStaged(staged)
      }
    }
  }

  private func addStaged(_ files: [StagedFile]) {
    for file in files {
      if stagedFiles.count >= 3 { break }
      let images = stagedFiles.compactMap(\.image).count + (stagedShot == nil ? 0 : 1)
      if file.image != nil, images >= 2 { continue }
      stagedFiles.append(file)
    }
    if !files.isEmpty {
      stagedToken += 1
      if holding { publishTurnContext() }
    }
    resumeDeferred()
  }

  private func startLocalCalendar() {
    guard !previewCanvas else { return }
    publishCalendarPolicy()
    MacDesk.configure(toolsOn: macTools)
    CalendarDesk.onProposal = { [weak self] proposal in
      self?.presentWrite(proposal)
    }
    MacDesk.onProposal = { [weak self] card in
      self?.presentMac(card)
    }
    let token = LocalMcpToken.load()
    let server = LocalMcpServer(
      token: token,
      tools: LocalToolHost(
        act: { tool, args in
          switch tool {
          case "finder.reveal", "mail.draft", "open.url", "open.app":
            return MacDesk.propose(tool: tool, args: args)
          default:
            return CalendarDesk.propose(tool: tool, args: args)
          }
        },
        remindersText: { MacDesk.remindersText() },
        finderText: { query in MacDesk.finderText(query: query) },
        calendarText: { day in CalendarDesk.toolText(day: day) }
      )
    )
    server.start { [weak self] port in
      Task { @MainActor in
        self?.registerArthurCalendar(port: port, token: token)
      }
    }
    localMcp = server
  }

  private func registerArthurCalendar(port: UInt16, token: String) {
    let server = McpServer.hosted(
      name: "arthur",
      url: "http://127.0.0.1:\(port)/mcp",
      headers: ["Authorization": "Bearer \(token)"]
    )
    if let existing = mcpServers.first(where: { $0.name == server.name }), existing == server {
      return
    }
    upsertMcp(server)
  }

  func resolveSurfaceAction(_ action: SurfaceAction) {
    switch action.kind {
    case "approve":
      resolveWrite(id: action.id, granted: true, via: "card")
    case "dismiss":
      resolveWrite(id: action.id, granted: false, via: "card")
    case "undo":
      resolveWrite(id: action.id, granted: true, via: "undo")
    case "edit":
      if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        draft = action.label
      }
      composerFocusToken += 1
    default:
      break
    }
  }

  func resolvePendingWrite() {
    guard let id = pendingWriteId else { return }
    if pendingWritePhase == "undo" {
      resolveWrite(id: id, granted: true, via: "undo")
    } else {
      resolveWrite(id: id, granted: true, via: "card")
    }
  }

  private func resolveWrite(id: String, granted: Bool, via: String) {
    if let proposal = CalendarDesk.resolve(id: id, granted: granted, via: via) {
      applyWrite(proposal)
      return
    }
    presentMac(MacDesk.resolve(id: id, granted: granted, via: via))
  }

  private func applyWrite(_ proposal: CalendarDesk.WriteProposal?) {
    guard let proposal else { return }
    presentWrite(proposal)
  }

  private func presentMac(_ card: MacDesk.WriteCard?) {
    guard let card else { return }
    pendingWritePhase = card.phase
    pendingWriteId = card.phase == "approve" || card.phase == "undo" ? card.id : nil
    showWrite(id: card.id, title: card.title, summary: card.summary, phase: card.phase)
  }

  private func presentWrite(_ proposal: CalendarDesk.WriteProposal) {
    pendingWritePhase = proposal.phase
    pendingWriteId = proposal.phase == "approve" || proposal.phase == "undo" ? proposal.id : nil
    showWrite(id: proposal.id, title: proposal.title, summary: proposal.summary, phase: proposal.phase)
  }

  private func showWrite(id: String, title: String, summary: String, phase: String) {
    let actions: [SurfaceAction]
    switch phase {
    case "approve":
      actions = [
        SurfaceAction(id: id, label: "Approve", kind: "approve"),
        SurfaceAction(id: id, label: "Not now", kind: "dismiss"),
      ]
      client.sendArmApproval(id: id)
    case "undo":
      actions = [SurfaceAction(id: id, label: "Undo", kind: "undo")]
      client.sendClearApproval()
    default:
      actions = []
      client.sendClearApproval()
    }
    let surface = ChatSurface(
      kindRaw: "generic",
      version: 2,
      title: title,
      summary: summary,
      payload: .object(["proposal_id": .string(id)]),
      actions: actions
    )
    upsertProposalSurface(surface, id: id)
  }

  private func upsertProposalSurface(_ surface: ChatSurface, id: String) {
    for index in discussion.indices {
      var line = discussion[index]
      guard let slot = line.surfaces.firstIndex(where: {
        $0.payload.object["proposal_id"]?.displayString == id
      }) else { continue }
      var next = surface
      next.id = line.surfaces[slot].id
      line.surfaces[slot] = next
      discussion[index] = line
      persistTranscript()
      return
    }
    attachSurface(surface, turnId: turnId)
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

  private func wakeHeard() {
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

  private func beginListening(handsFree open: Bool = false) {
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

  private func sendEndedUtterance() {
    if stagedToken != sentToken { publishTurnContext() }
    expectingReply = true
    setWork(.findingWords)
    become(.thinking)
    client.sendEnd()
    consumeIfSent()
  }

  /// The server already started the turn from trailing silence. Stop the mic
  /// without sending a second end.
  private func stopCaptureForServer() {
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

  private func commitDraft(_ text: String, context: DeskContext) {
    guard canSend else { return }
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
  }

  private func sendTurnCancel() {
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
    pendingSpeaker = ""
    hearingLineId = UUID()
    hearingText = "…"
  }

  private func clearHearing() {
    hearingText = ""
  }

  /// Voice (and late `turn`) path. Typed sends already appended in `sendDraft`.
  /// `heard` lands first and `turn` repeats the same line after the reply, so
  /// a second append used to place the question under Arthur's answer.
  private func commitVoiceTranscript(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    youSaid = trimmed
    if typedThisTurn {
      clearHearing()
      return
    }
    if let idx = discussion.firstIndex(where: { $0.id == hearingLineId }) {
      if discussion[idx].text != trimmed {
        let old = discussion[idx]
        discussion[idx] = DiscussionLine(
          fromYou: true,
          text: trimmed,
          id: old.id,
          turnId: old.turnId,
          surfaces: old.surfaces,
          speakerName: old.speakerName.isEmpty ? pendingSpeaker : old.speakerName
        )
        persistTranscript()
      }
      clearHearing()
      return
    }
    if discussion.contains(where: { $0.fromYou && $0.text == trimmed }) {
      clearHearing()
      return
    }
    let line = DiscussionLine(
      fromYou: true, text: trimmed, id: hearingLineId, speakerName: pendingSpeaker)
    if let arthurIdx = discussion.indices.last, !discussion[arthurIdx].fromYou, arthurTurnIsLive {
      discussion.insert(line, at: arthurIdx)
      if discussion.count > DiscussionLimits.visibleLineCap {
        discussion.removeFirst(discussion.count - DiscussionLimits.visibleLineCap)
      }
      persistTranscript()
    } else {
      appendDiscussion(fromYou: true, text: trimmed, id: hearingLineId, speakerName: pendingSpeaker)
    }
    clearHearing()
  }

  private func resetArthurReplyKey() {
    arthurReplyKey = ""
  }

  /// Key shared by every Arthur `said` in the in-flight turn (or speak-back).
  private func bindArthurReplyKey() -> String {
    if let notice = speakBack, notice.live {
      let key = notice.runId.isEmpty ? "speak:\(notice.id.uuidString)" : "speak:\(notice.runId)"
      arthurReplyKey = key
      return key
    }
    if arthurReplyKey.isEmpty {
      arthurReplyKey = !turnId.isEmpty ? "turn:\(turnId)" : "forming:\(formingLineId.uuidString)"
    }
    return arthurReplyKey
  }

  private var arthurTurnIsLive: Bool {
    expectingReply || phase == .speaking || phase == .thinking || (speakBack?.live == true)
  }

  private func appendDiscussion(
    fromYou: Bool,
    text: String,
    id: UUID? = nil,
    turnId: String? = nil,
    speakerName: String = ""
  ) {
    // Intercom marks sentences that follow a blank line with a leading
    // "\n\n". Trim spaces/tabs first so the marker survives, then separate
    // it — a new paragraph must never be stitched onto the previous one.
    let spaceTrimmed = text.trimmingCharacters(in: .whitespaces)
    let paragraphBreak = spaceTrimmed.hasPrefix("\n\n")
    let trimmed = spaceTrimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let last = discussion.last, last.fromYou == fromYou, last.text == trimmed { return }

    if !fromYou, let idx = discussion.indices.last, !discussion[idx].fromYou {
      let last = discussion[idx]
      let turnKey = turnId ?? bindArthurReplyKey()
      let sameTurn = !last.turnId.isEmpty && last.turnId == turnKey
      let liveOrphan = last.turnId.isEmpty && arthurTurnIsLive
      if sameTurn || liveOrphan {
        // Same turn always shares one bubble; the paragraph break decides
        // whether the text joins the running paragraph or starts a new one.
        if ArthurProseJoin.alreadySpoken(last.text, trimmed) { return }
        let joined = paragraphBreak
          ? last.text + "\n\n" + trimmed
          : ArthurProseJoin.join(last.text, trimmed)
        discussion[idx] = DiscussionLine(
          fromYou: false,
          text: joined,
          id: last.id,
          turnId: last.turnId.isEmpty ? turnKey : last.turnId,
          surfaces: last.surfaces
        )
        persistTranscript()
        return
      }
      if !paragraphBreak, ArthurProseJoin.shouldStitch(last.text, trimmed) {
        if ArthurProseJoin.alreadySpoken(last.text, trimmed) { return }
        let joined = ArthurProseJoin.join(last.text, trimmed)
        discussion[idx] = DiscussionLine(
          fromYou: false,
          text: joined,
          id: last.id,
          turnId: last.turnId.isEmpty ? turnKey : last.turnId,
          surfaces: last.surfaces
        )
        persistTranscript()
        return
      }
    }

    discussion.append(
      DiscussionLine(
        fromYou: fromYou,
        text: trimmed,
        id: id ?? UUID(),
        turnId: fromYou ? "" : (turnId ?? bindArthurReplyKey()),
        speakerName: fromYou ? speakerName : ""
      )
    )
    if discussion.count > DiscussionLimits.visibleLineCap {
      discussion.removeFirst(discussion.count - DiscussionLimits.visibleLineCap)
    }
    persistTranscript()
  }

  private func replyKeys(for rawTurnId: String) -> [String] {
    var keys: [String] = []
    func add(_ key: String) {
      guard !key.isEmpty, !keys.contains(key) else { return }
      keys.append(key)
    }
    add(rawTurnId)
    if !rawTurnId.isEmpty { add("turn:\(rawTurnId)") }
    add(turnId)
    if !turnId.isEmpty { add("turn:\(turnId)") }
    add(arthurReplyKey)
    return keys
  }

  private func attachSurface(_ surface: ChatSurface, turnId rawTurnId: String) {
    let keys = replyKeys(for: rawTurnId)
    if let idx = discussion.lastIndex(where: { line in
      !line.fromYou && keys.contains(line.turnId)
    }) {
      applySurface(surface, at: idx, turnKey: keys.first { $0.hasPrefix("turn:") } ?? keys.first)
      return
    }
    if arthurTurnIsLive, let idx = discussion.indices.last, !discussion[idx].fromYou {
      applySurface(surface, at: idx, turnKey: keys.first { $0.hasPrefix("turn:") } ?? keys.first)
      return
    }
    pendingSurfaces.append((rawTurnId, surface))
  }

  private func applySurface(_ surface: ChatSurface, at idx: Int, turnKey: String?) {
    var line = discussion[idx]
    if !line.surfaces.contains(where: { $0.isDuplicate(of: surface) }) {
      line.surfaces.append(surface)
    }
    if line.turnId.isEmpty, let turnKey, !turnKey.isEmpty {
      line.turnId = turnKey
    }
    discussion[idx] = line
    persistTranscript()
  }

  private func flushPendingSurfaces() {
    guard !pendingSurfaces.isEmpty else { return }
    let queued = pendingSurfaces
    pendingSurfaces.removeAll()
    for item in queued {
      attachSurface(item.surface, turnId: item.turnId)
    }
  }

  private func persistTranscript(deviceId: String? = nil) {
    guard !previewCanvas else { return }
    let device = deviceId ?? transcriptDeviceId
    captureActiveLines()
    ConfigStore.saveTranscript(discussion, deviceId: device)
    persistLibrary(deviceId: device)
  }

  /// A turn is on the wire or the mic is open. Switching threads would orphan it.
  var canStartConversation: Bool {
    !holding && phase != .listening && phase != .thinking && phase != .speaking
  }

  var conversationIsEmpty: Bool {
    discussion.isEmpty && formingText.isEmpty && hearingText.isEmpty
  }

  var listedConversations: [DeskConversation] {
    conversations.sorted { $0.updatedAt > $1.updatedAt }
  }

  func newConversation() {
    guard canStartConversation else { return }
    captureActiveLines()
    guard !conversationIsEmpty else { return }
    conversations.removeAll { $0.id != activeConversationId && $0.lines.isEmpty }
    let item = DeskConversation.empty(needsFreshServer: true)
    conversations.insert(item, at: 0)
    activeConversationId = item.id
    discussion = []
    formingText = ""
    hearingText = ""
    youSaid = ""
    draft = ""
    conversationId = 0
    client.sendNewConversation(bind: item.id.uuidString)
    persistTranscript()
  }

  func openConversation(_ id: UUID) {
    guard id != activeConversationId else { return }
    guard canStartConversation else { return }
    guard conversations.contains(where: { $0.id == id }) else { return }
    captureActiveLines()
    let previous = activeConversationId
    if let previousItem = conversations.first(where: { $0.id == previous }),
       previousItem.lines.isEmpty {
      conversations.removeAll { $0.id == previous }
    }
    guard let item = conversations.first(where: { $0.id == id }) else { return }
    activeConversationId = id
    discussion = item.lines
    formingText = ""
    hearingText = ""
    youSaid = ""
    conversationId = item.serverConversationId
    if item.needsFreshServer {
      client.sendNewConversation(bind: id.uuidString)
    } else if item.serverConversationId > 0 {
      client.sendResumeConversation(item.serverConversationId, bind: id.uuidString)
    }
    persistTranscript()
  }

  private func persistDraft() {
    guard !previewCanvas else { return }
    ConfigStore.saveDraft(draft)
  }

  private struct SpeechSpan {
    var text: String
    var startFrame: AVAudioFramePosition
    var endFrame: AVAudioFramePosition?
    var estimatedFrames: AVAudioFramePosition
  }

  /// ~2 words a second, a little slower than Kokoro, so text doesn't finish
  /// before the voice. Once the sentence's audio is fully queued the real
  /// duration takes over.
  private func estimatedFrames(for text: String) -> AVAudioFramePosition {
    let words = max(1, text.split { $0.isWhitespace }.count)
    return AVAudioFramePosition(Double(words) / 2.0 * AudioIO.sampleRate)
  }

  private func resetSpeechSync() {
    pendingSpeech = nil
    speechSpans.removeAll()
    spokenReveal = ""
    pacingReply = false
    speechTick?.invalidate()
    speechTick = nil
  }

  private func startSpeechTick() {
    guard speechTick == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshSpokenReveal()
      }
    }
    speechTick = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func sealOpenSpan() {
    guard !speechSpans.isEmpty, speechSpans[speechSpans.count - 1].endFrame == nil else { return }
    let end = max(audio.scheduledFrames, speechSpans[speechSpans.count - 1].startFrame + 1)
    speechSpans[speechSpans.count - 1].endFrame = end
  }

  private func beginSpeechIfNeeded() {
    guard let text = pendingSpeech else { return }
    pendingSpeech = nil
    let start = audio.scheduledFrames
    speechSpans.append(SpeechSpan(
      text: text,
      startFrame: start,
      endFrame: nil,
      estimatedFrames: estimatedFrames(for: text)
    ))
    pacingReply = true
    startSpeechTick()
  }

  private func finishSpeechPacing() {
    if !speechSpans.isEmpty {
      spokenReveal = speechSpans.map(\.text).joined(separator: " ")
    }
    pacingReply = false
    speechTick?.invalidate()
    speechTick = nil
    pendingSpeech = nil
    speechSpans.removeAll()
  }

  private func reveal(_ text: String, fraction: Double) -> String {
    if fraction >= 0.995 { return text }
    let count = Int((fraction * Double(text.count)).rounded(.down))
    guard count > 0 else { return "" }
    let end = text.index(text.startIndex, offsetBy: min(count, text.count))
    let head = text[..<end]
    if let space = head.lastIndex(of: " ") {
      return String(head[..<space])
    }
    return String(head)
  }

  private func refreshSpokenReveal() {
    let played = audio.playedFrames()
    var parts: [String] = []
    for span in speechSpans {
      let duration = span.endFrame.map { max(Int64(1), $0 - span.startFrame) } ?? span.estimatedFrames
      let elapsed = played - span.startFrame
      if elapsed <= 0 { break }
      let fraction = min(1, Double(elapsed) / Double(max(duration, 1)))
      let piece = reveal(span.text, fraction: fraction)
      if piece.isEmpty { break }
      parts.append(piece)
      if piece.count < span.text.count { break }
    }
    let next = parts.joined(separator: " ")
    if next != spokenReveal { spokenReveal = next }
    let sealed = speechSpans.allSatisfy { $0.endFrame != nil }
    let caughtUp = sealed && pendingSpeech == nil && !audio.playbackPending
      && spokenReveal == speechSpans.map(\.text).joined(separator: " ")
    if caughtUp, !expectingReply {
      finishSpeechPacing()
      if phase == .speaking {
        become(client.isConnected ? .idle : .disconnected)
      }
    }
  }

  private func handle(_ event: IntercomEvent) {
    switch event {
    case .ready(_, let deviceId):
      reconnectWork?.cancel()
      reconnectWork = nil
      reconnectAttempt = 0
      if !deviceId.isEmpty { socketDeviceId = deviceId }
      become(.idle)
      publishFocus()
      healthOK = true
      healthDetail = "connected"
      errorText = ""
      refreshSessionContinuity(initial: lastPolledTurnId.isEmpty)
      alignServerConversation()
    case .accept(let id):
      turnId = id
      lastSurface = .desk
      if !id.isEmpty { lastPolledTurnId = id }
      if holding { stopCaptureForServer() }
      consumeIfSent()
    case .pcm(let data):
      if expectingReply || phase == .speaking || pacingReply {
        beginSpeechIfNeeded()
        become(.speaking)
        if work != .speaking { setWork(.speaking) }
        audio.playPCM(data)
        ingestSpeakLevel(AudioIO.pcmLevel(data, gain: 2.4))
        refreshSpokenReveal()
      }
    case .speaker(_, let name, let confident):
      let label = HouseholdRoster.indicator(name: name, confident: confident)
      pendingSpeaker = label
      if let idx = discussion.firstIndex(where: { $0.id == hearingLineId }) {
        discussion[idx].speakerName = label
        persistTranscript()
      }
    case .heard(let text, let partial):
      switch HeardLine.interpret(text: text, partial: partial) {
      case .live(let line):
        hearingText = line
      case .commit(let line):
        wakeTurn = false
        commitVoiceTranscript(line)
      case nil:
        break
      }
    case .turn(let eventTurnId, let transcript, let conv, let ok, _):
      guard eventTurnId.isEmpty || eventTurnId == turnId else { return }
      if !transcript.isEmpty {
        commitVoiceTranscript(transcript)
      } else {
        clearHearing()
      }
      typedThisTurn = false
      if conv > 0 { noteServerConversation(conv) }
      if !ok { errorText = "That turn did not finish cleanly." }
    case .conversation(let id, _, let bind):
      noteBoundConversation(id, bind: bind)
    case .done(let ok, let err, let eventTurnId):
      guard eventTurnId.isEmpty || eventTurnId == turnId else { return }
      expectingReply = false
      typedThisTurn = false
      formingText = ""
      flushPendingSurfaces()
      pendingSurfaces.removeAll()
      resetArthurReplyKey()
      clearHearing()
      setWork(.none)
      if !ok, !err.isEmpty { errorText = err }
      sealOpenSpan()
      if audio.playbackPending {
        become(.speaking)
        startSpeechTick()
      } else {
        finishSpeechPacing()
        become(client.isConnected ? .idle : .disconnected)
      }
      if speakBack?.live == true { finishSpeakBack() }
    case .speak(let kind, let runId, let text):
      resetArthurReplyKey()
      expectingReply = true
      become(.speaking)
      setWork(.speaking)
      presentSpeakBack(kind: kind, runId: runId, text: text)
    case .said(let text):
      let id = formingText.isEmpty ? UUID() : formingLineId
      sealOpenSpan()
      if soundOn {
        pendingSpeech = text
        pacingReply = true
        startSpeechTick()
      }
      appendDiscussion(fromYou: false, text: text, id: id)
      flushPendingSurfaces()
      formingText = ""
      if !soundOn {
        become(.speaking)
        setWork(.speaking)
      } else if phase != .speaking {
        become(.thinking)
      }
      if speakBack?.live == true { noteSpeakBackSaid(text) }
    case .surface(let turnId, let surface):
      attachSurface(surface, turnId: turnId)
    case .approval(let id, let granted):
      resolveWrite(id: id, granted: granted, via: "voice")
    case .forming(let text):
      if formingText.isEmpty {
        formingLineId = UUID()
      }
      _ = bindArthurReplyKey()
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
      resetSpeechSync()
      pendingSurfaces.removeAll()
      resetArthurReplyKey()
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
    } else if notice.spokenText != trimmed, !ArthurProseJoin.alreadySpoken(notice.spokenText, trimmed) {
      notice.spokenText = ArthurProseJoin.join(notice.spokenText, trimmed)
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
    if p == .idle {
      resumeWake()
    } else if !holding {
      audio.setWakeWanted(false)
    }
  }

  private func applyWake() {
    audio.onWake = { [weak self] in self?.wakeHeard() }
    resumeWake()
  }

  func loadHousehold() {
    Task { await reloadHousehold() }
  }

  func teachVoice() {
    let name = teachName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !teaching else { return }
    guard phase == .idle, !holding else {
      householdStatus = "Finish the current turn first."
      return
    }
    teaching = true
    teachPhrase = 0
    householdStatus = ""
    let calendar = teachCalendar
    Task { await runTeach(name: name, calendar: calendar) }
  }

  func forgetPerson(_ id: String) {
    Task {
      _ = await householdCall("/v1/household/people/\(id)", method: "DELETE", body: nil)
      await reloadHousehold()
    }
  }

  private func runTeach(name: String, calendar: String) async {
    defer {
      teaching = false
      resumeWake()
    }
    let body: [String: String] = ["name": name, "calendar": calendar]
    guard let payload = try? JSONSerialization.data(withJSONObject: body),
          let (data, code) = await householdCall("/v1/household/people", method: "POST", body: payload),
          code == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["id"] as? String
    else {
      householdStatus = "Could not add that person."
      return
    }
    for index in 0..<HouseholdRoster.phrases.count {
      teachPhrase = index
      let pcm = await recordEnrollment()
      guard let pcm else {
        householdStatus = "The microphone was busy."
        return
      }
      let voice: [String: Any] = [
        "pcm": pcm.base64EncodedString(),
        "sample_rate": Int(AudioIO.sampleRate),
        "phrase": index,
      ]
      guard let voiceBody = try? JSONSerialization.data(withJSONObject: voice),
            let (_, voiceCode) = await householdCall(
              "/v1/household/people/\(id)/voice", method: "POST", body: voiceBody),
            voiceCode == 200
      else {
        householdStatus = "That phrase did not stick. Try again."
        return
      }
    }
    teachName = ""
    teachCalendar = ""
    householdStatus = "\(name) is enrolled."
    await reloadHousehold()
  }

  private func reloadHousehold() async {
    guard let (data, code) = await householdCall("/v1/household/people", method: "GET", body: nil),
          code == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["people"] as? [[String: Any]]
    else { return }
    household = rows.compactMap { row in
      guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
      let phrases = (row["phrases"] as? NSNumber)?.intValue ?? (row["phrases"] as? Int ?? 0)
      return HouseholdRoster.Person(
        id: id,
        name: name,
        calendar: row["calendar"] as? String ?? "",
        phrases: phrases
      )
    }
  }

  private func recordEnrollment() async -> Data? {
    await withCheckedContinuation { continuation in
      audio.recordClip { data in
        continuation.resume(returning: data)
      }
    }
  }

  private func householdCall(_ path: String, method: String, body: Data?) async -> (Data, Int)? {
    guard let url = URL(string: "http://\(config.host):\(config.httpPort)\(path)") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(config.deviceToken)", forHTTPHeaderField: "Authorization")
    request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-Id")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse
    else { return nil }
    return (data, http.statusCode)
  }

  private func resumeWake() {
    guard !previewCanvas else { return }
    guard !teaching else {
      audio.setWakeWanted(false)
      return
    }
    guard wakeWord, micGranted, !holding, !preparingTalk, phase == .idle else {
      if !holding, !wakeWord || !micGranted {
        audio.setWakeWanted(false)
      }
      if !wakeWord { wakeMuted = false }
      return
    }
    wakeMuted = AudioIO.inputHardwareMuted()
    if wakeMuted {
      audio.setWakeWanted(false)
      return
    }
    audio.setWakeWanted(true)
  }

  private func noteFalseWake() {
    wakeTurn = false
    let count = ConfigStore.bumpWakeFalseAccepts()
    NSLog("arthur wake false-accept count=%d", count)
  }

  private func watchFocus() {
    guard !previewCanvas else { return }
    INFocusStatusCenter.default.requestAuthorization { _ in
      DispatchQueue.main.async { [weak self] in self?.publishFocus() }
    }
  }

  private func publishFocus() {
    guard !previewCanvas else { return }
    let center = INFocusStatusCenter.default
    let focused = center.authorizationStatus == .authorized && center.focusStatus.isFocused == true
    client.sendJSON(["type": "presence", "dnd": focused])
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
    if deskFieldFocused { return event }
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

  private func loadLibrary(deviceId: String) {
    let library = ConfigStore.loadLibrary(deviceId: deviceId)
    conversations = library.conversations
    activeConversationId = library.activeId
    discussion = library.conversations.first { $0.id == library.activeId }?.lines ?? []
    if let server = library.conversations.first(where: { $0.id == library.activeId })?.serverConversationId,
       server > 0 {
      conversationId = server
    }
  }

  private func captureActiveLines() {
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

  private func persistLibrary(deviceId: String? = nil) {
    guard !previewCanvas else { return }
    ConfigStore.saveLibrary(
      ConversationLibrary(activeId: activeConversationId, conversations: conversations),
      deviceId: deviceId ?? transcriptDeviceId
    )
  }

  /// Adopt a server id onto the open thread only when that thread is not
  /// waiting on a fresh conversation and does not already name another one.
  private func noteServerConversation(_ id: Int64) {
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

  private func noteBoundConversation(_ id: Int64, bind: String) {
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

  private func alignServerConversation() {
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
