import XCTest

final class ArthurHistoryTests: XCTestCase {
  func testSearchFindsAnOlderDecision() {
    let olderId = UUID()
    let question = UUID()
    let answer = UUID()
    let older = HistoryThread(
      id: olderId,
      title: "Kitchen",
      updatedAt: Date(timeIntervalSinceNow: -40 * 24 * 3600),
      lines: [
        HistoryLine(id: question, text: "What did we decide about the kitchen?"),
        HistoryLine(id: answer, text: "We decided the kitchen stays blue."),
      ]
    )
    let newer = HistoryThread(
      id: UUID(),
      title: "Lights",
      updatedAt: Date(),
      lines: [HistoryLine(id: UUID(), text: "Turn the lights off.")]
    )
    let hits = HistorySearch.hits(in: [newer, older], query: "kitchen stays")
    XCTAssertEqual(hits.count, 1)
    XCTAssertEqual(hits[0].conversationId, olderId)
    XCTAssertEqual(hits[0].lineIndex, 1)
    XCTAssertTrue(hits[0].snippet.localizedCaseInsensitiveContains("blue"))
  }

  func testPagingReachesTheFirstLine() {
    XCTAssertEqual(HistorySearch.shownCount(total: 100, focusIndex: nil), 40)
    XCTAssertEqual(HistorySearch.shownCount(total: 100, focusIndex: 0), 100)
    XCTAssertEqual(HistorySearch.shownCount(total: 100, focusIndex: 70), 40)
    XCTAssertEqual(HistorySearch.shownCount(total: 12, focusIndex: 0), 12)
  }

  func testDeskListsKeepOpenWorkOnly() throws {
    let facts = """
    {"entries":[{"id":7,"title":"Kitchen","content":"Stays blue.","type":"user"}]}
    """.data(using: .utf8)!
    let parsed = DeskLibrary.facts(from: facts)
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed[0].title, "Kitchen")
    XCTAssertEqual(DeskLibrary.restoreBody(parsed[0])["content"] as? String, "Stays blue.")

    let schedules = """
    {"schedules":[
      {"id":3,"message":"Water the plants","schedule_phrase":"tomorrow at 9","status":"active"},
      {"id":4,"message":"Old","schedule_phrase":"yesterday","status":"completed"}
    ]}
    """.data(using: .utf8)!
    XCTAssertEqual(DeskLibrary.schedules(from: schedules).map(\.id), [3])

    let todos = """
    {"todos":[
      {"id":9,"subject":"Buy milk","status":"pending"},
      {"id":10,"subject":"Done","status":"completed"}
    ]}
    """.data(using: .utf8)!
    XCTAssertEqual(DeskLibrary.todos(from: todos).map(\.subject), ["Buy milk"])
  }
}
