import SwiftUI

/// Desk card for a versioned Intercom `surface`. Weather, news, and
/// markets get typed layouts; everything else (including unknown kinds)
/// uses generic.
struct SurfaceCard: View {
  let surface: ChatSurface
  var preferCompact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if preferCompact {
          compact
        } else {
          ViewThatFits(in: .horizontal) {
            full
            compact
          }
        }
      }
      if !surface.actions.isEmpty {
        SurfaceActionRow(actions: shownActions, cardTitle: surface.title)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibility)
  }

  private var shownActions: [SurfaceAction] {
    if !preferCompact { return surface.actions }
    return surface.actions.filter { $0.kind == "approve" || $0.kind == "undo" }
  }

  @ViewBuilder
  private var full: some View {
    if surface.kind == .weather, let weather = surface.weather {
      WeatherCard(surface: surface, weather: weather, compact: false)
    } else if surface.kind == .news, let news = surface.news {
      NewsCard(surface: surface, news: news, compact: false)
    } else if surface.kind == .markets, let markets = surface.markets {
      MarketsCard(surface: surface, markets: markets, compact: false)
    } else {
      GenericSurfaceCard(surface: surface, compact: false)
    }
  }

  @ViewBuilder
  private var compact: some View {
    if surface.kind == .weather, let weather = surface.weather {
      WeatherCard(surface: surface, weather: weather, compact: true)
    } else if surface.kind == .news, let news = surface.news {
      NewsCard(surface: surface, news: news, compact: true)
    } else if surface.kind == .markets, let markets = surface.markets {
      MarketsCard(surface: surface, markets: markets, compact: true)
    } else {
      GenericSurfaceCard(surface: surface, compact: true)
    }
  }

  private var accessibility: String {
    let title = surface.title.isEmpty ? "Card" : surface.title
    if surface.summary.isEmpty { return title }
    return "\(title), \(surface.summary)"
  }
}

private struct SurfaceActionRow: View {
  @Environment(AppModel.self) private var model
  let actions: [SurfaceAction]
  var cardTitle: String = "" 

  var body: some View {
    HStack(spacing: 8) {
      ForEach(actions) { action in
        Button(action.label) {
          model.resolveSurfaceAction(action)
        }
        .accessibilityLabel(cardTitle.isEmpty ? action.label : "\(action.label), \(cardTitle)")
        .controlSize(.small)
        .modifier(SurfaceActionStyle(prominent: fills(action)))
      }
    }
  }

  private func fills(_ action: SurfaceAction) -> Bool {
    action.kind == "approve" || action.kind == "undo"
  }
}

private struct SurfaceActionStyle: ViewModifier {
  var prominent: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if prominent {
      content.buttonStyle(.borderedProminent)
    } else {
      content.buttonStyle(.bordered)
    }
  }
}

private struct GenericSurfaceCard: View {
  let surface: ChatSurface
  var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 4 : 8) {
      if !surface.title.isEmpty {
        Text(surface.title)
          .font(.system(compact ? .callout : .body, design: .serif).weight(.semibold))
          .foregroundStyle(.primary)
      }
      if !surface.summary.isEmpty {
        Text(surface.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !compact {
        if !surface.fields.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(surface.fields.prefix(6).enumerated()), id: \.offset) { _, field in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.label)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .frame(minWidth: 72, alignment: .leading)
                Text(field.value)
                  .font(.caption)
                  .foregroundStyle(.primary)
              }
            }
          }
        }
        if !surface.markdownBody.isEmpty {
          ArthurMarkdown.inline(surface.markdownBody, live: false)
            .font(.callout)
        }
        if let source = surface.sources.first {
          if let url = source.link {
            Link(destination: url) {
              Text(source.title.isEmpty ? url.host ?? "Source" : source.title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          } else if !source.title.isEmpty {
            Text(source.title)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
    .padding(.horizontal, compact ? 12 : 14)
    .padding(.vertical, compact ? 8 : 12)
    .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
    .arthurPlate(radius: compact ? 14 : 16)
  }
}

#if DEBUG
@MainActor
private func surfacePreview(_ surface: ChatSurface, compact: Bool = false, width: CGFloat = 400) -> some View {
  SurfaceCard(surface: surface, preferCompact: compact)
    .environment(AppModel.previewCanvas())
    .padding(24)
    .frame(width: width, alignment: .topLeading)
    .preferredColorScheme(.dark)
}

#Preview("Surface card · note") {
  surfacePreview(ArthurPreviews.noteSurface)
}

#Preview("Surface card · note compact") {
  surfacePreview(ArthurPreviews.noteSurface, compact: true, width: 320)
}

#Preview("Surface card · approval") {
  surfacePreview(ArthurPreviews.approvalSurface)
}

#Preview("Surface card · approval compact") {
  surfacePreview(ArthurPreviews.approvalSurface, compact: true, width: 320)
}

#Preview("Surface card · weather") {
  surfacePreview(ArthurPreviews.weatherSurface)
}

#Preview("Surface card · news") {
  surfacePreview(ArthurPreviews.newsSurface)
}

#Preview("Surface card · markets") {
  surfacePreview(ArthurPreviews.marketsSurface)
}
#endif
