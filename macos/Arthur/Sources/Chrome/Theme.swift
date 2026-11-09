import AppKit
import SwiftUI

enum ArthurTheme {
  /// Droplet and card colors. The window uses the system appearance.
  static let accent = Color.white
  static let accentNSColor = NSColor.white
  static let ink = Color.black
  static let paper = Color.white.opacity(0.92)
  static let mute = Color.white.opacity(0.55)
  static let whisper = Color.white.opacity(0.55)
  static let error = Color(red: 0.86, green: 0.40, blue: 0.42)
  static let bubbleFill = Color.white.opacity(0.05)
  static let codeFill = Color.white.opacity(0.06)
}

extension View {
  /// Liquid Glass plate for a card that floats on the desk or droplet.
  /// The system draws the edge, so this does not add a fill or stroke.
  /// `tint` washes the glass with a card color. It is not a second fill.
  func arthurPlate(radius: CGFloat = 20, tint: Color? = nil) -> some View {
    let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
    return glassEffect(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }

  /// A link that stays in the card's text color instead of the system accent.
  func arthurQuietLink() -> some View {
    buttonStyle(.plain).tint(.primary)
  }

  /// Primary card actions take prominent glass. Secondary actions stay regular.
  func arthurAction(prominent: Bool) -> some View {
    modifier(ArthurActionStyle(prominent: prominent))
  }
}

/// State label on a status card. A solid capsule, not a second glass layer.
struct ArthurStatusChip: View {
  var label: String
  var urgent = false

  var body: some View {
    Text(label)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .foregroundStyle(urgent ? Color.white : Color.primary)
      .background(urgent ? ArthurTheme.error : Color.primary.opacity(0.14), in: Capsule())
      .accessibilityLabel("State: \(label)")
  }
}

private struct ArthurActionStyle: ViewModifier {
  var prominent: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if prominent {
      content.buttonStyle(.glassProminent)
    } else {
      content.buttonStyle(.glass)
    }
  }
}
