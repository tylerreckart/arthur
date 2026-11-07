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
  /// Fades up into the corner under the menu-bar icon.
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
  /// True while `reply` is still growing. The card keeps the newest lines.
  var replyLive = false

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
    let streaming = model.streamingReply
    let replyLive = stage != .listening && !streaming.isEmpty
    let reply: String
    if stage == .listening {
      reply = ""
    } else if replyLive {
      reply = tail(streaming, 1200)
    } else if stage == .thinking {
      reply = ""
    } else {
      reply = lastArthur?.text ?? ""
    }

    let card = (stage == .listening || stage == .thinking) ? nil : lastArthur?.surfaces.last
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
      reply: replyLive ? reply : clip(reply, 700),
      noteTitle: card?.title ?? "",
      noteBody: card?.summary ?? "",
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
      attentionSummary: urgent?.summary ?? "",
      replyLive: replyLive
    )
  }

  /// Latest words, so a long live reply does not lay out from the first sentence.
  private static func tail(_ text: String, _ limit: Int) -> String {
    guard text.count > limit else { return text }
    let start = text.index(text.endIndex, offsetBy: -limit)
    let clipped = text[start...]
    guard let breakAt = clipped.firstIndex(where: { $0 == " " || $0 == "\n" }) else {
      return String(clipped)
    }
    return String(clipped[clipped.index(after: breakAt)...])
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
  /// Open, close, and drag. Paused once the card is sitting still so reply
  /// text is not re-laid-out on a 60 fps clock.
  var chromeAnimating = true
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

  func wantsChromeAnimation(at date: Date) -> Bool {
    if closing || dragging { return true }
    if date.timeIntervalSince(openBegan) < 0.42 { return true }
    if date.timeIntervalSince(dragReleasedAt) < 0.55 { return true }
    return false
  }

  func setChromeAnimating(_ on: Bool) {
    if chromeAnimating != on { chromeAnimating = on }
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
