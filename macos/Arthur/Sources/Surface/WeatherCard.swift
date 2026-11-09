import SwiftUI

struct WeatherCard: View {
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
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(place)
          .font(.system(.subheadline, design: .serif).weight(.semibold))
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
        sourceLink
      }

      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          if let temp = weather.temperature {
            Text("\(temp)°")
              .font(.system(size: 44, weight: .light, design: .serif))
              .monospacedDigit()
              .foregroundStyle(.primary)
          }
          Text(conditionText)
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
          .font(.system(size: 30, weight: .regular))
          .foregroundStyle(ArthurTheme.accent)
          .symbolRenderingMode(.hierarchical)
          .frame(width: 56, height: 56)
          .background(Color.primary.opacity(0.08), in: Circle())
          .accessibilityHidden(true)
      }

      if hasMeta {
        metaRow
      }

      if !weather.hours.isEmpty {
        forecastBlock(weather.hours, daily: false)
      }
      if !weather.days.isEmpty {
        forecastBlock(weather.days, daily: true)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: 360, alignment: .leading)
    .arthurPlate(radius: 20)
  }

  private var compactBody: some View {
    HStack(spacing: 10) {
      Image(systemName: WeatherSymbol.systemImage(for: weather.condition))
        .font(.body)
        .foregroundStyle(ArthurTheme.accent)
        .symbolRenderingMode(.hierarchical)
        .frame(width: 28, height: 28)
        .background(Color.primary.opacity(0.08), in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(place)
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
    .arthurPlate(radius: 16)
  }

  private var place: String {
    surface.title.isEmpty ? "Home" : surface.title
  }

  private var conditionText: String {
    weather.conditionLabel.isEmpty ? surface.summary : weather.conditionLabel
  }

  private var compactSummary: String {
    if !surface.summary.isEmpty { return surface.summary }
    if let temp = weather.temperature, !weather.conditionLabel.isEmpty {
      return "\(weather.conditionLabel), \(temp)°"
    }
    return weather.conditionLabel
  }

  private var hasMeta: Bool {
    weather.humidity != nil || weather.windSpeed != nil
  }

  private var metaRow: some View {
    HStack(spacing: 14) {
      if let humidity = weather.humidity {
        Label("\(humidity)%", systemImage: "humidity")
      }
      if let wind = windText {
        Label(wind, systemImage: "wind")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  private var windText: String? {
    guard let wind = weather.windSpeed else { return nil }
    let unit = weather.windUnit.isEmpty ? "" : " \(weather.windUnit)"
    if wind.rounded() == wind {
      return "\(Int(wind))\(unit)"
    }
    return "\(String(format: "%.1f", wind))\(unit)"
  }

  private func forecastBlock(_ slots: [WeatherSlot], daily: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(daily ? "Daily" : "Hourly")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
      forecastStrip(slots, daily: daily)
    }
  }

  @ViewBuilder
  private func forecastStrip(_ slots: [WeatherSlot], daily: Bool) -> some View {
    if slots.count > 6 {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(slots) { slot in
            forecastCell(slot, daily: daily)
          }
        }
      }
    } else {
      HStack(spacing: 4) {
        ForEach(slots) { slot in
          forecastCell(slot, daily: daily)
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private func forecastCell(_ slot: WeatherSlot, daily: Bool) -> some View {
    VStack(spacing: 4) {
      Text(slot.label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Image(systemName: WeatherSymbol.systemImage(for: slot.condition))
        .font(.body)
        .foregroundStyle(ArthurTheme.accent.opacity(0.92))
        .symbolRenderingMode(.hierarchical)
      Text(slot.temperatureText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.primary)
        .lineLimit(1)
    }
    .frame(minWidth: daily ? 52 : 40)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(forecastLabel(slot))
  }

  private func forecastLabel(_ slot: WeatherSlot) -> String {
    [slot.label, slot.conditionLabel, slot.temperatureText]
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  @ViewBuilder
  private var sourceLink: some View {
    if let source = surface.sources.first {
      let name = sourceName(source)
      if let url = source.link, !name.isEmpty {
        Link(destination: url) {
          sourceLabel(name, linked: true)
        }
      } else if !name.isEmpty {
        sourceLabel(name, linked: false)
      }
    }
  }

  /// Skip a source title that only repeats the place name. Show the host instead.
  private func sourceName(_ source: SurfaceSource) -> String {
    let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let repeatsPlace = title.isEmpty || title.caseInsensitiveCompare(place) == .orderedSame
    if repeatsPlace {
      return source.link?.host ?? ""
    }
    return title
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
private func weatherPreview(compact: Bool, width: CGFloat) -> some View {
  let surface = ArthurPreviews.weatherSurface
  return WeatherCard(surface: surface, weather: WeatherPayload(surface.payload), compact: compact)
    .arthurPreviewDesk(width: width)
}

#Preview("Weather") {
  weatherPreview(compact: false, width: 400)
}

#Preview("Weather · compact") {
  weatherPreview(compact: true, width: 320)
}
#endif
