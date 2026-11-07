import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var typing: Bool
  @State private var scrolledAway = false
  @State private var followLiveEdge = true
  @State private var suppressScrollTracking = false
  @State private var seededClusterIDs = false
  @State private var knownClusterIDs: Set<UUID> = []
  @State private var showReturnHint = false
  @State private var didShowReturnHint = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

  private static let bottomAnchor = "bottom"
  /// Distance from the live edge before we stop pinning (points).
  private static let liveEdgeSlop: CGFloat = 80

  var body: some View {
    @Bindable var model = model
    NavigationSplitView(columnVisibility: $columnVisibility) {
      ConversationSidebar()
    } detail: {
      detailColumn
    }
    .onChange(of: typing) { _, on in
      model.composerFocused = on
      if on, !didShowReturnHint {
        showReturnHint = true
        didShowReturnHint = true
      }
      if !on { showReturnHint = false }
    }
    .onAppear {
      if model.sidebarOpen { columnVisibility = .doubleColumn }
      focusComposerIfAllowed()
    }
    .onChange(of: columnVisibility) { _, visibility in
      let open = visibility != .detailOnly
      if model.sidebarOpen != open { model.sidebarOpen = open }
    }
    .onChange(of: model.sidebarOpen) { _, open in
      let target: NavigationSplitViewVisibility = open ? .doubleColumn : .detailOnly
      if columnVisibility != target { columnVisibility = target }
    }
    .onChange(of: model.composerFocusToken) { _, _ in
      focusComposerIfAllowed()
    }
    .onChange(of: model.holding) { _, holding in
      if !holding { focusComposerIfAllowed() }
    }
    .onChange(of: model.settingsOpen) { _, open in
      if !open { focusComposerIfAllowed() }
    }
    .onChange(of: model.activeConversationId) {
      knownClusterIDs = []
      seededClusterIDs = false
      followLiveEdge = true
      scrolledAway = false
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
      guard let window = note.object as? NSWindow, window.isKeyWindow else { return }
      focusComposerIfAllowed()
    }
  }

  private var detailColumn: some View {
    @Bindable var model = model
    return VStack(spacing: 0) {
      if let notice = model.speakBack {
        SpeakBackBanner(notice: notice) {
          model.dismissSpeakBack()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
      }
      transcript
        .id(model.activeConversationId)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle("Arthur")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.newConversation()
        } label: {
          Label("New conversation", systemImage: "square.and.pencil")
        }
        .disabled(!model.canStartConversation || model.conversationIsEmpty)
        .keyboardShortcut("n", modifiers: .command)
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.activityOpen = true
        } label: {
          Label("Activity", systemImage: "checklist")
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .badge(model.attentionCount > 0 ? Text("\(model.attentionCount)") : nil)
      }
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            model.soundOn.toggle()
          } label: {
            Label(
              model.soundOn ? "Sound on" : "Sound off",
              systemImage: model.soundOn ? "speaker.wave.2" : "speaker.slash"
            )
          }
          Button {
            model.memoryOpen = true
          } label: {
            Label("Memory", systemImage: "text.book.closed")
          }
          Divider()
          Button("Settings…") { model.settingsOpen = true }
        } label: {
          Label("More", systemImage: "ellipsis.circle")
        }
      }
    }
    .safeAreaBar(edge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        if !model.errorText.isEmpty {
          ErrorBanner(text: model.errorText) {
            model.dismissError()
          }
        }
        ComposerBar(
          typing: $typing,
          showReturnHint: showReturnHint && !model.holding
        )
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
      .padding(.top, 2)
    }
    .sheet(isPresented: $model.memoryOpen) {
      MemoryDesk()
        .environment(model)
    }
    .sheet(isPresented: $model.activityOpen) {
      ActivityPanel()
        .environment(model)
    }
    .sheet(isPresented: $model.settingsOpen) {
      SettingsView()
        .environment(model)
    }
  }

  private func focusComposerIfAllowed() {
    guard !model.holding, !model.settingsOpen else { return }
    model.composerFocused = true
    typing = true
  }

  @ViewBuilder
  private var transcript: some View {
    if model.discussion.isEmpty, model.formingText.isEmpty, model.hearingText.isEmpty,
       model.phase != .thinking {
      emptyState
    } else {
      ScrollViewReader { proxy in
        // Built once per pass — stopTarget and the compact-card check used to
        // each rebuild the whole cluster list, once per row on top of that.
        let clusters = transcriptClusters
        let lastArthurId = clusters.last(where: { !$0.fromYou })?.id
        let stopId = model.canCancel ? lastArthurId : nil
        ScrollView {
          // The saved conversation is complete. This window pages from the
          // latest lines so a long thread does not remount the whole history.
          VStack(alignment: .leading, spacing: 20) {
            if model.canRevealEarlier {
              Button("Earlier") { model.revealEarlier() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            ForEach(clusters) { cluster in
              TranscriptClusterView(
                cluster: cluster,
                showStop: stopId == cluster.id,
                playEntrance: seededClusterIDs && !knownClusterIDs.contains(cluster.id),
                preferCompact: hallwayCompact && cluster.id == lastArthurId,
                onEdit: { text in
                  model.prefillDraft(text)
                  typing = true
                }
              )
              .background {
                ForEach(cluster.lineIds, id: \.self) { lineId in
                  Color.clear.frame(height: 0).id(lineId)
                }
              }
              .onAppear { knownClusterIDs.insert(cluster.id) }
            }
            if showWorkTrail {
              WorkTrail(line: model.work.line)
            }
            Color.clear.frame(height: 1).id(Self.bottomAnchor)
          }
          .padding(.horizontal, 22)
          .padding(.top, 12)
          .padding(.bottom, 10)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followLiveEdge ? .bottom : nil, for: .sizeChanges)
        .onAppear { seedClusterIDsIfNeeded() }
        .onChange(of: model.historyFocus) { _, focus in
          guard let focus else { return }
          proxy.scrollTo(focus, anchor: .center)
        }
        .onChange(of: model.discussion.count) {
          pinToLiveEdgeIfFollowing(proxy)
        }
        .onChange(of: model.formingText) {
          pinToLiveEdgeIfFollowing(proxy)
        }
        .onChange(of: model.streamingReply) {
          pinToLiveEdgeIfFollowing(proxy)
        }
        .onChange(of: model.hearingText) {
          pinToLiveEdgeIfFollowing(proxy)
        }
        .onChange(of: model.discussion.map(\.surfaces.count)) {
          pinToLiveEdgeIfFollowing(proxy)
        }
        .onScrollGeometryChange(for: TranscriptScrollEdge.self) { geo in
          TranscriptScrollEdge(
            height: geo.contentSize.height,
            leftover: geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
          )
        } action: { old, new in
          noteScrollGeometry(old: old, new: new)
        }
        .onScrollPhaseChange { _, phase in
          if phase == .interacting {
            suppressScrollTracking = false
          }
        }
        .overlay(alignment: .bottom) {
          Group {
            if scrolledAway {
              jumpToLatestButton(proxy)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
          }
          .animation(.easeInOut(duration: 0.18), value: scrolledAway)
        }
      }
    }
  }

  private var transcriptClusters: [TranscriptCluster] {
    var clusters: [TranscriptCluster] = []
    for line in model.visibleDiscussion {
      if var last = clusters.last, last.fromYou == line.fromYou {
        let splitArthurTurn = !line.fromYou
          && !last.turnId.isEmpty
          && !line.turnId.isEmpty
          && last.turnId != line.turnId
        let splitSpeaker = line.fromYou && last.speakerName != line.speakerName
        if !splitArthurTurn && !splitSpeaker {
          last.texts.append(line.text)
          last.surfaces.append(contentsOf: line.surfaces)
          last.lineIds.append(line.id)
          clusters[clusters.count - 1] = last
          continue
        }
      }
      clusters.append(
        TranscriptCluster(
          id: line.id,
          fromYou: line.fromYou,
          texts: [line.text],
          turnId: line.turnId,
          surfaces: line.surfaces,
          speakerName: line.speakerName,
          lineIds: [line.id]
        )
      )
    }
    for i in clusters.indices where !clusters[i].fromYou {
      clusters[i].texts = ArthurProseJoin.coalesce(
        clusters[i].texts,
        oneBubble: !clusters[i].turnId.isEmpty
      )
    }
    let ghost = model.hearingText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !ghost.isEmpty {
      if var last = clusters.last, last.fromYou, last.speakerName.isEmpty {
        last.texts.append(ghost)
        last.liveLast = true
        clusters[clusters.count - 1] = last
      } else {
        clusters.append(TranscriptCluster(
          id: model.hearingLineId,
          fromYou: true,
          texts: [ghost],
          liveLast: true
        ))
      }
    }
    let streaming = model.streamingReply
    if !streaming.isEmpty {
      let turnKey = model.liveArthurTurnId
      if let idx = clusters.lastIndex(where: { cluster in
        !cluster.fromYou && (
          cluster.id == model.formingLineId ||
          (!turnKey.isEmpty && cluster.turnId == turnKey)
        )
      }) {
        clusters[idx].texts = [streaming]
        clusters[idx].liveLast = true
      } else if !model.formingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        clusters.append(TranscriptCluster(
          id: model.formingLineId,
          fromYou: false,
          texts: [streaming],
          turnId: turnKey,
          lineIds: [model.formingLineId],
          liveLast: true
        ))
      }
    }
    return clusters
  }

  private var showWorkTrail: Bool {
    switch model.work {
    case .none, .speaking: return false
    case .findingWords, .tool: return model.phase == .thinking || model.phase == .speaking
    }
  }

  /// Hallway turns (or a narrow desk) should not force a full weather card.
  private var hallwayCompact: Bool {
    model.lastSurface == .hallway
  }

  private var emptyState: some View {
    VStack(spacing: 22) {
      ArthurMarkTile(size: 56, shadows: false)
      VStack(spacing: 10) {
        Text("Hello.")
          .font(.largeTitle)
        Text(emptyHint)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      if !model.holding {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { starterChips }
          VStack(spacing: 8) { starterChips }
        }
      }
    }
    .padding(.horizontal, 28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyHint: String {
    switch model.phase {
    case .disconnected:
      return model.errorText.isEmpty ? model.healthDetail : "He’ll be here when the intercom is back."
    case .connecting:
      return "Reaching intercom…"
    case .listening:
      return model.handsFree ? "Pause when you're done" : "Release to send"
    default:
      if model.quietTextMode {
        return "Type below — Space won’t talk"
      }
      return "Click the droplet, or \(model.pttHotkey.display)"
    }
  }
  @ViewBuilder
  private var starterChips: some View {
    StarterChip("Remind me") {
      model.prefillDraft("Remind me ")
      typing = true
    }
    StarterChip("What’s on today?") {
      model.prefillDraft("What’s on my calendar today?")
      typing = true
    }
    StarterChip("What did we say?") {
      model.prefillDraft("What did we say earlier?")
      typing = true
    }
  }

  private func seedClusterIDsIfNeeded() {
    guard !seededClusterIDs else { return }
    knownClusterIDs.formUnion(transcriptClusters.map(\.id))
    seededClusterIDs = true
  }

  private func noteScrollGeometry(old: TranscriptScrollEdge, new: TranscriptScrollEdge) {
    if suppressScrollTracking { return }
    // Growing content while pinned briefly increases leftover before the
    // follow scroll lands. Do not treat that as the user leaving the edge.
    if followLiveEdge, new.height > old.height + 0.5 { return }
    noteScrollLeftover(new.leftover)
  }

  private func noteScrollLeftover(_ leftover: CGFloat) {
    let away = leftover > Self.liveEdgeSlop
    if away != scrolledAway {
      scrolledAway = away
    }
    if followLiveEdge == away {
      followLiveEdge = !away
    }
  }

  /// Pin without animation so streaming tokens do not ease-scroll every char.
  private func pinToLiveEdgeIfFollowing(_ proxy: ScrollViewProxy) {
    guard followLiveEdge else { return }
    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
      proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }
  }

  private func jumpToLatest(_ proxy: ScrollViewProxy) {
    suppressScrollTracking = true
    scrolledAway = false
    followLiveEdge = true
    withAnimation(.easeOut(duration: 0.26)) {
      proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
      suppressScrollTracking = false
    }
  }

  private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
    Button {
      jumpToLatest(proxy)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
        Text("Jump to latest")
          .font(.caption.weight(.semibold))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .glassEffect()
    .help("Scroll to the latest line")
    .accessibilityLabel("Jump to latest")
  }
}

private struct TranscriptScrollEdge: Equatable {
  var height: CGFloat
  var leftover: CGFloat
}

private struct WorkTrail: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let line: String
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color.primary.opacity(0.7))
        .frame(width: 6, height: 6)
        .opacity(pulse ? 1 : 0.32)
      Text(line)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.leading, 2)
    .onAppear {
      guard !reduceMotion else { pulse = true; return }
      withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
    .accessibilityLabel(line)
  }
}

private struct SpeakBackBanner: View {
  let notice: SpeakBackNotice
  var dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: notice.muted ? "bell.slash.fill" : "bell.fill")
        .foregroundStyle(.primary)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(notice.title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
        Text(notice.message)
          .font(.callout)
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if notice.muted, !notice.spokenText.isEmpty {
          Text("Arthur spoke a reminder (muted)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.plain)
      .help("Dismiss")
      .accessibilityLabel("Dismiss reminder")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(notice.title), \(notice.message)")
  }
}

private struct ErrorBanner: View {
  @Environment(AppModel.self) private var model
  let text: String
  var dismiss: () -> Void
  private func modelReconnect() { model.reconnect() }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(ArthurTheme.error)
        .padding(.top, 1)
        .accessibilityHidden(true)
      Text(text)
        .font(.callout)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Retry") { modelReconnect() }
        .font(.callout.weight(.semibold))
        .accessibilityLabel("Retry connection")
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.plain)
      .help("Dismiss")
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

private struct StarterChip: View {
  let title: String
  var action: () -> Void

  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    .buttonStyle(.bordered)
    .help(title)
  }
}

private struct ComposerBar: View {
  @Environment(AppModel.self) private var model
  @FocusState.Binding var typing: Bool
  var showReturnHint = false

  var body: some View {
    @Bindable var model = model

    VStack(alignment: .leading, spacing: 8) {
      if model.screenStaged || !model.stagedFiles.isEmpty {
        stagedChips
      }
      composerRow
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      model.takeDroppedProviders(providers)
      return true
    }
    .onPasteCommand(of: [.fileURL, .image]) { providers in
      model.takeDroppedProviders(providers)
    }
  }

  private var composerRow: some View {
    @Bindable var model = model
    return HStack(alignment: .center, spacing: 8) {
      if model.holding {
        listeningAffordance
      } else {
        if model.screenLook {
            ComposerCircle(systemImage: "laptopcomputer", enabled: model.canTalk) {
            model.lookAtScreen()
          }
          .help("Look at the screen once, then ask")
          .accessibilityLabel("Look at the screen")
        }
        VStack(alignment: .leading, spacing: 3) {
          if showReturnHint {
            Text("Return to send · Shift-Return for a new line")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          TextField(
            "Ask Arthur",
            text: $model.draft,
            prompt: Text(model.quietTextMode ? "Ask Arthur — Space types" : "Ask Arthur"),
            axis: .vertical
          )
          .textFieldStyle(.plain)
          .font(.body)
          .lineLimit(1...8)
          .focused($typing)
          .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
          .accessibilityLabel("Ask Arthur")
        }
      }

      if model.canCancel {
        ComposerStop {
          model.cancelTurn()
        }
      }

      if model.hasDraft, !model.holding {
        ComposerCircle(systemImage: "arrow.up", enabled: model.canTalk) {
          model.sendDraft()
        }
        .help("Send")
        .accessibilityLabel("Send")
      }

      ComposerCircle(
        systemImage: model.holding ? "waveform" : "mic.fill",
        enabled: model.canTalk,
        active: model.holding || model.phase == .speaking,
        action: {}
      )
      .help(model.handsFree
        ? "Pause when you're done"
        : (model.holding
          ? "Release to send"
          : "Tap to talk · hold to talk · \(model.pttHotkey.display)"))
      .accessibilityLabel(model.handsFree ? "Listening" : (model.holding ? "Release" : "Talk"))
      .accessibilityHint("Tap to talk hands-free, or hold to talk. \(model.pttHotkey.display) does the same.")
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if model.canTalk, !model.holding { model.pttDown(explicit: true) }
          }
          .onEnded { _ in
            if model.holding { model.pttUp() }
          }
      )
    }
  }

  private var stagedChips: some View {
    HStack(spacing: 6) {
      if model.screenStaged {
        Button {
          model.clearScreen()
        } label: {
          Text("Screen")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Looking at your screen. Click to discard.")
        .accessibilityLabel("Discard screenshot")
      }
      ForEach(model.stagedFiles) { file in
        Button {
          model.removeStaged(file.id)
        } label: {
          Text(file.label)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Remove \(file.label)")
        .accessibilityLabel("Remove \(file.label)")
      }
    }
  }

  private var listeningAffordance: some View {
    HStack(spacing: 10) {
      ListeningMeter(level: model.inputLevel)
      VStack(alignment: .leading, spacing: 1) {
        Text("Listening")
          .font(.title3)
        Text(model.handsFree ? "Pause when you're done" : "Release to send")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(model.handsFree ? "Listening" : "Listening, release to send")
  }
}

private struct ListeningMeter: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var level: Double
  @State private var pulse = false

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<5, id: \.self) { i in
        let lit = level > Double(i) / 5.2
        Capsule()
          .fill(Color.primary.opacity(lit ? 0.92 : 0.22))
          .frame(width: 3, height: 7 + CGFloat(i) * 2.4)
      }
    }
    .opacity(0.72 + (pulse ? 0.2 : 0) + min(level, 1) * 0.08)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
}

private struct ComposerStop: View {
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Stop", systemImage: "stop.fill")
    }
    .buttonStyle(.borderedProminent)
    .help("Stop Arthur")
    .accessibilityLabel("Stop")
  }
}

private struct ComposerCircle: View {
  let systemImage: String
  var enabled = true
  /// Listening / speaking — white fill instead of the idle accent.
  var active = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
            .foregroundColor(Color(.controlBackgroundColor))
            .padding(5)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.circle)
    .glassEffect(.regular.tint(.primary).interactive())
    .disabled(!enabled)
  }
}

private struct TranscriptCluster: Identifiable {
  let id: UUID
  let fromYou: Bool
  var texts: [String]
  var turnId = ""
  var surfaces: [ChatSurface] = []
  var speakerName = ""
  var lineIds: [UUID] = []
  var liveLast = false
}

private struct TranscriptClusterView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let cluster: TranscriptCluster
  var showStop = false
  var playEntrance = false
  var preferCompact = false
  var onEdit: (String) -> Void
  @State private var settled = false
  @State private var decided = false

  var body: some View {
    clusterBody
      .opacity(settled ? 1 : 0)
      .offset(y: settled ? 0 : 7)
      .onAppear { settleIfNeeded() }
  }

  @ViewBuilder
  private var clusterBody: some View {
    if cluster.fromYou {
      UserCopy(
        texts: cluster.texts,
        speakerName: cluster.speakerName,
        liveLast: cluster.liveLast,
        onEdit: onEdit
      )
    } else {
      ArthurCopy(
        texts: cluster.texts,
        surfaces: cluster.surfaces,
        live: cluster.liveLast,
        showStop: showStop,
        preferCompact: preferCompact
      )
    }
  }

  /// Hearing / forming rows skip the entrance so tokens and the ghost →
  /// final You line do not remount-animate. History seeds as already settled.
  private func settleIfNeeded() {
    guard !decided else { return }
    decided = true
    if !playEntrance || cluster.liveLast || reduceMotion {
      settled = true
      return
    }
    withAnimation(.easeOut(duration: 0.32)) {
      settled = true
    }
  }
}

private struct UserCopy: View {
  let texts: [String]
  var speakerName = ""
  var liveLast = false
  var onEdit: (String) -> Void

  private var caption: String {
    if liveLast { return "You · …" }
    let name = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "You" : name
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      Text(caption)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      VStack(alignment: .trailing, spacing: 6) {
        ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
          let live = liveLast && index == texts.count - 1
          Text(text)
            .font(.body)
            .foregroundStyle(live ? Color.secondary : Color.primary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .padding(.vertical, 2)
            .transaction { txn in
              if live { txn.animation = nil }
            }
            .contextMenu {
              if !live {
                Button("Edit & resend") { onEdit(text) }
                Button("Copy") { ArthurPasteboard.copy(text) }
              }
            }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, 72)
    .animation(.easeOut(duration: 0.2), value: liveLast)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(liveLast ? "You, listening" : "\(caption), \(texts.joined(separator: " "))")
    .accessibilityAction(named: "Edit & resend") {
      guard !liveLast, let last = texts.last else { return }
      onEdit(last)
    }
  }
}

private struct ArthurCopy: View {
  @Environment(AppModel.self) private var model
  let texts: [String]
  var surfaces: [ChatSurface] = []
  var live = false
  var showStop = false
  var preferCompact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(live ? "Arthur · writing" : "Arthur")
        .font(.caption2)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
          let streaming = live && index == texts.count - 1
          ArthurReply(text: text, live: streaming)
            .transaction { txn in
              if streaming { txn.animation = nil }
            }
        }
      }
      if !surfaces.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(surfaces) { surface in
            if surface.actions.contains(where: { $0.kind == "approve" || $0.kind == "undo" }) {
              JobCard(
                job: JobItem(id: "surface-\(surface.id)", kind: .approval,
                             title: surface.title, summary: surface.summary,
                             state: .needsApproval,
                             primaryLabel: surface.actions.first(where: { $0.kind == "approve" || $0.kind == "undo" })?.label ?? "",
                             secondaryLabel: surface.actions.first(where: { $0.kind == "dismiss" })?.label ?? ""),
                onPrimary: { if let a = surface.actions.first(where: { $0.kind == "approve" || $0.kind == "undo" }) { model.resolveSurfaceAction(a) } },
                onSecondary: { if let a = surface.actions.first(where: { $0.kind == "dismiss" }) { model.resolveSurfaceAction(a) } }
              )
            } else {
              SurfaceCard(surface: surface, preferCompact: preferCompact)
            }
          }
        }
        .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeOut(duration: 0.2), value: live)
    .contextMenu {
      Button("Copy") { ArthurPasteboard.copy(texts.joined(separator: " ")) }
      if showStop {
        Button("Stop") { model.cancelTurn() }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    var parts = ["Arthur", texts.joined(separator: " ")]
    for surface in surfaces {
      if !surface.title.isEmpty { parts.append(surface.title) }
      if !surface.summary.isEmpty { parts.append(surface.summary) }
    }
    return parts.filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

private struct ArthurReply: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let text: String
  var live = false

  var body: some View {
    if live, !reduceMotion {
      // Scrolling freezes an ordinary body. The timeline keeps reading the
      // latest tokens; equatable skips the layout when the string is unchanged.
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
        LiveProse(text: model.streamingReply.isEmpty ? text : model.streamingReply)
          .equatable()
      }
    } else {
      blockStack(text)
    }
  }

  private func blockStack(_ shown: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(ArthurMarkdown.blocks(from: shown).enumerated()), id: \.offset) { _, block in
        switch block {
        case .prose(let line):
          ArthurProse(text: line, live: live)
        case .bullets(let items):
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                  .font(.body)
                  .foregroundStyle(.secondary)
                ArthurProse(text: item, live: live)
              }
            }
          }
        case .numbers(let items):
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1).")
                  .font(.body)
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
                ArthurProse(text: item, live: live)
              }
            }
          }
        case .code(let code):
          ArthurCodeBlock(code: code)
        }
      }
    }
  }
}

/// Plain text for the in-flight reply. Markdown is parsed once the turn
/// settles, so a token does not rebuild the block stack.
private struct LiveProse: View, Equatable {
  var text: String

  static func == (lhs: LiveProse, rhs: LiveProse) -> Bool {
    lhs.text == rhs.text
  }

  var body: some View {
    Text(text)
      .font(.title3)
      .foregroundStyle(.primary)
      .multilineTextAlignment(.leading)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .transaction { $0.animation = nil }
  }
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var settingsPath = NavigationPath()

  var body: some View {
    @Bindable var model = model
    NavigationStack(path: $settingsPath) {
      Form {
        Section {
          Text("Connection and device below apply when you tap Done. Switches, pickers, and voice enrollment further down apply right away.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Connection") {
          LabeledContent("Host") {
            TextField("127.0.0.1", text: $model.config.host)
          }
          LabeledContent("HTTP") {
            TextField("8090", value: $model.config.httpPort, format: .number)
              .frame(width: 80)
          }
          LabeledContent("WebSocket") {
            TextField("8093", value: $model.config.wsPort, format: .number)
              .frame(width: 80)
          }
          LabeledContent("intercom.json") {
            Text(model.config.configPath)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
          }
          LabeledContent("Token") {
            Text(model.config.deviceToken.isEmpty ? "missing" : "loaded")
              .foregroundStyle(model.config.deviceToken.isEmpty ? .red : .secondary)
          }
        }
        Section {
          Picker("Device", selection: $model.config.deviceId) {
            ForEach(model.sessions) { session in
              Text(session.deviceId).tag(session.deviceId)
            }
            if !model.sessions.contains(where: { $0.deviceId == model.config.deviceId }) {
              Text(model.config.deviceId).tag(model.config.deviceId)
            }
          }
        } header: {
          Text("Shared memory")
        } footer: {
          Text("The conversation you have open is this device’s memory. Pick the hallway device to share that memory with the wall button.")
        }

        Section {
          LabeledContent("Access") {
            Text(model.micGranted ? "Allowed" : "Off")
              .foregroundStyle(model.micGranted ? Color.secondary : Color.primary)
          }
          if !model.micGranted {
            Button(microphoneAccessTitle) {
              model.requestMicrophoneAccess()
            }
          }
          Picker("Input", selection: $model.microphoneID) {
            Text("System default").tag("")
            ForEach(model.microphones) { mic in
              Text(mic.name).tag(mic.id)
            }
            if !model.microphoneID.isEmpty,
               !model.microphones.contains(where: { $0.id == model.microphoneID }) {
              Text("Unavailable").tag(model.microphoneID)
            }
          }
        } header: {
          Text("Microphone")
        } footer: {
          Text(microphoneFooter)
        }

        Section {
          Toggle("Quiet text mode", isOn: $model.quietTextMode)
        } header: {
          Text("Typing")
        } footer: {
          Text("When on, Space will not start push-to-talk. \(model.pttHotkey.display) and the menu-bar droplet still talk.")
        }

        Section {
          Picker("Shortcut", selection: $model.pttHotkey) {
            ForEach(pttHotkeyChoices) { hotkey in
              Text(hotkey.display).tag(hotkey)
            }
          }
        } header: {
          Text("Push to talk")
        } footer: {
          Text(pttHotkeyFooter)
        }

        Section {
          if model.household.isEmpty {
            Text("No one enrolled")
              .foregroundStyle(.secondary)
          }
          ForEach(model.household) { person in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                if !person.calendar.isEmpty {
                  Text(person.calendar)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text(person.phrases >= 3 ? "Voice ready" : "\(person.phrases) of 3")
                .foregroundStyle(.secondary)
              Button("Remove") { model.forgetPerson(person.id) }
            }
          }
          Button("Enroll a household member…") { model.householdEnrollOpen = true }
          if !model.householdStatus.isEmpty {
            Text(model.householdStatus)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Household")
        } footer: {
          Text("Three phrases teach a voice. He uses a name only when he is sure. He does not mix calendars or memories. Someone he does not recognize can still use the lights and the timers.")
        }

        Section {
          Picker("Calendar", selection: $model.calendarSharing) {
            ForEach(CalendarSharing.allCases, id: \.self) { choice in
              Text(choice.settingsLabel).tag(choice)
            }
          }
          Toggle("App and selection", isOn: $model.seesFront)
          if model.seesFront, !FrontDesk.trusted {
            Button("Allow Accessibility") { FrontDesk.prompt() }
          }
          Toggle("Look at the screen", isOn: $model.screenLook)
          if model.screenLook, !ScreenLook.allowed {
            Button("Allow Screen Recording") { ScreenLook.requestAccess() }
          }
          Toggle("Reminders, Finder, and Mail", isOn: $model.macTools)
          Toggle("Wake word", isOn: $model.wakeWord)
          if model.wakeWord, model.wakeMuted {
            Text("The microphone is muted.")
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("This Mac")
        } footer: {
          Text("Today and tomorrow stay on this Mac. Arthur does not read the app in front of you, your reminders, or the screen unless you turn that on. A file you drop is included with the next question. A change, a Mail draft, and opening something wait until you approve. He does not send mail. Wake word listens for “Arthur” and starts a hands-free turn. It stays off until you turn it on, and it stays quiet while the microphone is muted. Restart arbiter --api once after Arthur first writes these tools.")
        }

        McpSettingsSection()

        if !model.mcpSaveError.isEmpty {
          Section {
            Text(model.mcpSaveError)
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Settings")
      .navigationDestination(for: McpEditorRoute.self) { route in
        McpServerEditor(route: route, server: mcpServer(for: route))
      }
      .toolbar {
        if settingsPath.isEmpty {
          ToolbarItem(placement: .cancellationAction) {
            Button("Reload") { model.reloadFromDisk() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              model.applySettings()
              dismiss()
            }
            .font(.system(size: 13, weight: .semibold))
          }
        }
      }
      .sheet(isPresented: $model.householdEnrollOpen) {
        HouseholdEnrollSheet().environment(model)
      }
      .onAppear {
        model.loadMcpRegistry()
        model.refreshMicrophones()
        model.loadHousehold()
      }
    }
    .frame(minWidth: 520, minHeight: 560)
  }

  private func mcpServer(for route: McpEditorRoute) -> McpServer? {
    guard case .edit(let name) = route else { return nil }
    return model.mcpServers.first { $0.name == name }
  }

  private var pttHotkeyChoices: [PTTHotkey] {
    var items = PTTHotkey.presets
    if !items.contains(model.pttHotkey) {
      items.insert(model.pttHotkey, at: 0)
    }
    return items
  }

  private var microphoneAccessTitle: String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .denied, .restricted:
      return "Open System Settings"
    default:
      return "Allow microphone"
    }
  }

  private var microphoneFooter: String {
    if !model.microphoneID.isEmpty,
       !model.microphones.contains(where: { $0.id == model.microphoneID }) {
      return "That microphone is unplugged. Arthur will use the system default until it comes back."
    }
    if let chosen = model.microphones.first(where: { $0.id == model.microphoneID }) {
      return "Arthur records from \(chosen.name) while you hold talk."
    }
    let system = AudioIO.captureDevice(preferredID: "")?.localizedName ?? "the Mac’s current microphone"
    return "System default is \(system). Arthur follows it until you pick an input."
  }

  private var pttHotkeyFooter: String {
    var text = "Hold \(model.pttHotkey.display) from anywhere — the Arthur window does not need to be focused."
    if model.quietTextMode {
      text += " Quiet text is on, so Space will not start talk inside the window."
    } else {
      text += " Space still works as push-to-talk inside the window when you are not typing."
    }
    text += " The default shortcut uses the system hotkey API and does not need Accessibility or Input Monitoring."
    if DeskAccessory.shared.usingInputMonitoringFallback {
      text += " Arthur could not register that system hotkey, so it is listening with a global key monitor. Grant Input Monitoring to Arthur in System Settings → Privacy & Security if the shortcut does nothing while another app is focused."
    }
    return text
  }
}


private struct HouseholdEnrollSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 16) {
      Text("Teach Arthur a voice").font(.title3.weight(.semibold))
      Text("Say each phrase when asked. Wake word pauses while you record.")
        .font(.callout).foregroundStyle(.secondary)
      // 1-2-3 progress
      HStack(spacing: 8) {
        ForEach(0..<HouseholdRoster.phrases.count, id: \.self) { i in
          VStack(spacing: 4) {
            Circle().fill(i < model.teachPhrase || !model.teaching && !model.householdStatus.isEmpty && model.householdStatus.contains("enrolled") ? Color.white : Color.white.opacity(0.18))
              .frame(width: 10, height: 10)
            Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
          }
          if i < HouseholdRoster.phrases.count - 1 { Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1) }
        }
      }
      .accessibilityLabel(model.teaching ? "Phrase \(min(model.teachPhrase + 1, HouseholdRoster.phrases.count)) of \(HouseholdRoster.phrases.count)" : "Not recording")
      if !model.teaching {
        TextField("Name", text: $model.teachName)
        TextField("Calendar title", text: $model.teachCalendar)
      }
      if model.teaching {
        Text(HouseholdRoster.phrases[min(model.teachPhrase, HouseholdRoster.phrases.count - 1)])
          .font(.callout).foregroundStyle(.primary)
      }
      if !model.householdStatus.isEmpty {
        Text(model.householdStatus).font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        if model.teaching {
          Button("Cancel enrollment") { model.cancelTeach() }
        }
        Spacer()
        Button("Close") { if model.teaching { model.cancelTeach() }; dismiss() }
        if !model.teaching {
          Button(model.teaching ? "Listening…" : "Start — 3 phrases") { model.teachVoice() }
            .disabled(model.teachName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .font(.callout.weight(.semibold))
        }
      }
    }
    .padding(20).frame(width: 440)
  }
}

#if DEBUG
#Preview("Household · mid-enrollment") {
  let m = AppModel.previewCanvas(); m.teaching = true; m.teachPhrase = 1; m.teachName = "Sam"
  return HouseholdEnrollSheet().environment(m).frame(width: 480, height: 380)
}
#Preview("Activity · error offline") {
  let m = AppModel.previewCanvas(phase: .disconnected); m.errorText = "Disconnected from intercom."
  return ActivityPanel().environment(m).frame(width: 520, height: 620)
}
#Preview("Activity · approval pending") {
  let m = AppModel.previewCanvas()
  m.pendingWriteTitle = "Add calendar event"; m.pendingWriteSummary = "Dentist tomorrow at 9am"
  // pendingWriteLabel is derived from private phase; surface via schedules as fallback rows
  m.deskSchedules = [DeskSchedule(id: 3, message: "Water the plants", phrase: "tomorrow at 9:00 am", status: "active")]
  return ActivityPanel().environment(m).frame(width: 520, height: 620)
}
#endif

#if DEBUG
#Preview("Empty") {
  ContentView()
    .environment(AppModel.previewCanvas())
    .frame(width: 520, height: 680)
    .preferredColorScheme(.dark)
}

#Preview("Conversation") {
  ContentView()
    .environment(
      AppModel.previewCanvas(
        discussion: [
          DiscussionLine(fromYou: true, text: "What's on this evening?"),
          DiscussionLine(
            fromYou: false,
            text: "Clear, and cooler than yesterday. Nothing else on the desk."
          ),
        ]
      )
    )
    .frame(width: 520, height: 680)
    .preferredColorScheme(.dark)
}

#Preview("Listening") {
  ContentView()
    .environment(ArthurPreviews.listening)
    .frame(width: 520, height: 680)
    .preferredColorScheme(.dark)
}

#Preview("Conversations") {
  ContentView()
    .environment(
      AppModel.previewCanvas(
        history: ArthurPreviews.conversationHistory,
        sidebarOpen: true
      )
    )
    .frame(width: 780, height: 680)
    .preferredColorScheme(.dark)
}

#Preview("Settings") {
  SettingsView()
    .environment(AppModel.previewCanvas())
    .frame(width: 560, height: 680)
    .preferredColorScheme(.dark)
}
#endif
