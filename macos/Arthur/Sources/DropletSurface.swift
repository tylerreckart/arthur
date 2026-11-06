import AppKit
import Metal
import MetalKit
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
      hotkey: hotkey
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
  var send: (String) -> Void = { _ in }
  var approve: () -> Void = {}
  var look: () -> Void = {}
  var fieldFocus: (Bool) -> Void = { _ in }
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
  var fieldFocused = false
  var metalOK = true
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
  var bead: BeadState
  var diameter: CGFloat = 16
  /// When set, draw this instant instead of running a timeline.
  /// The menu-bar image is re-rendered from a timer; the toolbar uses the clock.
  var clock: Date? = nil

  private var animating: Bool {
    bead.listening || bead.thinking || bead.speaking || bead.dripping || bead.connected
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

  private func squish(sample: DripSample, drag: CGSize) -> CGSize {
    let sx = CGFloat(sample.squishX) * (1 - min(0.14, max(-0.14, drag.width / 420)))
    let sy = CGFloat(sample.squishY) * (1 + min(0.20, max(-0.12, drag.height / 520)))
    return CGSize(width: sx, height: sy)
  }

  private func makeDraw(sample: DripSample, layout: DropletLayout, time: Float) -> DropletDraw {
    let hover = session.hovering
    return DropletDraw(
      time: time,
      anchorX: Float(layout.anchor.x),
      anchorY: Float(layout.anchor.y),
      cardX: Float(layout.card.minX),
      cardY: Float(layout.card.minY),
      cardW: Float(layout.card.width),
      cardH: Float(layout.card.height),
      fall: sample.fall,
      bridge: sample.bridge,
      morph: sample.morph,
      squishX: Float(layout.squish.width),
      squishY: Float(layout.squish.height),
      level: Float(session.content.level),
      speak: Float(session.content.speak),
      phase: phaseIndex(session.content.stage),
      pointerX: Float(session.pointer.x),
      pointerY: Float(session.pointer.y),
      hovering: hover ? 1 : 0,
      presence: sample.presence
    )
  }

  private func phaseIndex(_ stage: DropletStage) -> Float {
    switch stage {
    case .ready: return 0
    case .listening: return 1
    case .thinking: return 2
    case .replying: return 3
    }
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

      if content.reply.isEmpty {
        Text(content.stage == .ready ? "Hello." : (content.stage == .listening ? "Listening" : "…"))
          .font(.system(size: 20, weight: .regular, design: .serif))
          .foregroundStyle(Color.white.opacity(content.stage == .ready || content.stage == .listening ? 0.92 : 0.45))
          .frame(maxWidth: .infinity, alignment: .leading)
        if content.stage == .ready,
           !content.subtitle.isEmpty,
           !content.subtitle.hasPrefix("Hold the droplet") {
          Text(content.subtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        SpokenReply(text: content.reply)
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
        guard !session.talkArmed, !session.fieldFocused, !session.closing else { return }
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

private struct InkPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .brightness(configuration.isPressed ? 0.08 : 0)
      .animation(.spring(response: 0.26, dampingFraction: 0.62), value: configuration.isPressed)
  }
}

private struct InkWaveform: View {
  var level: Double

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      HStack(alignment: .center, spacing: 3) {
        ForEach(0..<28, id: \.self) { index in
          let wave = sin(time * 5.4 + Double(index) * 0.42)
          let lift = 0.35 + 0.65 * min(1, level)
          let height = 3 + lift * (7 + 16 * (0.5 + 0.5 * wave))
          Capsule()
            .fill(Color.white.opacity(0.22 + 0.62 * lift * (0.45 + 0.55 * (0.5 + 0.5 * wave))))
            .frame(width: 2, height: height)
            .blur(radius: level > 0.45 ? 0.45 : 0)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 32)
    }
    .accessibilityHidden(true)
  }
}

private struct ThinkingSheen: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      let travel = 0.5 + 0.5 * sin(time * 0.95)
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.white.opacity(0.06))
            .frame(height: 2)
          Capsule()
            .fill(
              LinearGradient(
                colors: [Color.white.opacity(0.0), Color.white.opacity(0.85), Color.white.opacity(0.0)],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: 48, height: 3)
            .blur(radius: 1.1)
            .offset(x: (geo.size.width - 48) * travel)
        }
        .frame(height: geo.size.height, alignment: .center)
      }
      .frame(height: 8)
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Liquid

private struct DropletDraw: Equatable {
  var time: Float
  var anchorX: Float
  var anchorY: Float
  var cardX: Float
  var cardY: Float
  var cardW: Float
  var cardH: Float
  var fall: Float
  var bridge: Float
  var morph: Float
  var squishX: Float
  var squishY: Float
  var level: Float
  var speak: Float
  var phase: Float
  var pointerX: Float
  var pointerY: Float
  var hovering: Float
  var presence: Float
}

private struct DropletFallbackBody: View {
  var draw: DropletDraw

  var body: some View {
    let morph = CGFloat(min(max(draw.morph, 0), 1))
    let width = max(16, CGFloat(draw.cardW) * morph + 18 * (1 - morph))
    let height = max(16, CGFloat(draw.cardH) * morph + 18 * (1 - morph))
    let landed = CGPoint(
      x: CGFloat(draw.cardX) + CGFloat(draw.cardW) / 2,
      y: CGFloat(draw.cardY) + height / 2
    )
    let gathered = CGPoint(x: CGFloat(draw.anchorX), y: CGFloat(draw.anchorY) + 14)
    let fall = CGFloat(draw.fall)
    let center = CGPoint(
      x: gathered.x + (landed.x - gathered.x) * fall,
      y: gathered.y + (landed.y - gathered.y) * fall
    )
    ZStack {
      if draw.bridge > 0.03 {
        Capsule()
          .fill(Color.black)
          .frame(width: 4 + CGFloat(draw.bridge) * 8, height: max(8, center.y - CGFloat(draw.anchorY)))
          .position(x: CGFloat(draw.anchorX), y: (CGFloat(draw.anchorY) + center.y) / 2)
      }
      RoundedRectangle(cornerRadius: morph > 0.45 ? DropletMetrics.corner : width / 2, style: .continuous)
        .fill(Color.black)
        .overlay {
          RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous)
            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            .blur(radius: 0.4)
        }
        .frame(width: width, height: height)
        .position(center)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
    }
    .opacity(Double(draw.presence))
  }
}

private struct DropletMetal: NSViewRepresentable {
  var draw: DropletDraw
  var onUnavailable: () -> Void

  func makeCoordinator() -> DropletRenderer { DropletRenderer() }

  func makeNSView(context: Context) -> MTKView {
    let view = MTKView()
    context.coordinator.attach(view, onUnavailable: onUnavailable)
    context.coordinator.drawState = draw
    context.coordinator.push(view)
    return view
  }

  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.drawState = draw
    context.coordinator.push(view)
    if view.isPaused { view.isPaused = false }
  }
}

private struct DropletGPU {
  var time: Float = 0
  var anchorX: Float = 0
  var anchorY: Float = 0
  var cardX: Float = 0
  var cardY: Float = 0
  var cardW: Float = 1
  var cardH: Float = 1
  var fall: Float = 0
  var bridge: Float = 0
  var morph: Float = 0
  var squishX: Float = 1
  var squishY: Float = 1
  var level: Float = 0
  var speak: Float = 0
  var phase: Float = 0
  var pointerX: Float = 0.3
  var pointerY: Float = 0.2
  var hovering: Float = 0
  var presence: Float = 1
  var resolutionX: Float = 1
  var resolutionY: Float = 1
}

final class DropletRenderer: NSObject, MTKViewDelegate {
  fileprivate var drawState = DropletDraw(
    time: 0, anchorX: 0, anchorY: 0, cardX: 0, cardY: 0, cardW: 1, cardH: 1,
    fall: 0, bridge: 0, morph: 0, squishX: 1, squishY: 1, level: 0, speak: 0,
    phase: 0, pointerX: 0.3, pointerY: 0.2, hovering: 0, presence: 0
  )

  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var pipeline: MTLRenderPipelineState?
  private var uniforms: MTLBuffer?
  private var reportedFailure = false
  private var onUnavailable: (() -> Void)?

  func attach(_ view: MTKView, onUnavailable: @escaping () -> Void) {
    self.onUnavailable = onUnavailable
    guard let device = MTLCreateSystemDefaultDevice() else {
      fail()
      return
    }
    self.device = device
    view.device = device
    view.delegate = self
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 60
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = CGColor(gray: 0, alpha: 0)
    if let metal = view.layer as? CAMetalLayer {
      metal.isOpaque = false
    }
    queue = device.makeCommandQueue()
    uniforms = device.makeBuffer(length: MemoryLayout<DropletGPU>.stride, options: .storageModeShared)
    pipeline = Self.makePipeline(device: device, pixelFormat: view.colorPixelFormat)
    if pipeline == nil { fail() }
  }

  func push(_ view: MTKView) {
    view.isPaused = false
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let pipeline, let queue, let uniforms,
          let drawable = view.currentDrawable,
          let descriptor = view.currentRenderPassDescriptor
    else { return }

    let scaleX = Float(view.drawableSize.width / max(view.bounds.width, 1))
    let scaleY = Float(view.drawableSize.height / max(view.bounds.height, 1))
    var gpu = DropletGPU()
    let state = drawState
    gpu.time = state.time
    gpu.anchorX = state.anchorX * scaleX
    gpu.anchorY = state.anchorY * scaleY
    gpu.cardX = state.cardX * scaleX
    gpu.cardY = state.cardY * scaleY
    gpu.cardW = state.cardW * scaleX
    gpu.cardH = state.cardH * scaleY
    gpu.fall = state.fall
    gpu.bridge = state.bridge
    gpu.morph = state.morph
    gpu.squishX = state.squishX
    gpu.squishY = state.squishY
    gpu.level = state.level
    gpu.speak = state.speak
    gpu.phase = state.phase
    gpu.pointerX = state.pointerX
    gpu.pointerY = state.pointerY
    gpu.hovering = state.hovering
    gpu.presence = state.presence
    gpu.resolutionX = Float(view.drawableSize.width)
    gpu.resolutionY = Float(view.drawableSize.height)
    uniforms.contents().assumingMemoryBound(to: DropletGPU.self).pointee = gpu

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor)
    else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(uniforms, offset: 0, index: 0)
    enc.setFragmentBuffer(uniforms, offset: 0, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cmd.present(drawable)
    cmd.commit()
  }

  private func fail() {
    guard !reportedFailure else { return }
    reportedFailure = true
    DispatchQueue.main.async { [onUnavailable] in onUnavailable?() }
  }

  private static func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
    guard let library = try? device.makeLibrary(source: DropletShader.source, options: nil),
          let vs = library.makeFunction(name: "droplet_vertex"),
          let fs = library.makeFunction(name: "droplet_fragment")
    else { return nil }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vs
    desc.fragmentFunction = fs
    desc.colorAttachments[0].pixelFormat = pixelFormat
    desc.colorAttachments[0].isBlendingEnabled = true
    desc.colorAttachments[0].sourceRGBBlendFactor = .one
    desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    desc.colorAttachments[0].sourceAlphaBlendFactor = .one
    desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try? device.makeRenderPipelineState(descriptor: desc)
  }
}

private enum DropletShader {
  static let source = """
  #include <metal_stdlib>
  using namespace metal;

  struct Uniforms {
    float time;
    float anchorX;
    float anchorY;
    float cardX;
    float cardY;
    float cardW;
    float cardH;
    float fall;
    float bridge;
    float morph;
    float squishX;
    float squishY;
    float level;
    float speak;
    float phase;
    float pointerX;
    float pointerY;
    float hovering;
    float presence;
    float resolutionX;
    float resolutionY;
  };

  struct VertexOut {
    float4 position [[position]];
    float2 uv;
  };

  struct Scene {
    float dist;
    float2 center;
    float2 halfSize;
  };

  vertex VertexOut droplet_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(-1.0, 3.0), float2(3.0, -1.0) };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    return out;
  }

  float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + float2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
  }

  float sdCapsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
    return length(pa - ba * h) - r;
  }

  float smin(float a, float b, float k) {
    if (k <= 0.001) return min(a, b);
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
  }

  Scene evalScene(float2 p, constant Uniforms &u) {
    float m = clamp(u.morph, 0.0, 1.0);
    float over = max(u.morph - 1.0, 0.0);
    float2 outer = float2(u.cardW, u.cardH) * 0.5 * (1.0 + over * 0.04);
    float2 halfSize = mix(float2(9.0), max(outer, float2(9.0)), m);
    float corner = mix(9.0, min(28.0, min(halfSize.x, halfSize.y)), m);
    float2 cardCenter = float2(u.cardX, u.cardY) + float2(u.cardW, u.cardH) * 0.5;
    float2 landed = float2(cardCenter.x, u.cardY + halfSize.y);
    float2 gathered = float2(u.anchorX, u.anchorY + 12.0);
    float2 center = mix(gathered, landed, clamp(u.fall, 0.0, 1.0));

    float2 q = p - center;
    float sx = max(u.squishX, 0.25);
    float sy = max(u.squishY, 0.25);
    q.x /= sx;
    q.y /= sy;
    float body = sdRoundBox(q, halfSize, corner) * min(sx, sy);

    float dist = body;
    if (u.bridge > 0.004) {
      float2 neckEnd = center + float2(0.0, -halfSize.y * 0.2);
      float neckR = mix(1.15, 8.0, u.bridge);
      float cap = sdCapsule(p, float2(u.anchorX, u.anchorY), neckEnd, neckR);
      float k = mix(8.0, 46.0, u.bridge);
      dist = smin(body, cap, k);
    }
    Scene scene;
    scene.dist = dist;
    scene.center = center;
    scene.halfSize = halfSize;
    return scene;
  }

  fragment float4 droplet_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.resolutionX, (1.0 - in.uv.y) * u.resolutionY);
    Scene scene = evalScene(p, u);
    float dist = scene.dist;

    // Normals of a rounded box are constant across each face and jump
    // along the diagonals, which reads as a folded metal envelope.
    // Shade only from position so the body stays a soft black drop.
    float2 rel = (p - scene.center) / max(scene.halfSize, float2(1.0));
    float above = saturate(-rel.y);
    float lift = above * above;
    float2 drift = float2(sin(u.time * 0.31), cos(u.time * 0.23)) * 0.03;
    float2 hover = (float2(u.pointerX, u.pointerY) - float2(0.32, 0.20)) * u.hovering * 0.12;
    float2 h = (rel - float2(0.0, -0.55) - drift - hover) * float2(0.75, 1.35);
    float lobe = exp(-dot(h, h) * 0.85);

    float3 col = float3(0.015, 0.015, 0.017);
    col += float3(0.045, 0.046, 0.050) * lift;
    col += float3(0.55, 0.56, 0.58) * lobe * 0.045;

    if (u.phase > 0.5 && u.phase < 1.5) {
      float wave = sin(p.x * 0.03 + u.time * 3.4) * (1.2 + u.level * 4.0);
      float band = p.y - (scene.center.y - scene.halfSize.y * 0.04) - wave;
      float meniscus = exp(-band * band / (48.0 + u.level * 40.0));
      col += float3(0.55) * meniscus * (0.015 + u.level * 0.05);
    }

    if (u.phase > 1.5) {
      float amp = u.phase > 2.5 ? (0.02 + u.speak * 0.035) : 0.016;
      float2 c1 = scene.center + float2(sin(u.time * 0.45) * scene.halfSize.x * 0.35, cos(u.time * 0.32) * scene.halfSize.y * 0.16);
      float b1 = exp(-dot(p - c1, p - c1) / 6400.0);
      col += float3(0.62, 0.63, 0.66) * b1 * amp;
    }

    float rim = smoothstep(2.6, 0.6, abs(dist));
    col += float3(0.40, 0.41, 0.43) * rim * above * 0.05;
    col = clamp(col, 0.0, 1.0);

    float aa = mix(2.0, 1.1, clamp(u.morph, 0.0, 1.0));
    float bodyA = smoothstep(aa, -aa, dist) * u.presence;
    float glow = smoothstep(12.0, 0.0, dist) * 0.03 * u.presence;
    Scene shadowScene = evalScene(p - float2(0.0, 12.0), u);
    float shadow = smoothstep(22.0, -1.0, shadowScene.dist) * 0.32 * u.presence;

    float outA = max(bodyA, max(glow * (1.0 - bodyA), shadow * (1.0 - bodyA)));
    float3 outC = col * bodyA + float3(0.01) * glow * (1.0 - bodyA);
    return float4(outC, outA);
  }
  """
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

  func focusForTyping() {
    panel?.makeKey()
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
    session.fieldFocused = false
    session.talkArmed = false
    panel?.ignoresMouseEvents = true
    setMetalPaused(true)
    panel?.orderOut(nil)
    onClosed?()
  }

  private func setMetalPaused(_ paused: Bool) {
    guard let content = panel?.contentView else { return }
    func walk(_ view: NSView) {
      if let metal = view as? MTKView { metal.isPaused = paused }
      view.subviews.forEach(walk)
    }
    walk(content)
  }

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
#endif
