import Foundation

/// One entry in the phone's or the Mac's diagnostic log.
///
/// Encodes as a JSON object with the keys `time`, `date`, `level`, `category`, `event`, `message`
/// and `fields`. `message` is left out when `nil` and `fields` when empty. `date` is always an
/// ISO 8601 UTC string with milliseconds, such as `"2026-10-24T14:03:05.123Z"`, whatever the
/// encoder's date strategy.
public struct LogEntry: Equatable, Codable, Sendable {
  /// The sender's `ProcessInfo.systemUptime` when the entry was made, in seconds. The same clock
  /// as the times in packets and sensor recordings.
  public var time: Double

  /// The sender's wall clock when the entry was made, kept to whole milliseconds because that is
  /// all the encoding carries.
  public var date: Date {
    didSet { date = date.roundedToMilliseconds }
  }

  public var level: LogLevel

  /// The part of the app that logged it, such as `"net"` or `"server"`.
  public var category: String

  /// A short machine-readable name for what happened, such as `"status"`.
  public var event: String

  public var message: String?

  public var fields: [String: LogValue]

  private enum CodingKeys: String, CodingKey {
    case time, date, level, category, event, message, fields
  }

  public init(
    time: Double,
    date: Date,
    level: LogLevel,
    category: String,
    event: String,
    message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    self.time = time
    self.date = date.roundedToMilliseconds
    self.level = level
    self.category = category
    self.event = event
    self.message = message
    self.fields = fields
  }

  /// Creates an entry stamped with the current uptime and wall clock.
  public init(
    level: LogLevel,
    category: String,
    event: String,
    message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    self.init(
      time: ProcessInfo.processInfo.systemUptime,
      date: Date(),
      level: level,
      category: category,
      event: event,
      message: message,
      fields: fields)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let dateString = try container.decode(String.self, forKey: .date)
    guard let date = Self.parseDate(dateString) else {
      throw DecodingError.dataCorruptedError(
        forKey: .date, in: container, debugDescription: "Not an ISO 8601 date: \(dateString)")
    }
    self.init(
      time: try container.decode(Double.self, forKey: .time),
      date: date,
      level: try container.decode(LogLevel.self, forKey: .level),
      category: try container.decode(String.self, forKey: .category),
      event: try container.decode(String.self, forKey: .event),
      message: try container.decodeIfPresent(String.self, forKey: .message),
      fields: try container.decodeIfPresent([String: LogValue].self, forKey: .fields) ?? [:])
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(time, forKey: .time)
    try container.encode(dateString, forKey: .date)
    try container.encode(level, forKey: .level)
    try container.encode(category, forKey: .category)
    try container.encode(event, forKey: .event)
    try container.encodeIfPresent(message, forKey: .message)
    if !fields.isEmpty {
      try container.encode(fields, forKey: .fields)
    }
  }

  // MARK: - JSON Lines

  /// The entry as one line of compact JSON, without the trailing newline.
  ///
  /// Keys come in the order `time`, `date`, `level`, `category`, `event`, `message`, `fields`,
  /// and `fields` is sorted by key, so the same entry always gives the same bytes. Decode it with
  /// `JSONDecoder`.
  public func jsonLine() -> Data {
    var json = "{\"time\":"
    json += Self.jsonNumber(time)
    json += ",\"date\":"
    json += Self.jsonString(dateString)
    json += ",\"level\":"
    json += Self.jsonString(level.rawValue)
    json += ",\"category\":"
    json += Self.jsonString(category)
    json += ",\"event\":"
    json += Self.jsonString(event)
    if let message {
      json += ",\"message\":"
      json += Self.jsonString(message)
    }
    if !fields.isEmpty {
      json += ",\"fields\":{"
      json += fields.sorted { $0.key < $1.key }
        .map { Self.jsonString($0.key) + ":" + Self.jsonValue($0.value) }
        .joined(separator: ",")
      json += "}"
    }
    json += "}"
    return Data(json.utf8)
  }

  private static func jsonValue(_ value: LogValue) -> String {
    switch value {
    case .string(let string): jsonString(string)
    case .int(let int): String(int)
    case .double(let double): jsonNumber(double)
    case .bool(let bool): bool ? "true" : "false"
    }
  }

  /// Swift's shortest round-trip form (`0.1`, `1e-05`, `100.0`) is valid JSON for every finite
  /// double.
  private static func jsonNumber(_ value: Double) -> String {
    if let name = LogValue.nonFiniteName(value) {
      return jsonString(name)
    }
    return value.description
  }

  private static func jsonString(_ string: String) -> String {
    var escaped = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": escaped += "\\\""
      case "\\": escaped += "\\\\"
      case "\n": escaped += "\\n"
      case "\r": escaped += "\\r"
      case "\t": escaped += "\\t"
      case _ where scalar.value < 0x20:
        let hex = String(scalar.value, radix: 16)
        escaped += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      default:
        escaped.unicodeScalars.append(scalar)
      }
    }
    escaped += "\""
    return escaped
  }

  // MARK: - Dates

  private var dateString: String {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
    var seconds = milliseconds / 1000
    var fraction = milliseconds % 1000
    if fraction < 0 {
      seconds -= 1
      fraction += 1000
    }
    let whole = Date(timeIntervalSince1970: Double(seconds)).formatted(.iso8601)
    let digits = String(fraction)
    // `whole` ends in "Z"; the milliseconds go in front of it.
    return whole.dropLast() + "." + String(repeating: "0", count: 3 - digits.count) + digits + "Z"
  }

  private static func parseDate(_ string: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
      return date
    }
    return try? Date.ISO8601FormatStyle().parse(string)
  }
}

extension Date {
  /// The date rounded to whole milliseconds since 1970, built the same way every time so that
  /// equal milliseconds give equal dates.
  fileprivate var roundedToMilliseconds: Date {
    Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
  }
}
