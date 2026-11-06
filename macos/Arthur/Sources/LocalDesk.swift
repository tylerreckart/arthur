import Foundation

/// Text Arthur may attach from the Mac in front of the user. Nothing here
/// touches Accessibility, EventKit, or the screen.
enum DeskPresence {
  static func frontmost(app: String, window: String, trusted: Bool) -> String {
    let name = clip(app.isEmpty ? "Unknown" : app, 80)
    if !trusted {
      return "App \(name). Window and selection need Accessibility access, which is off. Do not invent what is on screen."
    }
    let title = clip(window, 120)
    if title.isEmpty { return "App \(name). No window title." }
    return "App \(name). Window \(title)."
  }

  static func selection(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return "Selected text:\n\(clip(trimmed, 2000))"
  }

  static func reminders(_ items: [ReminderLine]) -> String {
    if items.isEmpty { return "No open reminders." }
    var lines: [String] = []
    let shown = items.prefix(20)
    var list = ""
    for item in shown {
      if item.list != list {
        list = item.list
        lines.append(list.isEmpty ? "Reminders:" : "\(clip(list, 40)):")
      }
      let due = item.due.isEmpty ? "" : " (\(item.due))"
      lines.append("- \(clip(item.title.isEmpty ? "Reminder" : item.title, 80))\(due)")
    }
    if items.count > shown.count {
      lines.append("- \(items.count - shown.count) more.")
    }
    return lines.joined(separator: "\n")
  }

  static func finderHits(_ paths: [String]) -> String {
    let shown = paths.prefix(8).map { clip($0, 180) }.filter { !$0.isEmpty }
    if shown.isEmpty { return "No matching files in your home folder." }
    var lines = shown.map { "- \($0)" }
    if paths.count > shown.count {
      lines.append("- \(paths.count - shown.count) more.")
    }
    return lines.joined(separator: "\n")
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit - 1)) + "…"
  }
}

struct ReminderLine: Equatable {
  var list: String
  var title: String
  var due: String
}

enum DeskFiles {
  static func kind(filename: String) -> Kind {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    if imageExtensions.contains(ext) { return .image }
    if textExtensions.contains(ext) { return .text }
    return .other
  }

  static func textNote(name: String, body: String) -> String {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = title.isEmpty ? "file" : title
    let clipped = clip(body, 3500)
    if clipped.isEmpty { return "\(shown)\nThe file was empty." }
    return "\(shown)\n\(clipped)"
  }

  static func otherNote(name: String) -> String {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = title.isEmpty ? "A file" : title
    return "\(shown) is attached. Only text and images can be read."
  }

  static func imageNote(name: String) -> String {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = title.isEmpty ? "A picture" : title
    return "\(shown) is attached as an image on this turn."
  }

  /// Spotlight name query, or empty when the words are not safe to search.
  static func finderQuery(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    var term = ""
    for scalar in trimmed.unicodeScalars {
      if term.count >= 60 { break }
      if scalar.value < 32 || scalar.value == 0x7f { continue }
      if "\"'\\*`".unicodeScalars.contains(scalar) { continue }
      term.unicodeScalars.append(scalar)
    }
    term = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard term.count >= 2 else { return "" }
    return "kMDItemDisplayName == '*\(term)*'cd"
  }

  static func webURL(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: text),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host,
          !host.isEmpty,
          url.user == nil
    else { return nil }
    return url.absoluteString
  }

  static func appName(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...60).contains(text.count) else { return nil }
    for scalar in text.unicodeScalars {
      if scalar.value < 32 { return nil }
      let ok = CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "." ||
        scalar == "-" || scalar == "+"
      if !ok { return nil }
    }
    return text
  }

  static func email(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    guard text.count <= 120, text.contains("@"), text.contains("."), !text.contains(" ") else { return nil }
    for scalar in text.unicodeScalars {
      if !scalar.isASCII || scalar.value < 33 { return nil }
      if scalar == "\"" || scalar == "\\" || scalar == "<" || scalar == ">" { return nil }
    }
    return text
  }

  /// AppleScript double-quoted string body. Drops control characters.
  static func appleString(_ raw: String) -> String {
    var out = ""
    for scalar in raw.unicodeScalars {
      if out.count >= 4000 { break }
      switch scalar {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n", "\r": out += " "
      default:
        if scalar.value < 32 { continue }
        out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  static func utf8Text(_ data: Data) -> String? {
    guard !data.isEmpty, data.count <= 64_000, !data.contains(0) else { return nil }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let sample = text.prefix(512)
    let odd = sample.unicodeScalars.filter { $0.value < 9 || ($0.value > 13 && $0.value < 32) }.count
    if odd > 8 { return nil }
    return text
  }

  enum Kind: Equatable {
    case text
    case image
    case other
  }

  private static let textExtensions: Set<String> = [
    "txt", "md", "swift", "json", "log", "csv", "py", "cpp", "cc", "c", "h", "hpp",
    "rs", "ts", "tsx", "js", "jsx", "html", "css", "xml", "yaml", "yml", "toml",
    "sh", "zsh", "rb", "go", "java", "kt", "m", "mm",
  ]
  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic",
  ]

  private static func clip(_ text: String, _ limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit - 1)) + "…"
  }
}
