import Foundation

struct DiscussionLine: Identifiable, Equatable, Codable {
  let id: UUID
  let fromYou: Bool
  let text: String
  /// Same-turn Arthur `said` chunks share this key so the desk can stitch
  /// them into one bubble. Empty on pre-stitch transcripts.
  var turnId: String
  /// Versioned cards for this turn (weather, generic fallback). Empty on
  /// older transcripts and speech-only turns.
  var surfaces: [ChatSurface]

  enum CodingKeys: String, CodingKey {
    case id, fromYou, text, turnId, surfaces
  }

  init(
    fromYou: Bool,
    text: String,
    id: UUID = UUID(),
    turnId: String = "",
    surfaces: [ChatSurface] = []
  ) {
    self.id = id
    self.fromYou = fromYou
    self.text = text
    self.turnId = turnId
    self.surfaces = surfaces
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    fromYou = try c.decode(Bool.self, forKey: .fromYou)
    text = try c.decode(String.self, forKey: .text)
    turnId = try c.decodeIfPresent(String.self, forKey: .turnId) ?? ""
    surfaces = try c.decodeIfPresent([ChatSurface].self, forKey: .surfaces) ?? []
  }
}

/// Stitch early-flush / sentence-TTS fragments back into spoken prose.
///
/// Intercom emits one `said` per flushed TTS chunk. `early_flush_words`
/// often cuts after ~7 words, `to_speakable` then appends a period, and
/// the next chunk arrives as `", and …"` — three spaced paragraphs for
/// one reply. Join those at append time and again when clustering history.
///
/// Join never drops unique words from either side. Loose substring
/// containment used to treat a forming *tail* as a replacement for the
/// accumulated `said`, which made mid-reply tokens disappear.
enum ArthurProseJoin {
  private static let continuations: Set<String> = [
    "and", "but", "or", "so", "yet", "nor", "then", "though",
    "because", "while", "plus", "also",
  ]

  static func join(_ previous: String, _ incoming: String) -> String {
    let left = previous.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
    if left.isEmpty { return right }
    if right.isEmpty { return left }
    if alreadySpoken(left, right) { return left }
    if isGrowingPrefix(left, right) { return right }
    return stitch(left, right)
  }

  /// Collapse a same-speaker Arthur cluster. `oneBubble` joins every chunk
  /// (one turn). Otherwise only stitch fragments / continuations so a
  /// speak-back after an older untagged reply stays a separate paragraph.
  static func coalesce(_ texts: [String], oneBubble: Bool) -> [String] {
    var out: [String] = []
    for raw in texts {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      if let last = out.last, oneBubble || shouldStitch(last, text) {
        out[out.count - 1] = join(last, text)
      } else {
        out.append(text)
      }
    }
    return out
  }

  static func shouldStitch(_ previous: String, _ incoming: String) -> Bool {
    let left = previous.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !left.isEmpty, !right.isEmpty else { return false }
    if alreadySpoken(left, right) || isGrowingPrefix(left, right) { return true }
    if startsWithClausePunct(right) { return true }
    if endsWithClausePunct(left) { return true }
    if !endsSentence(left) { return true }
    if isContinuationClause(left, right) { return true }
    return false
  }

  /// Incoming is already in `previous` as the same text or a leading prefix.
  /// Used to skip duplicate `said` chunks without treating a shared suffix
  /// ("… sir") or a mid-string phrase as "already have this."
  static func alreadySpoken(_ previous: String, _ incoming: String) -> Bool {
    let h = fold(previous)
    let n = fold(incoming)
    guard !n.isEmpty else { return true }
    return h == n || h.hasPrefix(n + " ")
  }

  /// Incoming is the same text grown by more words (streaming prefix).
  static func isGrowingPrefix(_ previous: String, _ incoming: String) -> Bool {
    let h = fold(previous)
    let n = fold(incoming)
    guard !h.isEmpty, n.count > h.count else { return false }
    return n.hasPrefix(h + " ")
  }

  static func fold(_ text: String) -> String {
    let lowered = text.lowercased().map { ch -> Character in
      if ch.isLetter || ch.isNumber { return ch }
      return " "
    }
    return String(lowered)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func stitch(_ left: String, _ right: String) -> String {
    let rightBare = stripLeadingClausePunct(right)
    if isContinuationClause(left, right) {
      var stem = left
      if endsSentence(stem) {
        stem.removeLast()
        stem = stem.trimmingCharacters(in: .whitespaces)
      }
      if endsWithClausePunct(stem) {
        return stem + " " + rightBare
      }
      return stem + ", " + rightBare
    }
    if startsWithClausePunct(right) {
      if endsSentence(left) {
        var stem = left
        stem.removeLast()
        stem = stem.trimmingCharacters(in: .whitespaces)
        return stem + ", " + rightBare
      }
      if endsWithClausePunct(left) {
        return left + " " + rightBare
      }
      return left + (right.hasPrefix(",") || right.hasPrefix(";") || right.hasPrefix(":")
        ? right
        : ", " + rightBare)
    }
    if endsWithClausePunct(left) || !endsSentence(left) {
      return left + " " + rightBare
    }
    return left + " " + right
  }

  private static func isContinuationClause(_ left: String, _ right: String) -> Bool {
    let trimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)
    let bare = stripLeadingClausePunct(trimmed)
    guard let firstWord = bare.split(whereSeparator: \.isWhitespace).first else { return false }
    guard continuations.contains(String(firstWord).lowercased()) else { return false }
    if startsWithClausePunct(trimmed) { return true }
    if !endsSentence(left) { return true }
    // `to_speakable` adds a period to an early-flush fragment; the real
    // clause continues in lowercase ("sir." + "and given…").
    if let first = bare.first, first.isLowercase { return true }
    return false
  }

  private static func endsSentence(_ text: String) -> Bool {
    guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
    return last == "." || last == "!" || last == "?"
  }

  private static func endsWithClausePunct(_ text: String) -> Bool {
    guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
    return last == "," || last == ";" || last == ":"
  }

  private static func startsWithClausePunct(_ text: String) -> Bool {
    guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
    return first == "," || first == ";" || first == ":"
  }

  private static func stripLeadingClausePunct(_ text: String) -> String {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = s.first, first == "," || first == ";" || first == ":" {
      s.removeFirst()
      s = s.trimmingCharacters(in: .whitespaces)
    }
    return s
  }
}

enum WorkState: Equatable {
  case none
  case findingWords
  case tool(String)
  case speaking

  var line: String {
    switch self {
    case .none: return ""
    case .findingWords: return "Finding the words. I am not sure how long."
    case .tool(let name): return WorkState.describe(name)
    case .speaking: return "Speaking."
    }
  }

  static func describe(_ tool: String) -> String {
    let t = tool.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    switch t {
    case "search": return "Looking something up."
    case "fetch": return "Reading a page."
    case "browse": return "Looking at a page."
    case "mem": return "Checking what I already know."
    case "exec": return "Doing something on the host."
    case "schedule": return "Setting a reminder."
    case "write": return "Writing a note."
    case "read", "list": return "Looking through files."
    default: return "Working on it. I am not sure how long."
    }
  }
}
