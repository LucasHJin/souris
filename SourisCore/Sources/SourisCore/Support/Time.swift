import Foundation

/// The system uptime clock both ends put in packets. It is monotonic and does not count sleep.
enum Uptime {
  static func micros() -> UInt64 {
    UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
  }
}

extension Duration {
  /// The duration in seconds, as a `Double`.
  var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) * 1e-18
  }

  /// The duration in milliseconds, as a `Double`.
  var milliseconds: Double {
    seconds * 1000
  }
}

extension Duration {
  /// The duration as a dispatch interval, rounded up to whole microseconds.
  var dispatchInterval: DispatchTimeInterval {
    let microseconds = (seconds * 1_000_000).rounded(.up)
    return .microseconds(Int(microseconds))
  }
}
