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
}
