import Foundation

struct HistoryLine: Equatable {
  var id: UUID
  var text: String
}

struct HistoryThread: Equatable {
  var id: UUID
  var title: String
  var updatedAt: Date
  var lines: [HistoryLine]
}

struct HistoryHit: Equatable, Identifiable {
  var conversationId: UUID
  var title: String
  var lineIndex: Int
  var lineId: UUID
  var snippet: String
  var updatedAt: Date

  var id: String { "\(conversationId.uuidString)-\(lineIndex)" }
}

/// Full-text search and paging over the desk's saved conversations.
enum HistorySearch {
  static func hits(in conversations: [HistoryThread], query: String) -> [HistoryHit] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard needle.count >= 2 else { return [] }
    var out: [HistoryHit] = []
    for item in conversations {
      for (index, line) in item.lines.enumerated() {
        guard line.text.range(of: needle, options: String.CompareOptions.caseInsensitive) != nil else { continue }
        out.append(HistoryHit(
          conversationId: item.id,
          title: item.title,
          lineIndex: index,
          lineId: line.id,
          snippet: snippet(line.text),
          updatedAt: item.updatedAt
        ))
        if out.count == 40 { break }
      }
      if out.count == 40 { break }
    }
    return out.sorted { $0.updatedAt > $1.updatedAt }
  }

  /// How many lines from the end to keep on screen so `focusIndex` is included.
  static func shownCount(total: Int, focusIndex: Int?) -> Int {
    let page = DiscussionLimits.visibleLineCap
    guard total > page else { return total }
    guard let focusIndex, focusIndex >= 0, focusIndex < total else { return page }
    let fromEnd = total - focusIndex
    let pages = max(1, (fromEnd + page - 1) / page)
    return min(total, pages * page)
  }

  private static func snippet(_ text: String) -> String {
    let flat = text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if flat.count <= 90 { return flat }
    return String(flat.prefix(89)) + "…"
  }
}
