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
