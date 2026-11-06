import AppKit
import Carbon
import SwiftUI

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

/// Menu-bar droplet, global PTT hotkey, and the card that falls open from it.
/// Calls `AppModel.talkPressed` / `talkReleased` — the same path as in-window Space.
@MainActor
final class DeskAccessory: NSObject, NSMenuDelegate {
  static let shared = DeskAccessory()

  private static let carbonSignature = OSType(0x41525448) // 'ARTH'
  private static let carbonHotKeyID: UInt32 = 1

  private weak var model: AppModel?
  private var openWindow: (() -> Void)?

  private var statusItem: NSStatusItem?
  private var menu: NSMenu?
  private var muteItem: NSMenuItem?
  private var holdView: HoldTalkMenuView?

  private var holdWork: DispatchWorkItem?
  private var talkingFromStatus = false
  private var statusPressActive = false
  private var pressMonitors: [Any] = []

  private var carbonHandler: EventHandlerRef?
  private var carbonHotKey: EventHotKeyRef?
  private var globalKeyMonitors: [Any] = []
  private(set) var usingInputMonitoringFallback = false

  let bead = BeadState()
  private let droplet = DropletController()
  private var beadTimer: Timer?
  private var toolbarAnchor: NSRect = .zero
  private var usingToolbarAnchor = false
  private var cardPinned = false
  private var cardFollowing = false
  private var dismissWork: DispatchWorkItem?
  private var dripWork: DispatchWorkItem?
  private var outsideMonitors: [Any] = []
  private var watching = false
  private var attached = false

  private override init() {
    super.init()
  }

  func attach(model: AppModel, openWindow: @escaping () -> Void) {
    self.model = model
    self.openWindow = openWindow
    guard !attached else {
      registerHotkey(model.pttHotkey)
      return
    }
    attached = true
    installStatusItem()
    registerHotkey(model.pttHotkey)
    startWatching()
  }

  func detach() {
    unregisterHotkey()
    if let carbonHandler {
      RemoveEventHandler(carbonHandler)
    }
    carbonHandler = nil
    removePressMonitors()
    holdWork?.cancel()
    holdWork = nil
    dripWork?.cancel()
    dripWork = nil
    cancelDismiss()
    removeOutsideMonitors()
    droplet.hideImmediate()
    beadTimer?.invalidate()
    beadTimer = nil
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
    menu = nil
    muteItem = nil
    holdView = nil
    attached = false
    watching = false
  }

  func revealMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    let existing = NSApp.windows.first { window in
      !(window is NSPanel) && window.level == .normal
    }
    if let existing {
      if existing.isMiniaturized { existing.deminiaturize(nil) }
      existing.makeKeyAndOrderFront(nil)
      return
    }
    openWindow?()
  }

  func registerHotkey(_ hotkey: PTTHotkey) {
    unregisterHotkey()
    ensureCarbonHandler()
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.carbonSignature, id: Self.carbonHotKeyID)
    let status = RegisterEventHotKey(
      UInt32(hotkey.keyCode),
      hotkey.carbonModifiers,
      id,
      GetApplicationEventTarget(),
      0,
      &ref
    )
    if status == noErr, ref != nil {
      carbonHotKey = ref
      usingInputMonitoringFallback = false
      return
    }
    installKeyMonitorFallback(hotkey)
  }

  /// C callback trampoline — hops to the main actor. Do not capture.
  nonisolated func receiveCarbonHotKey(kind: UInt32) {
    Task { [weak self] in
      await MainActor.run {
        self?.applyCarbonHotKey(kind: kind)
      }
    }
  }

  private func applyCarbonHotKey(kind: UInt32) {
    if kind == UInt32(kEventHotKeyPressed) {
      model?.talkPressed()
    } else if kind == UInt32(kEventHotKeyReleased) {
      model?.talkReleased()
    }
  }

  private func ensureCarbonHandler() {
    guard carbonHandler == nil else { return }
    var types = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    var handler: EventHandlerRef?
    let installed = types.withUnsafeMutableBufferPointer { buffer in
      InstallEventHandler(
        GetApplicationEventTarget(),
        arthurHotKeyHandler,
        2,
        buffer.baseAddress,
        Unmanaged.passUnretained(self).toOpaque(),
        &handler
      )
    }
    if installed == noErr {
      carbonHandler = handler
    }
  }

  private func unregisterHotkey() {
    if let carbonHotKey {
      UnregisterEventHotKey(carbonHotKey)
    }
    carbonHotKey = nil
    for monitor in globalKeyMonitors {
      NSEvent.removeMonitor(monitor)
    }
    globalKeyMonitors.removeAll()
    usingInputMonitoringFallback = false
  }

  /// Last-resort path. Global *keyboard* monitors require Input Monitoring
  /// (System Settings → Privacy & Security). Mouse monitors do not.
  private func installKeyMonitorFallback(_ hotkey: PTTHotkey) {
    usingInputMonitoringFallback = true
    let down = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, hotkey.matches(event), !event.isARepeat else { return }
      Task { @MainActor in self.model?.talkPressed() }
    }
    let up = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
      guard let self, hotkey.matches(event) else { return }
      Task { @MainActor in self.model?.talkReleased() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      guard let self, hotkey.matches(event) else { return event }
      if event.type == .keyDown {
        if event.isARepeat { return nil }
        Task { @MainActor in self.model?.talkPressed() }
      } else {
        Task { @MainActor in self.model?.talkReleased() }
      }
      return nil
    }
    if let down { globalKeyMonitors.append(down) }
    if let up { globalKeyMonitors.append(up) }
    if let local { globalKeyMonitors.append(local) }
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: 22)
    if let button = item.button {
      button.title = ""
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleNone
      button.toolTip = "Arthur — click to open, hold to talk. Right-click for the menu."
      button.setAccessibilityTitle("Arthur")
      button.setAccessibilityHelp("Click to open Arthur. Hold to talk. Right-click for the menu. Default shortcut is Option-Space.")
      button.target = self
      button.action = #selector(statusButtonEvent(_:))
      button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
    }
    statusItem = item
    menu = buildMenu()
    wireDroplet()
    refreshStatusImage()
  }

  /// The status item is a template glyph. The toolbar bead keeps the squircle plate.
  private func refreshStatusImage(fromTimer: Bool = false) {
    let animating = bead.listening || bead.thinking || bead.speaking || bead.dripping || bead.connected
    if fromTimer || beadTimer == nil || !animating {
      paintStatusImage()
    }
    if animating {
      guard beadTimer == nil else { return }
      let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshStatusImage(fromTimer: true) }
      }
      beadTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    } else {
      beadTimer?.invalidate()
      beadTimer = nil
    }
  }

  private func paintStatusImage() {
    guard let button = statusItem?.button else { return }
    let side: CGFloat = 16
    let renderer = ImageRenderer(
      content: ArthurGlyph()
        .fill(Color.black)
        .frame(width: side, height: side)
    )
    renderer.scale = button.window?.backingScaleFactor ?? 2
    renderer.proposedSize = ProposedViewSize(width: side, height: side)
    renderer.isOpaque = false
    if let image = renderer.nsImage {
      image.isTemplate = true
      image.size = NSSize(width: side, height: side)
      button.image = image
    }
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu(title: "Arthur")
    menu.delegate = self

    let open = NSMenuItem(title: "Open Arthur", action: #selector(openArthurAction), keyEquivalent: "")
    open.target = self
    menu.addItem(open)

    let hold = NSMenuItem()
    let view = HoldTalkMenuView(shortcut: model?.pttHotkey.display ?? PTTHotkey.optionSpace.display)
    view.onDown = { [weak self] in self?.model?.talkPressed() }
    view.onUp = { [weak self] in self?.model?.talkReleased() }
    hold.view = view
    holdView = view
    menu.addItem(hold)

    menu.addItem(.separator())

    let mute = NSMenuItem(title: muteTitle, action: #selector(toggleMuteAction), keyEquivalent: "")
    mute.target = self
    muteItem = mute
    menu.addItem(mute)

    menu.addItem(.separator())

    let quit = NSMenuItem(title: "Quit Arthur", action: #selector(quitAction), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    return menu
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    muteItem?.title = muteTitle
    holdView?.shortcut = model?.pttHotkey.display ?? PTTHotkey.optionSpace.display
    holdView?.enabled = model?.canTalk == true || model?.holding == true
  }

  private var muteTitle: String {
    (model?.soundOn ?? true) ? "Mute Sound" : "Unmute Sound"
  }

  @objc private func statusButtonEvent(_ sender: Any?) {
    guard let event = NSApp.currentEvent else { return }
    switch event.type {
    case .leftMouseDown:
      beginStatusPress()
    case .leftMouseUp:
      finishStatusPress()
    case .rightMouseUp:
      cancelStatusPress()
      popMenu()
    default:
      break
    }
  }

  private func beginStatusPress() {
    cancelStatusPress()
    statusPressActive = true
    talkingFromStatus = false
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.statusPressActive else { return }
      self.talkingFromStatus = true
      self.model?.talkPressed()
      self.present(
        anchor: self.menuBarAnchor,
        fromToolbar: false,
        drip: false,
        pinned: false,
        follow: true
      )
    }
    holdWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)

    let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      Task { @MainActor in self?.finishStatusPress() }
      return event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
      Task { @MainActor in self?.finishStatusPress() }
    }
    if let local { pressMonitors.append(local) }
    if let global { pressMonitors.append(global) }
  }

  private func finishStatusPress() {
    guard statusPressActive else { return }
    statusPressActive = false
    let wasTalking = talkingFromStatus
    holdWork?.cancel()
    holdWork = nil
    talkingFromStatus = false
    removePressMonitors()
    if wasTalking {
      model?.talkReleased()
    } else {
      toggle(anchor: menuBarAnchor, fromToolbar: false)
    }
  }

  private func cancelStatusPress() {
    holdWork?.cancel()
    holdWork = nil
    statusPressActive = false
    if talkingFromStatus {
      talkingFromStatus = false
      model?.talkReleased()
    }
    removePressMonitors()
  }

  private func removePressMonitors() {
    for monitor in pressMonitors {
      NSEvent.removeMonitor(monitor)
    }
    pressMonitors.removeAll()
  }

  private func popMenu() {
    guard let button = statusItem?.button, let menu else { return }
    menuNeedsUpdate(menu)
    let point = NSPoint(x: 0, y: button.bounds.height + 4)
    menu.popUp(positioning: nil, at: point, in: button)
  }

  @objc private func openArthurAction() {
    revealMainWindow()
  }

  @objc private func toggleMuteAction() {
    model?.soundOn.toggle()
  }

  @objc private func quitAction() {
    NSApp.terminate(nil)
  }

  private func startWatching() {
    guard !watching else { return }
    watching = true
    observeModel()
  }

  private func observeModel() {
    guard watching, let model else { return }
    withObservationTracking {
      _ = DropletContent.capture(model)
      _ = model.soundOn
      _ = model.turnModality
    } onChange: {
      Task { @MainActor in
        self.syncChrome()
        self.observeModel()
      }
    }
    syncChrome()
  }

  private func syncChrome() {
    guard let model else { return }
    let content = DropletContent.capture(model)
    let listening = model.turnModality == .utterance && (model.holding || model.phase == .listening)
    bead.listening = listening
    bead.thinking = model.phase == .thinking
    bead.speaking = model.phase == .speaking
    bead.level = model.inputLevel
    refreshStatusImage()

    if let button = statusItem?.button {
      button.toolTip = listening
        ? (model.handsFree
          ? "Arthur is listening — pause when you're done"
          : "Arthur is listening — release to send")
        : "Arthur — click to open, hold to talk. Right-click for the menu."
      button.setAccessibilityTitle(bead.accessibilityLabel)
    }
    holdView?.listening = model.holding
    holdView?.handsFree = model.handsFree
    holdView?.enabled = model.canTalk || model.holding
    holdView?.shortcut = model.pttHotkey.display
    muteItem?.title = muteTitle

    let mainKey = mainWindowIsKey
    let utteranceActive = model.turnModality == .utterance && (
      model.holding || model.phase == .listening || model.phase == .thinking || model.phase == .speaking
    )
    let incoming = model.speakBack?.live == true

    if mainKey && cardFollowing && !cardPinned && droplet.onScreen {
      dismissDroplet()
    }

    if !mainWindowIsKey && (utteranceActive || incoming) {
      cardFollowing = true
      if droplet.onScreen && !droplet.session.closing {
        cancelDismiss()
        if !usingToolbarAnchor {
          droplet.place(anchor: menuBarAnchor)
        }
      } else {
        present(anchor: menuBarAnchor, fromToolbar: false, drip: false, pinned: false, follow: true)
      }
    } else if cardFollowing && !cardPinned && droplet.onScreen && !utteranceActive && !incoming {
      scheduleDismiss(reset: false)
    }

    if droplet.onScreen {
      droplet.update(content)
    }
  }

  func toggleFromToolbar() {
    let anchor = toolbarAnchor.width > 1 ? toolbarAnchor : menuBarAnchor
    toggle(anchor: anchor, fromToolbar: toolbarAnchor.width > 1)
  }

  func noteToolbarAnchor(_ rect: NSRect) {
    guard rect.width > 1, rect.height > 1 else { return }
    toolbarAnchor = rect
    guard usingToolbarAnchor, droplet.onScreen else { return }
    droplet.place(anchor: rect)
  }

  @discardableResult
  func dismissDroplet() -> Bool {
    guard droplet.onScreen else { return false }
    cardPinned = false
    cardFollowing = false
    cancelDismiss()
    model?.deskFieldFocused = false
    droplet.hideAnimated()
    return true
  }

  private var mainWindowIsKey: Bool {
    NSApp.windows.contains { window in
      window.isKeyWindow && window.isVisible && !(window is NSPanel) && window.level == .normal
    }
  }

  private var menuBarAnchor: NSRect {
    guard let button = statusItem?.button, let window = button.window else {
      let screen = NSScreen.main?.frame ?? .zero
      return NSRect(x: screen.midX - 8, y: screen.maxY - 22, width: 16, height: 20)
    }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  private func toggle(anchor: NSRect, fromToolbar: Bool) {
    if droplet.onScreen && !droplet.session.closing {
      dismissDroplet()
      return
    }
    present(anchor: anchor, fromToolbar: fromToolbar, drip: false, pinned: true, follow: false)
  }

  private func present(
    anchor: NSRect,
    fromToolbar: Bool,
    drip: Bool,
    pinned: Bool,
    follow: Bool
  ) {
    if let model {
      droplet.update(DropletContent.capture(model))
    }
    if pinned { cardPinned = true }
    if follow { cardFollowing = true }
    if !cardPinned && !cardFollowing { cardPinned = true }
    usingToolbarAnchor = fromToolbar
    let opening = !droplet.onScreen || droplet.session.closing
    droplet.show(anchor: anchor, drip: drip && opening)
    bead.connected = true
    if drip && opening {
      bead.dripping = true
      dripWork?.cancel()
      let work = DispatchWorkItem { [weak self] in
        self?.bead.dripping = false
      }
      dripWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.78, execute: work)
    }
    installOutsideMonitors()
    cancelDismiss()
  }

  private func wireDroplet() {
    droplet.session.actions.talkDown = { [weak self] in self?.model?.talkPressed() }
    droplet.session.actions.talkUp = { [weak self] in self?.model?.talkReleased() }
    droplet.session.actions.stop = { [weak self] in self?.model?.cancelTurn() }
    droplet.session.actions.open = { [weak self] in
      self?.revealMainWindow()
      self?.dismissDroplet()
    }
    droplet.session.actions.dismiss = { [weak self] in self?.dismissDroplet() }
    droplet.session.actions.approve = { [weak self] in self?.model?.resolvePendingWrite() }
    droplet.session.actions.look = { [weak self] in self?.model?.lookAtScreen() }
    droplet.session.actions.send = { [weak self] text in
      self?.cardPinned = true
      self?.cancelDismiss()
      self?.model?.sendTypedLine(text)
    }
    droplet.session.actions.fieldFocus = { [weak self] on in
      guard let self else { return }
      self.model?.deskFieldFocused = on
      if on {
        self.cardPinned = true
        self.model?.composerFocused = false
        self.cancelDismiss()
        self.droplet.focusForTyping()
      }
    }
    droplet.session.actions.hover = { [weak self] hot in
      guard let self, hot, self.cardFollowing, !self.cardPinned else { return }
      self.scheduleDismiss(reset: true)
    }
    droplet.onClosed = { [weak self] in
      guard let self else { return }
      self.bead.connected = false
      self.bead.dripping = false
      self.model?.deskFieldFocused = false
      self.removeOutsideMonitors()
    }
  }

  private func scheduleDismiss(reset: Bool) {
    if !reset, dismissWork != nil { return }
    dismissWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.cardPinned else { return }
      guard let model = self.model else { return }
      let live = model.holding || model.phase == .listening || model.phase == .thinking || model.phase == .speaking
      if live || model.speakBack?.live == true { return }
      self.cardFollowing = false
      self.droplet.hideAnimated()
    }
    dismissWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 7.5, execute: work)
  }

  private func cancelDismiss() {
    dismissWork?.cancel()
    dismissWork = nil
  }

  private func installOutsideMonitors() {
    guard outsideMonitors.isEmpty else { return }
    let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      Task { @MainActor in self?.outsideClick() }
      return event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      Task { @MainActor in self?.outsideClick() }
    }
    if let local { outsideMonitors.append(local) }
    if let global { outsideMonitors.append(global) }
  }

  private func removeOutsideMonitors() {
    for monitor in outsideMonitors {
      NSEvent.removeMonitor(monitor)
    }
    outsideMonitors.removeAll()
  }

  private func outsideClick() {
    guard droplet.onScreen, droplet.acceptsHits else { return }
    let mouse = NSEvent.mouseLocation
    if menuBarAnchor.insetBy(dx: -8, dy: -8).contains(mouse) { return }
    if toolbarAnchor.width > 1, toolbarAnchor.insetBy(dx: -8, dy: -8).contains(mouse) { return }
    let card = droplet.cardScreenRect
    guard card.width > 20 else { return }
    if card.insetBy(dx: -12, dy: -18).contains(mouse) { return }
    if model?.holding == true || model?.phase == .listening { return }
    dismissDroplet()
  }
}

/// Carbon handler cannot capture context; `userData` is the `DeskAccessory`.
private let arthurHotKeyHandler: EventHandlerUPP = { _, event, userData in
  guard let event, let userData else { return OSStatus(noErr) }
  let accessory = Unmanaged<DeskAccessory>.fromOpaque(userData).takeUnretainedValue()
  accessory.receiveCarbonHotKey(kind: GetEventKind(event))
  return OSStatus(noErr)
}

private final class HoldTalkMenuView: NSView {
  var onDown: (() -> Void)?
  var onUp: (() -> Void)?
  var shortcut: String {
    didSet { needsDisplay = true }
  }
  var listening = false {
    didSet { needsDisplay = true }
  }
  var handsFree = false {
    didSet { needsDisplay = true }
  }
  var enabled = true {
    didSet { needsDisplay = true }
  }

  private var tracking = false

  init(shortcut: String) {
    self.shortcut = shortcut
    super.init(frame: NSRect(x: 0, y: 0, width: 248, height: 28))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize { NSSize(width: 248, height: 28) }

  override func mouseDown(with event: NSEvent) {
    guard enabled else { return }
    tracking = true
    listening = true
    onDown?()
    var keep = true
    while keep {
      autoreleasepool {
        guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else {
          keep = false
          return
        }
        if next.type == .leftMouseUp { keep = false }
      }
    }
    tracking = false
    listening = false
    onUp?()
  }

  override func draw(_ dirtyRect: NSRect) {
    let bounds = bounds.insetBy(dx: 6, dy: 2)
    let title = listening ? "Listening…" : "Tap to Talk"
    let titleColor: NSColor
    if !enabled {
      titleColor = NSColor.tertiaryLabelColor
    } else if listening {
      titleColor = ArthurTheme.accentNSColor
    } else {
      titleColor = NSColor.labelColor
    }
    let titleAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.menuFont(ofSize: 13),
      .foregroundColor: titleColor,
    ]
    let hintAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.menuFont(ofSize: 12),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let titleSize = (title as NSString).size(withAttributes: titleAttrs)
    let hint = listening ? (handsFree ? "Pause when you're done" : "Release to send") : shortcut
    let hintSize = (hint as NSString).size(withAttributes: hintAttrs)
    let y = bounds.midY - titleSize.height / 2
    (title as NSString).draw(at: NSPoint(x: bounds.minX + 8, y: y), withAttributes: titleAttrs)
    (hint as NSString).draw(
      at: NSPoint(x: bounds.maxX - hintSize.width - 8, y: bounds.midY - hintSize.height / 2),
      withAttributes: hintAttrs
    )
    _ = tracking
  }
}
