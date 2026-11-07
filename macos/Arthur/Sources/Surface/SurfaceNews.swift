import Foundation

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
