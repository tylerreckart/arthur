import AppKit
import CoreGraphics
import CoreVideo
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

  /// Grabs pixels whenever Screen Recording is already granted. `CGPreflight`
  /// can stay false for an ad-hoc build after the user has allowed capture, so
  /// a failed preflight is not a reason to skip the shot. A prompt runs only
  /// when the grab itself fails, and a grant is followed by another grab.
  static func capture() async -> DeskContext.Image? {
    if let image = await grab() { return image }
    let granted = await MainActor.run { () -> Bool in
      CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }
    guard granted else { return nil }
    return await grab()
  }

  private static func grab() async -> DeskContext.Image? {
    if let image = await snapshot(excludingOwnWindows: true) { return image }
    await MainActor.run { LookChrome.hide() }
    let image = await snapshot(excludingOwnWindows: false)
    if image != nil {
      await MainActor.run { LookChrome.show() }
    }
    return image
  }

  private static func snapshot(excludingOwnWindows: Bool) async -> DeskContext.Image? {
    if !excludingOwnWindows, let rect = await MainActor.run(body: { NSScreen.main?.frame ?? NSScreen.screens.first?.frame }) {
      if let image = try? await captureRect(rect), let jpeg = jpegData(image) {
        return DeskContext.Image(mediaType: "image/jpeg", data: jpeg.base64EncodedString())
      }
    }
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      let mainID = await MainActor.run { () -> UInt32? in
        (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      }
      let display = content.displays.first { $0.displayID == mainID } ?? content.displays.first
      guard let display else { return nil }
      let excluded = excludingOwnWindows ? ownWindows(in: content, on: display) : []
      let filter = SCContentFilter(display: display, excludingWindows: excluded)
      let scale = max(1, Double(SCShareableContent.info(for: filter).pointPixelScale))
      if let image = try? await shoot(filter: filter, display: display, pixelScale: scale),
         let jpeg = jpegData(image) {
        return DeskContext.Image(mediaType: "image/jpeg", data: jpeg.base64EncodedString())
      }
      if scale > 1.01,
         let image = try? await shoot(filter: filter, display: display, pixelScale: 1),
         let jpeg = jpegData(image) {
        return DeskContext.Image(mediaType: "image/jpeg", data: jpeg.base64EncodedString())
      }
      return nil
    } catch {
      return nil
    }
  }

  private static func ownWindows(in content: SCShareableContent, on display: SCDisplay) -> [SCWindow] {
    let pid = ProcessInfo.processInfo.processIdentifier
    let bundle = Bundle.main.bundleIdentifier
    return content.windows.filter { window in
      guard window.frame.intersects(display.frame), window.frame.width > 1, window.frame.height > 1 else {
        return false
      }
      guard let owner = window.owningApplication else { return false }
      if owner.processID == pid { return true }
      return bundle != nil && owner.bundleIdentifier == bundle
    }
  }

  /// Completion-handler form. The no-argument `captureImage` import can resolve
  /// to a void call that drops the picture.
  private static func shoot(filter: SCContentFilter, display: SCDisplay, pixelScale: Double) async throws -> CGImage {
    let config = SCStreamConfiguration()
    let pixelW = Double(display.width) * pixelScale
    let pixelH = Double(display.height) * pixelScale
    let fit = min(1, 1280 / max(max(pixelW, pixelH), 1))
    config.width = even(pixelW * fit)
    config.height = even(pixelH * fit)
    config.scalesToFit = true
    config.preservesAspectRatio = true
    config.showsCursor = true
    config.capturesAudio = false
    config.captureDynamicRange = .SDR
    config.pixelFormat = kCVPixelFormatType_32BGRA
    return try await withCheckedThrowingContinuation { continuation in
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
        if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: error ?? CocoaError(.coderReadCorrupt))
        }
      }
    }
  }

  private static func captureRect(_ rect: CGRect) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      SCScreenshotManager.captureImage(in: rect) { image, error in
        if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: error ?? CocoaError(.coderReadCorrupt))
        }
      }
    }
  }

  private static func even(_ value: Double) -> Int {
    let rounded = max(2, Int(value.rounded()))
    return rounded - (rounded % 2)
  }

  private static func jpegData(_ image: CGImage) -> Data? {
    var limit = 1280
    var current = image
    while limit >= 640 {
      let prepared = flatten(current, maxLongSide: limit) ?? current
      if let data = encode(prepared, quality: 0.55), data.count <= 700_000 { return data }
      if let data = encode(prepared, quality: 0.35), data.count <= 850_000 { return data }
      current = prepared
      limit = (limit * 3) / 4
    }
    return nil
  }

  /// 8-bit sRGB. An HDR screenshot does not encode as JPEG.
  private static func flatten(_ image: CGImage, maxLongSide: Int) -> CGImage? {
    let longSide = max(image.width, image.height)
    let scale = min(1, Double(maxLongSide) / Double(max(longSide, 1)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  private static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
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
    let path = NSBezierPath(rect: bounds.insetBy(dx: 6, dy: 6))
    path.lineWidth = 4
    NSColor.white.withAlphaComponent(0.92).setStroke()
    path.stroke()
  }
}
