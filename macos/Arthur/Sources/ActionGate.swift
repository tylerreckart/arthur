import CryptoKit
import Foundation

/// Clock phrases the model is allowed to pass to a write tool.
enum ClockPhrase {
  /// Minutes from midnight. `16:00`, `4:00 PM`, and `4pm` all parse. A bare
  /// hour without am/pm is 24-hour, so `4:00` is four in the morning.
  static func minuteOfDay(_ raw: String) -> Int? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    text = text.replacingOccurrences(of: ".", with: "")
    text = text.replacingOccurrences(of: " ", with: "")
    guard !text.isEmpty else { return nil }
    var suffix: String?
    if text.hasSuffix("am") || text.hasSuffix("pm") {
      suffix = String(text.suffix(2))
      text = String(text.dropLast(2))
    }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard let hourRaw = Int(parts.first ?? ""), !hourRaw.description.isEmpty else { return nil }
    var hour = hourRaw
    let minute: Int
    if parts.count == 1 {
      minute = 0
    } else if parts.count == 2 || parts.count == 3, let parsed = Int(parts[1]) {
      minute = parsed
    } else {
      return nil
    }
    guard (0...59).contains(minute) else { return nil }
    if let suffix {
      guard (1...12).contains(hour) else { return nil }
      if suffix == "am" {
        if hour == 12 { hour = 0 }
      } else if hour < 12 {
        hour += 12
      }
    } else if hour > 23 {
      return nil
    }
    return hour * 60 + minute
  }
}

/// Append-only local record of a write. Arguments stay a hash.
enum ActionAudit {
  static func hashArgs(_ args: [String: String]) -> String {
    let canonical = args.keys.sorted().map { "\($0)=\(args[$0] ?? "")" }.joined(separator: "\n")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func line(
    at time: Date = Date(),
    tool: String,
    args: [String: String],
    approvedBy: String,
    result: String
  ) -> String {
    let stamp = ISO8601DateFormatter().string(from: time)
    let object: [String: String] = [
      "approved_by": approvedBy,
      "args_hash": hashArgs(args),
      "result": result,
      "time": stamp,
      "tool": tool,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  static func append(
    tool: String,
    args: [String: String],
    approvedBy: String,
    result: String,
    to url: URL = defaultURL
  ) {
    let text = line(tool: tool, args: args, approvedBy: approvedBy, result: result)
    guard !text.isEmpty else { return }
    let path = url.path
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((text + "\n").utf8))
  }

  static var defaultURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Arthur", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("audit.jsonl")
  }
}
