import AppKit
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var typing: Bool
  @State private var scrolledAway = false
  @State private var showReturnHint = false
  @State private var didShowReturnHint = false

  var body: some View {
    @Bindable var model = model
    ZStack(alignment: .top) {
      SpeakingRipple(active: model.phase == .speaking, restrained: rippleRestrained)
        .frame(maxWidth: .infinity)
        .frame(height: rippleRestrained ? 128 : 152)
        .allowsHitTesting(false)
      NavigationStack {
        transcript
          .navigationTitle("Arthur")
          .toolbarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .navigation) {
              ContinuityChip()
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
          .scrollEdgeEffectStyle(.soft, for: .top)
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
      Rectangle()
        .fill(.ultraThinMaterial)
        .mask {
          LinearGradient(
            stops: [
              .init(color: .black.opacity(0.55), location: 0),
              .init(color: .black.opacity(0.18), location: 0.62),
              .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        }
        .frame(maxWidth: .infinity)
        .frame(height: ArthurChrome.fadeBand)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .coordinateSpace(ArthurChrome.space)
    .preferredColorScheme(.dark)
    .tint(ArthurTheme.accent)
    .background(.clear)
    .onChange(of: typing) { _, on in
      model.composerFocused = on
      if on, !didShowReturnHint {
        showReturnHint = true
        didShowReturnHint = true
      }
      if !on { showReturnHint = false }
    }
    .onAppear { focusComposerIfAllowed() }
    .onChange(of: model.composerFocusToken) { _, _ in
      focusComposerIfAllowed()
    }
    .onChange(of: model.holding) { _, holding in
      if !holding { focusComposerIfAllowed() }
    }
    .onChange(of: model.settingsOpen) { _, open in
      if !open { focusComposerIfAllowed() }
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
          LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(transcriptClusters) { cluster in
              TranscriptClusterView(
                cluster: cluster,
                showStop: stopTarget == cluster.id,
                onEdit: { text in
                  model.prefillDraft(text)
                  typing = true
                }
              )
            }
            if showWorkTrail {
              WorkTrail(line: model.work.line)
            }
            if showForming {
              ArthurCopy(
                texts: [model.formingText],
                live: true,
                showStop: model.canCancel
              )
            }
            Color.clear.frame(height: 1).id("bottom")
          }
          .padding(.horizontal, 22)
          .padding(.top, 58)
          .padding(.bottom, 10)
        }
        .onChange(of: model.discussion.count) {
          scroll(proxy)
        }
        .onChange(of: model.formingText) {
          scroll(proxy)
        }
        .onChange(of: model.hearingText) {
          scroll(proxy)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
          geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
        } action: { _, leftover in
          scrolledAway = leftover > 88
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .scrollIndicators(.automatic)
        .background { ScrollEdgeEnabler() }
        .background(.clear)
      }
    }
  }

  private var transcriptClusters: [TranscriptCluster] {
    var clusters: [TranscriptCluster] = []
    for line in model.discussion {
      if var last = clusters.last, last.fromYou == line.fromYou {
        last.texts.append(line.text)
        clusters[clusters.count - 1] = last
      } else {
        clusters.append(TranscriptCluster(id: line.id, fromYou: line.fromYou, texts: [line.text]))
      }
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
    return clusters
  }

  private var showForming: Bool {
    guard model.phase == .thinking || model.phase == .speaking else { return false }
    let live = fold(model.formingText)
    guard !live.isEmpty else { return false }
    let spoken = fold(
      model.discussion.reversed().filter { !$0.fromYou }.prefix(8).map(\.text).joined(separator: " ")
    )
    return spoken.isEmpty || !spoken.contains(live)
  }

  private var showWorkTrail: Bool {
    switch model.work {
    case .none, .speaking: return false
    case .findingWords, .tool: return model.phase == .thinking || model.phase == .speaking
    }
  }

  private var stopTarget: UUID? {
    guard model.canCancel, !showForming else { return nil }
    return transcriptClusters.last(where: { !$0.fromYou })?.id
  }

  private var rippleRestrained: Bool {
    model.discussion.count >= 4 || scrolledAway
  }

  private func fold(_ text: String) -> String {
    let lowered = text.lowercased().map { ch -> Character in
      if ch.isLetter || ch.isNumber { return ch }
      return " "
    }
    return String(lowered)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private var emptyState: some View {
    VStack(spacing: 22) {
      VStack(spacing: 8) {
        Text("Arthur")
          .font(.system(.largeTitle, design: .serif))
        Text(emptyHint)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      if !model.holding {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { starterChips }
          VStack(spacing: 8) { starterChips }
        }
      }
      Text(emptyFooter)
        .font(.caption)
        .foregroundStyle(.tertiary)
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
      return "Release to send"
    default:
      if model.quietTextMode {
        return "Type below — Space won’t talk"
      }
      return "Hold Talk or \(model.pttHotkey.display), or type below"
    }
  }

  private var emptyFooter: String {
    if model.quietTextMode {
      return "Quiet text on · \(model.pttHotkey.display) still talks · ⌘L to type"
    }
    return "Hold Talk or \(model.pttHotkey.display) to speak · ⌘L to type"
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

  private func scroll(_ proxy: ScrollViewProxy) {
    var transaction = Transaction()
    transaction.animation = .easeOut(duration: 0.18)
    withTransaction(transaction) {
      proxy.scrollTo("bottom", anchor: .bottom)
    }
  }
}

private struct ContinuityChip: View {
  @Environment(AppModel.self) private var model
  @State private var dim = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(dotColor)
        .frame(width: 6, height: 6)
        .opacity(shouldPulse && dim ? 0.35 : 1)
      VStack(alignment: .leading, spacing: 0) {
        Text(model.chromeLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let last = lastSurfaceLine {
          Text(last)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.fill.quaternary, in: Capsule())
    .animation(.easeInOut(duration: 0.2), value: model.chromeLabel)
    .animation(.easeInOut(duration: 0.2), value: model.lastSurface)
    .help(model.chromeDetail)
    .onAppear { syncPulse() }
    .onChange(of: shouldPulse) { _, _ in syncPulse() }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(model.chromeDetail)
  }

  private var lastSurfaceLine: String? {
    guard model.phase == .idle, model.sharesHallwayMemory, let surface = model.lastSurface else {
      return nil
    }
    return surface == .desk ? "Last from Mac" : "Last from hallway"
  }

  private var shouldPulse: Bool {
    model.phase == .connecting || model.phase == .listening || model.phase == .thinking
  }

  private func syncPulse() {
    if shouldPulse {
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        dim = true
      }
    } else {
      withAnimation(.easeOut(duration: 0.15)) { dim = false }
    }
  }

  private var dotColor: Color {
    switch model.phase {
    case .disconnected: return .red.opacity(0.8)
    case .connecting: return .secondary
    case .idle: return model.micGranted ? Color.green.opacity(0.85) : ArthurTheme.accent
    case .listening, .thinking, .speaking: return ArthurTheme.accent
    }
  }
}

private struct WorkTrail: View {
  let line: String
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(ArthurTheme.accent)
        .frame(width: 6, height: 6)
        .opacity(pulse ? 1 : 0.32)
      Text(line)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.leading, 2)
    .fadeUnderHeader()
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
        .foregroundStyle(ArthurTheme.accent)
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
    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
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
        .foregroundStyle(ArthurTheme.accent)
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
    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
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
    .background(.fill.quaternary, in: Capsule())
    .help(title)
  }
}

private struct ComposerBar: View {
  @Environment(AppModel.self) private var model
  @FocusState.Binding var typing: Bool
  var showReturnHint = false

  var body: some View {
    @Bindable var model = model

    HStack(alignment: .center, spacing: 8) {
      if model.holding {
        listeningAffordance
      } else {
        QuietModeToggle()
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
      .help(model.holding ? "Release to send" : "Hold to talk · \(model.pttHotkey.display) also talks")
      .accessibilityLabel(model.holding ? "Release" : "Talk")
      .accessibilityHint("Hold to talk. \(model.pttHotkey.display) also starts push-to-talk.")
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
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .animation(.easeInOut(duration: 0.16), value: model.holding)
    .animation(.easeInOut(duration: 0.16), value: model.canCancel)
    .animation(.easeInOut(duration: 0.16), value: model.quietTextMode)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
  }

  private var listeningAffordance: some View {
    HStack(spacing: 10) {
      ListeningMeter(level: model.inputLevel)
      VStack(alignment: .leading, spacing: 1) {
        Text("Listening")
          .font(.body.weight(.medium))
          .foregroundStyle(ArthurTheme.accent)
        Text("Release to send")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Listening, release to send")
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
          .fill(ArthurTheme.accent.opacity(lit ? 0.95 : 0.28))
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
      .foregroundStyle(model.quietTextMode ? ArthurTheme.accent : .secondary)
      .padding(.horizontal, model.quietTextMode ? 8 : 6)
      .frame(height: 32)
      .background(
        model.quietTextMode ? ArthurTheme.accent.opacity(0.16) : Color.clear,
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
    .accessibilityHint("Turns off Space as push-to-talk. Option-Space and the menu bar still talk.")
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
  /// Listening / speaking — white fill instead of the idle orange.
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
    if !enabled { return Color.secondary.opacity(0.35) }
    if active { return .white }
    return ArthurTheme.accent
  }
}

private struct TranscriptCluster: Identifiable {
  let id: UUID
  let fromYou: Bool
  var texts: [String]
  var liveLast = false
}

private struct TranscriptClusterView: View {
  let cluster: TranscriptCluster
  var showStop = false
  var onEdit: (String) -> Void

  var body: some View {
    if cluster.fromYou {
      UserCopy(texts: cluster.texts, liveLast: cluster.liveLast, onEdit: onEdit)
    } else {
      ArthurCopy(texts: cluster.texts, live: false, showStop: showStop)
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
        .fadeUnderHeader()
      VStack(alignment: .trailing, spacing: 6) {
        ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
          let live = liveLast && index == texts.count - 1
          Text(text)
            .font(.body)
            .foregroundStyle(live ? .secondary : .primary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
              ArthurTheme.bubbleFill.opacity(live ? 0.7 : 1),
              in: .rect(cornerRadius: 16, style: .continuous)
            )
            .fadeUnderHeader()
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
  var live = false
  var showStop = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(live ? "Arthur · writing" : "Arthur")
        .font(.caption2)
        .foregroundStyle(ArthurTheme.accent.opacity(0.8))
        .fadeUnderHeader()
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
          ArthurReply(text: text, live: live)
            .fadeUnderHeader()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu {
      Button("Copy") { ArthurPasteboard.copy(texts.joined(separator: "\n\n")) }
      if showStop {
        Button("Stop") { model.cancelTurn() }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Arthur, \(texts.joined(separator: " "))")
    .accessibilityAction(named: "Copy") {
      ArthurPasteboard.copy(texts.joined(separator: "\n\n"))
    }
  }
}

private struct ArthurReply: View {
  let text: String
  var live = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(ArthurMarkdown.blocks(from: text).enumerated()), id: \.offset) { _, block in
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
          Text("Intercom maps each device onto one conversation. Pick the hallway device so this Mac shares memory with the wall button. The title-bar chip reads Shared with hallway when that session is connected.")
        }

        Section {
          Toggle("Quiet text mode", isOn: $model.quietTextMode)
        } header: {
          Text("Typing")
        } footer: {
          Text("When on, Space will not start push-to-talk. \(model.pttHotkey.display) and the menu bar extra still talk.")
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
            .buttonStyle(.glassProminent)
          }
        }
      }
      .onAppear { model.loadMcpRegistry() }
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
