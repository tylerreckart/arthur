import AppKit
import SwiftUI

// MARK: - Brand mark

/// The Arthur mark — the rounded "a", white on a black squircle.
///
/// The path data is verbatim from the brand SVG
/// (`Assets/arthur.icon/Assets/arthur.svg`, the same file Icon Composer
/// uses for the app icon). Keep the two in sync: edit the SVG first,
/// then paste its `d` attribute here.
enum ArthurMark {
  /// SVG path data, absolute commands only (M L H V C Z), viewBox 160 × 160.
  static let pathData =
    "M160 106.667C160 128.528 160 139.459 154.575 147.207"
    + "C152.567 150.074 150.074 152.567 147.207 154.575"
    + "C139.459 160 128.528 160 106.667 160H56.6667"
    + "C31.6095 160 19.0809 160 10.7164 152.981"
    + "C9.37852 151.859 8.14125 150.621 7.01867 149.284"
    + "C0 140.919 0 128.391 0 103.333V88.4012"
    + "C0 80.9999 5.99993 75 13.4012 75"
    + "C17.5619 75 21.4865 76.9325 24.0233 80.2303L65.9766 134.77"
    + "C68.5135 138.067 72.4381 140 76.5988 140"
    + "C84.0001 140 90 134 90 126.599V111.667"
    + "C90 86.6095 90 74.0809 82.9813 65.7164"
    + "C81.8587 64.3785 80.6215 63.1413 79.2836 62.0187"
    + "C70.9191 55 58.3905 55 33.3333 55H18.3333"
    + "C15.2362 55 13.6877 55 12.3953 54.7721"
    + "C6.1851 53.6771 1.3229 48.8149 0.227884 42.6047"
    + "C0 41.3123 0 39.7638 0 36.6667"
    + "C0 30.4724 0 27.3753 0.455767 24.7906"
    + "C2.64581 12.3702 12.3702 2.64581 24.7906 0.455767"
    + "C27.3753 0 30.4724 0 36.6667 0H53.3333"
    + "C97.0564 0 118.918 0 134.415 10.8509"
    + "C140.148 14.8654 145.135 19.8521 149.149 25.5854"
    + "C160 41.0821 160 62.9436 160 106.667Z"

  static let viewBox = CGSize(width: 160, height: 160)

  /// The glyph fitted into `rect`, centered and preserving aspect.
  ///
  /// `flipY`: SwiftUI and SVG share y-down coordinates; CoreGraphics
  /// bitmaps are y-up, so callers drawing with CGContext pass `true`.
  static func glyphPath(in rect: CGRect, flipY: Bool = false) -> CGPath {
    let aspect = viewBox.width / max(viewBox.height, 1)
    var fit = CGRect(origin: .zero, size: rect.size)
    if rect.width / max(rect.height, 1) > aspect {
      fit.size.width = rect.height * aspect
      fit.origin.x = (rect.width - fit.width) / 2
    } else {
      fit.size.height = rect.width / aspect
      fit.origin.y = (rect.height - fit.height) / 2
    }
    let sx = fit.width / viewBox.width
    let sy = fit.height / viewBox.height
    let ox = rect.minX + fit.minX
    let oy = rect.minY + fit.minY
    // X = ox + x·sx; Y = oy + y·sy, or with the y-axis flipped,
    // Y = oy + (viewBox.height − y)·sy.
    var affine = flipY
      ? CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: ox, ty: oy + viewBox.height * sy)
      : CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: ox, ty: oy)
    return parse(pathData).copy(using: &affine) ?? parse(pathData)
  }

  /// Parses absolute-command SVG path data (M L H V C Z) into a CGPath.
  static func parse(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var cursor = CGPoint.zero
    var subpathStart = CGPoint.zero
    var index = d.startIndex

    func number() -> CGFloat? {
      guard index < d.endIndex else { return nil }
      while index < d.endIndex, d[index] == " " || d[index] == "," { index = d.index(after: index) }
      let start = index
      while index < d.endIndex,
            d[index].isNumber || d[index] == "." || d[index] == "-" || d[index] == "e" {
        index = d.index(after: index)
      }
      guard start < index, let value = Double(d[start..<index]) else { return nil }
      return CGFloat(value)
    }

    func point() -> CGPoint? {
      guard let x = number(), let y = number() else { return nil }
      return CGPoint(x: x, y: y)
    }

    while index < d.endIndex {
      let command = d[index]
      index = d.index(after: index)
      switch command {
      case "M":
        guard let p = point() else { continue }
        path.move(to: p)
        cursor = p
        subpathStart = p
      case "L":
        guard let p = point() else { continue }
        path.addLine(to: p)
        cursor = p
      case "H":
        guard let x = number() else { continue }
        path.addLine(to: CGPoint(x: x, y: cursor.y))
        cursor.x = x
      case "V":
        guard let y = number() else { continue }
        path.addLine(to: CGPoint(x: cursor.x, y: y))
        cursor.y = y
      case "C":
        guard let c1 = point(), let c2 = point(), let p = point() else { continue }
        path.addCurve(to: p, control1: c1, control2: c2)
        cursor = p
      case "Z":
        path.closeSubpath()
        cursor = subpathStart
      default:
        continue
      }
    }
    return path
  }
}

/// The white "a" as a SwiftUI shape (y-down, like the SVG).
struct ArthurGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    Path(ArthurMark.glyphPath(in: rect))
  }
}

/// The brand mark: the SVG glyph on a black squircle.
struct ArthurMarkTile: View {
  var size: CGFloat
  /// Glyph margin inside the tile, as a fraction of the tile.
  var inset: CGFloat = 0.09
  /// Corner radius as a fraction of the tile.
  var corner: CGFloat = 0.24
  var glyphOpacity: Double = 1
  var rimOpacity: Double = 0.12
  var shadows = true

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * corner, style: .continuous)
        .fill(Color.black)
      ArthurGlyph()
        .fill(Color.white.opacity(glyphOpacity))
        .padding(size * inset)
      RoundedRectangle(cornerRadius: size * corner, style: .continuous)
        .strokeBorder(Color.white.opacity(rimOpacity), lineWidth: max(0.5, size * 0.035))
    }
    .frame(width: size, height: size)
    .shadow(
      color: shadows ? .black.opacity(0.32) : .clear,
      radius: shadows ? size * 0.11 : 0,
      y: shadows ? size * 0.05 : 0
    )
    .accessibilityHidden(true)
  }
}

// MARK: - Bead snapshot

enum BeadClock {
  private static let start = CACurrentMediaTime()
  static var time: Float { Float(CACurrentMediaTime() - start) }
}

/// The menu-bar bead as an NSImage. A status item wants an NSImage, so
/// the vector mark is painted offscreen — black tile, white glyph, with
/// the same state behavior as the SwiftUI bead.
enum BeadSnapshot {
  @MainActor
  static func image(bead: BeadState, points: CGFloat, scale: CGFloat) -> NSImage? {
    let pixels = max(1, Int((points * scale).rounded()))
    guard let ctx = CGContext(
      data: nil,
      width: pixels,
      height: pixels,
      bitsPerComponent: 8,
      bytesPerRow: pixels * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }

    let time = BeadClock.time
    let listening = bead.listening
    let level = min(1, max(0, bead.level))
    let breath = (bead.thinking || bead.speaking)
      ? 0.5 + 0.5 * sin(Double(time) * (bead.speaking ? 2.3 : 1.05))
      : 0
    let pulse = 1.0
      + (listening ? 0.035 * level + 0.012 * sin(Double(time) * 4.6) : 0)
      + (bead.dripping ? 0.05 * sin(Double(time) * 7.2) : 0)
      + 0.008 * breath
    let side = CGFloat(pixels)
    let tileSide = side * 0.94 * CGFloat(pulse)
    let tile = CGRect(
      x: (side - tileSide) / 2,
      y: (side - tileSide) / 2,
      width: tileSide,
      height: tileSide
    )
    let corner = tileSide * 0.24

    // SVG space is y-down; the bitmap is y-up.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)

    if listening {
      // A soft white halo that lifts with your voice.
      ctx.setShadow(
        offset: .zero,
        blur: 2 + 7 * level,
        color: CGColor(gray: 1.0, alpha: 0.22 + 0.4 * level)
      )
    }
    let rounded = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(rounded)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let inset = tile.insetBy(dx: tile.width * 0.09, dy: tile.height * 0.09)
    let glyph = ArthurMark.glyphPath(in: inset)
    let glyphAlpha = CGFloat(
      0.88 + 0.12 * breath + (listening ? 0.1 : 0)
    )
    ctx.setFillColor(CGColor(gray: 1, alpha: min(1, glyphAlpha)))
    ctx.addPath(glyph)
    ctx.fillPath()

    let rimAlpha = bead.connected ? 0.22 : 0.12
    ctx.setStrokeColor(CGColor(gray: 1, alpha: rimAlpha))
    ctx.setLineWidth(max(1, CGFloat(pixels) * 0.035))
    ctx.addPath(rounded)
    ctx.strokePath()
    ctx.restoreGState()

    guard let cg = ctx.makeImage() else { return nil }
    let image = NSImage(cgImage: cg, size: NSSize(width: points, height: points))
    image.isTemplate = false
    return image
  }

  static func fallback(points: CGFloat) -> NSImage {
    let size = NSSize(width: points, height: points)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: points, height: points).insetBy(dx: 0.5, dy: 0.5)
    let tile = NSBezierPath(
      roundedRect: rect,
      xRadius: points * 0.24,
      yRadius: points * 0.24
    )
    NSColor.black.setFill()
    tile.fill()
    if let ctx = NSGraphicsContext.current?.cgContext {
      ctx.saveGState()
      ctx.translateBy(x: 0, y: points)
      ctx.scaleBy(x: 1, y: -1)
      ctx.setFillColor(CGColor(gray: 1, alpha: 1))
      ctx.addPath(ArthurMark.glyphPath(in: rect.insetBy(dx: points * 0.09, dy: points * 0.09)))
      ctx.fillPath()
      ctx.restoreGState()
    }
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let rim = NSBezierPath(
      roundedRect: rect.insetBy(dx: 0.4, dy: 0.4),
      xRadius: points * 0.24,
      yRadius: points * 0.24
    )
    rim.lineWidth = 0.7
    rim.stroke()
    image.unlockFocus()
    image.isTemplate = false
    return image
  }
}
