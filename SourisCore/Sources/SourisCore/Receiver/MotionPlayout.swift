import Foundation

/// How the Mac paces the cursor motion it receives.
public enum PointerPacing: String, CaseIterable, Codable, Sendable {
  /// Moves once per display refresh along the phone's own timeline, interpolated between its
  /// samples, a few milliseconds behind it so every refresh has a sample on each side.
  case smooth

  /// Moves once per display refresh to the newest motion, with no added delay.
  case responsive

  /// Moves as each packet arrives, as before pacing existed.
  case immediate
}

/// Replays the phone's cursor motion on the phone's own timeline, one display refresh at a time.
///
/// The phone stamps each packet with its uptime. The smallest arrival-minus-stamp seen is the
/// fastest trip, and how far each packet exceeds it is how late it was. A playhead walks the
/// phone's timeline `targetDelay` behind the newest moment the Mac could know about, and each
/// refresh shows the cumulative motion interpolated at the playhead, so the cursor moves evenly
/// even though packets arrive unevenly (ARKit at 60 Hz, Core Motion at 100 Hz, Wi-Fi in clumps).
///
/// When packets arrive late (a Wi-Fi stall), the playhead stops at the newest motion, and once the
/// backlog lands it plays it out at up to `maxRate` times real time instead of jumping. More than
/// `maxLag` behind, it skips ahead so the cursor is never far behind the hand.
///
/// Times are seconds: phone uptime for samples, Mac uptime for arrivals and frames.
public struct MotionPlayout: Sendable {
  /// The fastest a backlog plays out, as a multiple of real time.
  public static let maxRate: Double = 3

  /// How quickly the playhead closes a gap to where it should be: a gap this many seconds long
  /// doubles the playback rate.
  public static let catchUpTime: TimeInterval = 0.05

  /// The furthest the playhead may trail where it should be, seconds.
  public static let maxLag: TimeInterval = 0.25

  /// The most delay `.smooth` adds, seconds. Past it, late packets are a stall to catch up on
  /// rather than jitter to hide.
  public static let maxSmoothingDelay: TimeInterval = 0.03

  /// Extra delay `.smooth` keeps on top of the lateness and sample spacing it measures, so the
  /// playhead stays clear of the newest sample instead of running into it every few frames.
  public static let smoothingMargin: TimeInterval = 0.002

  /// How far past real time `.responsive` may jump in one frame to reach the newest sample,
  /// seconds: a little over one sample spacing.
  public static let responsiveSlack: TimeInterval = 0.012

  /// A gap in the phone's samples longer than this means the phone held still and sent nothing,
  /// seconds.
  public static let restGap: TimeInterval = 0.03

  /// How fast the fastest-trip estimate may rise, seconds per second, so it follows the two
  /// clocks drifting apart. 50 ppm is several times any crystal's drift.
  public static let clockDriftAllowance = 50e-6

  private struct Sample: Sendable {
    var time: TimeInterval
    var total: SIMD2<Double>
  }

  /// What one `frame(at:)` decided, for the log.
  public struct Stats: Equatable, Sendable {
    /// Frames shown.
    public var frames = 0

    /// Frames that played faster than real time to catch up.
    public var catchUpFrames = 0

    /// Phone time skipped because the playhead fell more than `maxLag` behind, seconds.
    public var skipped: TimeInterval = 0

    /// The largest gap between the playhead and where it should be, seconds.
    public var maxBehind: TimeInterval = 0

    public init() {}
  }

  public var pacing: PointerPacing

  private var samples = RingBuffer<Sample>(capacity: 512)
  private var fastestTrip: Double?
  private var lastArrival: TimeInterval?
  private var playhead: TimeInterval?
  private var lastFrame: TimeInterval?

  /// Recent lateness (excess over the fastest trip) and sample spacing, seconds.
  private var lateness = RecentWindow<Double>(capacity: 256)
  private var spacing = RecentWindow<Double>(capacity: 256)

  public private(set) var stats = Stats()

  public init(pacing: PointerPacing = .smooth) {
    self.pacing = pacing
  }

  /// The delay the playhead keeps behind the newest moment the Mac could know about, seconds.
  public var targetDelay: TimeInterval {
    guard pacing == .smooth else { return 0 }
    let measured = Self.quantile(lateness, 0.9) + Self.quantile(spacing, 0.9)
    return min(Self.maxSmoothingDelay, measured + Self.smoothingMargin)
  }

  /// The newest total received.
  public var newestTotal: SIMD2<Double>? {
    samples.last?.total
  }

  /// Adds the cumulative motion as of `phoneTime`, which arrived at `arrival`. Samples that aren't
  /// newer than the newest one are ignored.
  public mutating func add(
    total: SIMD2<Double>,
    phoneTime: TimeInterval,
    arrival: TimeInterval
  ) {
    let trip = arrival - phoneTime
    if let fastestTrip, let lastArrival {
      let allowance = Self.clockDriftAllowance * max(0, arrival - lastArrival)
      self.fastestTrip = min(fastestTrip + allowance, trip)
    } else {
      fastestTrip = trip
    }
    lastArrival = arrival
    lateness.append(trip - (fastestTrip ?? trip))

    if let newest = samples.last {
      guard phoneTime > newest.time else { return }
      let gap = phoneTime - newest.time
      if gap > Self.restGap {
        // The phone sent nothing because nothing moved, so the motion starts just before this
        // sample, not back at the previous one.
        let start = phoneTime - Self.quantile(spacing, 0.5, fallback: 0.01)
        samples.append(Sample(time: start, total: newest.total))
        if let playhead, playhead >= newest.time {
          self.playhead = start
        }
      } else {
        spacing.append(gap)
      }
    }
    samples.append(Sample(time: phoneTime, total: total))
  }

  /// Advances the playhead to the frame shown at Mac time `time` and returns the total to show,
  /// or nil before the first sample.
  public mutating func frame(at time: TimeInterval) -> SIMD2<Double>? {
    guard let newest = samples.last, let fastestTrip else { return nil }
    let elapsed = min(0.05, max(0, time - (lastFrame ?? time)))
    lastFrame = time
    stats.frames += 1

    var head = playhead ?? newest.time
    let target = time - fastestTrip - targetDelay
    // How far the playhead would trail the target after a frame at real-time speed.
    var behind = target - (head + elapsed)
    if behind > Self.maxLag {
      let skip = behind - Self.maxLag
      head += skip
      stats.skipped += skip
      behind = Self.maxLag
    }
    stats.maxBehind = max(stats.maxBehind, behind)
    let rate = min(Self.maxRate, max(0.5, 1 + behind / Self.catchUpTime))
    if rate > 1.5 && head < newest.time {
      stats.catchUpFrames += 1
    }
    var advance = rate * elapsed
    if pacing == .responsive {
      // Show the newest motion whenever it is only a sample or so ahead; only a real backlog is
      // spread out.
      advance = max(advance, elapsed + Self.responsiveSlack)
    }
    head = min(newest.time, head + advance)
    playhead = head
    dropSamples(before: head)
    return total(at: head)
  }

  /// Moves the playhead to the newest sample, e.g. before a click so it lands where the phone
  /// says, and returns the newest total.
  public mutating func flush() -> SIMD2<Double>? {
    guard let newest = samples.last else { return nil }
    playhead = newest.time
    dropSamples(before: newest.time)
    return newest.total
  }

  /// Forgets everything, e.g. when the phone changes.
  public mutating func reset() {
    samples.removeAll()
    fastestTrip = nil
    lastArrival = nil
    playhead = nil
    lastFrame = nil
    lateness.removeAll()
    spacing.removeAll()
  }

  /// Starts a fresh `stats` window and returns the one that ended.
  public mutating func takeStats() -> Stats {
    defer { stats = Stats() }
    return stats
  }

  // MARK: - Private

  private func total(at time: TimeInterval) -> SIMD2<Double>? {
    guard let first = samples.first, let last = samples.last else { return nil }
    if time <= first.time { return first.total }
    if time >= last.time { return last.total }
    var index = samples.count - 1
    while index > 0 && samples[index - 1].time > time {
      index -= 1
    }
    let before = samples[index - 1]
    let after = samples[index]
    let fraction = (time - before.time) / (after.time - before.time)
    return before.total + (after.total - before.total) * fraction
  }

  /// Drops samples older than the one at or before `time`, which interpolation still needs.
  private mutating func dropSamples(before time: TimeInterval) {
    while samples.count > 1 && samples[1].time <= time {
      samples.removeFirst()
    }
  }

  private static func quantile(
    _ values: RecentWindow<Double>,
    _ fraction: Double,
    fallback: Double = 0
  ) -> Double {
    guard !values.isEmpty else { return fallback }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(fraction * Double(sorted.count - 1)))]
  }
}
