import AppKit
import SwiftUI

struct WindowTransparency: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowTransparencyView {
    WindowTransparencyView()
  }

  func updateNSView(_ view: WindowTransparencyView, context: Context) {
    view.apply()
  }
}

final class WindowTransparencyView: NSView {
  override var isOpaque: Bool { false }
  private weak var appliedWindow: NSWindow?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    apply()
  }

  func apply() {
    guard let window, window !== appliedWindow else { return }
    appliedWindow = window
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)
    window.isMovableByWindowBackground = true
    window.contentView?.wantsLayer = true
    window.contentView?.clipsToBounds = false
    window.contentView?.layer?.isOpaque = false
    window.contentView?.layer?.masksToBounds = false
    window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
  }
}

struct ScrollEdgeEnabler: NSViewRepresentable {
  func makeNSView(context: Context) -> ScrollEdgeEnablerView {
    ScrollEdgeEnablerView()
  }

  func updateNSView(_ view: ScrollEdgeEnablerView, context: Context) {
    view.enable()
  }
}

final class ScrollEdgeEnablerView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    enable()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    enable()
  }

  func enable() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let scroll = self.enclosingScrollView ?? self.findScrollView() {
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = true
      }
    }
  }

  private func findScrollView() -> NSScrollView? {
    var view: NSView? = superview
    while let current = view {
      if let scroll = current as? NSScrollView { return scroll }
      view = current.superview
    }
    return window?.contentView.flatMap { search($0) }
  }

  private func search(_ root: NSView) -> NSScrollView? {
    if let scroll = root as? NSScrollView { return scroll }
    for child in root.subviews {
      if let found = search(child) { return found }
    }
    return nil
  }
}

struct WindowGlassBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSGlassEffectView {
    let glass = NSGlassEffectView()
    glass.style = .regular
    glass.cornerRadius = 0
    return glass
  }

  func updateNSView(_ glass: NSGlassEffectView, context: Context) {}
}

enum ArthurChrome {
  static let space = NamedCoordinateSpace.named("arthurChrome")
  static let fadeBand: CGFloat = 48
}

/// Soften a row as it slides under the title bar. Kept mild so whole
/// paragraphs do not jump to a ghost.
struct FadeUnderHeader: ViewModifier {
  func body(content: Content) -> some View {
    content.visualEffect { inner, proxy in
      let frame = proxy.frame(in: ArthurChrome.space)
      let band = ArthurChrome.fadeBand
      let linear = max(0, min(1, (band - frame.minY) / band))
      let overflow = max(0, frame.maxY - band)
      let atten = max(0, 1 - overflow / 48)
      let t = linear * linear * (3 - 2 * linear) * atten
      return inner
        .blur(radius: t * 5, opaque: false)
        .opacity(1 - t * 0.28)
    }
  }
}

extension View {
  func fadeUnderHeader() -> some View {
    modifier(FadeUnderHeader())
  }
}
