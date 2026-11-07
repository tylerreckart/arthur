import Foundation

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
