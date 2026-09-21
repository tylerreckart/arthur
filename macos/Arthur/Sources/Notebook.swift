import Foundation

struct DiscussionLine: Identifiable, Equatable, Codable {
  let id: UUID
  let fromYou: Bool
  let text: String

  init(fromYou: Bool, text: String) {
    self.id = UUID()
    self.fromYou = fromYou
    self.text = text
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
