import AppKit
import AVFoundation
import SwiftUI

struct TranscriptScrollEdge: Equatable {
  var height: CGFloat
  var leftover: CGFloat
}

struct WorkTrail: View {
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

struct SpeakBackBanner: View {
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

struct ErrorBanner: View {
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

struct StarterChip: View {
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

struct ComposerBar: View {
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

struct ListeningMeter: View {
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

struct ComposerStop: View {
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Stop", systemImage: "stop.fill")
    }
    .glassEffect(.regular.tint(.white).interactive())
    .help("Stop Arthur")
    .accessibilityLabel("Stop")
  }
}

struct ComposerCircle: View {
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

struct TranscriptCluster: Identifiable {
  let id: UUID
  let fromYou: Bool
  var texts: [String]
  var turnId = ""
  var surfaces: [ChatSurface] = []
  var speakerName = ""
  var lineIds: [UUID] = []
  var liveLast = false
}

struct TranscriptClusterView: View {
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

struct UserCopy: View {
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

struct ArthurCopy: View {
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

struct ArthurReply: View {
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
struct LiveProse: View, Equatable {
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
