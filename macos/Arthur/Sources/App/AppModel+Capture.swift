import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
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

  func addStaged(_ files: [StagedFile]) {
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

  func startLocalCalendar() {
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

  func registerArthurCalendar(port: UInt16, token: String) {
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
    case "desk":
      performDesk(action)
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

  func resolveWrite(id: String, granted: Bool, via: String) {
    if let proposal = CalendarDesk.resolve(id: id, granted: granted, via: via) {
      applyWrite(proposal)
      return
    }
    presentMac(MacDesk.resolve(id: id, granted: granted, via: via))
  }

  func applyWrite(_ proposal: CalendarDesk.WriteProposal?) {
    guard let proposal else { return }
    presentWrite(proposal)
  }

  func presentMac(_ card: MacDesk.WriteCard?) {
    guard let card else { return }
    pendingWriteTitle = card.title; pendingWriteSummary = card.summary
    pendingWritePhase = card.phase
    pendingWriteId = card.phase == "approve" || card.phase == "undo" ? card.id : nil
    showWrite(id: card.id, title: card.title, summary: card.summary, phase: card.phase)
  }

  func presentWrite(_ proposal: CalendarDesk.WriteProposal) {
    pendingWriteTitle = proposal.title; pendingWriteSummary = proposal.summary
    pendingWritePhase = proposal.phase
    pendingWriteId = proposal.phase == "approve" || proposal.phase == "undo" ? proposal.id : nil
    showWrite(id: proposal.id, title: proposal.title, summary: proposal.summary, phase: proposal.phase)
  }

  func showWrite(id: String, title: String, summary: String, phase: String) {
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

  func upsertProposalSurface(_ surface: ChatSurface, id: String) {
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

  var activityJobs: [JobItem] {
    ActivityBuilder.jobs(
      pendingTitle: pendingWriteTitle, pendingSummary: pendingWriteSummary,
      pendingLabel: pendingWriteLabel,
      isRunning: phase == .thinking || phase == .speaking, workLine: work.line,
      canCancel: canCancel, errorText: errorText,
      isOffline: phase == .disconnected || phase == .connecting,
      schedules: deskSchedules, todos: deskTodos,
      speakBackTitle: speakBack?.title ?? "", speakBackMessage: speakBack?.live == true ? (speakBack?.message ?? "") : "")
  }
  var attentionCount: Int { ActivityBuilder.attentionCount(activityJobs) }
  var mostUrgentJob: JobItem? { ActivityBuilder.mostUrgent(activityJobs) }
}
