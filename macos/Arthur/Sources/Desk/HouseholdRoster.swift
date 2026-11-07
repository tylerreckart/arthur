import Foundation

/// Who is enrolled, and which calendar source belongs to them.
/// The daemon decides whether a turn is confident. This never guesses.
enum HouseholdRoster {
  static let phrases = [
    "Arthur, it's me.",
    "What's on today?",
    "Leave the lights as they are.",
  ]

  struct Person: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var calendar: String
    var phrases: Int
  }

  /// A name for the transcript caption. Empty stays "You".
  static func indicator(name: String, confident: Bool) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard confident, !trimmed.isEmpty else { return "" }
    return trimmed
  }

  static func calendarSource(personId: String) -> String {
    "cal-\(personId)"
  }

  /// One source per person whose calendar title matches an event calendar.
  /// Matching is case-insensitive. A person with no events still gets a source
  /// so the daemon can prefer an empty personal day over the household list.
  static func personalSources(
    events: [CalendarEventSnapshot],
    people: [Person],
    now: Date,
    timeZone: TimeZone
  ) -> [DeskContext.Source] {
    var out: [DeskContext.Source] = []
    for person in people {
      let title = person.calendar.trimmingCharacters(in: .whitespacesAndNewlines)
      let id = person.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, !id.isEmpty else { continue }
      let mine = events.filter { $0.calendar.caseInsensitiveCompare(title) == .orderedSame }
      let text = CalendarAgenda.describe(now: now, timeZone: timeZone, events: mine)
      out.append(DeskContext.Source(name: calendarSource(personId: id), text: text))
    }
    return out
  }
}
