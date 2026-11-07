import SwiftUI

struct NewsCard: View {
  let surface: ChatSurface
  let news: NewsPayload
  var compact = false

  var body: some View {
    if compact {
      compactBody
    } else {
      fullBody
    }
  }

  private var fullBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(surface.title.isEmpty ? "News" : surface.title)
        .font(.system(.caption, design: .serif).weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(news.items.prefix(6)) { item in
          headlineRow(item, showSummary: false)
        }
      }
      sourceRow
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: 360, alignment: .leading)
    .arthurPlate(radius: 16)
  }

  private var compactBody: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(surface.title.isEmpty ? "News" : surface.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if let first = news.items.first {
        Text(first.title)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text(compactMeta(first))
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      } else if !surface.summary.isEmpty {
        Text(surface.summary)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .arthurPlate(radius: 14)
  }

  @ViewBuilder
  private func headlineRow(_ item: NewsItem, showSummary: Bool) -> some View {
    let content = VStack(alignment: .leading, spacing: 2) {
      Text(item.title)
        .font(.callout)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        if !item.source.isEmpty {
          Text(item.source)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if !item.relativeTime.isEmpty {
          Text(item.relativeTime)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      if showSummary, !item.summary.isEmpty {
        Text(item.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    if let url = item.link {
      Link(destination: url) { content }
    } else {
      content
    }
  }

  private func compactMeta(_ item: NewsItem) -> String {
    [item.source, item.relativeTime].filter { !$0.isEmpty }.joined(separator: "  ·  ")
  }

  @ViewBuilder
  private var sourceRow: some View {
    if let source = surface.sources.first {
      if let url = source.link {
        Link(destination: url) {
          Text(source.title.isEmpty ? url.host ?? "Source" : source.title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      } else if !source.title.isEmpty {
        Text(source.title)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
  }
}

#if DEBUG
private func newsPreview(compact: Bool, width: CGFloat) -> some View {
  let surface = ArthurPreviews.newsSurface
  return NewsCard(surface: surface, news: NewsPayload(surface.payload), compact: compact)
    .padding(24)
    .frame(width: width, alignment: .topLeading)
    .preferredColorScheme(.dark)
}

#Preview("News") {
  newsPreview(compact: false, width: 400)
}

#Preview("News · compact") {
  newsPreview(compact: true, width: 320)
}
#endif
