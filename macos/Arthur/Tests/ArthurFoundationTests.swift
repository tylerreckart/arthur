import XCTest

final class ArthurFoundationTests: XCTestCase {
  func testSurfaceDecodeIgnoresMissingActions() {
    let decoded = ChatSurface.decode([
      "kind": "weather",
      "version": 1,
      "title": "Home",
      "summary": "Partly cloudy",
      "payload": ["temperature": 18],
    ])
    XCTAssertEqual(decoded.kind, .weather)
    XCTAssertEqual(decoded.version, 1)
    XCTAssertEqual(decoded.title, "Home")
    XCTAssertTrue(decoded.actions.isEmpty)
  }

  func testSurfaceDecodeKeepsActionsWithoutDroppingTheCard() {
    let event = ChatSurface.decodeEvent([
      "type": "surface",
      "turn_id": "turn-1",
      "surface": [
        "kind": "generic",
        "version": 1,
        "title": "Move the three o'clock",
        "summary": "To four",
        "actions": [
          [
            "id": "move-1",
            "label": "Approve",
            "kind": "approve",
            "tool_call": ["name": "calendar.move"],
          ],
          ["id": "", "label": "broken", "kind": "dismiss"],
          "skip-me",
        ],
        "future_field": "ignored",
      ],
    ])
    XCTAssertEqual(event?.turnId, "turn-1")
    let surface = event?.surface
    XCTAssertEqual(surface?.version, 1)
    XCTAssertEqual(surface?.title, "Move the three o'clock")
    XCTAssertEqual(surface?.actions.count, 1)
    XCTAssertEqual(surface?.actions.first?.id, "move-1")
    XCTAssertEqual(surface?.actions.first?.kind, "approve")
    let call = surface?.actions.first?.toolCall
    XCTAssertEqual(call?.object["name"]?.displayString, "calendar.move")
  }

  func testUnknownSurfaceKindStaysGeneric() {
    let decoded = ChatSurface.decode([
      "kind": "portfolio",
      "version": 2,
      "title": "Holdings",
    ])
    XCTAssertEqual(decoded.kind, .generic)
    XCTAssertEqual(decoded.kindRaw, "portfolio")
    XCTAssertEqual(decoded.version, 2)
  }

  func testProseJoinStitchesAFlushedClause() {
    XCTAssertEqual(ArthurProseJoin.join("", "Ready."), "Ready.")
    XCTAssertEqual(
      ArthurProseJoin.join("Hello there.", "Hello there."),
      "Hello there."
    )
    XCTAssertEqual(
      ArthurProseJoin.join("The weather is fine.", ", and warmer later."),
      "The weather is fine, and warmer later."
    )
    XCTAssertEqual(
      ArthurProseJoin.coalesce(
        ["The weather is fine.", ", and warmer later."],
        oneBubble: false
      ),
      ["The weather is fine, and warmer later."]
    )
  }

  func testDiscussionWindowIsNamedForLaterPaging() {
    XCTAssertEqual(DiscussionLimits.visibleLineCap, 40)
  }

  func testLiveReplyShowsTokensAheadOfSpeech() {
    XCTAssertEqual(
      ArthurLiveReply.shown(committed: "", forming: "The weather is"),
      "The weather is"
    )
    XCTAssertEqual(
      ArthurLiveReply.shown(
        committed: "The weather is fine.",
        forming: "The weather is fine. It warms up"
      ),
      "The weather is fine. It warms up"
    )
    XCTAssertEqual(
      ArthurLiveReply.shown(committed: "The weather is fine.", forming: "The weather is fine."),
      "The weather is fine."
    )
    XCTAssertEqual(
      ArthurLiveReply.shown(committed: "The weather is fine.", forming: "It warms up later"),
      "The weather is fine. It warms up later"
    )
  }

  func testNewsPayloadStripsEncodedMarkup() {
    let news = NewsPayload(.object([
      "items": .array([
        .object([
          "title": .string("Harbor fog lifts before noon - Gazette"),
          "source": .string("Gazette"),
          "url": .string("https://gazette.example/story"),
          "summary": .string(
            "&lt;ol&gt;&lt;li&gt;&lt;a href=&quot;https://news.google.com/rss/articles/abc&quot;&gt;Harbor fog lifts before noon&lt;/a&gt;&amp;nbsp;&amp;nbsp;&lt;font&gt;Gazette&lt;/font&gt;&lt;/li&gt;&lt;/ol&gt;"
          ),
        ]),
        .object([
          "title": .string("Night train adds a car"),
          "source": .string("Rail Notes"),
          "summary": .string("&lt;p&gt;The extra car runs after the last departure.&lt;/p&gt;"),
        ]),
      ]),
    ]))
    XCTAssertEqual(news.items.count, 2)
    XCTAssertEqual(news.items[0].title, "Harbor fog lifts before noon")
    XCTAssertEqual(news.items[0].summary, "")
    XCTAssertEqual(news.items[0].source, "Gazette")
    XCTAssertEqual(news.items[1].summary, "The extra car runs after the last departure.")
    XCTAssertFalse(news.items[1].summary.contains("<"))
  }

  func testVoiceLineStaysUnderASettledReply() {
    let lines = [
      DiscussionLine(fromYou: true, text: "What's in the news?"),
      DiscussionLine(
        fromYou: false,
        text: "Here are the top headlines.",
        turnId: "turn:previous"
      ),
    ]
    let index = VoiceTranscriptOrder.insertionIndex(
      count: lines.count,
      isYou: { lines[$0].fromYou },
      turnId: { lines[$0].turnId },
      turnIsLive: true,
      liveKeys: [""]
    )
    XCTAssertEqual(index, lines.count)

    let wrongTurn = VoiceTranscriptOrder.insertionIndex(
      count: lines.count,
      isYou: { lines[$0].fromYou },
      turnId: { lines[$0].turnId },
      turnIsLive: true,
      liveKeys: ["turn:next"]
    )
    XCTAssertEqual(wrongTurn, lines.count)
  }

  func testVoiceLineSitsAboveTheInFlightReply() {
    let lines = [
      DiscussionLine(
        fromYou: false,
        text: "Here are the top headlines.",
        turnId: "turn:previous"
      ),
      DiscussionLine(fromYou: false, text: "Markets open higher.", turnId: "turn:next"),
      DiscussionLine(fromYou: false, text: "Futures are up.", turnId: "turn:next"),
    ]
    let index = VoiceTranscriptOrder.insertionIndex(
      count: lines.count,
      isYou: { lines[$0].fromYou },
      turnId: { lines[$0].turnId },
      turnIsLive: true,
      liveKeys: ["turn:next"]
    )
    XCTAssertEqual(index, 1)

    let idle = VoiceTranscriptOrder.insertionIndex(
      count: lines.count,
      isYou: { lines[$0].fromYou },
      turnId: { lines[$0].turnId },
      turnIsLive: false,
      liveKeys: ["turn:next"]
    )
    XCTAssertEqual(idle, lines.count)
  }
}
