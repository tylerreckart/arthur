import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
  func handle(_ event: IntercomEvent) {
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
      if expectingReply || phase == .speaking {
        become(.speaking)
        if work != .speaking { setWork(.speaking) }
        audio.playPCM(data)
        ingestSpeakLevel(AudioIO.pcmLevel(data, gain: 2.4))
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
      if audio.playbackPending {
        become(.speaking)
        armVoiceWatch()
      } else {
        resetSpeechSync()
        become(client.isConnected ? .idle : .disconnected)
      }
      flushTranscriptSave()
      if speakBack?.live == true { finishSpeakBack() }
    case .speak(let kind, let runId, let text):
      resetArthurReplyKey()
      expectingReply = true
      become(.speaking)
      setWork(.speaking)
      presentSpeakBack(kind: kind, runId: runId, text: text)
    case .said(let text):
      let id = formingText.isEmpty ? UUID() : formingLineId
      appendDiscussion(fromYou: false, text: text, id: id)
      let pending = formingText.trimmingCharacters(in: .whitespacesAndNewlines)
      if pending.isEmpty || ArthurProseJoin.alreadySpoken(liveTurnCommittedText, pending) {
        formingText = ""
      }
      flushPendingSurfaces()
      if !soundOn {
        become(.speaking)
        setWork(.speaking)
      } else if phase != .speaking, phase != .thinking {
        become(.thinking)
      }
      if speakBack?.live == true { noteSpeakBackSaid(text) }
    case .surface(let turnId, let surface):
      attachSurface(surface, turnId: turnId)
    case .approval(let id, let granted):
      resolveWrite(id: id, granted: granted, via: "voice")
    case .forming(let text):
      if text == formingText { return }
      if formingText.isEmpty {
        formingLineId = UUID()
      }
      _ = bindArthurReplyKey()
      formingText = text
      if phase != .speaking, phase != .listening, phase != .thinking {
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

  func presentSpeakBack(kind: String, runId: String, text: String) {
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

  func noteSpeakBackSaid(_ text: String) {
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

  func finishSpeakBack() {
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

  func clearSpeakBackBadge() {
    SpeakBackNotifier.clearBadge()
  }

  func become(_ p: ArthurPhase) {
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

  func applyWake() {
    audio.onWake = { [weak self] in self?.wakeHeard() }
    resumeWake()
  }
}
