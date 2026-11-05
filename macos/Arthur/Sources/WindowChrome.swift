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

  override func layout() {
    super.layout()
    // The sidebar titlebar segment is created when the column opens.
    paintTitlebar()
  }

  func apply() {
    guard let window, window !== appliedWindow else { return }
    appliedWindow = window
    window.isOpaque = true
    window.backgroundColor = .black
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)
    window.isMovableByWindowBackground = true
    window.contentView?.wantsLayer = true
    window.contentView?.clipsToBounds = false
    window.contentView?.layer?.isOpaque = false
    window.contentView?.layer?.masksToBounds = false
    window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    paintTitlebar()
  }

  /// The sidebar half of a split titlebar uses a lighter material than the
  /// detail. Paint every titlebar segment the same black as the desk.
  private func paintTitlebar() {
    guard let window, let close = window.standardWindowButton(.closeButton) else { return }
    var container: NSView? = close
    while let view = container, view.frame.width < window.frame.width - 1 {
      container = view.superview
    }
    guard let container else { return }
    blacken(container)
  }

  private func blacken(_ view: NSView) {
    let name = String(describing: type(of: view))
    if let effect = view as? NSVisualEffectView {
      // The material draws under sublayers. A black cover makes the sidebar
      // segment match the detail. Only configure the effect once; resetting
      // it on every layout pass restarts the sidebar animation.
      let coverName = "arthur-titlebar-black"
      if effect.layer?.sublayers?.contains(where: { $0.name == coverName }) != true {
        effect.material = .titlebar
        effect.blendingMode = .withinWindow
        effect.state = .followsWindowActiveState
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.black.cgColor
        let cover = CALayer()
        cover.name = coverName
        cover.backgroundColor = NSColor.black.cgColor
        cover.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        cover.frame = effect.bounds
        effect.layer?.addSublayer(cover)
      }
      effect.layer?.sublayers?.first { $0.name == coverName }?.frame = effect.bounds
    } else if name.contains("Titlebar") || name.contains("Toolbar") {
      view.wantsLayer = true
      view.layer?.backgroundColor = NSColor.black.cgColor
    }
    view.subviews.forEach(blacken)
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

/// Fade content as it slides under the title bar, continuously in Y.
///
/// `View.visualEffect` hands the closure an `EmptyVisualEffect`, which has
/// no `.mask` (macOS 26). Applying the gradient as a `View` mask keeps the
/// chrome-Y fade: the upper part of a bubble in `fadeBand` softens, text
/// below the band stays solid. Selection and markdown stay intact.
struct FadeUnderHeader: ViewModifier {
  func body(content: Content) -> some View {
    content.mask {
      GeometryReader { proxy in
        let frame = proxy.frame(in: ArthurChrome.space)
        let height = max(proxy.size.height, 1)
        let startY = (0 - frame.minY) / height
        let endY = (ArthurChrome.fadeBand - frame.minY) / height
        LinearGradient(
          stops: [
            .init(color: .black.opacity(0.06), location: 0),
            .init(color: .black.opacity(0.45), location: 0.42),
            .init(color: .black, location: 1),
          ],
          startPoint: UnitPoint(x: 0.5, y: startY),
          endPoint: UnitPoint(x: 0.5, y: endY)
        )
      }
    }
  }
}

extension View {
  func fadeUnderHeader() -> some View {
    modifier(FadeUnderHeader())
  }
}
