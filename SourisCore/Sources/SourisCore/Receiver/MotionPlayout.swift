import Foundation
import simd

/// How the Mac paces the cursor motion it receives.
public enum PointerPacing: String, CaseIterable, Codable, Sendable {
  /// Responsive on the cable, whose packets arrive evenly within a few milliseconds, and Smooth
  /// over Bluetooth and Wi-Fi, whose packets come in bunches.
  case auto

  /// Moves once per display refresh along the phone's own timeline, interpolated between its
  /// samples, a few milliseconds behind it so every refresh has a sample on each side.
  case smooth

  /// Moves once per display refresh to the newest motion, with no added delay.
  case responsive

  /// Moves as each packet arrives, as before pacing existed.
  case immediate

  /// The pacing to use over `transport`: `.auto` resolved for it, any other choice unchanged.
  public func resolved(for transport: LinkTransport) -> PointerPacing {
    guard self == .auto else { return self }
    return transport == .usb ? .responsive : .smooth
  }
}

/// Replays the phone's cursor motion and scrolling on the phone's own timeline, one display
/// refresh at a time.
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
/// Over a link whose `Limits` allow it, `.smooth` coasts when the playhead runs out: the cursor
/// keeps going on its last speed, slowing down, for up to `maxCoast`. Once packets land again the
/// difference between where it coasted to and where the phone says it was blends away over
/// `coastBlendTime`, so a coast never jumps the cursor back. Scrolling never coasts.
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

  /// A coast slows by a factor of e every this many seconds, so coasting past a real stop
  /// overshoots by at most the speed times this.
  public static let coastDamping: TimeInterval = 0.015

  /// How long the gap between a coast and the phone's own motion takes to shrink by a factor of
  /// e, seconds.
  public static let coastBlendTime: TimeInterval = 0.03

  /// Limits that depend on what carries the packets.
  public struct Limits: Equatable, Sendable {
    /// The most delay `.smooth` adds, seconds. Past it, late packets are a stall to catch up on
    /// rather than jitter to hide.
    public var maxSmoothingDelay: TimeInterval

    /// How long `.smooth` may coast once it has shown the newest sample and the next is late,
    /// seconds. Zero never coasts.
    public var maxCoast: TimeInterval

    public init(maxSmoothingDelay: TimeInterval, maxCoast: TimeInterval) {
      self.maxSmoothingDelay = maxSmoothingDelay
      self.maxCoast = maxCoast
    }

    /// The limits for a link.
    ///
    /// Bluetooth delivers in connection events tens of milliseconds apart, so its jitter is
    /// worth more delay to hide, and a short coast bridges the occasional missed event. Wi-Fi's
    /// lateness is mostly stalls far longer than any delay or coast could hide.
    public static func forLink(_ transport: LinkTransport) -> Limits {
      switch transport {
      case .usb: Limits(maxSmoothingDelay: 0.03, maxCoast: 0)
      case .bluetooth: Limits(maxSmoothingDelay: 0.08, maxCoast: 0.03)
      case .wifi: Limits(maxSmoothingDelay: 0.03, maxCoast: 0)
      }
    }
  }

  /// What one refresh shows: the cumulative cursor motion, points, and scroll, pixels.
  public struct Frame: Equatable, Sendable {
    public var cursor: SIMD2<Double>
    public var scroll: SIMD2<Double>

    public init(cursor: SIMD2<Double>, scroll: SIMD2<Double> = .zero) {
      self.cursor = cursor
      self.scroll = scroll
    }
  }

  private struct Sample: Sendable {
    var time: TimeInterval
    var cursor: SIMD2<Double>
    var scroll: SIMD2<Double>
  }

  /// What the frames since the last `takeStats()` did, for the log.
  public struct Stats: Equatable, Sendable {
    /// Frames shown.
    public var frames = 0

    /// Frames that played faster than real time to catch up.
    public var catchUpFrames = 0

    /// Phone time skipped because the playhead fell more than `maxLag` behind, seconds.
    public var skipped: TimeInterval = 0

    /// The largest gap between the playhead and where it should be, seconds.
    public var maxBehind: TimeInterval = 0

    /// Frames that coasted past the newest sample.
    public var coastFrames = 0

    /// The furthest the cursor was shown from the phone's own motion by a coast, points.
    public var maxCoastOffset: Double = 0

    public init() {}
  }

  public var pacing: PointerPacing

  public var limits: Limits

  private var samples = RingBuffer<Sample>(capacity: 512)
  private var fastestTrip: Double?
  private var lastArrival: TimeInterval?
  private var playhead: TimeInterval?
  private var lastFrame: TimeInterval?

  /// The cursor's speed over the newest sample's interval, points per second; zero after a rest.
  private var newestVelocity = SIMD2<Double>.zero

  /// How long the current coast has run, seconds, and how far it has taken the cursor past the
  /// phone's own motion, points.
  private var coastTime: TimeInterval = 0
  private var coastOffset = SIMD2<Double>.zero

  /// Recent lateness (excess over the fastest trip) and sample spacing, seconds.
  private var lateness = RecentWindow<Double>(capacity: 256)
  private var spacing = RecentWindow<Double>(capacity: 256)

  public private(set) var stats = Stats()

  /// - Parameters:
  ///   - pacing: `.smooth` or `.responsive`; `.auto` must be resolved first and plays as
  ///     `.smooth`.
  ///   - limits: The link's limits.
  public init(
    pacing: PointerPacing = .smooth,
    limits: Limits = .forLink(.wifi)
  ) {
    self.pacing = pacing
    self.limits = limits
  }

  /// The delay the playhead keeps behind the newest moment the Mac could know about, seconds.
  public var targetDelay: TimeInterval {
    guard isSmooth else { return 0 }
    let measured = Self.quantile(lateness, 0.9) + Self.quantile(spacing, 0.9)
    return min(limits.maxSmoothingDelay, measured + Self.smoothingMargin)
  }

  /// The newest totals received.
  public var newest: Frame? {
    samples.last.map { Frame(cursor: $0.cursor, scroll: $0.scroll) }
  }

  /// Adds the cumulative motion and scroll as of `phoneTime`, which arrived at `arrival`. Samples
  /// that aren't newer than the newest one are ignored.
  public mutating func add(
    total: SIMD2<Double>,
    scroll: SIMD2<Double> = .zero,
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
        samples.append(Sample(time: start, cursor: newest.cursor, scroll: newest.scroll))
        if let playhead, playhead >= newest.time {
          self.playhead = start
        }
        newestVelocity = (total - newest.cursor) / (phoneTime - start)
      } else {
        spacing.append(gap)
        newestVelocity = (total - newest.cursor) / gap
      }
    }
    samples.append(Sample(time: phoneTime, cursor: total, scroll: scroll))
  }

  /// Advances the playhead to the frame shown at Mac time `time` and returns the totals to show,
  /// or nil before the first sample.
  public mutating func frame(at time: TimeInterval) -> Frame? {
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
    let ranOut = head + advance > newest.time
    head = min(newest.time, head + advance)
    playhead = head
    dropSamples(before: head)
    updateCoast(ranOut: ranOut, elapsed: elapsed)
    guard let shown = totals(at: head) else { return nil }
    return Frame(cursor: shown.cursor + coastOffset, scroll: shown.scroll)
  }

  /// Moves the playhead to the newest sample, e.g. before a click so it lands where the phone
  /// says, and returns the newest totals.
  public mutating func flush() -> Frame? {
    guard let newest = samples.last else { return nil }
    playhead = newest.time
    dropSamples(before: newest.time)
    coastTime = 0
    coastOffset = .zero
    return Frame(cursor: newest.cursor, scroll: newest.scroll)
  }

  /// Forgets how fast packets travel, keeping the motion, for when the link changes (the cable
  /// to Bluetooth): the new link's trips are measured afresh rather than counted as late.
  public mutating func relink() {
    fastestTrip = nil
    lastArrival = nil
    lateness.removeAll()
    spacing.removeAll()
  }

  /// Forgets everything, e.g. when the phone changes.
  public mutating func reset() {
    samples.removeAll()
    relink()
    playhead = nil
    lastFrame = nil
    newestVelocity = .zero
    coastTime = 0
    coastOffset = .zero
  }

  /// Starts a fresh `stats` window and returns the one that ended.
  public mutating func takeStats() -> Stats {
    defer { stats = Stats() }
    return stats
  }

  // MARK: - Private

  private var isSmooth: Bool {
    pacing == .smooth || pacing == .auto
  }

  /// Coasts while the playhead has run out and the link allows it, and otherwise blends the coast
  /// back into the phone's motion.
  private mutating func updateCoast(ranOut: Bool, elapsed: TimeInterval) {
    let canCoast = ranOut && isSmooth && coastTime < limits.maxCoast
    guard canCoast else {
      if !ranOut {
        coastTime = 0
      }
      coastOffset *= exp(-elapsed / Self.coastBlendTime)
      if simd_length(coastOffset) < 0.01 {
        coastOffset = .zero
      }
      return
    }
    // Distance covered between the coast's old and new ages at speed v · e^(−t/τ).
    let damping = Self.coastDamping
    let start = coastTime
    coastTime = min(limits.maxCoast, coastTime + elapsed)
    let distance = damping * (exp(-start / damping) - exp(-coastTime / damping))
    coastOffset += newestVelocity * distance
    stats.coastFrames += 1
    stats.maxCoastOffset = max(stats.maxCoastOffset, simd_length(coastOffset))
  }

  private func totals(at time: TimeInterval) -> Frame? {
    guard let first = samples.first, let last = samples.last else { return nil }
    if time <= first.time { return Frame(cursor: first.cursor, scroll: first.scroll) }
    if time >= last.time { return Frame(cursor: last.cursor, scroll: last.scroll) }
    var index = samples.count - 1
    while index > 0 && samples[index - 1].time > time {
      index -= 1
    }
    let before = samples[index - 1]
    let after = samples[index]
    let fraction = (time - before.time) / (after.time - before.time)
    return Frame(
      cursor: before.cursor + (after.cursor - before.cursor) * fraction,
      scroll: before.scroll + (after.scroll - before.scroll) * fraction)
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
