import Foundation

/// Decides when the phone may hand Bluetooth its next notification.
///
/// iOS accepts notifications until its transmit queue is full, and each one then waits for all
/// those ahead of it. Filling that queue (as the bridge first did) made every cursor update wait
/// 80–170 ms. The pacer hands over at most one notification per `interval` and keeps the interval
/// near what the link drains:
/// - A refused notification means the queue is full: the interval grows by half.
/// - Ping round trips, timed from when the bridge hands the ping over, are compared with the
///   lowest one in the last `baselineWindow`. Each way a packet waits for the next connection
///   event, up to 30 ms, so single round trips swing by up to 60 ms with nothing queued. The lowest
///   of the last `recentCount` is one that caught the events; well above the baseline, packets are
///   queuing and the interval grows by a quarter, and close to it the interval shrinks by
///   `shrinkStep`. Each change waits for `recentCount` round trips measured after the last one.
///
/// Times are seconds of phone uptime.
public struct BluetoothPacer: Sendable {
  public static let initialInterval: TimeInterval = 0.015
  public static let minimumInterval: TimeInterval = 0.0075
  public static let maximumInterval: TimeInterval = 0.06

  /// How many recent round trips decide a change.
  public static let recentCount = 4

  /// The lowest recent round trip this far above the baseline means notifications are queuing,
  /// seconds.
  public static let queuingThreshold: TimeInterval = 0.02

  /// The lowest recent round trip within this of the baseline means the queue is clear, seconds.
  public static let clearThreshold: TimeInterval = 0.008

  public static let shrinkStep: TimeInterval = 0.001

  /// How long the lowest round trip counts as the baseline, seconds.
  public static let baselineWindow: TimeInterval = 10

  /// The time to leave between notifications, seconds.
  public private(set) var interval = initialInterval

  private var lastSend: TimeInterval?
  private var lastChange: TimeInterval?
  private var roundTrips: [(time: TimeInterval, value: TimeInterval)] = []

  public init() {}

  /// The lowest round trip in the last `baselineWindow`, seconds.
  public var baselineRoundTrip: TimeInterval? {
    roundTrips.map(\.value).min()
  }

  /// The lowest of the last `recentCount` round trips measured since the interval last changed,
  /// once there are that many.
  public var recentRoundTrip: TimeInterval? {
    let fresh = roundTrips.filter { $0.time > lastChange ?? -.infinity }
    guard fresh.count >= Self.recentCount else { return nil }
    return fresh.suffix(Self.recentCount).map(\.value).min()
  }

  /// The earliest time the next notification may go.
  public var nextSendTime: TimeInterval {
    lastSend.map { $0 + interval } ?? 0
  }

  public func canSend(at time: TimeInterval) -> Bool {
    time >= nextSendTime
  }

  public mutating func didSend(at time: TimeInterval) {
    lastSend = time
  }

  /// iOS refused a notification: its queue is full.
  public mutating func didRefuse(at time: TimeInterval) {
    change(to: interval * 1.5, at: time)
  }

  /// A pong came back `roundTrip` seconds after its ping was handed to Bluetooth.
  public mutating func didMeasure(roundTrip: TimeInterval, at time: TimeInterval) {
    roundTrips.removeAll { $0.time < time - Self.baselineWindow }
    roundTrips.append((time, roundTrip))
    guard let baseline = baselineRoundTrip, let recent = recentRoundTrip else { return }
    if recent > baseline + Self.queuingThreshold {
      change(to: interval * 1.25, at: time)
    } else if recent < baseline + Self.clearThreshold {
      change(to: interval - Self.shrinkStep, at: time)
    }
  }

  /// Forgets what the link was like, e.g. when the Mac connects again.
  public mutating func reset() {
    self = BluetoothPacer()
  }

  private mutating func change(to newInterval: TimeInterval, at time: TimeInterval) {
    interval = min(Self.maximumInterval, max(Self.minimumInterval, newInterval))
    lastChange = time
  }
}
