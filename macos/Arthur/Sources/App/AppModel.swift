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

/// Paint cache for the live reply. A class so updates do not publish
/// through `@Observable` while a view is reading `streamingReply`.
private final class ReplyPaintCache {
  var stamp = ""
  var text = ""
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
  /// Lines kept on screen. The saved conversation holds the rest.
  var historyShown = DiscussionLimits.visibleLineCap
  var historyQuery = ""
  var historyFocus: UUID?
  var memoryOpen = false
  var memoryQuery = ""
  var memoryFacts: [MemoryFact] = []
  var memoryUndo: MemoryFact?
  var editingMemory = false
  var memoryEditTitle = ""
  var memoryEditContent = ""
  var deskSchedules: [DeskSchedule] = []
  var deskTodos: [DeskTodo] = []
  var reschedulePhrases: [Int: String] = [:]
  var deskStatus = ""
  var deskLoadState: DeskLoadState = .idle
  var activityOpen = false
  var pendingWriteTitle = ""
  var pendingWriteSummary = ""
  var rescheduleDates: [Int: Date] = [:]
  var sidebarNotice = ""
  var householdEnrollOpen = false
  var teachCancelled = false
  var editingMemoryId = 0
  var work: WorkState = .none
  var youSaid = ""
  var formingText = ""
  /// Stable id for the in-flight Arthur bubble so `.forming` → `.said`
  /// does not remount the cluster (avoids a jump / flash).
  var formingLineId = UUID()
  /// Token stream for the in-flight reply. Empty once that text has settled.
  /// Words are shown as they arrive; the voice is allowed to lag behind.
  var streamingReply: String {
    let committed = liveTurnCommittedText
    let forming = formingText
    let formingLive = !forming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard formingLive || (expectingReply && !committed.isEmpty) else { return "" }
    let stamp = arthurReplyKey + "\u{1}" + committed + "\u{1}" + forming
    if stamp == replyPaintCache.stamp { return replyPaintCache.text }
    let shown = ArthurLiveReply.shown(committed: committed, forming: forming)
    replyPaintCache.stamp = stamp
    replyPaintCache.text = shown
    return shown
  }
  /// Shared by every Arthur `said` in the current turn (or live speak-back)
  /// so later `accept` ids do not split one reply into two bubbles.
  var arthurReplyKey = ""
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
  var turnModality: TurnModality = .none
  var conversationId: Int64 = 0
  var conversations: [DeskConversation] = []
  var activeConversationId = UUID()
  /// Sidebar column. The desk starts on the transcript.
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
  var pendingSpeaker = ""
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
  var stagedShot: DeskContext.Image?
  var stagedToken = 0
  var sentToken = 0
  var lookInFlight = false
  var fileLoads = 0
  var deferredSend: (() -> Void)?
  var presenceReady = false
  /// This listen was opened by the wake word. An empty result counts as a false accept.
  var wakeTurn = false
  var pendingWriteId: String?
  var pendingWritePhase = ""
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

  let client = IntercomClient()
  let audio = AudioIO()
  var healthTimer: Timer?
  var keyMonitor: Any?
  var pttStarted: Date?
  var reconnectWork: DispatchWorkItem?
  var reconnectAttempt = 0
  var wantsSocket = false
  var pcmBytes = 0
  var endpoint = UtteranceEndpoint()
  var expectingReply = false
  var typedThisTurn = false
  var voiceWatch: Timer?
  var transcriptSave: DispatchWorkItem?
  let transcriptQueue = DispatchQueue(label: "arthur.transcript", qos: .utility)
  private let replyPaintCache = ReplyPaintCache()
  var started = false
  var transcriptDeviceId = ""
  var pttFromKeyboard = false
  var speakBackDismiss: DispatchWorkItem?
  var activeObserver: NSObjectProtocol?
  var lastPolledTurnId = ""
  /// Surfaces that arrived before the matching Arthur `said` line.
  var pendingSurfaces: [(turnId: String, surface: ChatSurface)] = []
  /// Set only by `previewCanvas`. Skips notebook, draft, and quiet-mode writes
  /// so the Xcode canvas cannot clobber the running desk.
  var previewCanvas = false
  var sessionCalendarAllowed = false {
    didSet {
      guard oldValue != sessionCalendarAllowed else { return }
      publishCalendarPolicy()
    }
  }
  /// A calendar confirm dialog is up. A second press must not start another one.
  var preparingTalk = false
  /// True from the press that opened a confirm dialog until that press releases.
  var talkPointerDown = false
  /// The release after a dialog arms hands-free instead of sending a truncated turn.
  var releaseArmsHandsFree = false
  var localMcp: LocalMcpServer?

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
}
