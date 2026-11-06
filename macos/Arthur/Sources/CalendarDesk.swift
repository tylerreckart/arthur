import AppKit
import EventKit
import Foundation

enum CalendarSharing: String, CaseIterable, Hashable {
  case off
  case ask
  case session
  case always

  var settingsLabel: String {
    switch self {
    case .off: return "Off"
    case .ask: return "Ask each time"
    case .session: return "Until I quit"
    case .always: return "Always"
    }
  }
}

/// EventKit plus the sharing choice. Event lookups stay on the main thread.
enum CalendarDesk {
  private static let store = EKEventStore()
  private static let lock = NSLock()
  private static var sharing: CalendarSharing = .off
  private static var sessionAllowed = false
  private static var askUntil = Date.distantPast

  static var hasAccess: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
  }

  static func configure(sharing: CalendarSharing, sessionAllowed: Bool) {
    lock.lock()
    self.sharing = sharing
    self.sessionAllowed = sessionAllowed
    lock.unlock()
  }

  static func toolText(day: String) -> String {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync { toolText(day: day) }
    }
    let policy = snapshot()
    switch policy.sharing {
    case .off:
      return CalendarAgenda.unavailable("The user turned calendar sharing off in Arthur's settings.")
    case .ask:
      guard policy.askUntil > Date() else {
        return CalendarAgenda.unavailable("The user has not shared the calendar for this turn.")
      }
    case .session:
      guard policy.sessionAllowed else {
        return CalendarAgenda.unavailable("The user has not shared the calendar for this session.")
      }
    case .always:
      break
    }
    guard hasAccess else {
      return CalendarAgenda.unavailable("Calendar access is off in System Settings.")
    }
    return CalendarAgenda.describe(now: Date(), timeZone: .current, events: fetch(days: 2), day: day)
  }

  /// Interactive path may show a confirm dialog and the system permission prompt.
  static func context(sharing: CalendarSharing, sessionAllowed: Bool, interactive: Bool) async -> (DeskContext, Bool) {
    let grantedSession = sessionAllowed
    switch sharing {
    case .off:
      return (DeskContext.calendar(CalendarAgenda.unavailable(
        "The user turned calendar sharing off in Arthur's settings."
      )), false)
    case .ask:
      guard interactive, confirm(session: false) else {
        return (DeskContext.calendar(CalendarAgenda.unavailable(
          "The user declined calendar sharing for this turn."
        )), false)
      }
      noteAskGranted()
    case .session where !sessionAllowed:
      guard interactive, confirm(session: true) else {
        return (DeskContext.calendar(CalendarAgenda.unavailable(
          "The user has not shared the calendar for this session."
        )), false)
      }
    case .session, .always:
      break
    }
    guard await ensureAccess() else {
      return (DeskContext.calendar(CalendarAgenda.unavailable(
        "Calendar access is off in System Settings."
      )), sharing == .session)
    }
    let allow = sharing == .session || grantedSession
    return await MainActor.run {
      let text = CalendarAgenda.describe(now: Date(), timeZone: .current, events: fetch(days: 2))
      return (DeskContext.calendar(text), allow)
    }
  }

  static func agendaNow() -> DeskContext {
    DeskContext.calendar(CalendarAgenda.describe(now: Date(), timeZone: .current, events: fetch(days: 2)))
  }

  private static func noteAskGranted() {
    lock.lock()
    askUntil = Date().addingTimeInterval(120)
    lock.unlock()
  }

  private static func snapshot() -> (sharing: CalendarSharing, sessionAllowed: Bool, askUntil: Date) {
    lock.lock()
    defer { lock.unlock() }
    return (sharing, sessionAllowed, askUntil)
  }

  @MainActor
  private static func ensureAccess() async -> Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    if status == .fullAccess { return true }
    guard status == .notDetermined else { return false }
    return (try? await store.requestFullAccessToEvents()) ?? false
  }

  private static func fetch(days: Int) -> [CalendarEventSnapshot] {
    var calendar = Calendar.current
    calendar.timeZone = .current
    let start = calendar.startOfDay(for: Date())
    guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    return store.events(matching: predicate).map { event in
      CalendarEventSnapshot(
        title: event.title ?? "Busy",
        start: event.startDate,
        end: event.endDate,
        allDay: event.isAllDay,
        calendar: event.calendar.title
      )
    }
  }

  private static func confirm(session: Bool) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    let alert = NSAlert()
    alert.messageText = session ? "Share your calendar until Arthur quits?" : "Share your calendar for this turn?"
    alert.informativeText = "Arthur reads today and tomorrow on this Mac to answer you. He does not put the list in the transcript."
    alert.addButton(withTitle: "Share")
    alert.addButton(withTitle: "Not now")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
