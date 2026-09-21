import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var typing: Bool

  var body: some View {
    @Bindable var model = model
    ZStack(alignment: .top) {
      SpeakingRipple(active: model.phase == .speaking)
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .allowsHitTesting(false)
      NavigationStack {
        transcript
          .navigationTitle("Arthur")
          .toolbarTitleDisplayMode(.inline)
          .toolbar {
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
          .safeAreaBar(edge: .bottom) {
            ComposerBar(typing: $typing)
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
  }

  @ViewBuilder
  private var transcript: some View {
    if model.discussion.isEmpty, model.formingText.isEmpty, model.phase != .thinking {
      emptyState
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 28) {
            if !model.errorText.isEmpty {
              Text(model.errorText)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fadeUnderHeader()
            }
            ForEach(transcriptClusters) { cluster in
              TranscriptClusterView(cluster: cluster)
            }
            if showForming {
              ArthurCopy(texts: [model.formingText], live: true)
            } else if model.phase == .thinking, model.formingText.isEmpty {
              Text(model.work.line.isEmpty ? "…" : model.work.line)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
                .fadeUnderHeader()
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
    ContentUnavailableView {
      Label("Arthur", systemImage: "text.bubble")
    } description: {
      Text(emptyHint)
    }
  }

  private var emptyHint: String {
    switch model.phase {
    case .disconnected: return model.healthDetail
    case .connecting: return "Reaching intercom…"
    case .listening: return "Release to send"
    default: return "Hold Talk or space, or type below"
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

private struct ComposerBar: View {
  @Environment(AppModel.self) private var model
  @FocusState.Binding var typing: Bool

  var body: some View {
    @Bindable var model = model
    let hasDraft = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let canTalk = model.phase != .disconnected && model.phase != .connecting

    HStack(alignment: .center, spacing: 10) {
      TextField(
        "Ask Arthur",
        text: $model.draft,
        prompt: Text(model.holding ? "Listening…" : "Ask Arthur"),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(.body)
      .lineLimit(1...6)
      .focused($typing)
      .disabled(model.holding)
      .onSubmit { model.sendDraft() }
      .onKeyPress { press in
        guard press.key == .return else { return .ignored }
        if press.modifiers.contains(.shift) { return .ignored }
        guard hasDraft else { return .handled }
        model.sendDraft()
        return .handled
      }
      .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)

      if hasDraft, !model.holding {
        ComposerCircle(systemImage: "arrow.up", enabled: canTalk) {
          model.sendDraft()
        }
        .help("Send")
        .accessibilityLabel("Send")
      }

      ComposerCircle(
        systemImage: model.holding ? "waveform" : "mic.fill",
        enabled: canTalk,
        action: {}
      )
      .help(model.holding ? "Release to send" : "Hold to talk")
      .accessibilityLabel(model.holding ? "Release" : "Talk")
      .accessibilityHint("Hold to talk")
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if canTalk, !model.holding { model.pttDown() }
          }
          .onEnded { _ in
            if model.holding { model.pttUp() }
          }
      )
    }
    .padding(.leading, 18)
    .padding(.trailing, 8)
    .padding(.vertical, 7)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
  }
}

private struct ComposerCircle: View {
  let systemImage: String
  var enabled = true
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(enabled ? ArthurTheme.accent : Color.secondary.opacity(0.35), in: Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}

private struct TranscriptCluster: Identifiable {
  let id: UUID
  let fromYou: Bool
  var texts: [String]
}

private struct TranscriptClusterView: View {
  let cluster: TranscriptCluster

  var body: some View {
    if cluster.fromYou {
      UserCopy(texts: cluster.texts)
    } else {
      ArthurCopy(texts: cluster.texts, live: false)
    }
  }
}

private struct UserCopy: View {
  let texts: [String]

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      Text("You")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .tracking(0.8)
        .fadeUnderHeader()
      VStack(alignment: .trailing, spacing: 6) {
        ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
          Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
            .fadeUnderHeader()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, 72)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("You, \(texts.joined(separator: " "))")
  }
}

private struct ArthurCopy: View {
  let texts: [String]
  var live = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(live ? "Arthur · writing" : "Arthur")
        .font(.caption.weight(.semibold))
        .foregroundStyle(ArthurTheme.accent)
        .textCase(.uppercase)
        .tracking(0.8)
        .fadeUnderHeader()
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
          Text(text)
            .font(.system(.title3, design: .serif))
            .foregroundStyle(.primary.opacity(live ? 0.55 : 1))
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .fadeUnderHeader()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, 36)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Arthur, \(texts.joined(separator: " "))")
  }
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var model = model
    NavigationStack {
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
          Text("Intercom maps each device onto one conversation. This stays in settings so the desk app can share memory with the hallway speaker.")
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Settings")
      .toolbar {
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
    .frame(minWidth: 420, minHeight: 380)
    .preferredColorScheme(.dark)
    .tint(ArthurTheme.accent)
  }
}
