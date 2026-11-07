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

  /// Personal calendars ride beside the household one. The daemon drops the
  /// ones that are not this speaker's after it scores the voice.
  static func personalSources(people: [HouseholdRoster.Person]) -> [DeskContext.Source] {
    guard !people.isEmpty else { return [] }
    return HouseholdRoster.personalSources(
      events: fetch(days: 2),
      people: people,
      now: Date(),
      timeZone: .current
    )
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

  struct WriteProposal: Equatable {
    var id: String
    var title: String
    var summary: String
    var tool: String
    /// `approve` until it happens, then `undo`.
    var phase: String
  }

  static var onProposal: ((WriteProposal) -> Void)?

  /// Builds a card and does not change Calendar or Reminders unless `confirmed` is set.
  static func propose(tool: String, args: [String: Any]) -> String {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync { propose(tool: tool, args: args) }
    }
    if let denied = writeDenial() { return denied }
    let fields = stringArgs(args)
    let confirmed = isConfirmed(args["confirmed"])
    switch tool {
    case "calendar.move":
      return proposeMove(fields, confirmed: confirmed)
    case "calendar.create":
      return proposeCreate(fields, confirmed: confirmed)
    case "reminders.create":
      return proposeReminder(fields, confirmed: confirmed)
    case "reminders.complete":
      return proposeComplete(fields, confirmed: confirmed)
    default:
      return "That action is not available."
    }
  }

  /// Approve, dismiss, or undo the card with this id. Voice and the button share it.
  static func resolve(id: String, granted: Bool, via: String) -> WriteProposal? {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync { resolve(id: id, granted: granted, via: via) }
    }
    writeLock.lock()
    guard var stored = writes[id] else {
      writeLock.unlock()
      return nil
    }
    if !granted {
      guard stored.phase == "approve" else {
        writeLock.unlock()
        return stored.proposal
      }
      stored.phase = "dismissed"
      writes[id] = stored
      writeLock.unlock()
      ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: via, result: "dismissed")
      return WriteProposal(id: id, title: stored.title, summary: "Left as it was.", tool: stored.tool, phase: "dismissed")
    }
    if stored.phase == "undo" {
      stored.phase = "undoing"
      writes[id] = stored
      writeLock.unlock()
      return undo(stored, via: via)
    }
    guard stored.phase == "approve" else {
      writeLock.unlock()
      return stored.proposal
    }
    stored.phase = "running"
    writes[id] = stored
    writeLock.unlock()
    switch stored.kind {
    case .move(let eventId, _, _, _, let newStart, let newEnd):
      guard let event = store.event(withIdentifier: eventId) else {
        return fail(stored, result: "missing")
      }
      event.startDate = newStart
      event.endDate = newEnd
      do { try store.save(event, span: .thisEvent, commit: true) } catch {
        return fail(stored, result: "failed")
      }
      return finish(stored, summary: "Moved. Undo puts it back.", undo: stored.kind, via: via)
    case .createEvent(let title, let start, let end, _):
      let event = EKEvent(eventStore: store)
      event.title = title
      event.startDate = start
      event.endDate = end
      event.calendar = store.defaultCalendarForNewEvents
      guard event.calendar != nil else { return fail(stored, result: "failed") }
      do { try store.save(event, span: .thisEvent, commit: true) } catch {
        return fail(stored, result: "failed")
      }
      var kind = stored.kind
      if case .createEvent(let title, let start, let end, _) = kind {
        kind = .createEvent(title: title, start: start, end: end, createdId: event.eventIdentifier)
      }
      stored.kind = kind
      return finish(stored, summary: "Added. Undo removes it.", undo: kind, via: via)
    case .createReminder(let title, let due, _):
      guard remindersAllowed() else { return fail(stored, result: "failed") }
      guard let calendar = store.defaultCalendarForNewReminders() else { return fail(stored, result: "failed") }
      let reminder = EKReminder(eventStore: store)
      reminder.title = title
      reminder.calendar = calendar
      if let due {
        reminder.dueDateComponents = Calendar.current.dateComponents(
          [.year, .month, .day, .hour, .minute], from: due)
      }
      do { try store.save(reminder, commit: true) } catch { return fail(stored, result: "failed") }
      let kind = StoredKind.createReminder(title: title, due: due, createdId: reminder.calendarItemIdentifier)
      stored.kind = kind
      return finish(stored, summary: "Added. Undo removes it.", undo: kind, via: via)
    case .completeReminder(let reminderId, _):
      guard remindersAllowed() else { return fail(stored, result: "failed") }
      guard let reminder = store.calendarItem(withIdentifier: reminderId) as? EKReminder else {
        return fail(stored, result: "missing")
      }
      reminder.isCompleted = true
      do { try store.save(reminder, commit: true) } catch { return fail(stored, result: "failed") }
      return finish(stored, summary: "Completed. Undo reopens it.", undo: stored.kind, via: via)
    }
  }

  private static func undo(_ stored: StoredWrite, via: String) -> WriteProposal? {
    switch stored.kind {
    case .move(let eventId, _, let oldStart, let oldEnd, _, _):
      guard let event = store.event(withIdentifier: eventId) else { return fail(stored, result: "missing") }
      event.startDate = oldStart
      event.endDate = oldEnd
      do { try store.save(event, span: .thisEvent, commit: true) } catch { return fail(stored, result: "failed") }
    case .createEvent(_, _, _, let createdId):
      guard let createdId, let event = store.event(withIdentifier: createdId) else {
        return fail(stored, result: "missing")
      }
      do { try store.remove(event, span: .thisEvent, commit: true) } catch { return fail(stored, result: "failed") }
    case .createReminder(_, _, let createdId):
      guard let createdId, let reminder = store.calendarItem(withIdentifier: createdId) as? EKReminder else {
        return fail(stored, result: "missing")
      }
      do { try store.remove(reminder, commit: true) } catch { return fail(stored, result: "failed") }
    case .completeReminder(let reminderId, _):
      guard let reminder = store.calendarItem(withIdentifier: reminderId) as? EKReminder else {
        return fail(stored, result: "missing")
      }
      reminder.isCompleted = false
      do { try store.save(reminder, commit: true) } catch { return fail(stored, result: "failed") }
    }
    var done = stored
    done.phase = "done"
    writeLock.lock()
    writes[stored.id] = done
    writeLock.unlock()
    ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: via, result: "undone")
    return WriteProposal(id: stored.id, title: stored.title, summary: "Restored.", tool: stored.tool, phase: "done")
  }

  private static let writeLock = NSLock()
  private static var writes: [String: StoredWrite] = [:]

  private struct StoredWrite {
    var id: String
    var tool: String
    var title: String
    var args: [String: String]
    var phase: String
    var kind: StoredKind

    var proposal: WriteProposal {
      WriteProposal(id: id, title: title, summary: "", tool: tool, phase: phase)
    }
  }

  private enum StoredKind {
    case move(eventId: String, title: String, oldStart: Date, oldEnd: Date, newStart: Date, newEnd: Date)
    case createEvent(title: String, start: Date, end: Date, createdId: String?)
    case createReminder(title: String, due: Date?, createdId: String?)
    case completeReminder(id: String, title: String)
  }

  private static func writeDenial() -> String? {
    let policy = snapshot()
    switch policy.sharing {
    case .off:
      return CalendarAgenda.unavailable("The user turned calendar sharing off in Arthur's settings.")
    case .ask where policy.askUntil <= Date():
      return CalendarAgenda.unavailable("The user has not shared the calendar for this turn.")
    case .session where !policy.sessionAllowed:
      return CalendarAgenda.unavailable("The user has not shared the calendar for this session.")
    case .ask, .session, .always:
      break
    }
    guard hasAccess else {
      return CalendarAgenda.unavailable("Calendar access is off in System Settings.")
    }
    return nil
  }

  private static func proposeMove(_ fields: [String: String], confirmed: Bool) -> String {
    guard let toMinute = ClockPhrase.minuteOfDay(fields["to"] ?? "") else {
      return "I need a time to move it to."
    }
    let title = fields["title"] ?? ""
    let fromMinute = ClockPhrase.minuteOfDay(fields["from"] ?? "")
    guard !title.isEmpty || fromMinute != nil else { return "Say which event to move." }
    guard let event = matchEvent(title: title, minute: fromMinute, day: fields["day"] ?? "") else {
      return "I couldn't find that event."
    }
    guard !event.isAllDay, let oldStart = event.startDate, let oldEnd = event.endDate else {
      return "I can only move timed events."
    }
    let duration = oldEnd.timeIntervalSince(oldStart)
    var calendar = Calendar.current
    let day = calendar.startOfDay(for: oldStart)
    guard let newStart = calendar.date(byAdding: .minute, value: toMinute, to: day) else {
      return "I couldn't read that time."
    }
    let newEnd = newStart.addingTimeInterval(duration)
    let name = event.title ?? "Busy"
    let summary = "From \(clock(oldStart)) to \(clock(newStart)). Nothing changes until you approve."
    let kind = StoredKind.move(
      eventId: event.eventIdentifier,
      title: name,
      oldStart: oldStart,
      oldEnd: oldEnd,
      newStart: newStart,
      newEnd: newEnd
    )
    let question = "Shall I move \(name) from \(clock(oldStart)) to \(clock(newStart))?"
    return stage(
      tool: "calendar.move",
      title: "Move \(name)",
      summary: summary,
      args: fields,
      kind: kind,
      question: question,
      confirmed: confirmed
    )
  }

  private static func proposeCreate(_ fields: [String: String], confirmed: Bool) -> String {
    let title = fields["title"] ?? ""
    guard !title.isEmpty else { return "I need a name for the event." }
    guard let startMinute = ClockPhrase.minuteOfDay(fields["start"] ?? "") else {
      return "I need a start time."
    }
    var calendar = Calendar.current
    let day = dayStart(fields["day"] ?? "", calendar: &calendar)
    guard let start = calendar.date(byAdding: .minute, value: startMinute, to: day) else {
      return "I couldn't read that time."
    }
    let end: Date
    if let endMinute = ClockPhrase.minuteOfDay(fields["end"] ?? ""),
       let parsed = calendar.date(byAdding: .minute, value: endMinute, to: day),
       parsed > start {
      end = parsed
    } else {
      end = start.addingTimeInterval(3600)
    }
    let summary = "\(clock(start)) to \(clock(end)). Nothing is added until you approve."
    let kind = StoredKind.createEvent(title: title, start: start, end: end, createdId: nil)
    return stage(
      tool: "calendar.create",
      title: "Add \(title)",
      summary: summary,
      args: fields,
      kind: kind,
      question: "Shall I add \(title) at \(clock(start))?",
      confirmed: confirmed
    )
  }

  private static func proposeReminder(_ fields: [String: String], confirmed: Bool) -> String {
    guard remindersAllowed() else {
      return CalendarAgenda.unavailable("Reminders access is off in System Settings.")
    }
    let title = fields["title"] ?? ""
    guard !title.isEmpty else { return "I need a name for the reminder." }
    var due: Date?
    if let minute = ClockPhrase.minuteOfDay(fields["due"] ?? "") {
      var calendar = Calendar.current
      let day = dayStart(fields["day"] ?? "", calendar: &calendar)
      due = calendar.date(byAdding: .minute, value: minute, to: day)
    }
    let when = due.map { " at \(clock($0))" } ?? ""
    let summary = "Nothing is added until you approve."
    let kind = StoredKind.createReminder(title: title, due: due, createdId: nil)
    return stage(
      tool: "reminders.create",
      title: "Remind \(title)",
      summary: summary,
      args: fields,
      kind: kind,
      question: "Shall I remind you about \(title)\(when)?",
      confirmed: confirmed
    )
  }

  private static func proposeComplete(_ fields: [String: String], confirmed: Bool) -> String {
    guard remindersAllowed() else {
      return CalendarAgenda.unavailable("Reminders access is off in System Settings.")
    }
    let title = fields["title"] ?? ""
    guard !title.isEmpty else { return "Say which reminder to complete." }
    guard let reminder = reminders().first(where: {
      !$0.isCompleted && ($0.title ?? "").localizedCaseInsensitiveContains(title)
    }) else { return "I couldn't find that reminder." }
    let name = reminder.title ?? title
    let kind = StoredKind.completeReminder(id: reminder.calendarItemIdentifier, title: name)
    return stage(
      tool: "reminders.complete",
      title: "Complete \(name)",
      summary: "It stays open until you approve.",
      args: fields,
      kind: kind,
      question: "Shall I mark \(name) done?",
      confirmed: confirmed
    )
  }

  private static func stage(
    tool: String,
    title: String,
    summary: String,
    args: [String: String],
    kind: StoredKind,
    question: String,
    confirmed: Bool
  ) -> String {
    let id = UUID().uuidString
    let stored = StoredWrite(id: id, tool: tool, title: title, args: args, phase: "approve", kind: kind)
    writeLock.lock()
    writes[id] = stored
    writeLock.unlock()
    ActionAudit.append(tool: tool, args: args, approvedBy: "", result: "pending")
    if confirmed {
      if let done = resolve(id: id, granted: true, via: "spoken") {
        onProposal?(done)
      }
      let spoken = question.replacingOccurrences(of: "Shall I ", with: "")
        .replacingOccurrences(of: "?", with: ".")
      return "Done. \(spoken)"
    }
    onProposal?(WriteProposal(id: id, title: title, summary: summary, tool: tool, phase: "approve"))
    return "Pending approval. Nothing has changed. Ask in one short question and do not say it is done. \(question)"
  }

  private static func finish(_ stored: StoredWrite, summary: String, undo: StoredKind, via: String) -> WriteProposal {
    var next = stored
    next.phase = "undo"
    next.kind = undo
    writeLock.lock()
    writes[stored.id] = next
    writeLock.unlock()
    ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: via, result: "done")
    return WriteProposal(id: stored.id, title: stored.title, summary: summary, tool: stored.tool, phase: "undo")
  }

  private static func fail(_ stored: StoredWrite, result: String) -> WriteProposal? {
    ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: "", result: result)
    var next = stored
    next.phase = "failed"
    writeLock.lock()
    writes[stored.id] = next
    writeLock.unlock()
    return WriteProposal(
      id: stored.id,
      title: stored.title,
      summary: "I couldn't change it.",
      tool: stored.tool,
      phase: "failed"
    )
  }

  private static func matchEvent(title: String, minute: Int?, day: String) -> EKEvent? {
    var calendar = Calendar.current
    let start = dayStart(day, calendar: &calendar)
    guard let end = calendar.date(byAdding: .day, value: day.isEmpty ? 2 : 1, to: start) else { return nil }
    let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    let hits = events.filter { event in
      let name = event.title ?? ""
      if !title.isEmpty && !name.localizedCaseInsensitiveContains(title) { return false }
      if let minute {
        guard let when = event.startDate else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: when)
        let eventMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if eventMinute != minute { return false }
      }
      return !title.isEmpty || minute != nil
    }
    return hits.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }.first
  }

  private static func dayStart(_ day: String, calendar: inout Calendar) -> Date {
    let today = calendar.startOfDay(for: Date())
    if day.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tomorrow" {
      return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
    return today
  }

  private static func reminders() -> [EKReminder] {
    let predicate = store.predicateForReminders(in: nil)
    var found: [EKReminder] = []
    var done = false
    store.fetchReminders(matching: predicate) { list in
      found = list ?? []
      done = true
    }
    let deadline = Date().addingTimeInterval(2)
    while !done && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return found
  }

  private static func remindersAllowed() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if status == .fullAccess { return true }
    if status == .notDetermined {
      Task { @MainActor in
        _ = try? await store.requestFullAccessToReminders()
      }
    }
    return false
  }

  private static func stringArgs(_ args: [String: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for (key, value) in args {
      if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out[key] = trimmed }
      } else if let number = value as? NSNumber {
        out[key] = number.stringValue
      }
    }
    return out
  }

  private static func isConfirmed(_ value: Any?) -> Bool {
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String {
      let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return folded == "true" || folded == "yes" || folded == "1"
    }
    return false
  }

  private static func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
  }
}
