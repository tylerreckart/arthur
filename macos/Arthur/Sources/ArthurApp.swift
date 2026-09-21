import SwiftUI

@main
struct ArthurApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .frame(minWidth: 440, minHeight: 520)
        .containerBackground(for: .window) {
          WindowGlassBackground()
        }
        .background { WindowTransparency() }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
    .defaultSize(width: 520, height: 680)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Arthur") {
        Button("Settings…") { model.settingsOpen = true }
          .keyboardShortcut(",", modifiers: [.command])
        Divider()
        Button(model.soundOn ? "Mute Sound" : "Unmute Sound") {
          model.soundOn.toggle()
        }
      }
    }
  }
}
