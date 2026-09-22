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

/// Same-process menu bar extra, global PTT hotkey, and compact Listening HUD.
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

  private var hud: ListeningHUDController?
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
    hud?.hide()
    hud = nil
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
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Arthur") {
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
      }
      button.title = "Arthur"
      button.toolTip = "Arthur — hold to talk, click for menu"
      button.setAccessibilityTitle("Arthur")
      button.setAccessibilityHelp("Hold to talk, or click for the Arthur menu. Default shortcut is Option-Space.")
      button.target = self
      button.action = #selector(statusButtonEvent(_:))
      button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
    }
    statusItem = item
    menu = buildMenu()
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
      popMenu()
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
      _ = model.holding
      _ = model.inputLevel
      _ = model.soundOn
      _ = model.canTalk
      _ = model.phase
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
    if let button = statusItem?.button {
      let symbol = model.holding ? "mic.fill" : "waveform"
      if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Arthur") {
        image.isTemplate = true
        button.image = image
      }
      button.toolTip = model.holding
        ? "Arthur — listening, release to send"
        : "Arthur — hold to talk, click for menu"
    }
    holdView?.listening = model.holding
    holdView?.enabled = model.canTalk || model.holding
    muteItem?.title = muteTitle

    let mainKey = NSApp.windows.contains { window in
      window.isKeyWindow && window.isVisible && !(window is NSPanel) && window.level == .normal
    }
    if model.holding && !mainKey {
      if hud == nil { hud = ListeningHUDController() }
      hud?.show(level: model.inputLevel)
    } else {
      hud?.hide()
    }
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
    let title = listening ? "Listening…" : "Hold to Talk"
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
    let hint = listening ? "Release to send" : shortcut
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

private final class ListeningHUDController {
  private var panel: NSPanel?
  private var hosting: NSHostingView<ListeningHUDView>?

  func show(level: Double) {
    let view = ListeningHUDView(level: level)
    if let hosting {
      hosting.rootView = view
    } else {
      let hosting = NSHostingView(rootView: view)
      hosting.frame = NSRect(x: 0, y: 0, width: 228, height: 56)
      let panel = NSPanel(
        contentRect: hosting.frame,
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
      panel.hasShadow = true
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
      panel.contentView = hosting
      panel.animationBehavior = .utilityWindow
      self.hosting = hosting
      self.panel = panel
    }
    position()
    panel?.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func position() {
    guard let panel, let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.maxY - size.height - 10
    )
    panel.setFrameOrigin(origin)
  }
}

private struct ListeningHUDView: View {
  var level: Double

  var body: some View {
    HStack(spacing: 10) {
      HStack(alignment: .center, spacing: 3) {
        ForEach(0..<5, id: \.self) { i in
          let lit = level > Double(i) / 5.2
          Capsule()
            .fill(ArthurTheme.accent.opacity(lit ? 0.95 : 0.28))
            .frame(width: 3, height: 7 + CGFloat(i) * 2.4)
        }
      }
      VStack(alignment: .leading, spacing: 1) {
        Text("Listening…")
          .font(.body.weight(.medium))
          .foregroundStyle(ArthurTheme.accent)
        Text("Release to send")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(width: 228, height: 56)
    .preferredColorScheme(.dark)
    .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
  }
}
