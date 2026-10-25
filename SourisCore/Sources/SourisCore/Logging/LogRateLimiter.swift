/// Lets the first of a repeating log event through, then counts the repeats for a second.
///
/// Pass every occurrence to `admit(_:level:now:)` and log it only when that returns true. Call
/// `drainSummaries(now:)` on every timer tick: it returns one summary per key whose second ended
/// with repeats held back, and the next occurrence after that is logged in full again.
struct LogRateLimiter {
  /// How many occurrences of `key` were held back since the one that was logged.
  struct Summary: Equatable {
    var key: String
    var level: LogLevel
    var suppressed: Int

    /// The entry reporting the repeats, with the event name of the entries it stands for.
    func entry(category: String) -> LogEntry {
      LogEntry(
        level: level,
        category: category,
        event: key,
        message: "\(suppressed) more within a second of the last one logged",
        fields: ["repeats": .int(suppressed)])
    }
  }

  private struct Window {
    var start: ContinuousClock.Instant
    var level: LogLevel
    var suppressed = 0
  }

  let interval: Duration

  private var windows: [String: Window] = [:]
  private var finished: [Summary] = []

  init(interval: Duration = .seconds(1)) {
    self.interval = interval
  }

  mutating func admit(_ key: String, level: LogLevel, now: ContinuousClock.Instant) -> Bool {
    if let window = windows[key] {
      if now - window.start < interval {
        windows[key]?.suppressed += 1
        return false
      }
      finish(key, window)
    }
    windows[key] = Window(start: now, level: level)
    return true
  }

  mutating func drainSummaries(now: ContinuousClock.Instant) -> [Summary] {
    for (key, window) in windows where now - window.start >= interval {
      finish(key, window)
      windows[key] = nil
    }
    let summaries = finished
    finished.removeAll()
    return summaries
  }

  private mutating func finish(_ key: String, _ window: Window) {
    guard window.suppressed > 0 else { return }
    finished.append(Summary(key: key, level: window.level, suppressed: window.suppressed))
  }
}
