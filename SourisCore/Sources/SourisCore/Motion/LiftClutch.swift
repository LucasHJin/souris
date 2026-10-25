import Foundation
import simd

/// The heights of a point near each end of the phone, metres.
struct EdgeHeights: Equatable, Sendable {
  var front: Double
  var back: Double

  /// The lift height the desk, peak and set-down rules use.
  var lower: Double { min(front, back) }
}

/// The lift-to-reposition clutch, like lifting a mouse off the desk. It watches a point near each
/// end of the phone on good ARKit frames.
///
/// Engaged → lifted when each end rises more than `threshold` above its own lowest point in the
/// last `window` seconds, so slow arm drift never counts. A tilt, or the return from one, moves
/// the ends in opposite directions, so it can never pass; a real lift raises both. Lifted →
/// engaged once the lower end has come down `reengageDescent` from the lift's peak and its
/// least-squares slope over the last `reengageHold` seconds is under `reengageSpeed`. A fitted
/// slope rather than a smoothed frame-to-frame speed keeps ARKit's millimetre jitter from holding
/// the clutch open.
struct LiftClutch: Sendable {
  /// What one update decided.
  enum Event: Equatable, Sendable {
    case none

    /// The phone was just lifted. `rollback` is the cursor total when the rise began, and `rise`
    /// the smaller of the two ends' gains since then, metres.
    case lifted(rollback: SIMD2<Double>, rise: Double)

    /// The phone was set down, `drop` metres below the lift's peak; the caller re-engages (which
    /// calls `reset`).
    case setDown(drop: Double)
  }

  private struct Sample: Sendable {
    var time: TimeInterval
    var edges: EdgeHeights
    var cursor: SIMD2<Double>

    var height: Double { edges.lower }
  }

  /// The fewest samples the set-down slope is fitted to.
  static let minimumSlopeSamples = 4

  private(set) var isLifted = false

  /// The slow low-pass of the resting (lower-end) height, metres.
  private(set) var deskHeight: Double = 0

  /// Engaged: the last `window` seconds. Lifted: the last `reengageHold` seconds.
  private var recent = RingBuffer<Sample>(capacity: 256)
  private var peak: Double = 0
  private var lastTime: TimeInterval?

  /// Starts engaged with the desk at the lower end's height.
  mutating func reset(edges: EdgeHeights, time: TimeInterval) {
    isLifted = false
    deskHeight = edges.lower
    recent.removeAll()
    peak = edges.lower
    lastTime = time
  }

  /// Advances by one good ARKit frame.
  ///
  /// - Parameters:
  ///   - edges: Both ends' heights, metres.
  ///   - time: The frame's capture time.
  ///   - cursor: The cursor total before this frame's output, for rolling back a lift.
  ///   - canLift: False holds the clutch engaged (during a tilt scroll) and restarts the rise
  ///     window, so the end of a scroll can't be read as a lift either.
  mutating func update(
    edges: EdgeHeights,
    time: TimeInterval,
    cursor: SIMD2<Double>,
    canLift: Bool,
    settings: PipelineSettings.Lift
  ) -> Event {
    let interval = lastTime.map { max(0, time - $0) } ?? 0
    lastTime = max(lastTime ?? time, time)
    let height = edges.lower
    recent.append(Sample(time: time, edges: edges, cursor: cursor))

    if isLifted {
      peak = max(peak, height)
      dropSamples(before: time - settings.reengageHold)
      guard peak - height >= settings.reengageDescent,
        let slope = heightSlope(),
        abs(slope) < settings.reengageSpeed
      else { return .none }
      return .setDown(drop: peak - height)
    }

    if settings.deskTimeConstant > 0 {
      deskHeight += (1 - exp(-interval / settings.deskTimeConstant)) * (height - deskHeight)
    } else {
      deskHeight = height
    }
    guard canLift else {
      recent.removeAll()
      recent.append(Sample(time: time, edges: edges, cursor: cursor))
      return .none
    }
    dropSamples(before: time - settings.window)
    // Each end's latest lowest sample marks where its rise began.
    var lowestFront = recent[0]
    var lowestBack = recent[0]
    for index in 1..<recent.count {
      let sample = recent[index]
      if sample.edges.front <= lowestFront.edges.front {
        lowestFront = sample
      }
      if sample.edges.back <= lowestBack.edges.back {
        lowestBack = sample
      }
    }
    let rise = min(edges.front - lowestFront.edges.front, edges.back - lowestBack.edges.back)
    guard rise > settings.threshold else { return .none }
    isLifted = true
    peak = height
    recent.removeAll()
    recent.append(Sample(time: time, edges: edges, cursor: cursor))
    let start = lowestFront.time <= lowestBack.time ? lowestFront : lowestBack
    return .lifted(rollback: start.cursor, rise: rise)
  }

  private mutating func dropSamples(before time: TimeInterval) {
    while let oldest = recent.first, oldest.time < time {
      recent.removeFirst()
    }
  }

  /// The least-squares slope of height against time over `recent`, m/s, or nil with too few
  /// samples.
  private func heightSlope() -> Double? {
    guard recent.count >= Self.minimumSlopeSamples else { return nil }
    let count = Double(recent.count)
    var timeSum: Double = 0
    var heightSum: Double = 0
    for index in 0..<recent.count {
      // Relative to the first sample, so uptime-sized timestamps don't cost precision.
      timeSum += recent[index].time - recent[0].time
      heightSum += recent[index].height
    }
    let meanTime = timeSum / count
    let meanHeight = heightSum / count
    var covariance: Double = 0
    var variance: Double = 0
    for index in 0..<recent.count {
      let time = recent[index].time - recent[0].time - meanTime
      covariance += time * (recent[index].height - meanHeight)
      variance += time * time
    }
    guard variance > 0 else { return nil }
    return covariance / variance
  }
}
