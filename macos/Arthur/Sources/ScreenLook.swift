import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One screenshot, taken only when the user taps Look. The white frame stays
/// up until that picture is sent with the next question.
enum ScreenLook {
  static var allowed: Bool { CGPreflightScreenCaptureAccess() }

  static func requestAccess() {
    if !CGPreflightScreenCaptureAccess() {
      CGRequestScreenCaptureAccess()
    }
  }

  static func capture() async -> DeskContext.Image? {
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      return nil
    }
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      let mainID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      let display = content.displays.first { $0.displayID == mainID } ?? content.displays.first
      guard let display else { return nil }
      let mine = content.windows.filter {
        $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
      }
      let filter = SCContentFilter(display: display, excludingWindows: mine)
      let config = SCStreamConfiguration()
      let longSide = max(display.width, display.height)
      let scale = min(1, 1280 / Double(max(longSide, 1)))
      config.width = max(1, Int((Double(display.width) * scale).rounded()))
      config.height = max(1, Int((Double(display.height) * scale).rounded()))
      config.showsCursor = true
      config.capturesAudio = false
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      guard let jpeg = jpegData(image) else { return nil }
      return DeskContext.Image(mediaType: "image/jpeg", data: jpeg.base64EncodedString())
    } catch {
      return nil
    }
  }

  private static func jpegData(_ image: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    guard var data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55]) else {
      return nil
    }
    if data.count > 700_000 {
      guard let smaller = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.35]) else {
        return nil
      }
      data = smaller
    }
    guard data.count <= 850_000 else { return nil }
    return data
  }
}

enum LookChrome {
  private static var panel: NSPanel?

  static func show() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let panel = self.panel ?? NSPanel(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    panel.setFrame(screen.frame, display: true)
    if panel.contentView as? LookFrameView == nil {
      let frame = LookFrameView(frame: NSRect(origin: .zero, size: screen.frame.size))
      frame.autoresizingMask = [.width, .height]
      panel.contentView = frame
    }
    panel.orderFrontRegardless()
    self.panel = panel
  }

  static func hide() {
    panel?.orderOut(nil)
  }
}

private final class LookFrameView: NSView {
  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    dirtyRect.fill()
    NSColor.white.withAlphaComponent(0.92).setStroke()
    let path = NSBezierPath(rect: bounds.insetBy(dx: 6, dy: 6))
    path.lineWidth = 4
    path.stroke()
  }
}
