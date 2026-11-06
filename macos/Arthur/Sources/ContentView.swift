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
  /// Owned here so the split view can animate. A bool that snaps back to
  /// `.all` or `.detailOnly` cancels that animation on every frame.
  @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

  private static let bottomAnchor = "bottom"
  /// Distance from the live edge before we stop pinning (points).
  private static let liveEdgeSlop: CGFloat = 80

  var body: some View {
    @Bindable var model = model
    NavigationSplitView(columnVisibility: $columnVisibility) {
      ConversationSidebar()
    } detail: {
      NavigationStack {
        transcript
          .id(model.activeConversationId)
          .navigationTitle("Arthur")
          .toolbarTitleDisplayMode(.inline)
          .toolbarBackground(Color.black, for: .windowToolbar)
          .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
          .toolbar {
            ToolbarItem(placement: .navigation) {
              ArthurToolbarBead()
            }
            ToolbarItemGroup(placement: .primaryAction) {
              Button {
                model.newConversation()
              } label: {
                Label("New conversation", systemImage: "square.and.pencil")
              }
              .disabled(!model.canStartConversation || model.conversationIsEmpty)
              .help("New conversation")
              .keyboardShortcut("n", modifiers: .command)

              Button {
                model.soundOn.toggle()
              } label: {
                Label(
                  model.soundOn ? "Sound on" : "Sound off",
                  systemImage: model.soundOn ? "speaker.wave.2" : "speaker.slash"
                )
              }
              .help(model.soundOn ? "Mute Arthur" : "Unmute Arthur")

              Button {
                model.settingsOpen = true
              } label: {
                Label("Settings", systemImage: "gearshape")
              }
              .help("Settings")
            }
          }
          .safeAreaBar(edge: .top) {
            if let notice = model.speakBack {
              SpeakBackBanner(notice: notice) {
                model.dismissSpeakBack()
              }
              .padding(.horizontal, 16)
              .padding(.bottom, 4)
              .transition(.move(edge: .top).combined(with: .opacity))
            }
          }
          .animation(.easeInOut(duration: 0.22), value: model.speakBack?.id)
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
          .sheet(isPresented: $model.settingsOpen) {
            SettingsView()
              .environment(model)
          }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBackground(Color.black, for: .windowToolbar)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .coordinateSpace(ArthurChrome.space)
    .preferredColorScheme(.dark)
    .tint(.white)
    .background(Color.black)
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
        ScrollView {
          // VStack (not LazyVStack): the notebook caps at 40 lines, and
          // lazy identity / estimated heights fight pinning and fade.
          VStack(alignment: .leading, spacing: 20) {
            ForEach(transcriptClusters) { cluster in
              TranscriptClusterView(
                cluster: cluster,
                showStop: stopTarget == cluster.id,
                playEntrance: seededClusterIDs && !knownClusterIDs.contains(cluster.id),
                preferCompact: hallwayCompact && cluster.id == lastArthurClusterId,
                onEdit: { text in
                  model.prefillDraft(text)
                  typing = true
                }
              )
              .fadeUnderHeader()
              .onAppear { knownClusterIDs.insert(cluster.id) }
            }
            if showWorkTrail {
              WorkTrail(line: model.work.line)
                .fadeUnderHeader()
            }
            Color.clear.frame(height: 1).id(Self.bottomAnchor)
          }
          .padding(.horizontal, 22)
          .padding(.top, 58)
          .padding(.bottom, 10)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followLiveEdge ? .bottom : nil, for: .sizeChanges)
        .onAppear { seedClusterIDsIfNeeded() }
        .onChange(of: model.discussion.count) {
          pinToLiveEdgeIfFollowing(proxy)
        }
        .onChange(of: model.formingText) {
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
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .background { ScrollEdgeEnabler() }
        .background(.clear)
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
    for line in model.discussion {
      if var last = clusters.last, last.fromYou == line.fromYou {
        let splitArthurTurn = !line.fromYou
          && !last.turnId.isEmpty
          && !line.turnId.isEmpty
          && last.turnId != line.turnId
        if !splitArthurTurn {
          last.texts.append(line.text)
          last.surfaces.append(contentsOf: line.surfaces)
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
          surfaces: line.surfaces
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
      if var last = clusters.last, last.fromYou {
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
    if model.pacingReply, let idx = clusters.lastIndex(where: { !$0.fromYou }) {
      if model.spokenReveal.isEmpty {
        clusters.remove(at: idx)
      } else {
        clusters[idx].texts = [model.spokenReveal]
        clusters[idx].liveLast = true
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

  private var stopTarget: UUID? {
    guard model.canCancel else { return nil }
    return lastArthurClusterId
  }

  private var lastArthurClusterId: UUID? {
    transcriptClusters.last(where: { !$0.fromYou })?.id
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
          .font(.system(size: 28, weight: .regular, design: .serif))
          .foregroundStyle(ArthurTheme.paper)
        Text(emptyHint)
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(ArthurTheme.mute)
          .multilineTextAlignment(.center)
      }
      if !model.holding {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { starterChips }
          VStack(spacing: 8) { starterChips }
        }
      }
      Text(emptyFooter)
        .font(.system(size: 12))
        .foregroundStyle(ArthurTheme.whisper)
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

  private var emptyFooter: String {
    if model.quietTextMode {
      return "Quiet text on · \(model.pttHotkey.display) still talks · ⌘L to type"
    }
    return "The droplet talks and shows the reply · \(model.pttHotkey.display) · ⌘L to type"
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
      .foregroundStyle(ArthurTheme.paper)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
    .arthurPlate(radius: 14)
    .padding(.bottom, 6)
    .help("Scroll to the latest line")
    .accessibilityLabel("Jump to latest")
  }
}

private struct TranscriptScrollEdge: Equatable {
  var height: CGFloat
  var leftover: CGFloat
}

private struct WorkTrail: View {
  let line: String
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color.white.opacity(0.7))
        .frame(width: 6, height: 6)
        .opacity(pulse ? 1 : 0.32)
      Text(line)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.leading, 2)
    .onAppear {
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
        .foregroundStyle(ArthurTheme.paper)
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
    .arthurPlate(radius: 14)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(notice.title), \(notice.message)")
  }
}

private struct ErrorBanner: View {
  let text: String
  var dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(ArthurTheme.paper)
        .padding(.top, 1)
      Text(text)
        .font(.callout)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    .arthurPlate(radius: 14)
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
    .buttonStyle(.plain)
    .foregroundStyle(ArthurTheme.paper)
    .arthurPlate(radius: 16)
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
    .padding(.vertical, 10)
    .animation(.easeInOut(duration: 0.16), value: model.holding)
    .animation(.easeInOut(duration: 0.16), value: model.canCancel)
    .animation(.easeInOut(duration: 0.16), value: model.quietTextMode)
    .animation(.easeInOut(duration: 0.16), value: model.screenStaged)
    .animation(.easeInOut(duration: 0.16), value: model.stagedFiles.count)
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
        QuietModeToggle()
        if model.screenLook {
          ComposerCircle(systemImage: "viewfinder", enabled: model.canTalk) {
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
        .buttonStyle(.plain)
        .foregroundStyle(ArthurTheme.paper)
        .arthurPlate(radius: 12)
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
        .buttonStyle(.plain)
        .foregroundStyle(ArthurTheme.paper)
        .arthurPlate(radius: 12)
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
          .font(.system(size: 20, weight: .regular, design: .serif))
          .foregroundStyle(ArthurTheme.paper)
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
  var level: Double
  @State private var pulse = false

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<5, id: \.self) { i in
        let lit = level > Double(i) / 5.2
        Capsule()
          .fill(Color.white.opacity(lit ? 0.92 : 0.22))
          .frame(width: 3, height: 7 + CGFloat(i) * 2.4)
      }
    }
    .opacity(0.72 + (pulse ? 0.2 : 0) + min(level, 1) * 0.08)
    .onAppear {
      withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
}

private struct QuietModeToggle: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Button {
      model.toggleQuietTextMode()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: model.quietTextMode ? "keyboard.fill" : "keyboard")
          .font(.system(size: 12, weight: .semibold))
        if model.quietTextMode {
          Text("Text")
            .font(.caption2.weight(.semibold))
        }
      }
      .foregroundStyle(model.quietTextMode ? ArthurTheme.paper : ArthurTheme.mute)
      .padding(.horizontal, model.quietTextMode ? 8 : 6)
      .frame(height: 32)
      .background(
        model.quietTextMode ? Color.white.opacity(0.08) : Color.clear,
        in: Capsule()
      )
    }
    .buttonStyle(.plain)
    .help(
      model.quietTextMode
        ? "Quiet text on — Space types. \(model.pttHotkey.display) still talks."
        : "Quiet text — Space will not start talk"
    )
    .accessibilityLabel(model.quietTextMode ? "Quiet text on" : "Quiet text off")
    .accessibilityHint("Turns off Space as push-to-talk. Option-Space and the menu-bar droplet still talk.")
    .accessibilityAddTraits(model.quietTextMode ? [.isSelected] : [])
  }
}

private struct ComposerStop: View {
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: "stop.fill")
          .font(.system(size: 9, weight: .bold))
        Text("Stop")
          .font(.callout.weight(.semibold))
      }
      .foregroundStyle(.black)
      .padding(.horizontal, 11)
      .frame(height: 32)
      .background(Color.white, in: Capsule())
    }
    .buttonStyle(.plain)
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
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(active ? Color.black : .white)
        .frame(width: 32, height: 32)
        .background(circleFill, in: Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private var circleFill: Color {
    if !enabled { return Color.white.opacity(0.12) }
    if active { return .white }
    return Color.white.opacity(0.14)
  }
}

private struct TranscriptCluster: Identifiable {
  let id: UUID
  let fromYou: Bool
  var texts: [String]
  var turnId = ""
  var surfaces: [ChatSurface] = []
  var liveLast = false
}

private struct TranscriptClusterView: View {
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
      UserCopy(texts: cluster.texts, liveLast: cluster.liveLast, onEdit: onEdit)
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
    if !playEntrance || cluster.liveLast {
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
  var liveLast = false
  var onEdit: (String) -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      Text(liveLast ? "You · …" : "You")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      VStack(alignment: .trailing, spacing: 6) {
        ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
          let live = liveLast && index == texts.count - 1
          Text(text)
            .font(.system(size: 17, weight: .regular, design: .serif))
            .foregroundStyle(live ? ArthurTheme.whisper : ArthurTheme.mute)
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
    .accessibilityLabel(liveLast ? "You, listening" : "You, \(texts.joined(separator: " "))")
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
        .foregroundStyle(ArthurTheme.whisper)
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
            SurfaceCard(surface: surface, preferCompact: preferCompact)
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAction(named: "Copy") {
      ArthurPasteboard.copy(texts.joined(separator: " "))
    }
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
  let text: String
  var live = false

  var body: some View {
    if live {
      // The animation schedule keeps painting while the transcript is scrolling.
      // The scroll run loop does not refresh an ordinary body until the gesture ends.
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
        blockStack(model.spokenReveal.isEmpty ? text : model.spokenReveal)
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
                  .font(.system(.title3, design: .serif))
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
                  .font(.system(.title3, design: .serif))
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

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var settingsPath = NavigationPath()

  var body: some View {
    @Bindable var model = model
    NavigationStack(path: $settingsPath) {
      Form {
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
              .foregroundStyle(model.micGranted ? ArthurTheme.mute : Color.white.opacity(0.92))
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
      .scrollContentBackground(.hidden)
      .background(Color.black)
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
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
          }
        }
      }
      .onAppear {
        model.loadMcpRegistry()
        model.refreshMicrophones()
      }
    }
    .frame(minWidth: 520, minHeight: 560)
    .preferredColorScheme(.dark)
    .tint(ArthurTheme.accent)
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
