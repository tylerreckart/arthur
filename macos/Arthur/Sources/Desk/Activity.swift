import Foundation

/// One job Arthur is doing, waiting on, or has finished — the single state
/// model behind the Activity panel, the transcript approval card, and the
/// droplet's compact attention card. Pure value logic so it is unit-testable
/// without the app's SwiftUI/AppKit types.
enum JobState: Equatable {
  case needsApproval
  case running(stepLabel: String)
  case blocked(error: String)
  case done(summary: String)
  /// A schedule/todo that is still open — shown under Done & open in Activity.
  case open

  var chipLabel: String {
    switch self {
    case .needsApproval: return "Needs you"
    case .running: return "Running"
    case .blocked: return "Blocked"
    case .done: return "Done"
    case .open: return "Open"
    }
  }

  var sectionTitle: String { chipLabel == "Needs you" ? "Needs you" : chipLabel }
  var needsAttention: Bool {
    switch self { case .needsApproval, .blocked: return true; default: return false }
  }
}

enum JobKind: Equatable { case approval, turn, error, schedule, todo, speakBack }

struct JobItem: Equatable, Identifiable {
  var id: String
  var kind: JobKind
  var title: String
  var summary: String
  var state: JobState
  var primaryLabel: String = ""
  var secondaryLabel: String = ""
}

/// Memory-desk load state: loading, empty, and offline must not look alike.
enum DeskLoadState: Equatable {
  case idle, loading, loaded, failed(String)
  var isLoading: Bool { self == .loading }
  var failureMessage: String? { if case .failed(let m) = self { return m }; return nil }
}

enum ActivityBuilder {
  static func jobs(
    pendingTitle: String, pendingSummary: String, pendingLabel: String,
    isRunning: Bool, workLine: String, canCancel: Bool,
    errorText: String, isOffline: Bool,
    schedules: [DeskSchedule], todos: [DeskTodo],
    speakBackTitle: String = "", speakBackMessage: String = ""
  ) -> [JobItem] {
    var out: [JobItem] = []
    if !pendingLabel.isEmpty {
      out.append(JobItem(
        id: "pending-write", kind: .approval,
        title: pendingTitle.isEmpty ? "Approval needed" : pendingTitle,
        summary: pendingSummary,
        state: .needsApproval,
        primaryLabel: pendingLabel,
        secondaryLabel: pendingLabel == "Approve" ? "Not now" : ""))
    }
    if isRunning {
      out.append(JobItem(
        id: "current-turn", kind: .turn, title: "Arthur is working",
        summary: workLine.isEmpty ? "Working" : workLine,
        state: .running(stepLabel: workLine.isEmpty ? "Working" : workLine),
        primaryLabel: canCancel ? "Stop" : ""))
    }
    let err = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !err.isEmpty {
      out.append(JobItem(
        id: "last-error", kind: .error, title: isOffline ? "Arthur is offline" : "Something needs attention",
        summary: err, state: .blocked(error: err),
        primaryLabel: isOffline ? "Reconnect" : "Retry", secondaryLabel: "Dismiss"))
    }
    if !speakBackMessage.isEmpty {
      out.append(JobItem(
        id: "speak-back", kind: .speakBack,
        title: speakBackTitle.isEmpty ? "Reminder" : speakBackTitle,
        summary: speakBackMessage, state: .done(summary: speakBackMessage)))
    }
    for s in schedules {
      out.append(JobItem(
        id: "schedule-\(s.id)", kind: .schedule,
        title: s.message.isEmpty ? s.phrase : s.message,
        summary: s.phrase, state: .open,
        primaryLabel: "Complete", secondaryLabel: "Cancel"))
    }
    for t in todos {
      out.append(JobItem(
        id: "todo-\(t.id)", kind: .todo, title: t.subject, summary: "",
        state: .open, primaryLabel: "Complete", secondaryLabel: "Cancel"))
    }
    return out
  }

  static func attentionCount(_ jobs: [JobItem]) -> Int { jobs.filter { $0.state.needsAttention }.count }
  static func mostUrgent(_ jobs: [JobItem]) -> JobItem? {
    jobs.first { $0.state == .needsApproval } ?? jobs.first { $0.state.needsAttention }
  }
  static func jobs(in jobs: [JobItem], section: String) -> [JobItem] {
    jobs.filter {
      switch section {
      case "Needs you": return $0.state.needsAttention
      case "Running": if case .running = $0.state { return true }; return false
      default: if case .done = $0.state { return true }; if case .open = $0.state { return true }; return false
      }
    }
  }
}

/// Generates the same natural-language schedule phrase the old free-text
/// field accepted, from a picked date — so the daemon call shape is unchanged.
enum ReschedulePhrase {
  static func phrase(for date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let time = DateFormatter()
    time.locale = Locale(identifier: "en_US_POSIX")
    time.dateFormat = "h:mm a"
    let t = time.string(from: date).lowercased()
    if cal.isDate(date, inSameDayAs: now) { return "today at \(t)" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
       cal.isDate(date, inSameDayAs: tomorrow) {
      return "tomorrow at \(t)"
    }
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "MMM d"
    return "on \(day.string(from: date)) at \(t)"
  }

  static func defaultDate(now: Date = Date()) -> Date {
    var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
    comps.hour = 9; comps.minute = 0
    let today9 = Calendar.current.date(from: comps) ?? now
    return today9 > now ? today9 : Calendar.current.date(byAdding: .day, value: 1, to: today9) ?? now
  }
}
