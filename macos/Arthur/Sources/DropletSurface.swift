import AppKit
import SwiftUI

// MARK: - Motion

/// Frame-by-frame drip. The bead gathers, the neck stretches, the bulb
/// pinches off, then the fallen drop spreads downward into the card.
struct DripSample: Equatable {
  var fall: Float
  var bridge: Float
  var morph: Float
  var squishX: Float
  var squishY: Float
  var content: Float
  var presence: Float

  static let settled = DripSample(
    fall: 1, bridge: 0, morph: 1, squishX: 1, squishY: 1, content: 1, presence: 1
  )
  static let hidden = DripSample(
    fall: 0, bridge: 0, morph: 0, squishX: 1, squishY: 1, content: 0, presence: 0
  )
}

enum DripMotion {
  /// Fades up into the corner. The card is not attached to the toolbar.
  static func opening(_ t: Double) -> DripSample {
    if t >= 0.4 { return .settled }
    let reveal = smoother(min(1, t / 0.34))
    return DripSample(
      fall: Float(reveal), bridge: 0, morph: 1, squishX: 1, squishY: 1,
      content: Float(reveal), presence: Float(reveal)
    )
  }

  static func closing(_ t: Double) -> DripSample {
    if t <= 0 { return .settled }
    let gone = smoother(min(1, t / 0.22))
    return DripSample(
      fall: Float(1 - gone), bridge: 0, morph: 1, squishX: 1, squishY: 1,
      content: Float(1 - gone), presence: Float(1 - gone)
    )
  }

  private static func smoother(_ x: Double) -> Double {
    let u = min(1, max(0, x))
    return u * u * u * (u * (u * 6 - 15) + 10)
  }
}

// MARK: - Content

enum DropletStage: Equatable {
  case ready
  case listening
  case thinking
  case replying
}

struct DropletContent: Equatable {
  var stage: DropletStage
  var title: String
  var subtitle: String
  var you: String
  var reply: String
  var noteTitle: String
  var noteBody: String
  var approveLabel: String
  var lookLabel: String
  var level: Double
  var speak: Double
  var canTalk: Bool
  var canCancel: Bool
  var handsFree: Bool
  var holding: Bool
  var hotkey: String
  var attentionCount: Int = 0
  var attentionTitle: String = ""
  var attentionSummary: String = "" 

  var live: Bool { stage != .ready }

  static let empty = DropletContent(
    stage: .ready,
    title: "Arthur",
    subtitle: "",
    you: "",
    reply: "",
    noteTitle: "",
    noteBody: "",
    approveLabel: "",
    lookLabel: "",
    level: 0,
    speak: 0,
    canTalk: false,
    canCancel: false,
    handsFree: false,
    holding: false,
    hotkey: "⌥Space"
  )

  @MainActor
  static func capture(_ model: AppModel) -> DropletContent {
    let stage: DropletStage
    if model.holding || model.phase == .listening {
      stage = .listening
    } else if model.phase == .thinking {
      stage = .thinking
    } else if model.phase == .speaking {
      stage = .replying
    } else {
      stage = .ready
    }

    let hearing = model.hearingText.trimmingCharacters(in: .whitespacesAndNewlines)
    let youSaid = model.youSaid.trimmingCharacters(in: .whitespacesAndNewlines)
    let you: String
    if stage == .listening {
      you = (hearing.isEmpty || hearing == "…") ? "" : hearing
    } else if !youSaid.isEmpty {
      you = youSaid
    } else {
      you = model.discussion.last(where: \.fromYou)?.text ?? ""
    }

    let lastArthur = model.discussion.last(where: { !$0.fromYou })
    let reply: String
    if stage == .listening {
      reply = ""
    } else if model.pacingReply {
      reply = model.spokenReveal
    } else if stage == .thinking {
      reply = ""
    } else {
      reply = lastArthur?.text ?? ""
    }

    let surface = (stage == .listening || model.pacingReply || stage == .thinking) ? nil : lastArthur?.surfaces.last
    let workLine = model.work.line
    let speak = model.speakLevel
    let hotkey = model.pttHotkey.display
    let handsFree = model.handsFree
    let error = model.errorText.trimmingCharacters(in: .whitespacesAndNewlines)

    let subtitle: String
    if stage != .listening, !error.isEmpty {
      subtitle = error
    } else {
      switch stage {
      case .listening:
        subtitle = handsFree ? "Pause when you're done" : "Release to send"
      case .thinking:
        subtitle = workLine.isEmpty ? "Working" : workLine
      case .replying:
        subtitle = speak > 0.04 ? "Speaking" : ""
      case .ready:
        switch model.phase {
        case .connecting:
          subtitle = "Reaching intercom…"
        case .disconnected:
          subtitle = model.healthDetail
        default:
          if !model.deskCue.isEmpty {
            subtitle = model.deskCue
          } else if model.wakeWord && model.wakeMuted {
            subtitle = "Microphone muted"
          } else if model.wakeWord {
            subtitle = "Listening for Arthur"
          } else {
            subtitle = "Hold the droplet to talk · \(hotkey)"
          }
        }
      }
    }

    let title: String
    switch stage {
    case .listening: title = "Listening"
    case .thinking: title = "Thinking"
    case .replying:
      if model.speakBack?.live == true {
        title = model.speakBack?.title ?? "Arthur"
      } else {
        title = "Arthur"
      }
    case .ready: title = "Arthur"
    }

    let urgent = model.mostUrgentJob
    return DropletContent(
      stage: stage,
      title: title,
      subtitle: subtitle,
      you: clip(you, 280),
      reply: clip(reply, 700),
      noteTitle: surface?.title ?? "",
      noteBody: surface?.summary ?? "",
      approveLabel: model.pendingWriteLabel,
      lookLabel: model.screenLook ? "Look" : "",
      level: model.inputLevel,
      speak: speak,
      canTalk: model.canTalk,
      canCancel: model.canCancel,
      handsFree: handsFree,
      holding: model.holding,
      hotkey: hotkey,
      attentionCount: model.attentionCount,
      attentionTitle: urgent?.title ?? "",
      attentionSummary: urgent?.summary ?? ""
    )
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    guard text.count > limit else { return text }
    let end = text.index(text.startIndex, offsetBy: limit)
    return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}

enum DropletMetrics {
  static let panelSize = CGSize(width: 480, height: 700)
  static let cardWidth: CGFloat = 348
  static let cornerMargin: CGFloat = 20
  static let corner: CGFloat = 28
}

struct DropletActions {
  var talkDown: () -> Void = {}
  var talkUp: () -> Void = {}
  var stop: () -> Void = {}
  var open: () -> Void = {}
  var dismiss: () -> Void = {}
  var approve: () -> Void = {}
  var look: () -> Void = {}
  var openActivity: () -> Void = {}
  var hover: (Bool) -> Void = { _ in }
  var setAcceptsHits: (Bool) -> Void = { _ in }
  var cardFrame: (NSRect) -> Void = { _ in }
  var didFinishClose: () -> Void = {}
}

@MainActor
@Observable
final class BeadState {
  var listening = false
  var thinking = false
  var speaking = false
  var connected = false
  var dripping = false
  var level = 0.0

  var accessibilityLabel: String {
    if listening { return "Arthur, listening" }
    if thinking { return "Arthur, thinking" }
    if speaking { return "Arthur, speaking" }
    return "Arthur"
  }
}

@MainActor
@Observable
final class DropletSession {
  var content = DropletContent.empty
  var anchorX: CGFloat = 240
  var cardHeight: CGFloat = 168
  var pointer = CGPoint(x: 0.32, y: 0.18)
  var hovering = false
  var actions = DropletActions()
  var talkArmed = false

  var closing = false
  var openBegan = Date()
  var closeBegan = Date()
  var closeToken = 0
  private let epoch = Date()

  var dragging = false
  var drag = CGSize.zero
  private var releasedDrag = CGSize.zero
  private var dragReleasedAt = Date.distantPast

  func sample(at date: Date) -> DripSample {
    if closing {
      return DripMotion.closing(date.timeIntervalSince(closeBegan))
    }
    return DripMotion.opening(date.timeIntervalSince(openBegan))
  }

  func shaderTime(at date: Date) -> Float {
    Float(date.timeIntervalSince(epoch))
  }

  func dragOffset(at date: Date) -> CGSize {
    if dragging { return drag }
    let elapsed = date.timeIntervalSince(dragReleasedAt)
    let decay = exp(-elapsed * 8.5)
    if decay < 0.01 { return .zero }
    let wobble = sin(elapsed * 15) * exp(-elapsed * 6)
    return CGSize(
      width: releasedDrag.width * decay,
      height: releasedDrag.height * decay + releasedDrag.height * 0.14 * wobble
    )
  }

  func updateDrag(_ translation: CGSize) {
    dragging = true
    drag = CGSize(
      width: min(36, max(-36, translation.width)),
      height: min(140, max(-16, translation.height))
    )
  }

  /// Downward pull distance, for dismiss.
  func endDrag() -> CGFloat {
    let drop = drag.height
    releasedDrag = drag
    dragReleasedAt = Date()
    dragging = false
    drag = .zero
    return drop
  }

  func armTalk() {
    guard !talkArmed else { return }
    talkArmed = true
    actions.talkDown()
  }

  func releaseTalk() {
    guard talkArmed else { return }
    talkArmed = false
    actions.talkUp()
  }

  func setCardHeight(_ raw: CGFloat) {
    guard raw > 48 else { return }
    let next = min(500, max(124, raw.rounded(.up)))
    if abs(next - cardHeight) < 0.5 { return }
    cardHeight = next
  }
}

// MARK: - Bead

struct ArthurBead: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var bead: BeadState
  var diameter: CGFloat = 16
  /// When set, draw this instant instead of running a timeline.
  /// The menu-bar image is re-rendered from a timer; the toolbar uses the clock.
  var clock: Date? = nil

  private var animating: Bool {
    !reduceMotion && (bead.listening || bead.thinking || bead.speaking || bead.dripping || bead.connected)
  }

  var body: some View {
    Group {
      if let clock {
        mark(time: clock.timeIntervalSinceReferenceDate)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { context in
          mark(time: context.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .frame(width: diameter, height: diameter)
    .accessibilityHidden(true)
  }

  private func mark(time: TimeInterval) -> some View {
    let listening = bead.listening
    let level = bead.level
    let breath = (bead.thinking || bead.speaking) ? (0.5 + 0.5 * sin(time * (bead.speaking ? 2.6 : 1.15))) : 0
    let drip = bead.dripping ? sin(time * 7.2) : 0
    let scale = listening ? 1 + 0.035 * level + 0.012 * sin(time * 4.6) : 1
    let stretch = 0.10 * drip

    return ArthurMarkTile(
      size: diameter,
      glyphOpacity: 0.88 + 0.12 * breath + (listening ? 0.1 : 0),
      rimOpacity: bead.connected ? 0.22 : 0.12,
      shadows: diameter >= 20
    )
    .scaleEffect(x: scale * (1 - stretch), y: scale * (1 + stretch))
    .shadow(
      color: Color.white.opacity(listening ? 0.28 + 0.25 * level : 0),
      radius: listening ? 4 : 0
    )
  }
}

struct ArthurToolbarBead: View {
  private var bead: BeadState { DeskAccessory.shared.bead }

  var body: some View {
    Button {
      DeskAccessory.shared.toggleFromToolbar()
    } label: {
      ArthurBead(bead: bead, diameter: 15)
        .frame(width: 28, height: 28)
        .background {
          ScreenFrameReader { DeskAccessory.shared.noteToolbarAnchor($0) }
        }
    }
    .buttonStyle(.plain)
    .help(bead.listening ? "Arthur is listening" : "Arthur — open the droplet")
    .accessibilityLabel(bead.accessibilityLabel)
    .accessibilityHint("Opens Arthur. Hold the menu-bar droplet, or use the talk shortcut, to speak.")
  }
}

// MARK: - Card

struct DropletCardRoot: View {
  var session: DropletSession
  private var bead: BeadState { DeskAccessory.shared.bead }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
      let now = timeline.date
      let sample = session.sample(at: now)
      let drag = session.dragOffset(at: now)
      GeometryReader { geo in
        let layout = layout(in: geo.size, sample: sample, drag: drag)
        card(sample: sample, layout: layout)
        .frame(width: geo.size.width, height: geo.size.height)
        .onAppear { session.actions.cardFrame(layout.card) }
        .onChange(of: layout.card) { _, rect in
          session.actions.cardFrame(rect)
        }
        .onContinuousHover { phase in
          switch phase {
          case .active(let loc):
            if !session.hovering {
              session.hovering = true
              session.actions.hover(true)
            }
            let card = layout.card
            guard card.width > 1, card.height > 1 else { return }
            session.pointer = CGPoint(
              x: min(1, max(0, (loc.x - card.minX) / card.width)),
              y: min(1, max(0, (loc.y - card.minY) / card.height))
            )
          case .ended:
            if session.hovering {
              session.hovering = false
              session.actions.hover(false)
            }
          @unknown default:
            break
          }
        }
      }
      .onChange(of: hitsOpen(sample)) { _, open in
        session.actions.setAcceptsHits(open)
      }
    }
    .onChange(of: session.closeToken) { _, token in
      guard token > 0 else { return }
      let expected = token
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(280))
        guard session.closeToken == expected, session.closing else { return }
        session.actions.didFinishClose()
      }
    }
  }

  private func hitsOpen(_ sample: DripSample) -> Bool {
    sample.presence > 0.2
  }

  private func layout(in size: CGSize, sample: DripSample, drag: CGSize) -> DropletLayout {
    let width = DropletMetrics.cardWidth
    let height = session.cardHeight
    let margin = DropletMetrics.cornerMargin
    let rect = CGRect(
      x: size.width - width - margin + drag.width,
      y: size.height - height - margin + drag.height,
      width: width,
      height: height
    )
    return DropletLayout(
      card: rect,
      anchor: CGPoint(x: rect.midX, y: rect.minY),
      squish: CGSize(width: 1, height: 1)
    )
  }

  @ViewBuilder
  private func card(sample: DripSample, layout: DropletLayout) -> some View {
    let reveal = CGFloat(min(max(sample.content, 0), 1))
    let rise = CGFloat(min(max(sample.fall, 0), 1))
    DropletCardBody(session: session)
      .fixedSize(horizontal: false, vertical: true)
      .background {
        GeometryReader { proxy in
          Color.clear.preference(key: DropletHeightKey.self, value: proxy.size.height)
        }
      }
      .background(Color.black, in: RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous)
          .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
      .clipShape(RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous))
      .opacity(reveal)
      .offset(y: (1 - rise) * 36)
      .position(x: layout.card.midX, y: layout.card.midY)
      .onPreferenceChange(DropletHeightKey.self) { session.setCardHeight($0) }
      .preferredColorScheme(.dark)
  }
}

private struct DropletLayout {
  var card: CGRect
  var anchor: CGPoint
  var squish: CGSize
}

private struct DropletHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct DropletCardBody: View {
  var session: DropletSession

  var body: some View {
    let content = session.content
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 0) {
        Button(action: { session.actions.open() }) {
          ArthurGlyph()
            .fill(Color.white.opacity(0.92))
            .frame(width: 16, height: 16)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the conversation")
        .accessibilityLabel("Open Arthur")
        Spacer(minLength: 0)
        Button(action: { session.actions.dismiss() }) {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.82))
            .frame(width: 36, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
      }

      if !content.you.isEmpty {
        Text(content.you)
          .font(.callout)
          .foregroundStyle(ArthurTheme.mute)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("You said: \(content.you)")
      }

      if content.reply.isEmpty {
        Text(content.stage == .ready ? "Hello." : content.title)
          .font(.system(.title3, design: .serif))
          .foregroundStyle(Color.white.opacity(0.92))
          .frame(maxWidth: .infinity, alignment: .leading)
        // Subtitle (work line, error, or hint) shows in every stage — not
        // only .ready — so a long think never reads as a bare "…".
        if !content.subtitle.isEmpty,
           !content.subtitle.hasPrefix("Hold the droplet") {
          Text(content.subtitle)
            .font(.callout)
            .foregroundStyle(content.stage == .ready && content.subtitle == session.content.subtitle && !content.attentionTitle.isEmpty ? ArthurTheme.mute : ArthurTheme.mute)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(content.subtitle)
        }
      } else {
        SpokenReply(text: content.reply)
        if content.stage == .thinking || content.stage == .replying, !content.subtitle.isEmpty {
          Text(content.subtitle)
            .font(.callout).foregroundStyle(ArthurTheme.mute)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      // Nothing is approvable blind: the pending item's title + summary
      // sit directly above Approve / Not now, and tapping opens Activity.
      if !content.approveLabel.isEmpty, !content.noteTitle.isEmpty || !content.noteBody.isEmpty {
        JobCard(
          job: JobItem(id: "droplet-approval", kind: .approval,
                       title: content.noteTitle.isEmpty ? content.attentionTitle : content.noteTitle,
                       summary: content.noteBody.isEmpty ? content.attentionSummary : content.noteBody,
                       state: .needsApproval, primaryLabel: "", secondaryLabel: ""),
          compact: true,
          onTap: { session.actions.openActivity() }
        )
        .accessibilityHint("Opens Activity")
      } else if content.attentionCount > 0, !content.attentionTitle.isEmpty {
        Button { session.actions.openActivity() } label: {
          HStack(spacing: 6) {
            Text("\(content.attentionCount)").font(.caption2.weight(.bold))
              .padding(5).background(Color(red: 0.86, green: 0.40, blue: 0.42), in: Circle()).foregroundStyle(.white)
            Text(content.attentionTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.caption2)
          }.foregroundStyle(ArthurTheme.paper)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(content.attentionCount) items need you. Most urgent: \(content.attentionTitle)")
        .accessibilityHint("Opens Activity")
      }

      if content.canCancel {
        Button("Stop") { session.actions.stop() }
          .buttonStyle(.plain).font(.callout.weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 7)
          .foregroundStyle(.black).background(Color.white.opacity(0.92), in: Capsule())
          .accessibilityLabel("Stop Arthur")
      }

      if !content.approveLabel.isEmpty || !content.lookLabel.isEmpty {
        HStack(spacing: 8) {
          if !content.lookLabel.isEmpty {
            Button(content.lookLabel) { session.actions.look() }
              .buttonStyle(.plain)
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .foregroundStyle(Color.white.opacity(0.92))
              .overlay(Capsule().stroke(Color.white.opacity(0.92), lineWidth: 1))
              .accessibilityLabel("Look at the screen")
          }
          if !content.approveLabel.isEmpty {
            Button(content.approveLabel) { session.actions.approve() }
              .buttonStyle(.plain)
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .foregroundStyle(Color.black)
              .background(Color.white.opacity(0.92), in: Capsule())
              .accessibilityLabel(content.approveLabel)
          }
        }
      }

    }
    .padding(24)
    .frame(width: DropletMetrics.cardWidth, alignment: .leading)
    .animation(.easeOut(duration: 0.28), value: content.reply)
    .simultaneousGesture(cardDrag)
  }

  private var cardDrag: some Gesture {
    DragGesture(minimumDistance: 18)
      .onChanged { value in
        guard !session.talkArmed, !session.closing else { return }
        let sample = session.sample(at: Date())
        guard sample.morph > 0.92 else { return }
        session.updateDrag(value.translation)
      }
      .onEnded { _ in
        guard session.dragging else { return }
        let drop = session.endDrag()
        if drop > 108, !session.content.live {
          session.actions.dismiss()
        }
      }
  }

}

/// Arthur's spoken reply, revealed a few characters at a time as it arrives.
private struct SpokenReply: View {
  var text: String
  @State private var count = 0
  @State private var reveal: Task<Void, Never>?

  var body: some View {
    Text(String(text.prefix(count)))
      .font(.system(size: 20, weight: .regular, design: .serif))
      .foregroundStyle(Color.white)
      .lineLimit(8)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contextMenu {
        Button("Copy") { ArthurPasteboard.copy(text) }
      }
      .onAppear { catchUp(to: text) }
      .onChange(of: text) { old, next in
        if count > 0, !next.hasPrefix(String(old.prefix(count))) {
          count = 0
        }
        catchUp(to: next)
      }
      .onDisappear { reveal?.cancel() }
  }

  private func catchUp(to next: String) {
    reveal?.cancel()
    count = next.count
  }
}

// MARK: - Panel

final class DropletPanel: NSPanel {
  weak var host: DropletHostingView?
  private var passingThrough = false

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Clicks outside the card go to the menu-bar and toolbar triggers.
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      if !passingThrough, let host {
        let point: NSPoint
        if let superview = host.superview {
          point = superview.convert(event.locationInWindow, from: nil)
        } else {
          point = event.locationInWindow
        }
        if host.hitTest(point) == nil {
          passingThrough = true
          ignoresMouseEvents = true
          NSApp.postEvent(event, atStart: true)
          DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
              guard let self else { return }
              self.passingThrough = false
              if self.isVisible { self.ignoresMouseEvents = false }
            }
          }
          return
        }
      }
    default:
      break
    }
    super.sendEvent(event)
  }
}

@MainActor
final class DropletController {
  let session = DropletSession()
  var onClosed: (() -> Void)?
  private(set) var onScreen = false
  private(set) var acceptsHits = false
  private(set) var cardScreenRect: NSRect = .zero
  private var cardInPanel: NSRect = .zero
  private var panel: DropletPanel?

  func show(anchor: NSRect, drip: Bool) {
    if panel == nil { build() }
    let wasClosing = session.closing
    session.closing = false
    if drip || !onScreen || wasClosing {
      session.openBegan = Date()
      session.talkArmed = false
    }
    onScreen = true
    acceptsHits = true
    setMetalPaused(false)
    place(anchor: anchor)
    panel?.ignoresMouseEvents = false
    panel?.orderFrontRegardless()
  }

  func hideAnimated() {
    guard onScreen, !session.closing else {
      if !onScreen { finishClose() }
      return
    }
    session.closing = true
    session.closeBegan = Date()
    session.closeToken += 1
    session.releaseTalk()
  }

  func hideImmediate() {
    session.closing = false
    session.closeToken += 1
    finishClose()
  }

  func update(_ content: DropletContent) {
    session.content = content
  }

  func place(anchor: NSRect) {
    guard let panel else { return }
    let size = DropletMetrics.panelSize
    let screen = screen(containing: anchor) ?? NSScreen.main
    let vis = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let x = vis.maxX - size.width - 12
    let y = vis.minY + 12
    let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    if abs(panel.frame.minX - frame.minX) > 0.5 || abs(panel.frame.minY - frame.minY) > 0.5
        || panel.frame.size != frame.size {
      panel.setFrame(frame, display: true)
    }
    if cardInPanel.width < 1 {
      let width = DropletMetrics.cardWidth
      let height = max(session.cardHeight, 96)
      let margin = DropletMetrics.cornerMargin
      cardInPanel = NSRect(
        x: size.width - width - margin,
        y: size.height - height - margin,
        width: width,
        height: height
      )
    }
    noteCardInPanel(cardInPanel)
  }

  private func noteCardInPanel(_ rect: NSRect) {
    cardInPanel = rect
    guard let panel, rect.width > 1, rect.height > 1 else { return }
    let screen = NSRect(
      x: panel.frame.minX + rect.minX,
      y: panel.frame.maxY - rect.maxY,
      width: rect.width,
      height: rect.height
    )
    if abs(cardScreenRect.minX - screen.minX) < 0.5,
       abs(cardScreenRect.minY - screen.minY) < 0.5,
       abs(cardScreenRect.width - screen.width) < 0.5,
       abs(cardScreenRect.height - screen.height) < 0.5 {
      return
    }
    cardScreenRect = screen
  }

  private func build() {
    let size = DropletMetrics.panelSize
    let panel = DropletPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovable = false
    panel.animationBehavior = .none
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    let host = DropletHostingView(rootView: DropletCardRoot(session: session))
    host.frame = NSRect(origin: .zero, size: size)
    host.autoresizingMask = [.width, .height]
    host.cardScreenRect = { [weak self] in self?.cardScreenRect ?? .zero }
    host.acceptsHits = { [weak self] in self?.acceptsHits ?? false }
    panel.host = host
    panel.contentView = host
    session.actions.setAcceptsHits = { [weak self] on in
      guard let self, self.acceptsHits != on else { return }
      self.acceptsHits = on
      self.panel?.ignoresMouseEvents = !on
    }
    session.actions.cardFrame = { [weak self] rect in
      self?.noteCardInPanel(rect)
    }
    session.actions.didFinishClose = { [weak self] in
      self?.finishClose()
    }
    self.panel = panel
  }

  private func finishClose() {
    onScreen = false
    acceptsHits = false
    cardScreenRect = .zero
    cardInPanel = .zero
    session.closing = false
    session.hovering = false
    session.talkArmed = false
    panel?.ignoresMouseEvents = true
    setMetalPaused(true)
    panel?.orderOut(nil)
    onClosed?()
  }

  private func setMetalPaused(_ paused: Bool) {}

  private func screen(containing rect: NSRect) -> NSScreen? {
    let mid = CGPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.first { $0.frame.contains(mid) }
  }
}

final class DropletHostingView: NSHostingView<DropletCardRoot> {
  var cardScreenRect: () -> NSRect = { .zero }
  var acceptsHits: () -> Bool = { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard acceptsHits(), let window else { return nil }
    let local = convert(point, from: superview)
    let windowPoint = convert(local, to: nil)
    let screenPoint = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
    let rect = cardScreenRect().insetBy(dx: -10, dy: -16)
    guard rect.width > 20, rect.contains(screenPoint) else { return nil }
    return super.hitTest(point)
  }
}

struct ScreenFrameReader: NSViewRepresentable {
  var onChange: (NSRect) -> Void

  func makeNSView(context: Context) -> ScreenFrameView {
    ScreenFrameView(onChange: onChange)
  }

  func updateNSView(_ view: ScreenFrameView, context: Context) {
    view.onChange = onChange
    view.report()
  }
}

final class ScreenFrameView: NSView {
  var onChange: (NSRect) -> Void
  private var last = NSRect.null

  init(onChange: @escaping (NSRect) -> Void) {
    self.onChange = onChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    report()
  }

  override func layout() {
    super.layout()
    report()
  }

  func report() {
    guard let window, bounds.width > 1, bounds.height > 1 else { return }
    let rect = window.convertToScreen(convert(bounds, to: nil))
    if abs(rect.minX - last.minX) < 0.5, abs(rect.minY - last.minY) < 0.5,
       abs(rect.width - last.width) < 0.5, abs(rect.height - last.height) < 0.5 {
      return
    }
    last = rect
    onChange(rect)
  }
}

#if DEBUG
private struct DropletCardPreview: View {
  var content: DropletContent
  @State private var session: DropletSession

  init(content: DropletContent) {
    self.content = content
    let session = DropletSession()
    session.content = content
    session.openBegan = .distantPast
    _session = State(initialValue: session)
  }

  var body: some View {
    DropletCardBody(session: session)
      .background(Color.black, in: RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous))
      .preferredColorScheme(.dark)
  }
}

#Preview("Droplet · ready") {
  DropletCardPreview(content: .empty)
}

#Preview("Droplet · listening") {
  DropletCardPreview(content: ArthurPreviews.listeningDroplet)
}

#Preview("Droplet · reply") {
  DropletCardPreview(content: ArthurPreviews.replyDroplet)
}

#Preview("Droplet · thinking") {
  DropletCardPreview(content: ArthurPreviews.thinkingDroplet)
}

#Preview("Droplet · approval") {
  DropletCardPreview(content: ArthurPreviews.approvalDroplet)
}
#endif
