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
    let source = FeedPlainText.plain(obj["source"]?.displayString ?? "")
    let title = FeedPlainText.strippingSource(FeedPlainText.plain(obj["title"]?.displayString ?? ""), source: source)
    if title.isEmpty { return nil }
    self.init(
      title: title,
      summary: FeedPlainText.usefulSummary(obj["summary"]?.displayString ?? "", title: title, source: source),
      source: source,
      url: obj["url"]?.displayString ?? "",
      publishedAt: obj["published_at"]?.displayString ?? ""
    )
  }
}

/// Feed blurbs often arrive as escaped markup (`&lt;ol&gt;...`). Turn that
/// into text, and drop a blurb that only repeats the headline.
private enum FeedPlainText {
  static func plain(_ raw: String) -> String {
    let decoded = decode(decode(raw))
    return collapse(decode(stripTags(decoded)))
  }

  static func strippingSource(_ title: String, source: String) -> String {
    let suffix = " - \(source)"
    guard !source.isEmpty, title.count > suffix.count else { return title }
    let end = title.suffix(suffix.count)
    guard end.lowercased() == suffix.lowercased() else { return title }
    return title.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func usefulSummary(_ raw: String, title: String, source: String) -> String {
    let text = plain(raw)
    if text.isEmpty { return "" }
    let folded = text.lowercased()
    if folded.contains("<") || folded.contains("http://") || folded.contains("https://") {
      return ""
    }
    var rest = folded
    let titleFolded = title.lowercased()
    if !titleFolded.isEmpty {
      rest = rest.replacingOccurrences(of: titleFolded, with: "")
    }
    let sourceFolded = source.lowercased()
    if !sourceFolded.isEmpty {
      rest = rest.replacingOccurrences(of: sourceFolded, with: "")
    }
    if rest.contains(where: { $0.isLetter || $0.isNumber }) { return text }
    return ""
  }

  private static func decode(_ raw: String) -> String {
    var text = raw
    let entities = [
      ("&amp;", "&"),
      ("&lt;", "<"),
      ("&gt;", ">"),
      ("&quot;", "\""),
      ("&apos;", "'"),
      ("&#39;", "'"),
      ("&#x27;", "'"),
      ("&nbsp;", " "),
    ]
    for (from, to) in entities {
      text = text.replacingOccurrences(of: from, with: to)
    }
    return text
  }

  private static func stripTags(_ raw: String) -> String {
    var out = ""
    var inTag = false
    for ch in raw {
      if ch == "<" {
        inTag = true
        continue
      }
      if ch == ">" {
        inTag = false
        if let last = out.last, !last.isWhitespace { out.append(" ") }
        continue
      }
      if !inTag { out.append(ch) }
    }
    return out
  }

  private static func collapse(_ raw: String) -> String {
    raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
