import AppKit
import SwiftUI

enum ArthurTheme {
  /// Dusty periwinkle — night-sky accent on dark glass (`#8C87E0`).
  private static let accentR = 0.55
  private static let accentG = 0.53
  private static let accentB = 0.88

  static let accent = Color(red: accentR, green: accentG, blue: accentB)
  static let accentNSColor = NSColor(srgbRed: accentR, green: accentG, blue: accentB, alpha: 1)
  static let bubbleFill = Color.white.opacity(0.16)
  static let codeFill = Color.black.opacity(0.28)
}
