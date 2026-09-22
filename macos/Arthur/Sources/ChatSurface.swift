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

  var kind: SurfaceKind {
    SurfaceKind(rawValue: kindRaw) ?? .generic
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, version, title, summary, payload, sources
  }

  init(
    id: UUID = UUID(),
    kindRaw: String,
    version: Int = 1,
    title: String,
    summary: String,
    payload: JSONValue = .object([:]),
    sources: [SurfaceSource] = []
  ) {
    self.id = id
    self.kindRaw = kindRaw
    self.version = version
    self.title = title
    self.summary = summary
    self.payload = payload
    self.sources = sources
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
      "items", "instruments",
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
      sources: sources
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

struct WeatherSlot: Equatable, Hashable, Identifiable {
  var label: String
  var condition: String
  var conditionLabel: String
  var temperature: Int?
  var temperatureLow: Int?

  var id: String { label + "|" + (temperature.map(String.init) ?? "") }

  var temperatureText: String {
    if let high = temperature, let low = temperatureLow {
      return "\(high)° / \(low)°"
    }
    if let high = temperature { return "\(high)°" }
    if let low = temperatureLow { return "\(low)°" }
    return ""
  }
}

struct WeatherPayload: Equatable, Hashable {
  var condition: String
  var conditionLabel: String
  var temperature: Int?
  var temperatureUnit: String
  var feelsLike: Int?
  var humidity: Int?
  var windSpeed: Double?
  var windUnit: String
  var hours: [WeatherSlot]
  var days: [WeatherSlot]

  init(_ value: JSONValue) {
    let obj = value.object
    condition = obj["condition"]?.displayString ?? ""
    conditionLabel = obj["condition_label"]?.displayString ?? ""
    if conditionLabel.isEmpty { conditionLabel = WeatherSymbol.label(for: condition) }
    temperature = obj["temperature"]?.intValue
    temperatureUnit = obj["temperature_unit"]?.displayString ?? ""
    feelsLike = obj["feels_like"]?.intValue
    humidity = obj["humidity"]?.intValue
    windSpeed = obj["wind_speed"]?.doubleValue
    windUnit = obj["wind_unit"]?.displayString ?? ""
    hours = obj["hours"]?.array.compactMap(WeatherSlot.init) ?? []
    days = obj["days"]?.array.compactMap(WeatherSlot.init) ?? []
  }
}

private extension WeatherSlot {
  init?(_ value: JSONValue) {
    let obj = value.object
    let label = obj["label"]?.displayString ?? ""
    let condition = obj["condition"]?.displayString ?? ""
    let conditionLabel = obj["condition_label"]?.displayString
      ?? WeatherSymbol.label(for: condition)
    let temperature = obj["temperature"]?.intValue
    let temperatureLow = obj["temperature_low"]?.intValue
    if label.isEmpty, temperature == nil, condition.isEmpty { return nil }
    self.init(
      label: label.isEmpty ? "—" : label,
      condition: condition,
      conditionLabel: conditionLabel,
      temperature: temperature,
      temperatureLow: temperatureLow
    )
  }
}

enum WeatherSymbol {
  static func systemImage(for condition: String) -> String {
    let key = condition.lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    if key.contains("clear night") || key == "clearnight" { return "moon.stars.fill" }
    if key.contains("partly") { return "cloud.sun.fill" }
    if key.contains("lightning") || key.contains("thunder") { return "cloud.bolt.fill" }
    if key.contains("snow") { return "cloud.snow.fill" }
    if key.contains("pouring") || key.contains("heavy") { return "cloud.heavyrain.fill" }
    if key.contains("rain") { return "cloud.rain.fill" }
    if key.contains("hail") { return "cloud.hail.fill" }
    if key.contains("fog") { return "cloud.fog.fill" }
    if key.contains("wind") { return "wind" }
    if key.contains("cloud") { return "cloud.fill" }
    if key.contains("sun") || key.contains("clear") { return "sun.max.fill" }
    return "cloud.sun.fill"
  }

  static func label(for condition: String) -> String {
    let key = condition.lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    if key == "partlycloudy" || key == "partly cloudy" { return "Partly cloudy" }
    if key.isEmpty { return "" }
    return key.split(separator: " ").map { part in
      guard let first = part.first else { return "" }
      return String(first).uppercased() + part.dropFirst()
    }.joined(separator: " ")
  }
}

struct NewsItem: Equatable, Hashable, Identifiable {
  var title: String
  var summary: String
  var source: String
  var url: String
  var publishedAt: String

  var id: String { url.isEmpty ? title : url }

  var link: URL? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return nil }
    return url
  }

  var relativeTime: String {
    guard let date = Self.parsePublished(publishedAt) else { return "" }
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    return fmt.localizedString(for: date, relativeTo: Date())
  }

  private static func parsePublished(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: trimmed) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) { return date }
    let rfc = DateFormatter()
    rfc.locale = Locale(identifier: "en_US_POSIX")
    rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    if let date = rfc.date(from: trimmed) { return date }
    rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return rfc.date(from: trimmed)
  }
}

struct NewsPayload: Equatable, Hashable {
  var items: [NewsItem]
  var topic: String

  init(_ value: JSONValue) {
    let obj = value.object
    topic = obj["topic"]?.displayString ?? ""
    items = obj["items"]?.array.compactMap(NewsItem.init) ?? []
  }
}

private extension NewsItem {
  init?(_ value: JSONValue) {
    let obj = value.object
    let title = obj["title"]?.displayString ?? ""
    if title.isEmpty { return nil }
    self.init(
      title: title,
      summary: obj["summary"]?.displayString ?? "",
      source: obj["source"]?.displayString ?? "",
      url: obj["url"]?.displayString ?? "",
      publishedAt: obj["published_at"]?.displayString ?? ""
    )
  }
}

struct MarketInstrument: Equatable, Hashable, Identifiable {
  var symbol: String
  var name: String
  var price: Double?
  var change: Double?
  var changePct: Double?
  var currency: String
  var asOf: String

  var id: String { symbol }

  var priceText: String {
    guard let price else { return "—" }
    return MarketInstrument.formatPrice(price, currency: currency)
  }

  var changeText: String {
    guard let changePct else {
      guard let change else { return "" }
      return String(format: "%+.2f", change)
    }
    return String(format: "%+.2f%%", changePct)
  }

  var isUp: Bool { (changePct ?? change ?? 0) > 0 }
  var isDown: Bool { (changePct ?? change ?? 0) < 0 }

  static func formatPrice(_ price: Double, currency: String) -> String {
    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    fmt.minimumFractionDigits = price >= 1000 ? 0 : 2
    fmt.maximumFractionDigits = 2
    let body = fmt.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
    if currency.isEmpty || currency == "USD" { return body }
    return "\(body) \(currency)"
  }
}

struct MarketsPayload: Equatable, Hashable {
  var instruments: [MarketInstrument]
  var marketSummary: String

  init(_ value: JSONValue) {
    let obj = value.object
    marketSummary = obj["market_summary"]?.displayString ?? ""
    instruments = obj["instruments"]?.array.compactMap(MarketInstrument.init) ?? []
  }
}

private extension MarketInstrument {
  init?(_ value: JSONValue) {
    let obj = value.object
    let symbol = obj["symbol"]?.displayString ?? ""
    if symbol.isEmpty { return nil }
    var asOf = obj["as_of"]?.displayString ?? ""
    if asOf.isEmpty, let unix = obj["as_of"]?.intValue, unix > 0 {
      asOf = String(unix)
    }
    self.init(
      symbol: symbol,
      name: obj["name"]?.displayString ?? "",
      price: obj["price"]?.doubleValue,
      change: obj["change"]?.doubleValue,
      changePct: obj["change_pct"]?.doubleValue,
      currency: obj["currency"]?.displayString ?? "",
      asOf: asOf
    )
  }
}

/// Codable JSON tree so surface payloads survive transcript relaunch.
enum JSONValue: Equatable, Hashable, Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  var object: [String: JSONValue] {
    if case .object(let obj) = self { return obj }
    return [:]
  }

  var array: [JSONValue] {
    if case .array(let arr) = self { return arr }
    return []
  }

  var displayString: String {
    switch self {
    case .string(let s): return s
    case .number(let d):
      if d.rounded() == d { return String(Int(d)) }
      return String(d)
    case .bool(let b): return b ? "Yes" : "No"
    case .null: return ""
    case .object, .array: return ""
    }
  }

  var intValue: Int? {
    switch self {
    case .number(let d): return Int(d.rounded())
    case .string(let s): return Int(s)
    default: return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .number(let d): return d
    case .string(let s): return Double(s)
    default: return nil
    }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? c.decode(Int.self) {
      self = .number(Double(i))
    } else if let d = try? c.decode(Double.self) {
      self = .number(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else if let o = try? c.decode([String: JSONValue].self) {
      self = .object(o)
    } else {
      self = .null
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .number(let d):
      if d.rounded() == d, d >= Double(Int.min), d <= Double(Int.max) {
        try c.encode(Int(d))
      } else {
        try c.encode(d)
      }
    case .bool(let b): try c.encode(b)
    case .object(let o): try c.encode(o)
    case .array(let a): try c.encode(a)
    case .null: try c.encodeNil()
    }
  }

  static func fromAny(_ raw: Any) -> JSONValue {
    switch raw {
    case let s as String: return .string(s)
    case let n as Int: return .number(Double(n))
    case let n as Int64: return .number(Double(n))
    case let n as Double: return .number(n)
    case let n as Float: return .number(Double(n))
    case let n as NSNumber:
      // NSNumber is also Bool's bridging type.
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        return .bool(n.boolValue)
      }
      return .number(n.doubleValue)
    case let b as Bool: return .bool(b)
    case let arr as [Any]: return .array(arr.map(fromAny))
    case let obj as [String: Any]:
      var out: [String: JSONValue] = [:]
      for (k, v) in obj { out[k] = fromAny(v) }
      return .object(out)
    default: return .null
    }
  }
}
