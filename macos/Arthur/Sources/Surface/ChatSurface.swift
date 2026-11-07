import Foundation

/// Closed `surface.kind` values. Unknown wire kinds become `.generic`
/// so a new Intercom kind never drops the turn.
enum SurfaceKind: String, Codable, Hashable {
  case weather
  case generic
  case article
  case news
  case sourceList = "source_list"
  case markets
}

/// Optional desk action. Unknown or incomplete rows are skipped.
struct SurfaceAction: Equatable, Codable, Hashable, Identifiable {
  var id: String
  var label: String
  var kind: String
  var toolCall: JSONValue

  init(id: String, label: String, kind: String, toolCall: JSONValue = .object([:])) {
    self.id = id
    self.label = label
    self.kind = kind
    self.toolCall = toolCall
  }
}

struct SurfaceSource: Equatable, Codable, Hashable, Identifiable {
  var title: String
  var url: String

  var id: String { title + "|" + url }

  var link: URL? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return nil }
    return url
  }
}

/// Versioned desk card attached to an Arthur turn.
struct ChatSurface: Equatable, Codable, Identifiable, Hashable {
  var id: UUID
  /// Wire kind, even when we only know how to render it as generic.
  var kindRaw: String
  var version: Int
  var title: String
  var summary: String
  var payload: JSONValue
  var sources: [SurfaceSource]
  var actions: [SurfaceAction]

  var kind: SurfaceKind {
    SurfaceKind(rawValue: kindRaw) ?? .generic
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, version, title, summary, payload, sources, actions
  }

  init(
    id: UUID = UUID(),
    kindRaw: String,
    version: Int = 1,
    title: String,
    summary: String,
    payload: JSONValue = .object([:]),
    sources: [SurfaceSource] = [],
    actions: [SurfaceAction] = []
  ) {
    self.id = id
    self.kindRaw = kindRaw
    self.version = version
    self.title = title
    self.summary = summary
    self.payload = payload
    self.sources = sources
    self.actions = actions
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    kindRaw = try c.decodeIfPresent(String.self, forKey: .kind) ?? "generic"
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
    sources = try c.decodeIfPresent([SurfaceSource].self, forKey: .sources) ?? []
    actions = try c.decodeIfPresent([SurfaceAction].self, forKey: .actions) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(kindRaw, forKey: .kind)
    try c.encode(version, forKey: .version)
    try c.encode(title, forKey: .title)
    try c.encode(summary, forKey: .summary)
    try c.encode(payload, forKey: .payload)
    if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
    if !actions.isEmpty { try c.encode(actions, forKey: .actions) }
  }

  func isDuplicate(of other: ChatSurface) -> Bool {
    kindRaw == other.kindRaw && title == other.title && summary == other.summary
  }

  var weather: WeatherPayload? {
    guard kind == .weather else { return nil }
    return WeatherPayload(payload)
  }

  var news: NewsPayload? {
    guard kind == .news else { return nil }
    return NewsPayload(payload)
  }

  var markets: MarketsPayload? {
    guard kind == .markets else { return nil }
    return MarketsPayload(payload)
  }

  /// Primitive payload pairs for the generic card.
  var fields: [(label: String, value: String)] {
    guard case .object(let obj) = payload else { return [] }
    let skip: Set<String> = [
      "hours", "days", "forecast", "body", "markdown", "text", "html",
      "items", "instruments", "proposal_id",
    ]
    var out: [(String, String)] = []
    for key in obj.keys.sorted() {
      if skip.contains(key) { continue }
      guard let value = obj[key]?.displayString, !value.isEmpty else { continue }
      out.append((Self.prettyLabel(key), value))
    }
    return out
  }

  var markdownBody: String {
    guard case .object(let obj) = payload else { return "" }
    for key in ["body", "markdown", "text"] {
      if let value = obj[key]?.displayString, !value.isEmpty { return value }
    }
    return ""
  }

  /// Decode a WS `{type:surface, turn_id, surface}` object. Returns nil
  /// only when `surface` is missing or not an object — unknown kinds still
  /// succeed as generic.
  static func decodeEvent(_ json: [String: Any]) -> (turnId: String, surface: ChatSurface)? {
    let turnId = json["turn_id"] as? String ?? ""
    guard let raw = json["surface"] as? [String: Any] else { return nil }
    return (turnId, decode(raw))
  }

  static func decode(_ json: [String: Any]) -> ChatSurface {
    let kind = json["kind"] as? String ?? "generic"
    let version: Int
    if let n = json["version"] as? Int {
      version = n
    } else if let n = json["version"] as? NSNumber {
      version = n.intValue
    } else {
      version = 1
    }
    var sources: [SurfaceSource] = []
    var actions: [SurfaceAction] = []
    if let rows = json["actions"] as? [Any] {
      for row in rows {
        guard let obj = row as? [String: Any] else { continue }
        let id = obj["id"] as? String ?? ""
        let label = obj["label"] as? String ?? ""
        let kind = obj["kind"] as? String ?? ""
        guard !id.isEmpty, !label.isEmpty, !kind.isEmpty else { continue }
        let toolCall = JSONValue.fromAny(obj["tool_call"] ?? [:])
        actions.append(SurfaceAction(id: id, label: label, kind: kind, toolCall: toolCall))
      }
    }
    if let rows = json["sources"] as? [[String: Any]] {
      for row in rows {
        let title = row["title"] as? String ?? ""
        let url = row["url"] as? String ?? ""
        if !title.isEmpty || !url.isEmpty {
          sources.append(SurfaceSource(title: title, url: url))
        }
      }
    }
    return ChatSurface(
      kindRaw: kind,
      version: version,
      title: json["title"] as? String ?? "",
      summary: json["summary"] as? String ?? "",
      payload: JSONValue.fromAny(json["payload"] ?? [:]),
      sources: sources,
      actions: actions
    )
  }

  private static func prettyLabel(_ key: String) -> String {
    key.split(separator: "_")
      .map { part in
        guard let first = part.first else { return "" }
        return String(first).uppercased() + part.dropFirst()
      }
      .joined(separator: " ")
  }
}
