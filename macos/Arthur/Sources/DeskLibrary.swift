import Foundation

struct MemoryFact: Equatable, Identifiable {
  var id: Int
  var title: String
  var content: String
  var type: String
}

struct DeskSchedule: Equatable, Identifiable {
  var id: Int
  var message: String
  var phrase: String
  var status: String
}

struct DeskTodo: Equatable, Identifiable {
  var id: Int
  var subject: String
  var status: String
}

/// Parses Arbiter list payloads the desk proxy returns unchanged.
enum DeskLibrary {
  static func facts(from data: Data) -> [MemoryFact] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["entries"] as? [[String: Any]]
    else { return [] }
    return rows.compactMap { row in
      guard let id = intField(row["id"]),
            let title = row["title"] as? String
      else { return nil }
      return MemoryFact(
        id: id,
        title: title,
        content: row["content"] as? String ?? "",
        type: row["type"] as? String ?? ""
      )
    }
  }

  static func schedules(from data: Data) -> [DeskSchedule] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["schedules"] as? [[String: Any]]
    else { return [] }
    return rows.compactMap { row in
      guard let id = intField(row["id"]) else { return nil }
      let status = row["status"] as? String ?? ""
      guard status == "active" || status == "paused" else { return nil }
      return DeskSchedule(
        id: id,
        message: row["message"] as? String ?? "",
        phrase: row["schedule_phrase"] as? String ?? "",
        status: status
      )
    }
  }

  static func todos(from data: Data) -> [DeskTodo] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["todos"] as? [[String: Any]]
    else { return [] }
    return rows.compactMap { row in
      guard let id = intField(row["id"]) else { return nil }
      let status = row["status"] as? String ?? ""
      guard status == "pending" || status == "in_progress" else { return nil }
      return DeskTodo(
        id: id,
        subject: row["subject"] as? String ?? "",
        status: status
      )
    }
  }

  static func restoreBody(_ fact: MemoryFact) -> [String: Any] {
    [
      "type": fact.type.isEmpty ? "user" : fact.type,
      "title": fact.title,
      "content": fact.content,
      "source": "desk",
    ]
  }

  private static func intField(_ value: Any?) -> Int? {
    if let n = value as? Int { return n }
    if let n = value as? NSNumber { return n.intValue }
    return nil
  }
}
