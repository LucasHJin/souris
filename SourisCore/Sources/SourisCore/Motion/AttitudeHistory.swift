import Foundation
import simd

/// Recent Core Motion attitudes, for looking up the phone's attitude at an ARKit frame's capture
/// time. That lookup is what lets gyro assist carry an ARKit orientation forward to now.
struct AttitudeHistory: Sendable {
  /// The result of looking up the attitude at a time.
  enum Lookup: Equatable, Sendable {
    /// The attitude at that time, interpolated (device frame → Core Motion reference frame).
    case found(simd_quatd)

    /// The history doesn't cover the time yet (it is still filling); not a sign of trouble.
    case notCovered

    /// The time lies well outside a full history: the two clocks disagree, or Core Motion has
    /// stalled.
    case outOfRange
  }

  private struct Entry: Sendable {
    var time: TimeInterval
    var attitude: simd_quatd
  }

  /// How far past either end of the history a time may fall and still use the end sample.
  static let tolerance: TimeInterval = 0.02

  /// How long the history must span before a time older than it counts as out of range.
  static let fullSpan: TimeInterval = 0.4

  private var entries: RingBuffer<Entry>

  /// - Parameter capacity: Samples kept. 64 holds about 0.6 s at 100 Hz.
  init(capacity: Int = 64) {
    entries = RingBuffer(capacity: capacity)
  }

  /// The newest attitude.
  var latest: simd_quatd? { entries.last?.attitude }

  mutating func append(time: TimeInterval, attitude: simd_quatd) {
    if let newest = entries.last, time <= newest.time {
      // Out of order or duplicate: keep the history sorted by dropping it.
      return
    }
    entries.append(Entry(time: time, attitude: simd_normalize(attitude)))
  }

  mutating func removeAll() {
    entries.removeAll()
  }

  /// The attitude at `time`, slerped between the samples around it.
  func attitude(at time: TimeInterval) -> Lookup {
    guard let oldest = entries.first, let newest = entries.last else { return .notCovered }
    if time >= newest.time {
      return time - newest.time <= Self.tolerance ? .found(newest.attitude) : .outOfRange
    }
    if time <= oldest.time {
      if oldest.time - time <= Self.tolerance {
        return .found(oldest.attitude)
      }
      return newest.time - oldest.time >= Self.fullSpan ? .outOfRange : .notCovered
    }
    // ARKit frames are tens of milliseconds old, so the bracket is near the newest end.
    var index = entries.count - 2
    while index > 0 && entries[index].time > time {
      index -= 1
    }
    let before = entries[index]
    let after = entries[index + 1]
    let fraction = (time - before.time) / (after.time - before.time)
    return .found(simd_slerp(before.attitude, after.attitude, fraction))
  }
}
