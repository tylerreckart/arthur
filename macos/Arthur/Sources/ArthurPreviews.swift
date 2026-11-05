import SwiftUI

#if DEBUG
enum ArthurPreviews {
  @MainActor
  static var listening: AppModel {
    let model = AppModel.previewCanvas(phase: .listening)
    model.holding = true
    model.inputLevel = 0.62
    return model
  }

  static var listeningDroplet: DropletContent {
    var content = DropletContent.empty
    content.stage = .listening
    content.title = "Listening"
    content.subtitle = "Release to send"
    content.level = 0.62
    content.canTalk = true
    content.holding = true
    return content
  }

  static var replyDroplet: DropletContent {
    var content = DropletContent.empty
    content.stage = .replying
    content.reply = "Clear this evening. Cooler than yesterday."
    return content
  }
}
#endif
