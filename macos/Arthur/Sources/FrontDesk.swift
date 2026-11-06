import AppKit
import ApplicationServices
import Foundation

/// Frontmost app, window title, and selected text. Call only after the user
/// opts in. When the toggle is off, nothing in here should run.
enum FrontDesk {
  static var trusted: Bool { AXIsProcessTrusted() }

  static func prompt() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func sources() -> [DeskContext.Source] {
    let app = NSWorkspace.shared.frontmostApplication
    let name = app?.localizedName ?? "Unknown"
    let pid = app?.processIdentifier ?? 0
    guard trusted, pid > 0 else {
      return [DeskContext.Source(
        name: "frontmost",
        text: DeskPresence.frontmost(app: name, window: "", trusted: false)
      )]
    }
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.25)
    let window = windowTitle(element)
    var sources = [DeskContext.Source(
      name: "frontmost",
      text: DeskPresence.frontmost(app: name, window: window, trusted: true)
    )]
    if let selected = DeskPresence.selection(selectedText(element)) {
      sources.append(DeskContext.Source(name: "selection", text: selected))
    }
    return sources
  }

  private static func windowTitle(_ app: AXUIElement) -> String {
    guard let window = copyElement(app, kAXFocusedWindowAttribute) else { return "" }
    return copyString(window, kAXTitleAttribute)
  }

  private static func selectedText(_ app: AXUIElement) -> String {
    guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return "" }
    AXUIElementSetMessagingTimeout(focused, 0.25)
    return copyString(focused, kAXSelectedTextAttribute)
  }

  private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private static func copyString(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return ""
    }
    return value as? String ?? ""
  }
}
