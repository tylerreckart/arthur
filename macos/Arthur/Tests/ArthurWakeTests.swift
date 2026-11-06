import XCTest

final class ArthurWakeTests: XCTestCase {
  func testArthurAtTheStartWakes() {
    XCTAssertTrue(WakePhrase.matches("Arthur"))
    XCTAssertTrue(WakePhrase.matches("Arthur, what's the weather"))
    XCTAssertTrue(WakePhrase.matches("hey Arthur"))
    XCTAssertTrue(WakePhrase.matches("ok arthur, the time"))
  }

  func testLookalikesDoNotWake() {
    XCTAssertFalse(WakePhrase.matches(""))
    XCTAssertFalse(WakePhrase.matches("yesterday"))
    XCTAssertFalse(WakePhrase.matches("marthur"))
    XCTAssertFalse(WakePhrase.matches("Arthurian legends"))
    XCTAssertFalse(WakePhrase.matches("tell Arthur"))
  }

  func testPartialHeardStaysLive() {
    XCTAssertEqual(HeardLine.interpret(text: "what's the", partial: true), .live("what's the"))
    XCTAssertEqual(
      HeardLine.interpret(text: "what's the weather", partial: false),
      .commit("what's the weather")
    )
    XCTAssertNil(HeardLine.interpret(text: "  ", partial: true))
  }
}
