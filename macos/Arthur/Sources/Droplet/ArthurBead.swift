import AppKit
import SwiftUI

// MARK: - Bead

struct ArthurBead: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var bead: BeadState
  var diameter: CGFloat = 16

  private var animating: Bool {
    !reduceMotion && (bead.listening || bead.thinking || bead.speaking || bead.dripping || bead.connected)
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { context in
      mark(time: context.date.timeIntervalSinceReferenceDate)
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
