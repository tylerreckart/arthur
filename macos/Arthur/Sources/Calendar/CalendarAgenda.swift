import Foundation

struct CalendarEventSnapshot: Equatable {
  var title: String
  var start: Date
  var end: Date
  var allDay: Bool
  var calendar: String
}

/// Spoken-adjacent calendar text. The model reads this privately and answers
/// in Arthur's voice. It is not shown in the transcript.
enum CalendarAgenda {
  static func unavailable(_ reason: String) -> String {
    "unavailable. \(reason) If they ask about their schedule, say you cannot see the calendar. Do not invent events."
  }

  static func describe(
    now: Date,
    timeZone: TimeZone,
    events: [CalendarEventSnapshot],
    day: String = ""
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let today = calendar.startOfDay(for: now)
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
          let afterTomorrow = calendar.date(byAdding: .day, value: 1, to: tomorrow)
    else { return unavailable("The calendar could not be read.") }

    let asked = day.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var lines: [String] = []
    lines.append("Time zone \(timeZone.identifier). Today is \(weekday(today, calendar: calendar)).")

    let includeToday = asked.isEmpty || asked == "today" || asked == "both"
    let includeTomorrow = asked.isEmpty || asked == "tomorrow" || asked == "both"
    if !asked.isEmpty && asked != "today" && asked != "tomorrow" && asked != "both" {
      lines.append("Only today and tomorrow are on this Mac.")
    }

    if includeToday {
      let todays = overlapping(events, start: today, end: tomorrow)
      lines.append(todayStatus(now: now, events: todays, calendar: calendar))
      lines.append("Today:")
      lines.append(contentsOf: list(todays, calendar: calendar))
    }
    if includeTomorrow {
      let tomorrows = overlapping(events, start: tomorrow, end: afterTomorrow)
      lines.append("Tomorrow:")
      lines.append(contentsOf: list(tomorrows, calendar: calendar))
    }
    return lines.joined(separator: "\n")
  }

  private static func overlapping(
    _ events: [CalendarEventSnapshot],
    start: Date,
    end: Date
  ) -> [CalendarEventSnapshot] {
    events
      .filter { $0.start < end && $0.end > start }
      .sorted { $0.start < $1.start }
  }

  private static func todayStatus(
    now: Date,
    events: [CalendarEventSnapshot],
    calendar: Calendar
  ) -> String {
    let timed = events.filter { !$0.allDay }
    if let current = timed.first(where: { $0.start <= now && $0.end > now }) {
      return "In \(clip(current.title)) until \(clock(current.end, calendar: calendar))."
    }
    if let next = timed.first(where: { $0.start > now }) {
      return "Next: \(clip(next.title)) at \(clock(next.start, calendar: calendar)). Free until then."
    }
    if timed.isEmpty && events.allSatisfy(\.allDay) {
      return events.isEmpty ? "Nothing scheduled today." : "Only all-day events today."
    }
    return "Nothing else today."
  }

  private static func list(_ events: [CalendarEventSnapshot], calendar: Calendar) -> [String] {
    if events.isEmpty { return ["- Nothing scheduled."] }
    let shown = events.prefix(12)
    var lines = shown.map { event -> String in
      let name = clip(event.title)
      let where_ = event.calendar.isEmpty ? "" : " (\(clip(event.calendar)))"
      if event.allDay { return "- All day \(name)\(where_)" }
      return "- \(clock(event.start, calendar: calendar)) to \(clock(event.end, calendar: calendar)) \(name)\(where_)"
    }
    if events.count > shown.count {
      lines.append("- \(events.count - shown.count) more.")
    }
    return lines
  }

  private static func weekday(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEEE d MMMM yyyy"
    return formatter.string(from: date)
  }

  private static func clock(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
  }

  private static func clip(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if flat.count <= 80 { return flat.isEmpty ? "Busy" : flat }
    return String(flat.prefix(79)) + "…"
  }
}

struct DeskContext: Equatable {
  struct Source: Equatable {
    var name: String
    var text: String
  }

  struct Image: Equatable {
    var mediaType: String
    var data: String
  }

  var sources: [Source]
  var images: [Image] = []

  var isEmpty: Bool { sources.isEmpty && images.isEmpty }

  var wire: [String: Any] {
    var object: [String: Any] = [
      "sources": sources.map { ["name": $0.name, "text": $0.text] },
    ]
    if !images.isEmpty {
      object["images"] = images.map { ["media_type": $0.mediaType, "data": $0.data] }
    }
    return object
  }

  static func calendar(_ text: String) -> DeskContext {
    DeskContext(sources: [Source(name: "calendar", text: text)])
  }
}
