import CoreGraphics
import Foundation

/// Keeps the Mac's cursor position at full fractional precision between posted events.
///
/// macOS may round or lag the location it reports after an event is posted, so the tracker keeps
/// its own position and only resyncs to the real cursor when something else moved it (the
/// trackpad, another app). It decides that by comparing the real location with the positions it
/// posted within the last `historyDuration` seconds: if the real location is within `tolerance`
/// of any of them, the cursor is still ours; otherwise it resyncs to the real location before
/// applying the delta.
public struct CursorTracker: Sendable {
  /// A posted position and the uptime, in seconds, when it was posted.
  private struct Sample {
    var point: CGPoint
    var time: TimeInterval
  }

  /// The position the tracker last returned, or `nil` before the first move or after `reset()`.
  public private(set) var position: CGPoint?

  /// The resyncs to the real cursor since the tracker was created.
  ///
  /// The first move and the first move after `reset()` don't count.
  public private(set) var resyncCount = 0

  private let historyDuration: TimeInterval
  private let maxHistory: Int
  private let tolerance: Double

  /// Posted positions, oldest first. The newest is kept whatever its age.
  private var history: [Sample] = []

  /// Creates a tracker.
  ///
  /// - Parameters:
  ///   - historyDuration: Seconds a posted position stays eligible to match the real cursor.
  ///   - maxHistory: The most posted positions kept. Values below one are raised to one.
  ///   - tolerance: Points the real cursor may be from a kept position and still count as ours.
  public init(
    historyDuration: TimeInterval = 0.5,
    maxHistory: Int = 512,
    tolerance: Double = 1.5
  ) {
    self.historyDuration = historyDuration
    self.maxHistory = max(maxHistory, 1)
    self.tolerance = tolerance
  }

  /// Returns where to post the cursor after moving it by `delta`.
  ///
  /// - Parameters:
  ///   - delta: Screen points, +y down.
  ///   - actual: The cursor's current location as macOS reports it
  ///     (`CGEvent(source: nil)?.location`).
  ///   - displays: Active display bounds in global coordinates (`CGDisplayBounds`).
  ///   - time: The caller's monotonic uptime in seconds, such as `ProcessInfo.systemUptime`.
  ///     Each call must pass a time at or after the previous call's.
  public mutating func target(
    applying delta: SIMD2<Double>,
    actual: CGPoint,
    displays: [CGRect],
    time: TimeInterval
  ) -> CGPoint {
    trimHistory(at: time)
    let base: CGPoint
    if let position {
      if history.reversed().contains(where: { isNear($0.point, actual) }) {
        base = position
      } else {
        // Something else moved the cursor, so start again from where it is.
        base = actual
        resyncCount += 1
        clearHistory()
      }
    } else {
      base = actual
    }

    let proposed = CGPoint(x: base.x + CGFloat(delta.x), y: base.y + CGFloat(delta.y))
    let clamped = DisplayClamp.clamp(proposed, previous: base, displays: displays)
    position = clamped
    history.append(Sample(point: clamped, time: time))
    trimHistory(at: time)
    return clamped
  }

  /// Forgets the tracked position, so the next move starts from the real cursor.
  public mutating func reset() {
    position = nil
    clearHistory()
  }

  private func isNear(_ a: CGPoint, _ b: CGPoint) -> Bool {
    let dx = Double(a.x - b.x)
    let dy = Double(a.y - b.y)
    return dx * dx + dy * dy <= tolerance * tolerance
  }

  /// Drops positions older than `historyDuration` before `time`, then the oldest positions beyond
  /// `maxHistory`.
  private mutating func trimHistory(at time: TimeInterval) {
    let cutoff = time - historyDuration
    var stale = 0
    // Stop before the newest sample, which is kept whatever its age.
    while stale < history.count - 1 && history[stale].time < cutoff {
      stale += 1
    }
    history.removeFirst(max(stale, history.count - maxHistory))
  }

  private mutating func clearHistory() {
    history.removeAll(keepingCapacity: true)
  }
}
