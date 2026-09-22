import SwiftUI

/// Desk card for a versioned Intercom `surface`. Weather, news, and
/// markets get typed layouts; everything else (including unknown kinds)
/// uses generic.
struct SurfaceCard: View {
  let surface: ChatSurface
  var preferCompact = false

  var body: some View {
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibility)
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

private struct WeatherCard: View {
  let surface: ChatSurface
  let weather: WeatherPayload
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
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(surface.title.isEmpty ? "Home" : surface.title)
            .font(.system(.caption, design: .serif).weight(.semibold))
            .foregroundStyle(.secondary)
          if let temp = weather.temperature {
            Text("\(temp)°")
              .font(.system(size: 34, weight: .regular, design: .serif))
              .monospacedDigit()
              .foregroundStyle(.primary)
          }
          Text(weather.conditionLabel.isEmpty ? surface.summary : weather.conditionLabel)
            .font(.callout)
            .foregroundStyle(.primary)
          if let feel = weather.feelsLike {
            Text("Feels like \(feel)°")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: WeatherSymbol.systemImage(for: weather.condition))
          .font(.system(size: 28, weight: .regular))
          .foregroundStyle(ArthurTheme.accent)
          .symbolRenderingMode(.hierarchical)
          .padding(.top, 2)
      }

      if let extras = metaLine, !extras.isEmpty {
        Text(extras)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      if !weather.hours.isEmpty {
        forecastStrip(weather.hours, daily: false)
      }
      if !weather.days.isEmpty {
        forecastStrip(weather.days, daily: true)
      }

      sourceRow
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: 360, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
  }

  private var compactBody: some View {
    HStack(spacing: 10) {
      Image(systemName: WeatherSymbol.systemImage(for: weather.condition))
        .font(.body)
        .foregroundStyle(ArthurTheme.accent)
        .symbolRenderingMode(.hierarchical)
      VStack(alignment: .leading, spacing: 1) {
        Text(surface.title.isEmpty ? "Home" : surface.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(compactSummary)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
  }

  private var compactSummary: String {
    if !surface.summary.isEmpty { return surface.summary }
    if let temp = weather.temperature, !weather.conditionLabel.isEmpty {
      return "\(weather.conditionLabel), \(temp)°"
    }
    return weather.conditionLabel
  }

  private var metaLine: String? {
    var bits: [String] = []
    if let humidity = weather.humidity {
      bits.append("Humidity \(humidity)%")
    }
    if let wind = weather.windSpeed {
      let unit = weather.windUnit.isEmpty ? "" : " \(weather.windUnit)"
      if wind.rounded() == wind {
        bits.append("Wind \(Int(wind))\(unit)")
      } else {
        bits.append("Wind \(String(format: "%.1f", wind))\(unit)")
      }
    }
    return bits.isEmpty ? nil : bits.joined(separator: "  ·  ")
  }

  private func forecastStrip(_ slots: [WeatherSlot], daily: Bool) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(slots) { slot in
          VStack(spacing: 3) {
            Text(slot.label)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
            Image(systemName: WeatherSymbol.systemImage(for: slot.condition))
              .font(.caption)
              .foregroundStyle(ArthurTheme.accent.opacity(0.9))
              .symbolRenderingMode(.hierarchical)
            Text(slot.temperatureText)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.primary)
          }
          .frame(minWidth: daily ? 44 : 36)
        }
      }
    }
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

private struct NewsCard: View {
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
    .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
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
    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
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

private struct MarketsCard: View {
  let surface: ChatSurface
  let markets: MarketsPayload
  var compact = false

  private static let up = Color(red: 0.40, green: 0.72, blue: 0.52)
  private static let down = Color(red: 0.86, green: 0.40, blue: 0.42)

  var body: some View {
    if compact {
      compactBody
    } else {
      fullBody
    }
  }

  private var fullBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(surface.title.isEmpty ? "Markets" : surface.title)
        .font(.system(.caption, design: .serif).weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(spacing: 6) {
        ForEach(markets.instruments.prefix(8)) { inst in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
              Text(inst.symbol)
                .font(.callout.weight(.semibold).monospaced())
                .foregroundStyle(.primary)
              if !inst.name.isEmpty, inst.name != inst.symbol {
                Text(inst.name)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
            }
            Spacer(minLength: 8)
            Text(inst.priceText)
              .font(.callout.monospacedDigit())
              .foregroundStyle(.primary)
            Text(inst.changeText)
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(changeColor(inst))
              .frame(minWidth: 58, alignment: .trailing)
          }
        }
      }
      sourceRow
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: 360, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
  }

  private var compactBody: some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.line.uptrend.xyaxis")
        .font(.body)
        .foregroundStyle(ArthurTheme.accent)
        .symbolRenderingMode(.hierarchical)
      VStack(alignment: .leading, spacing: 1) {
        Text(surface.title.isEmpty ? "Markets" : surface.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(compactSummary)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
  }

  private var compactSummary: String {
    if !surface.summary.isEmpty { return surface.summary }
    if !markets.marketSummary.isEmpty { return markets.marketSummary }
    if let first = markets.instruments.first {
      return "\(first.symbol)  \(first.priceText)  \(first.changeText)"
    }
    return "Markets"
  }

  private func changeColor(_ inst: MarketInstrument) -> Color {
    if inst.isUp { return Self.up }
    if inst.isDown { return Self.down }
    return .secondary
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
    .glassEffect(.regular, in: .rect(cornerRadius: compact ? 14 : 16, style: .continuous))
  }
}
