import AppKit
import Carbon

/// Global push-to-talk shortcut. Default is ⌥Space — a configurable
/// `UserDefaults` pair (`arthur.pttKeyCode`, `arthur.pttModifierFlags`).
///
/// Registered with `RegisterEventHotKey`, which delivers press *and* release
/// without Accessibility or Input Monitoring. Those TCC prompts are only
/// needed if this API fails and Arthur falls back to `NSEvent` global
/// key monitors.
struct PTTHotkey: Hashable, Identifiable {
  var keyCode: UInt16
  var modifierFlags: NSEvent.ModifierFlags

  var id: String { "\(keyCode)-\(modifierFlags.intersection(Self.pttMask).rawValue)" }

  static func == (lhs: PTTHotkey, rhs: PTTHotkey) -> Bool {
    lhs.keyCode == rhs.keyCode
      && lhs.modifierFlags.intersection(Self.pttMask) == rhs.modifierFlags.intersection(Self.pttMask)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(keyCode)
    hasher.combine(modifierFlags.intersection(Self.pttMask).rawValue)
  }

  static let optionSpace = PTTHotkey(keyCode: 49, modifierFlags: .option)
  static let controlSpace = PTTHotkey(keyCode: 49, modifierFlags: .control)
  static let optionCommandSpace = PTTHotkey(keyCode: 49, modifierFlags: [.option, .command])

  static let presets: [PTTHotkey] = [.optionSpace, .controlSpace, .optionCommandSpace]
  static let pttMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

  var display: String {
    var parts: [String] = []
    let mods = modifierFlags.intersection(Self.pttMask)
    if mods.contains(.control) { parts.append("⌃") }
    if mods.contains(.option) { parts.append("⌥") }
    if mods.contains(.shift) { parts.append("⇧") }
    if mods.contains(.command) { parts.append("⌘") }
    parts.append(keyName)
    return parts.joined()
  }

  var keyName: String {
    switch keyCode {
    case 49: return "Space"
    default: return "Key \(keyCode)"
    }
  }

  var carbonModifiers: UInt32 {
    var bits: UInt32 = 0
    let mods = modifierFlags.intersection(Self.pttMask)
    if mods.contains(.command) { bits |= UInt32(cmdKey) }
    if mods.contains(.option) { bits |= UInt32(optionKey) }
    if mods.contains(.shift) { bits |= UInt32(shiftKey) }
    if mods.contains(.control) { bits |= UInt32(controlKey) }
    return bits
  }

  func matches(_ event: NSEvent) -> Bool {
    event.keyCode == keyCode
      && event.modifierFlags.intersection(Self.pttMask) == modifierFlags.intersection(Self.pttMask)
  }

  static func load() -> PTTHotkey {
    guard let stored = ConfigStore.loadPTTHotkey() else { return .optionSpace }
    return PTTHotkey(
      keyCode: stored.keyCode,
      modifierFlags: NSEvent.ModifierFlags(rawValue: stored.modifiers)
    )
  }

  func persist() {
    ConfigStore.savePTTHotkey(keyCode: keyCode, modifiers: modifierFlags.intersection(Self.pttMask).rawValue)
  }
}
