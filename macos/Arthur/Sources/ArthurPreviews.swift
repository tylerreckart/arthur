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

  static var conversationHistory: [DeskConversation] {
    [
      DeskConversation(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        title: "What's on this evening?",
        updatedAt: Date(),
        serverConversationId: 1,
        lines: [
          DiscussionLine(fromYou: true, text: "What's on this evening?"),
          DiscussionLine(fromYou: false, text: "Clear, and cooler than yesterday."),
        ]
      ),
      DeskConversation(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        title: "Kitchen lights",
        updatedAt: Date().addingTimeInterval(-86_400),
        serverConversationId: 2,
        lines: [
          DiscussionLine(fromYou: true, text: "Kitchen lights"),
          DiscussionLine(fromYou: false, text: "They're off."),
        ]
      ),
    ]
  }

  static var replyDroplet: DropletContent {
    var content = DropletContent.empty
    content.stage = .replying
    content.reply = "Clear this evening. Cooler than yesterday."
    return content
  }
}
#endif
