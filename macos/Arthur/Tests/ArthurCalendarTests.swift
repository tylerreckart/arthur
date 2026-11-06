import XCTest

final class ArthurCalendarTests: XCTestCase {
  func testAgendaNamesTheAfternoonAndTomorrow() {
    var calendar = Calendar(identifier: .gregorian)
    let zone = TimeZone(secondsFromGMT: 0)!
    calendar.timeZone = zone
    let now = date(calendar, year: 2026, month: 11, day: 6, hour: 15, minute: 0)
    let review = CalendarEventSnapshot(
      title: "Design review",
      start: date(calendar, year: 2026, month: 11, day: 6, hour: 16, minute: 0),
      end: date(calendar, year: 2026, month: 11, day: 6, hour: 17, minute: 0),
      allDay: false,
      calendar: "Work"
    )
    let standup = CalendarEventSnapshot(
      title: "Standup",
      start: date(calendar, year: 2026, month: 11, day: 7, hour: 9, minute: 0),
      end: date(calendar, year: 2026, month: 11, day: 7, hour: 9, minute: 15),
      allDay: false,
      calendar: "Work"
    )
    let text = CalendarAgenda.describe(now: now, timeZone: zone, events: [review, standup])
    XCTAssertTrue(text.contains("Design review"))
    XCTAssertTrue(text.contains("Free until"))
    XCTAssertTrue(text.contains("4:00 PM"))
    XCTAssertTrue(text.contains("Standup"))
    XCTAssertTrue(text.contains("Friday 6 November 2026"))
  }

  func testTomorrowSliceOmitsToday() {
    var calendar = Calendar(identifier: .gregorian)
    let zone = TimeZone(secondsFromGMT: 0)!
    calendar.timeZone = zone
    let now = date(calendar, year: 2026, month: 11, day: 6, hour: 15, minute: 0)
    let review = CalendarEventSnapshot(
      title: "Design review",
      start: date(calendar, year: 2026, month: 11, day: 6, hour: 16, minute: 0),
      end: date(calendar, year: 2026, month: 11, day: 6, hour: 17, minute: 0),
      allDay: false,
      calendar: ""
    )
    let standup = CalendarEventSnapshot(
      title: "Standup",
      start: date(calendar, year: 2026, month: 11, day: 7, hour: 9, minute: 0),
      end: date(calendar, year: 2026, month: 11, day: 7, hour: 9, minute: 15),
      allDay: false,
      calendar: ""
    )
    let text = CalendarAgenda.describe(
      now: now,
      timeZone: zone,
      events: [review, standup],
      day: "tomorrow"
    )
    XCTAssertTrue(text.contains("Standup"))
    XCTAssertFalse(text.contains("Design review"))
  }

  func testUnavailableCalendarTellsArthurNotToInvent() {
    let text = CalendarAgenda.unavailable("The user turned calendar sharing off in Arthur's settings.")
    XCTAssertTrue(text.contains("unavailable"))
    XCTAssertTrue(text.contains("Do not invent events."))
  }

  func testToolHostListsAndReadsTheCalendar() {
    let host = LocalToolHost { day in
      XCTAssertEqual(day, "tomorrow")
      return "Tomorrow: Standup"
    }
    let listed = host.respond(to: [
      "jsonrpc": "2.0",
      "id": 1,
      "method": "tools/list",
    ])
    let tools = (listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    XCTAssertEqual(tools?.first?["name"] as? String, "calendar.read")

    let called = host.respond(to: [
      "jsonrpc": "2.0",
      "id": 7,
      "method": "tools/call",
      "params": [
        "name": "calendar.read",
        "arguments": ["day": "tomorrow"],
      ],
    ])
    XCTAssertEqual(called?["id"] as? Int, 7)
    let result = called?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    XCTAssertEqual(content?.first?["text"] as? String, "Tomorrow: Standup")
    XCTAssertEqual(result?["isError"] as? Bool, false)
  }

  func testClockPhraseReadsAfternoon() {
    XCTAssertEqual(ClockPhrase.minuteOfDay("16:00"), 16 * 60)
    XCTAssertEqual(ClockPhrase.minuteOfDay("4:00 PM"), 16 * 60)
    XCTAssertEqual(ClockPhrase.minuteOfDay("4pm"), 16 * 60)
    XCTAssertEqual(ClockPhrase.minuteOfDay("12:00 AM"), 0)
    XCTAssertNil(ClockPhrase.minuteOfDay("tomorrow"))
  }

  func testAuditRecordsTheWriteWithoutTheArguments() throws {
    let args = ["title": "Design review", "to": "16:00"]
    let line = ActionAudit.line(
      at: Date(timeIntervalSince1970: 0),
      tool: "calendar.move",
      args: args,
      approvedBy: "card",
      result: "done"
    )
    XCTAssertTrue(line.contains("\"tool\":\"calendar.move\""))
    XCTAssertTrue(line.contains(ActionAudit.hashArgs(args)))
    XCTAssertFalse(line.contains("Design review"))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arthur-audit-\(UUID().uuidString).jsonl")
    ActionAudit.append(tool: "calendar.move", args: args, approvedBy: "", result: "pending", to: url)
    ActionAudit.append(tool: "calendar.move", args: args, approvedBy: "voice", result: "done", to: url)
    ActionAudit.append(tool: "calendar.move", args: args, approvedBy: "undo", result: "undone", to: url)
    let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(rows.count, 3)
    XCTAssertTrue(rows[0].contains("pending"))
    XCTAssertTrue(rows[1].contains("done"))
    XCTAssertTrue(rows[2].contains("undone"))
  }

  func testWriteToolStaysPending() {
    let host = LocalToolHost(
      act: { name, args in
        XCTAssertEqual(name, "calendar.move")
        XCTAssertEqual(args["to"] as? String, "16:00")
        return "Pending approval. Nothing has changed."
      },
      calendarText: { _ in "unused" }
    )
    let listed = host.respond(to: [
      "jsonrpc": "2.0",
      "id": 1,
      "method": "tools/list",
    ])
    let tools = (listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    let names = tools?.compactMap { $0["name"] as? String } ?? []
    XCTAssertTrue(names.contains("calendar.move"))
    XCTAssertTrue(names.contains("reminders.complete"))

    let called = host.respond(to: [
      "jsonrpc": "2.0",
      "id": 3,
      "method": "tools/call",
      "params": [
        "name": "calendar.move",
        "arguments": ["to": "16:00", "title": "Design review"],
      ],
    ])
    let result = called?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    XCTAssertEqual(content?.first?["text"] as? String, "Pending approval. Nothing has changed.")
    XCTAssertEqual(result?["isError"] as? Bool, false)
  }

  func testToolHostDropsNotifications() {
    let host = LocalToolHost { _ in "unused" }
    let response = host.respond(to: [
      "jsonrpc": "2.0",
      "method": "notifications/initialized",
    ])
    XCTAssertNil(response)
  }

  private func date(
    _ calendar: Calendar,
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int
  ) -> Date {
    calendar.date(from: DateComponents(
      timeZone: calendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute
    ))!
  }
}
