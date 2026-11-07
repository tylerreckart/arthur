import Foundation

struct MarketInstrument: Equatable, Hashable, Identifiable {
  var symbol: String
  var name: String
  var price: Double?
  var change: Double?
  var changePct: Double?
  var currency: String
  var asOf: String

  var id: String { symbol }

  var priceText: String {
    guard let price else { return "—" }
    return MarketInstrument.formatPrice(price, currency: currency)
  }

  var changeText: String {
    guard let changePct else {
      guard let change else { return "" }
      return String(format: "%+.2f", change)
    }
    return String(format: "%+.2f%%", changePct)
  }

  var isUp: Bool { (changePct ?? change ?? 0) > 0 }
  var isDown: Bool { (changePct ?? change ?? 0) < 0 }

  static func formatPrice(_ price: Double, currency: String) -> String {
    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    fmt.minimumFractionDigits = price >= 1000 ? 0 : 2
    fmt.maximumFractionDigits = 2
    let body = fmt.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
    if currency.isEmpty || currency == "USD" { return body }
    return "\(body) \(currency)"
  }
}

struct MarketsPayload: Equatable, Hashable {
  var instruments: [MarketInstrument]
  var marketSummary: String

  init(_ value: JSONValue) {
    let obj = value.object
    marketSummary = obj["market_summary"]?.displayString ?? ""
    instruments = obj["instruments"]?.array.compactMap(MarketInstrument.init) ?? []
  }
}

private extension MarketInstrument {
  init?(_ value: JSONValue) {
    let obj = value.object
    let symbol = obj["symbol"]?.displayString ?? ""
    if symbol.isEmpty { return nil }
    var asOf = obj["as_of"]?.displayString ?? ""
    if asOf.isEmpty, let unix = obj["as_of"]?.intValue, unix > 0 {
      asOf = String(unix)
    }
    self.init(
      symbol: symbol,
      name: obj["name"]?.displayString ?? "",
      price: obj["price"]?.doubleValue,
      change: obj["change"]?.doubleValue,
      changePct: obj["change_pct"]?.doubleValue,
      currency: obj["currency"]?.displayString ?? "",
      asOf: asOf
    )
  }
}
