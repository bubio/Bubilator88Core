import Foundation

/// A JSON value: what JSON-RPC messages, tool arguments and tool schemas are
/// made of.
///
/// Objects keep no key order of their own; `encoded()` sorts the keys so the
/// same value always serialises to the same bytes.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// Parse one JSON document.
  public init(parsing data: Data) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Compact UTF-8 JSON with sorted keys.
  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Encoding a value built from these cases cannot fail: there are no
    // non-finite numbers unless a caller puts one in, which is a bug.
    return (try? encoder.encode(self)) ?? Data("null".utf8)
  }

  /// `encoded()` as a string.
  public func encodedString() -> String {
    String(bytes: encoded(), encoding: .utf8) ?? "null"
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let members) = self { return members[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  /// The number as an integer, when it is one.
  public var intValue: Int? {
    guard case .number(let n) = self, n.rounded() == n,
          n >= Double(Int.min), n <= Double(Int.max) else { return nil }
    return Int(n)
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let b = try? container.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? container.decode(Double.self) {
      self = .number(n)
    } else if let s = try? container.decode(String.self) {
      self = .string(s)
    } else if let a = try? container.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let b): try container.encode(b)
    case .number(let n):
      // Integers print without a fraction: ids and addresses read better.
      if n.rounded() == n, abs(n) < 9.0e15 {
        try container.encode(Int64(n))
      } else {
        try container.encode(n)
      }
    case .string(let s): try container.encode(s)
    case .array(let a): try container.encode(a)
    case .object(let o): try container.encode(o)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
  init(_ value: Int) { self = .number(Double(value)) }
}
