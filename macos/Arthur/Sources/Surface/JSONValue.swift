import Foundation

/// Codable JSON tree so surface payloads survive transcript relaunch.
enum JSONValue: Equatable, Hashable, Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  var object: [String: JSONValue] {
    if case .object(let obj) = self { return obj }
    return [:]
  }

  var array: [JSONValue] {
    if case .array(let arr) = self { return arr }
    return []
  }

  var displayString: String {
    switch self {
    case .string(let s): return s
    case .number(let d):
      if d.rounded() == d { return String(Int(d)) }
      return String(d)
    case .bool(let b): return b ? "Yes" : "No"
    case .null: return ""
    case .object, .array: return ""
    }
  }

  var intValue: Int? {
    switch self {
    case .number(let d): return Int(d.rounded())
    case .string(let s): return Int(s)
    default: return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .number(let d): return d
    case .string(let s): return Double(s)
    default: return nil
    }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? c.decode(Int.self) {
      self = .number(Double(i))
    } else if let d = try? c.decode(Double.self) {
      self = .number(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else if let o = try? c.decode([String: JSONValue].self) {
      self = .object(o)
    } else {
      self = .null
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .number(let d):
      if d.rounded() == d, d >= Double(Int.min), d <= Double(Int.max) {
        try c.encode(Int(d))
      } else {
        try c.encode(d)
      }
    case .bool(let b): try c.encode(b)
    case .object(let o): try c.encode(o)
    case .array(let a): try c.encode(a)
    case .null: try c.encodeNil()
    }
  }

  static func fromAny(_ raw: Any) -> JSONValue {
    switch raw {
    case let s as String: return .string(s)
    case let n as Int: return .number(Double(n))
    case let n as Int64: return .number(Double(n))
    case let n as Double: return .number(n)
    case let n as Float: return .number(Double(n))
    case let n as NSNumber:
      // NSNumber is also Bool's bridging type.
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        return .bool(n.boolValue)
      }
      return .number(n.doubleValue)
    case let b as Bool: return .bool(b)
    case let arr as [Any]: return .array(arr.map(fromAny))
    case let obj as [String: Any]:
      var out: [String: JSONValue] = [:]
      for (k, v) in obj { out[k] = fromAny(v) }
      return .object(out)
    default: return .null
    }
  }
}
