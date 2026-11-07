import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
  /// Voice (and late `turn`) path. Typed sends already appended in `sendDraft`.
  /// `heard` lands first and `turn` repeats the same line after the reply, so
  /// a second append used to place the question under Arthur's answer.
  func commitVoiceTranscript(_ text: String) {
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
      persistTranscript()
    } else {
      appendDiscussion(fromYou: true, text: trimmed, id: hearingLineId, speakerName: pendingSpeaker)
    }
    clearHearing()
  }

  func resetArthurReplyKey() {
    arthurReplyKey = ""
  }

  /// Key shared by every Arthur `said` in the in-flight turn (or speak-back).
  func bindArthurReplyKey() -> String {
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

  var arthurTurnIsLive: Bool {
    expectingReply || phase == .speaking || phase == .thinking || (speakBack?.live == true)
  }

  func appendDiscussion(
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
    persistTranscript()
  }

  func replyKeys(for rawTurnId: String) -> [String] {
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

  func attachSurface(_ surface: ChatSurface, turnId rawTurnId: String) {
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

  func applySurface(_ surface: ChatSurface, at idx: Int, turnKey: String?) {
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

  func flushPendingSurfaces() {
    guard !pendingSurfaces.isEmpty else { return }
    let queued = pendingSurfaces
    pendingSurfaces.removeAll()
    for item in queued {
      attachSurface(item.surface, turnId: item.turnId)
    }
  }

  func persistTranscript(deviceId: String? = nil) {
    guard !previewCanvas else { return }
    let device = deviceId ?? transcriptDeviceId
    captureActiveLines()
    // Token and sentence bursts must not encode the notebook on the
    // main thread between paints. The latest copy is written once the
    // turn goes quiet, and immediately when the turn ends.
    if expectingReply {
      scheduleTranscriptSave(deviceId: device)
      return
    }
    transcriptSave?.cancel()
    transcriptSave = nil
    writeTranscript(deviceId: device, wait: true)
  }

  func scheduleTranscriptSave(deviceId: String) {
    transcriptSave?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.transcriptSave = nil
      self.writeTranscript(deviceId: deviceId, wait: false)
    }
    transcriptSave = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  func flushTranscriptSave() {
    let pending = transcriptSave
    transcriptSave = nil
    pending?.cancel()
    guard pending != nil else { return }
    writeTranscript(deviceId: transcriptDeviceId, wait: true)
  }

  func writeTranscript(deviceId: String, wait: Bool) {
    guard !previewCanvas else { return }
    captureActiveLines()
    let lines = discussion
    let library = ConversationLibrary(activeId: activeConversationId, conversations: conversations)
    let save: @Sendable () -> Void = {
      ConfigStore.saveTranscript(lines, deviceId: deviceId)
      ConfigStore.saveLibrary(library, deviceId: deviceId)
    }
    if wait {
      transcriptQueue.sync(execute: save)
    } else {
      transcriptQueue.async(execute: save)
    }
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

  var historyHits: [HistoryHit] {
    HistorySearch.hits(in: conversations.map { item in
      HistoryThread(
        id: item.id,
        title: item.title,
        updatedAt: item.updatedAt,
        lines: item.lines.map { HistoryLine(id: $0.id, text: $0.text) }
      )
    }, query: historyQuery)
  }

  var visibleDiscussion: [DiscussionLine] {
    let shown = min(max(historyShown, 0), discussion.count)
    if shown >= discussion.count { return discussion }
    return Array(discussion.suffix(shown))
  }

  var canRevealEarlier: Bool { discussion.count > visibleDiscussion.count }

  func revealEarlier() {
    historyShown += DiscussionLimits.visibleLineCap
  }

  func openHistory(_ hit: HistoryHit) {
    if hit.conversationId != activeConversationId {
      openConversation(hit.conversationId)
    }
    guard hit.conversationId == activeConversationId else { return }
    historyShown = HistorySearch.shownCount(total: discussion.count, focusIndex: hit.lineIndex)
    historyFocus = hit.lineId
    historyQuery = ""
  }

  func newConversation() {
    guard canStartConversation else {
      sidebarNotice = "Finish or stop the current turn before starting a new conversation."
      return
    }
    sidebarNotice = "" 
    captureActiveLines()
    guard !conversationIsEmpty else { return }
    conversations.removeAll { $0.id != activeConversationId && $0.lines.isEmpty }
    let item = DeskConversation.empty(needsFreshServer: true)
    conversations.insert(item, at: 0)
    activeConversationId = item.id
    historyShown = DiscussionLimits.visibleLineCap
    historyFocus = nil
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
    guard canStartConversation else {
      sidebarNotice = "Finish or stop the current turn before switching conversations."
      return
    }
    sidebarNotice = "" 
    guard conversations.contains(where: { $0.id == id }) else { return }
    captureActiveLines()
    let previous = activeConversationId
    if let previousItem = conversations.first(where: { $0.id == previous }),
       previousItem.lines.isEmpty {
      conversations.removeAll { $0.id == previous }
    }
    guard let item = conversations.first(where: { $0.id == id }) else { return }
    activeConversationId = id
    historyShown = DiscussionLimits.visibleLineCap
    historyFocus = nil
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

  func persistDraft() {
    guard !previewCanvas else { return }
    ConfigStore.saveDraft(draft)
  }

  /// `said` lines already committed for this turn, joined the same way the
  /// transcript bubble joins them. Empty before the first `said`.
  var liveTurnCommittedText: String {
    let key = arthurReplyKey
    guard !key.isEmpty else { return "" }
    var parts: [String] = []
    for line in discussion where !line.fromYou && line.turnId == key {
      parts.append(line.text)
    }
    if parts.count <= 1 { return parts.first ?? "" }
    return ArthurProseJoin.coalesce(parts, oneBubble: true).joined(separator: "\n\n")
  }

  func resetSpeechSync() {
    voiceWatch?.invalidate()
    voiceWatch = nil
  }

  /// Watches the audio queue only. It does not gate the words on screen.
  func armVoiceWatch() {
    guard voiceWatch == nil else { return }
    let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.finishVoiceIfQuiet()
      }
    }
    voiceWatch = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func finishVoiceIfQuiet() {
    guard !expectingReply, !audio.playbackPending else { return }
    resetSpeechSync()
    if phase == .speaking {
      become(client.isConnected ? .idle : .disconnected)
    }
  }
}
