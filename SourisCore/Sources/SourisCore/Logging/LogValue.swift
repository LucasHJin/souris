/// One value in a log entry's `fields`, encoded as a bare JSON scalar.
///
/// JSON keeps no distinction between `1` and `1.0`, so a whole-number `.double` reads back as
/// `.int`. Non-finite doubles encode as the strings `"nan"`, `"inf"` and `"-inf"`, and read back as
/// `.string`.
public enum LogValue: Equatable, Codable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      if let name = Self.nonFiniteName(value) {
        try container.encode(name)
      } else {
        try container.encode(value)
      }
    case .bool(let value):
      try container.encode(value)
    }
  }

  /// The string a non-finite double is written as, or `nil` for a finite one. JSON has no
  /// literal for NaN or infinity.
  static func nonFiniteName(_ value: Double) -> String? {
    if value.isNaN { return "nan" }
    if value.isInfinite { return value < 0 ? "-inf" : "inf" }
    return nil
  }
}

extension LogValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

extension LogValue: ExpressibleByStringInterpolation {}

extension LogValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) {
    self = .int(value)
  }
}

extension LogValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) {
    self = .double(value)
  }
}

extension LogValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }
}
