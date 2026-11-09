import SwiftUI

enum ArthurPreviews {
  /// Dark desk behind a card preview so Liquid Glass has a surface to sample.
  static var deskBackdrop: LinearGradient {
    LinearGradient(
      colors: [
        Color(red: 0.20, green: 0.21, blue: 0.23),
        Color(red: 0.10, green: 0.10, blue: 0.11),
        Color(red: 0.14, green: 0.15, blue: 0.16),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

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

  static var thinkingDroplet: DropletContent {
    var content = DropletContent.empty
    content.stage = .thinking
    content.title = "Thinking"
    content.subtitle = "Looking something up."
    content.you = "What's on tomorrow?"
    content.canCancel = true
    return content
  }

  static var approvalDroplet: DropletContent {
    var content = DropletContent.empty
    content.stage = .ready
    content.noteTitle = "Add calendar event"
    content.noteBody = "Dentist tomorrow at 9am — approve to add it."
    content.approveLabel = "Approve"
    content.attentionCount = 1
    content.attentionTitle = "Add calendar event"
    content.attentionSummary = "Dentist tomorrow at 9am"
    return content
  }

  static var replyDroplet: DropletContent {
    var content = DropletContent.empty
    content.stage = .replying
    content.reply = "Clear this evening. Cooler than yesterday."
    return content
  }

  static var weatherSurface: ChatSurface {
    ChatSurface(
      kindRaw: SurfaceKind.weather.rawValue,
      title: "Home",
      summary: "Partly cloudy, 64°",
      payload: .object([
        "condition": .string("partlycloudy"),
        "condition_label": .string("Partly cloudy"),
        "temperature": .number(64),
        "feels_like": .number(61),
        "humidity": .number(48),
        "wind_speed": .number(8),
        "wind_unit": .string("mph"),
        "hours": .array([
          forecast("3pm", "partlycloudy", 64),
          forecast("4pm", "cloudy", 63),
          forecast("5pm", "rain", 60),
          forecast("6pm", "clear night", 57),
        ]),
        "days": .array([
          forecast("Tue", "rain", 62, low: 51),
          forecast("Wed", "sunny", 68, low: 49),
          forecast("Thu", "cloudy", 59, low: 47),
        ]),
      ]),
      sources: [SurfaceSource(title: "Home", url: "https://home.local/weather")]
    )
  }

  static var newsSurface: ChatSurface {
    let iso = ISO8601DateFormatter()
    func item(
      _ title: String, _ source: String, _ host: String, _ ago: TimeInterval, _ summary: String
    ) -> JSONValue {
      .object([
        "title": .string(title),
        "summary": .string(summary),
        "source": .string(source),
        "url": .string("https://\(host)/story"),
        "published_at": .string(iso.string(from: Date().addingTimeInterval(-ago))),
      ])
    }
    return ChatSurface(
      kindRaw: SurfaceKind.news.rawValue,
      title: "Headlines",
      summary: "Three stories since this morning.",
      payload: .object([
        "topic": .string("desk"),
        "items": .array([
          item("Harbor fog lifts before noon", "Gazette", "gazette.example", 5_400,
               "The harbor is clear enough for the morning ferry."),
          item("Market square closes for the parade", "City Desk", "citydesk.example", 28_800,
               "Streets around the square stay shut until evening."),
          item("Night train adds a late Friday car", "Rail Notes", "railnotes.example", 86_400,
               "The extra car runs after the last scheduled departure."),
        ]),
      ]),
      sources: [SurfaceSource(title: "Feeds", url: "https://feeds.example/news")]
    )
  }

  static var marketsSurface: ChatSurface {
    func quote(_ symbol: String, _ name: String, _ price: Double, _ pct: Double) -> JSONValue {
      .object([
        "symbol": .string(symbol),
        "name": .string(name),
        "price": .number(price),
        "change_pct": .number(pct),
        "currency": .string("USD"),
      ])
    }
    return ChatSurface(
      kindRaw: SurfaceKind.markets.rawValue,
      title: "Markets",
      summary: "Mixed. Apple leads, Tesla gives some back.",
      payload: .object([
        "market_summary": .string("Mixed session"),
        "instruments": .array([
          quote("AAPL", "Apple", 189.42, 1.24),
          quote("TSLA", "Tesla", 248.10, -0.86),
          quote("GLD", "Gold", 241.05, 0),
        ]),
      ]),
      sources: [SurfaceSource(title: "Quotes", url: "https://finance.yahoo.com")]
    )
  }

  static var noteSurface: ChatSurface {
    ChatSurface(
      kindRaw: SurfaceKind.generic.rawValue,
      title: "This evening",
      summary: "Clear, and cooler than yesterday.",
      payload: .object([
        "when": .string("Tonight"),
        "where": .string("Home"),
        "body": .string("Keep the **three o'clock** and leave `standup` where it is."),
      ]),
      sources: [SurfaceSource(title: "Desk", url: "")]
    )
  }

  static var approvalSurface: ChatSurface {
    ChatSurface(
      kindRaw: SurfaceKind.generic.rawValue,
      title: "Add calendar event",
      summary: "Dentist tomorrow at 9am.",
      actions: [
        SurfaceAction(id: "approve-1", label: "Approve", kind: "approve"),
        SurfaceAction(id: "dismiss-1", label: "Not now", kind: "dismiss"),
      ]
    )
  }

  private static func forecast(_ label: String, _ condition: String, _ high: Int, low: Int? = nil) -> JSONValue {
    var fields: [String: JSONValue] = [
      "label": .string(label),
      "condition": .string(condition),
      "temperature": .number(Double(high)),
    ]
    if let low { fields["temperature_low"] = .number(Double(low)) }
    return .object(fields)
  }
}

extension View {
  /// Pins a card on the preview desk so glass samples the backdrop.
  func arthurPreviewDesk(width: CGFloat) -> some View {
    padding(24)
      .frame(width: width, alignment: .topLeading)
      .background(ArthurPreviews.deskBackdrop)
      .preferredColorScheme(.dark)
  }
}

