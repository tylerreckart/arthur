import AppKit
import SwiftUI

enum ArthurTheme {
  /// The desk window matches the droplet: pure black, white type, no chrome.
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
  /// A slightly lifted black plate with a subtle rim so it reads on black.
  func arthurPlate(radius: CGFloat = 16) -> some View {
    background(
      Color.white.opacity(0.05),
      in: RoundedRectangle(cornerRadius: radius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
    }
  }
}
