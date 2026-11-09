import SwiftUI

struct NewsCard: View {
  let surface: ChatSurface
  let news: NewsPayload
  var compact = false

  private static let paper = Color(red: 0.93, green: 0.72, blue: 0.38)

  var body: some View {
    if compact {
      compactBody
    } else {
      fullBody
    }
  }

  private var fullBody: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "newspaper.fill")
            .font(.caption)
            .foregroundStyle(Self.paper)
            .accessibilityHidden(true)
          Text(surface.title.isEmpty ? "News" : surface.title)
            .font(.system(.subheadline, design: .serif).weight(.semibold))
            .foregroundStyle(.primary)
        }
        Spacer(minLength: 8)
        sourceLink
      }
      .padding(.bottom, 4)

      if news.items.isEmpty, !surface.summary.isEmpty {
        Text(surface.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(news.items.prefix(6).enumerated()), id: \.element.id) { index, item in
            if index > 0 {
              Divider().opacity(0.45)
            }
            headlineRow(item)
              .padding(.vertical, 8)
          }
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: 360, alignment: .leading)
    .arthurPlate(radius: 20, tint: Self.paper.opacity(0.55))
  }

  private var compactBody: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "newspaper.fill")
        .font(.body)
        .foregroundStyle(Self.paper)
        .padding(.top, 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
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
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .arthurPlate(radius: 16, tint: Self.paper.opacity(0.55))
  }

  @ViewBuilder
  private func headlineRow(_ item: NewsItem) -> some View {
    let content = VStack(alignment: .leading, spacing: 3) {
      Text(item.title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      if !item.summary.isEmpty {
        Text(item.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 6) {
        if !item.source.isEmpty {
          Text(item.source)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
        if !item.relativeTime.isEmpty {
          Text(item.relativeTime)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    if let url = item.link {
      Link(destination: url) { content }
        .arthurQuietLink()
    } else {
      content
    }
  }

  private func compactMeta(_ item: NewsItem) -> String {
    [item.source, item.relativeTime].filter { !$0.isEmpty }.joined(separator: "  ·  ")
  }

  @ViewBuilder
  private var sourceLink: some View {
    if let source = surface.sources.first {
      if let url = source.link {
        Link(destination: url) {
          sourceLabel(source.title.isEmpty ? url.host ?? "Source" : source.title, linked: true)
        }
        .arthurQuietLink()
      } else if !source.title.isEmpty {
        sourceLabel(source.title, linked: false)
      }
    }
  }

  private func sourceLabel(_ title: String, linked: Bool) -> some View {
    HStack(spacing: 3) {
      Text(title)
        .lineLimit(1)
      if linked {
        Image(systemName: "arrow.up.right")
          .font(.system(size: 8, weight: .semibold))
      }
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
  }
}

#if DEBUG
private func newsPreview(compact: Bool, width: CGFloat) -> some View {
  let surface = ArthurPreviews.newsSurface
  return NewsCard(surface: surface, news: NewsPayload(surface.payload), compact: compact)
    .arthurPreviewDesk(width: width)
}

#Preview("News") {
  newsPreview(compact: false, width: 400)
}

#Preview("News · compact") {
  newsPreview(compact: true, width: 320)
}
#endif
