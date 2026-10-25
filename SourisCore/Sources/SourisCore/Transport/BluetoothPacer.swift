import Foundation

/// Decides when the phone may hand Bluetooth its next notification.
///
/// iOS accepts notifications until its transmit queue is full, and each one then waits for all
/// those ahead of it. Filling that queue (as the bridge first did) made every cursor update wait
/// 80–170 ms. The pacer hands over at most one notification per `interval` and keeps the interval
/// near what the link drains:
/// - A refused notification means the queue is full: the interval grows by half.
/// - Each ping's round trip is compared with the lowest one in the last `baselineWindow`. Well
///   above it, packets are queuing and the interval grows by a quarter, at most once per
///   `growthHoldoff`; close to it, the interval shrinks by `shrinkStep`.
///
/// Times are seconds of phone uptime.
public struct BluetoothPacer: Sendable {
  public static let initialInterval: TimeInterval = 0.015
  public static let minimumInterval: TimeInterval = 0.0075
  public static let maximumInterval: TimeInterval = 0.06

  /// A round trip this far above the baseline means notifications are queuing, seconds.
  public static let queuingThreshold: TimeInterval = 0.02

  /// A round trip within this of the baseline means the queue is clear, seconds.
  public static let clearThreshold: TimeInterval = 0.008

  public static let shrinkStep: TimeInterval = 0.001

  /// How long the lowest round trip counts as the baseline, seconds.
  public static let baselineWindow: TimeInterval = 10

  /// After the interval grows, slow round trips from packets already queued don't grow it again
  /// for this long, seconds.
  public static let growthHoldoff: TimeInterval = 0.25

  /// The time to leave between notifications, seconds.
  public private(set) var interval = initialInterval

  private var lastSend: TimeInterval?
  private var lastGrowth: TimeInterval?
  private var roundTrips: [(time: TimeInterval, value: TimeInterval)] = []

  public init() {}

  /// The lowest round trip in the last `baselineWindow`, seconds.
  public var baselineRoundTrip: TimeInterval? {
    roundTrips.map(\.value).min()
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
    grow(by: 1.5, at: time, force: true)
  }

  /// A pong came back `roundTrip` seconds after its ping went out.
  public mutating func didMeasure(roundTrip: TimeInterval, at time: TimeInterval) {
    roundTrips.removeAll { $0.time < time - Self.baselineWindow }
    roundTrips.append((time, roundTrip))
    guard let baseline = baselineRoundTrip else { return }
    if roundTrip > baseline + Self.queuingThreshold {
      grow(by: 1.25, at: time, force: false)
    } else if roundTrip < baseline + Self.clearThreshold {
      interval = max(Self.minimumInterval, interval - Self.shrinkStep)
    }
  }

  /// Forgets what the link was like, e.g. when the Mac connects again.
  public mutating func reset() {
    self = BluetoothPacer()
  }

  private mutating func grow(by factor: Double, at time: TimeInterval, force: Bool) {
    if !force, let lastGrowth, time - lastGrowth < Self.growthHoldoff { return }
    lastGrowth = time
    interval = min(Self.maximumInterval, interval * factor)
  }
}
