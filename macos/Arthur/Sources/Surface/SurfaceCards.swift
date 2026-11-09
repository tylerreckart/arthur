import SwiftUI

/// Desk card for a versioned Intercom `surface`. Weather, news, and
/// markets get typed layouts; everything else (including unknown kinds)
/// uses generic.
struct SurfaceCard: View {
  let surface: ChatSurface
  var preferCompact = false

  var body: some View {
    Group {
      if shownActions.isEmpty {
        card
      } else {
        GlassEffectContainer(spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            card
            SurfaceActionRow(actions: shownActions, cardTitle: surface.title)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibility)
  }

  @ViewBuilder
  private var card: some View {
    if preferCompact {
      compact
    } else {
      ViewThatFits(in: .horizontal) {
        full
        compact
      }
    }
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
        .arthurAction(prominent: fills(action))
        .controlSize(.small)
      }
    }
  }

  private func fills(_ action: SurfaceAction) -> Bool {
    action.kind == "approve" || action.kind == "undo"
  }
}

private struct GenericSurfaceCard: View {
  let surface: ChatSurface
  var compact = false

  private var awaitsApproval: Bool {
    surface.actions.contains { $0.kind == "approve" || $0.kind == "undo" }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 4 : 8) {
      if !surface.title.isEmpty || awaitsApproval {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if awaitsApproval {
            Image(systemName: "checkmark.circle")
              .font(compact ? .caption : .body)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          if !surface.title.isEmpty {
            Text(surface.title)
              .font(.system(compact ? .callout : .body, design: .serif).weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(compact ? 2 : 3)
          }
          Spacer(minLength: 4)
          if awaitsApproval {
            ArthurStatusChip(label: "Needs you", urgent: true)
          }
        }
      }
      if !surface.summary.isEmpty {
        Text(surface.summary)
          .font(compact ? .caption : .callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(compact ? 2 : 8)
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
    .padding(.horizontal, compact ? 12 : 16)
    .padding(.vertical, compact ? 8 : 14)
    .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
    .arthurPlate(radius: compact ? 16 : 20)
  }
}

#if DEBUG
@MainActor
private func surfacePreview(_ surface: ChatSurface, compact: Bool = false, width: CGFloat = 400) -> some View {
  SurfaceCard(surface: surface, preferCompact: compact)
    .environment(AppModel.previewCanvas())
    .arthurPreviewDesk(width: width)
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

#Preview("Info cards") {
  ScrollView {
    VStack(alignment: .leading, spacing: 20) {
      SurfaceCard(surface: ArthurPreviews.weatherSurface)
      SurfaceCard(surface: ArthurPreviews.newsSurface)
      SurfaceCard(surface: ArthurPreviews.approvalSurface)
    }
    .padding(24)
  }
  .environment(AppModel.previewCanvas())
  .frame(width: 420, height: 920)
  .background(ArthurPreviews.deskBackdrop)
  .preferredColorScheme(.dark)
}
#endif
