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
    .buttonStyle(.borderless)
    .glassEffect()
    .help("Scroll to the latest line")
    .accessibilityLabel("Jump to latest")
  }
}

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
#endif
