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
        conditionBadge(weather.condition, diameter: 58, symbol: 32)
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
    .arthurPlate(radius: 20, tint: WeatherColor.plate(for: weather.condition))
  }

  private var compactBody: some View {
    HStack(spacing: 10) {
      conditionBadge(weather.condition, diameter: 28, symbol: 15)
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
    .arthurPlate(radius: 16, tint: WeatherColor.plate(for: weather.condition))
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
        metaItem("\(humidity)%", systemImage: "humidity.fill", color: WeatherColor.rain)
      }
      if let wind = windText {
        metaItem(wind, systemImage: "wind", color: WeatherColor.wind)
      }
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
  }

  private func metaItem(_ title: String, systemImage: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage)
        .foregroundStyle(color)
      Text(title)
        .foregroundStyle(.secondary)
    }
  }

  private func conditionBadge(_ condition: String, diameter: CGFloat, symbol: CGFloat) -> some View {
    Image(systemName: WeatherSymbol.systemImage(for: condition))
      .font(.system(size: symbol, weight: .regular))
      .symbolRenderingMode(.multicolor)
      .frame(width: diameter, height: diameter)
      .background(WeatherColor.glow(for: condition), in: Circle())
      .accessibilityHidden(true)
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
        .symbolRenderingMode(.multicolor)
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
        .arthurQuietLink()
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

/// Condition colors for the weather plate, the symbol disc, and the meta icons.
private enum WeatherColor {
  static let sun = Color(red: 0.98, green: 0.74, blue: 0.28)
  static let sky = Color(red: 0.36, green: 0.58, blue: 0.92)
  static let rain = Color(red: 0.32, green: 0.62, blue: 0.98)
  static let storm = Color(red: 0.58, green: 0.46, blue: 0.95)
  static let snow = Color(red: 0.68, green: 0.84, blue: 0.98)
  static let night = Color(red: 0.52, green: 0.54, blue: 0.92)
  static let fog = Color(red: 0.68, green: 0.74, blue: 0.82)
  static let wind = Color(red: 0.46, green: 0.82, blue: 0.78)

  static func plate(for condition: String) -> Color {
    switch kind(condition) {
    case .night: return night
    case .storm: return storm
    case .rain: return rain
    case .snow: return snow
    case .fog: return fog
    case .sun: return sun
    case .cloud: return sky
    }
  }

  static func glow(for condition: String) -> Color {
    plate(for: condition).opacity(0.42)
  }

  private enum Kind { case sun, cloud, rain, snow, storm, night, fog }

  private static func kind(_ condition: String) -> Kind {
    let key = condition.lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    if key.contains("clear night") || key == "clearnight" || key.contains("night") { return .night }
    if key.contains("lightning") || key.contains("thunder") { return .storm }
    if key.contains("snow") { return .snow }
    if key.contains("rain") || key.contains("hail") || key.contains("pouring") { return .rain }
    if key.contains("fog") { return .fog }
    if key.contains("partly") || (key.contains("cloud") && !key.contains("sun")) { return .cloud }
    return .sun
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
