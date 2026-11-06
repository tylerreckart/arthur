import XCTest

final class ArthurHouseholdTests: XCTestCase {
  func testIndicatorUsesANameOnlyWhenSure() {
    XCTAssertEqual(HouseholdRoster.indicator(name: "Ada", confident: true), "Ada")
    XCTAssertEqual(HouseholdRoster.indicator(name: "  Ada  ", confident: true), "Ada")
    XCTAssertEqual(HouseholdRoster.indicator(name: "Ada", confident: false), "")
    XCTAssertEqual(HouseholdRoster.indicator(name: "  ", confident: true), "")
  }

  func testPersonalSourceNameFitsTheDaemon() {
    XCTAssertEqual(HouseholdRoster.calendarSource(personId: "pabcd1234"), "cal-pabcd1234")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [
      CalendarEventSnapshot(
        title: "Studio",
        start: now,
        end: now.addingTimeInterval(3600),
        allDay: false,
        calendar: "ada"
      ),
      CalendarEventSnapshot(
        title: "School",
        start: now,
        end: now.addingTimeInterval(3600),
        allDay: false,
        calendar: "Ben"
      ),
    ]
    let people = [
      HouseholdRoster.Person(id: "padaaaaa", name: "Ada", calendar: "Ada", phrases: 3),
      HouseholdRoster.Person(id: "pbenbbbb", name: "Ben", calendar: "", phrases: 3),
    ]
    let sources = HouseholdRoster.personalSources(
      events: events,
      people: people,
      now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    XCTAssertEqual(sources.count, 1)
    XCTAssertEqual(sources[0].name, "cal-padaaaaa")
    XCTAssertTrue(sources[0].text.contains("Studio"))
    XCTAssertFalse(sources[0].text.contains("School"))
  }
}
