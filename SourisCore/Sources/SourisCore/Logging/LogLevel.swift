/// How serious a log entry is, from least to most.
public enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
  case debug, info, warning, error

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.rank < rhs.rank
  }

  private var rank: Int {
    switch self {
    case .debug: 0
    case .info: 1
    case .warning: 2
    case .error: 3
    }
  }
}
