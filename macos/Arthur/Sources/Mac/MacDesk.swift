import AppKit
import EventKit
import Foundation

/// Reminders, Finder, Mail drafts, and opening an app or page.
/// Reads run only when the user has opted in. Writes stage a card.
enum MacDesk {
  struct WriteCard: Equatable {
    var id: String
    var title: String
    var summary: String
    var tool: String
    var phase: String
  }

  static var onProposal: ((WriteCard) -> Void)?

  private static let store = EKEventStore()
  private static let lock = NSLock()
  private static var toolsOn = false
  private static let writeLock = NSLock()
  private static var writes: [String: Stored] = [:]

  static func configure(toolsOn: Bool) {
    lock.lock()
    self.toolsOn = toolsOn
    lock.unlock()
  }

  static func remindersText() -> String {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync { remindersText() }
    }
    guard optedIn() else {
      return CalendarAgenda.unavailable("The user turned reminders off in Arthur's settings.")
    }
    guard remindersAllowed() else {
      return CalendarAgenda.unavailable("Reminders access is off in System Settings.")
    }
    let lines = reminders().filter { !$0.isCompleted }.prefix(24).map { item in
      ReminderLine(
        list: item.calendar.title,
        title: item.title ?? "Reminder",
        due: dueText(item)
      )
    }
    return DeskPresence.reminders(Array(lines))
  }

  static func finderText(query: String) -> String {
    guard optedIn() else {
      return CalendarAgenda.unavailable("The user turned Finder search off in Arthur's settings.")
    }
    let mdfind = DeskFiles.finderQuery(query)
    guard !mdfind.isEmpty else { return "Say a name to look for." }
    return DeskPresence.finderHits(spotlight(mdfind))
  }

  static func propose(tool: String, args: [String: Any]) -> String {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync { propose(tool: tool, args: args) }
    }
    guard optedIn() else {
      return CalendarAgenda.unavailable("The user turned these Mac actions off in Arthur's settings.")
    }
    let fields = stringArgs(args)
    let confirmed = isConfirmed(args["confirmed"])
    switch tool {
    case "finder.reveal":
      return proposeReveal(fields, confirmed: confirmed)
    case "mail.draft":
      return proposeMail(fields, confirmed: confirmed)
    case "open.url":
      return proposeURL(fields, confirmed: confirmed)
    case "open.app":
      return proposeApp(fields, confirmed: confirmed)
    default:
      return "That action is not available."
    }
  }

  static func resolve(id: String, granted: Bool, via: String) -> WriteCard? {
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
        return stored.card(summary: "")
      }
      stored.phase = "dismissed"
      writes[id] = stored
      writeLock.unlock()
      ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: via, result: "dismissed")
      return stored.card(summary: "Left as it was.")
    }
    if stored.phase == "undo" {
      stored.phase = "undoing"
      writes[id] = stored
      writeLock.unlock()
      return undo(stored, via: via)
    }
    guard stored.phase == "approve" else {
      writeLock.unlock()
      return stored.card(summary: "")
    }
    stored.phase = "running"
    writes[id] = stored
    writeLock.unlock()
    switch stored.kind {
    case .reveal(let path):
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: url.path) else { return fail(stored, result: "missing") }
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return finish(stored, summary: "Revealed in Finder.", via: via, undo: nil)
    case .mail(let to, let subject, let body, _):
      guard let messageId = createDraft(to: to, subject: subject, body: body) else {
        return fail(stored, result: "failed")
      }
      var kind = stored.kind
      kind = .mail(to: to, subject: subject, body: body, messageId: messageId)
      stored.kind = kind
      return finish(stored, summary: "Draft ready. Undo deletes it. It was not sent.", via: via, undo: kind)
    case .openURL(let url):
      guard let target = URL(string: url) else { return fail(stored, result: "failed") }
      guard NSWorkspace.shared.open(target) else { return fail(stored, result: "failed") }
      return finish(stored, summary: "Opened.", via: via, undo: nil)
    case .openApp(let name):
      guard openApp(named: name) else { return fail(stored, result: "missing") }
      return finish(stored, summary: "Opened \(name).", via: via, undo: nil)
    }
  }

  private static func proposeReveal(_ fields: [String: String], confirmed: Bool) -> String {
    guard let path = homeFile(fields["path"] ?? "") else {
      return "I can only reveal a file that is already in your home folder."
    }
    let name = URL(fileURLWithPath: path).lastPathComponent
    return stage(
      tool: "finder.reveal",
      title: "Reveal \(name)",
      summary: "Nothing opens until you approve.",
      args: ["path": path],
      kind: .reveal(path: path),
      question: "Shall I show \(name) in Finder?",
      confirmed: confirmed
    )
  }

  private static func proposeMail(_ fields: [String: String], confirmed: Bool) -> String {
    let subject = String((fields["subject"] ?? "").prefix(180))
    guard !subject.isEmpty else { return "I need a subject for the draft." }
    let body = String((fields["body"] ?? "").prefix(4000))
    var to = ""
    if let raw = fields["to"], !raw.isEmpty {
      guard let email = DeskFiles.email(raw) else { return "That address does not look usable." }
      to = email
    }
    let who = to.isEmpty ? "" : " to \(to)"
    return stage(
      tool: "mail.draft",
      title: "Draft\(who)",
      summary: "\(subject). Nothing is created until you approve. It will not be sent.",
      args: ["to": to, "subject": subject, "body": body],
      kind: .mail(to: to, subject: subject, body: body, messageId: ""),
      question: "Shall I draft\(who) about \(subject)?",
      confirmed: confirmed
    )
  }

  private static func proposeURL(_ fields: [String: String], confirmed: Bool) -> String {
    guard let url = DeskFiles.webURL(fields["url"] ?? "") else {
      return "I can only open an http or https address."
    }
    return stage(
      tool: "open.url",
      title: "Open page",
      summary: "Nothing opens until you approve.",
      args: ["url": url],
      kind: .openURL(url),
      question: "Shall I open that page?",
      confirmed: confirmed
    )
  }

  private static func proposeApp(_ fields: [String: String], confirmed: Bool) -> String {
    guard let name = DeskFiles.appName(fields["name"] ?? "") else { return "Say which app to open." }
    guard appURL(named: name) != nil else { return "I couldn't find that app." }
    return stage(
      tool: "open.app",
      title: "Open \(name)",
      summary: "Nothing opens until you approve.",
      args: ["name": name],
      kind: .openApp(name),
      question: "Shall I open \(name)?",
      confirmed: confirmed
    )
  }

  private static func stage(
    tool: String,
    title: String,
    summary: String,
    args: [String: String],
    kind: Kind,
    question: String,
    confirmed: Bool
  ) -> String {
    let id = UUID().uuidString
    let stored = Stored(id: id, tool: tool, title: title, args: args, phase: "approve", kind: kind)
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
    onProposal?(stored.card(summary: summary))
    return "Pending approval. Nothing has changed. Ask in one short question and do not say it is done. \(question)"
  }

  private static func finish(_ stored: Stored, summary: String, via: String, undo: Kind?) -> WriteCard {
    var next = stored
    if let undo {
      next.phase = "undo"
      next.kind = undo
    } else {
      next.phase = "done"
    }
    writeLock.lock()
    writes[stored.id] = next
    writeLock.unlock()
    ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: via, result: "done")
    return next.card(summary: summary)
  }

  private static func undo(_ stored: Stored, via: String) -> WriteCard? {
    switch stored.kind {
    case .mail(_, _, _, let messageId):
      guard deleteDraft(messageId) else { return fail(stored, result: "missing") }
    case .reveal, .openURL, .openApp:
      return fail(stored, result: "failed")
    }
    var done = stored
    done.phase = "done"
    writeLock.lock()
    writes[stored.id] = done
    writeLock.unlock()
    ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: via, result: "undone")
    return done.card(summary: "Draft deleted.")
  }

  private static func fail(_ stored: Stored, result: String) -> WriteCard {
    ActionAudit.append(tool: stored.tool, args: stored.args, approvedBy: "", result: result)
    var next = stored
    next.phase = "failed"
    writeLock.lock()
    writes[stored.id] = next
    writeLock.unlock()
    return next.card(summary: "I couldn't change it.")
  }

  private static func optedIn() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return toolsOn
  }

  private static func homeFile(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
    let target = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard target.path == home.path || target.path.hasPrefix(prefix) else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else { return nil }
    return target.path
  }

  private static func spotlight(_ query: String) -> [String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    task.arguments = ["-onlyin", NSHomeDirectory(), query]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return [] }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      task.waitUntilExit()
      group.leave()
    }
    if group.wait(timeout: .now() + 2) == .timedOut {
      task.terminate()
      return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
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

  private static func dueText(_ item: EKReminder) -> String {
    guard let due = item.dueDateComponents?.date else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "EEE h:mm a"
    return formatter.string(from: due)
  }

  private static func appURL(named name: String) -> URL? {
    if name.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
      return url
    }
    let file = name.hasSuffix(".app") ? name : name + ".app"
    let folders = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]
    for folder in folders {
      let url = folder.appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  private static func openApp(named name: String) -> Bool {
    guard let url = appURL(named: name) else { return false }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    return true
  }

  private static func createDraft(to: String, subject: String, body: String) -> String? {
    let subjectLit = DeskFiles.appleString(subject)
    let bodyLit = DeskFiles.appleString(body)
    var lines = [
      "tell application \"Mail\"",
      "set msg to make new outgoing message with properties {subject:\"\(subjectLit)\", content:\"\(bodyLit)\", visible:true}",
    ]
    if let email = DeskFiles.email(to) {
      lines.append("tell msg")
      lines.append("make new to recipient at end of to recipients with properties {address:\"\(email)\"}")
      lines.append("end tell")
    }
    lines.append("return id of msg")
    lines.append("end tell")
    guard let raw = runApple(lines.joined(separator: "\n")) else { return nil }
    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
    return id
  }

  private static func deleteDraft(_ messageId: String) -> Bool {
    guard messageId.allSatisfy(\.isNumber), !messageId.isEmpty else { return false }
    let source = """
    tell application "Mail"
      delete (first outgoing message whose id is \(messageId))
    end tell
    """
    return runApple(source) != nil
  }

  private static func runApple(_ source: String) -> String? {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return nil }
    let result = script.executeAndReturnError(&error)
    if error != nil { return nil }
    return result.stringValue ?? ""
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

  private struct Stored {
    var id: String
    var tool: String
    var title: String
    var args: [String: String]
    var phase: String
    var kind: Kind

    func card(summary: String) -> WriteCard {
      WriteCard(id: id, title: title, summary: summary, tool: tool, phase: phase)
    }
  }

  private enum Kind {
    case reveal(path: String)
    case mail(to: String, subject: String, body: String, messageId: String)
    case openURL(String)
    case openApp(String)
  }
}
