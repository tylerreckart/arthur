import AppKit
import SwiftUI

// MARK: - Panel

final class DropletPanel: NSPanel {
  weak var host: DropletHostingView?
  private var passingThrough = false

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Clicks outside the card go to the menu-bar icon.
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      if !passingThrough, let host {
        let point: NSPoint
        if let superview = host.superview {
          point = superview.convert(event.locationInWindow, from: nil)
        } else {
          point = event.locationInWindow
        }
        if host.hitTest(point) == nil {
          passingThrough = true
          ignoresMouseEvents = true
          NSApp.postEvent(event, atStart: true)
          DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
              guard let self else { return }
              self.passingThrough = false
              if self.isVisible { self.ignoresMouseEvents = false }
            }
          }
          return
        }
      }
    default:
      break
    }
    super.sendEvent(event)
  }
}

@MainActor
final class DropletController {
  let session = DropletSession()
  var onClosed: (() -> Void)?
  private(set) var onScreen = false
  private(set) var acceptsHits = false
  private(set) var cardScreenRect: NSRect = .zero
  private var cardInPanel: NSRect = .zero
  private var panel: DropletPanel?

  func show(anchor: NSRect, drip: Bool) {
    if panel == nil { build() }
    let wasClosing = session.closing
    session.closing = false
    if drip || !onScreen || wasClosing {
      session.openBegan = Date()
      session.chromeAnimating = true
      session.talkArmed = false
    }
    onScreen = true
    acceptsHits = true
    setMetalPaused(false)
    place(anchor: anchor)
    panel?.ignoresMouseEvents = false
    panel?.orderFrontRegardless()
  }

  func hideAnimated() {
    guard onScreen, !session.closing else {
      if !onScreen { finishClose() }
      return
    }
    session.closing = true
    session.chromeAnimating = true
    session.closeBegan = Date()
    session.closeToken += 1
    session.releaseTalk()
  }

  func hideImmediate() {
    session.closing = false
    session.closeToken += 1
    finishClose()
  }

  func update(_ content: DropletContent) {
    guard content != session.content else { return }
    session.content = content
  }

  func place(anchor: NSRect) {
    guard let panel else { return }
    let size = DropletMetrics.panelSize
    let screen = screen(containing: anchor) ?? NSScreen.main
    let vis = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let x = vis.maxX - size.width - 12
    let y = vis.minY + 12
    let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    if abs(panel.frame.minX - frame.minX) > 0.5 || abs(panel.frame.minY - frame.minY) > 0.5
        || panel.frame.size != frame.size {
      panel.setFrame(frame, display: true)
    }
    if cardInPanel.width < 1 {
      let width = DropletMetrics.cardWidth
      let height = max(session.cardHeight, 96)
      let margin = DropletMetrics.cornerMargin
      cardInPanel = NSRect(
        x: size.width - width - margin,
        y: size.height - height - margin,
        width: width,
        height: height
      )
    }
    noteCardInPanel(cardInPanel)
  }

  private func noteCardInPanel(_ rect: NSRect) {
    cardInPanel = rect
    guard let panel, rect.width > 1, rect.height > 1 else { return }
    let screen = NSRect(
      x: panel.frame.minX + rect.minX,
      y: panel.frame.maxY - rect.maxY,
      width: rect.width,
      height: rect.height
    )
    if abs(cardScreenRect.minX - screen.minX) < 0.5,
       abs(cardScreenRect.minY - screen.minY) < 0.5,
       abs(cardScreenRect.width - screen.width) < 0.5,
       abs(cardScreenRect.height - screen.height) < 0.5 {
      return
    }
    cardScreenRect = screen
  }

  private func build() {
    let size = DropletMetrics.panelSize
    let panel = DropletPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovable = false
    panel.animationBehavior = .none
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    let host = DropletHostingView(rootView: DropletCardRoot(session: session))
    host.frame = NSRect(origin: .zero, size: size)
    host.autoresizingMask = [.width, .height]
    host.cardScreenRect = { [weak self] in self?.cardScreenRect ?? .zero }
    host.acceptsHits = { [weak self] in self?.acceptsHits ?? false }
    panel.host = host
    panel.contentView = host
    session.actions.setAcceptsHits = { [weak self] on in
      guard let self, self.acceptsHits != on else { return }
      self.acceptsHits = on
      self.panel?.ignoresMouseEvents = !on
    }
    session.actions.cardFrame = { [weak self] rect in
      self?.noteCardInPanel(rect)
    }
    session.actions.didFinishClose = { [weak self] in
      self?.finishClose()
    }
    self.panel = panel
  }

  private func finishClose() {
    onScreen = false
    acceptsHits = false
    cardScreenRect = .zero
    cardInPanel = .zero
    session.closing = false
    session.hovering = false
    session.talkArmed = false
    panel?.ignoresMouseEvents = true
    setMetalPaused(true)
    panel?.orderOut(nil)
    onClosed?()
  }

  private func setMetalPaused(_ paused: Bool) {}

  private func screen(containing rect: NSRect) -> NSScreen? {
    let mid = CGPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.first { $0.frame.contains(mid) }
  }
}

final class DropletHostingView: NSHostingView<DropletCardRoot> {
  var cardScreenRect: () -> NSRect = { .zero }
  var acceptsHits: () -> Bool = { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard acceptsHits() else { return nil }
    let local = convert(point, from: superview)
    if let catcher = Self.closeCatcher(in: self, at: local) {
      return catcher
    }
    guard let window else { return nil }
    let windowPoint = convert(local, to: nil)
    let screenPoint = window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
    let rect = cardScreenRect().insetBy(dx: -10, dy: -16)
    guard rect.width > 20, rect.contains(screenPoint) else { return nil }
    return super.hitTest(point)
  }

  /// The close control sits in the card's top corner. Prefer it even when the
  /// settled card rect has not caught up, so the xmark is not passed through.
  private static func closeCatcher(in view: NSView, at point: NSPoint) -> CloseCatcherView? {
    for subview in view.subviews.reversed() {
      let local = subview.convert(point, from: view)
      guard subview.bounds.contains(local) else { continue }
      if let catcher = subview as? CloseCatcherView { return catcher }
      if let found = closeCatcher(in: subview, at: local) { return found }
    }
    return nil
  }
}
