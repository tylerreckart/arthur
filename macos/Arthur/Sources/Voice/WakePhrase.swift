import Foundation

/// The Mac wake word. A leading "Arthur", optionally after "hey" or "ok".
/// "yesterday" and "marthur" do not match. This is not a command grammar.
enum WakePhrase {
  static func matches(_ text: String) -> Bool {
    let words = tokens(text)
    guard let first = words.first else { return false }
    if first == "arthur" { return true }
    if words.count >= 2, (first == "hey" || first == "ok"), words[1] == "arthur" {
      return true
    }
    return false
  }

  private static func tokens(_ text: String) -> [String] {
    var word = ""
    var words: [String] = []
    for ch in text.lowercased() {
      if ch.isLetter {
        word.append(ch)
      } else if !word.isEmpty {
        words.append(word)
        word = ""
      }
    }
    if !word.isEmpty { words.append(word) }
    return words
  }
}

/// A partial `heard` paints the live line. The final one is the transcript.
enum HeardLine: Equatable {
  case live(String)
  case commit(String)

  static func interpret(text: String, partial: Bool) -> HeardLine? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return partial ? .live(trimmed) : .commit(trimmed)
  }
}
