import AppKit
import SwiftUI

@main
struct ArthurApp: App {
  @NSApplicationDelegateAdaptor(ArthurAppDelegate.self) private var appDelegate
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup("Arthur", id: "main") {
      ArthurWindowRoot()
        .environment(model)
        .frame(minWidth: 440, minHeight: 520)
        .containerBackground(for: .window) {
          WindowGlassBackground()
        }
        .background { WindowTransparency() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          DeskAccessory.shared.detach()
          model.stop()
        }
    }
    .defaultSize(width: 520, height: 680)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Arthur") {
        Button("Settings…") { model.settingsOpen = true }
          .keyboardShortcut(",", modifiers: [.command])
        Button("Ask Arthur") { model.focusComposer() }
          .keyboardShortcut("l", modifiers: [.command])
        Divider()
        Button(model.soundOn ? "Mute Sound" : "Unmute Sound") {
          model.soundOn.toggle()
        }
      }
      CommandGroup(after: .textEditing) {
        Button("Ask Arthur") { model.focusComposer() }
          .keyboardShortcut("k", modifiers: [.command])
      }
    }
  }
}

/// Keeps the process alive after the chat window closes so the menu bar extra
/// and global PTT hotkey stay armed, like the hallway button.
final class ArthurAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      DeskAccessory.shared.revealMainWindow()
    }
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    DeskAccessory.shared.detach()
  }
}

private struct ArthurWindowRoot: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ContentView()
      .onAppear {
        model.start()
        DeskAccessory.shared.attach(model: model) {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "main")
        }
      }
  }
}
