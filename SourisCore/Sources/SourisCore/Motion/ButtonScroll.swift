import Foundation

/// One accepted volume-button press, as the app reports it.
public struct ScrollButtonPress: Equatable, Codable, Sendable {
  /// The volume button that was pressed.
  public enum Direction: String, Codable, Sendable {
    case up
    case down
  }

  public var direction: Direction

  /// When the press happened, uptime seconds: the clock of sample arrival times.
  public var time: TimeInterval

  public init(direction: Direction, time: TimeInterval) {
    self.direction = direction
    self.time = time
  }
}

/// Volume-button scrolling. A press queues a distance, and the glide releases it as an
/// exponential decay, `pending · (1 − e^(−dt/glideTime))` per advance, so the total scrolled is
/// exactly what was queued. iOS repeats a held volume button, so presses in quick succession in
/// one direction ramp up the step.
struct ButtonScroll: Sendable {
  /// A glide with less than this left (px) emits it all and ends.
  static let finishThreshold: Double = 0.5

  /// A queued distance is being released.
  private(set) var isActive = false

  /// Signed distance still to emit, px.
  private(set) var pending: Double = 0

  /// Signed distance emitted since the glide started, px.
  private(set) var scrolled: Double = 0

  private var previousPress: ScrollButtonPress?
  private var holdStart: TimeInterval = 0
  private var lastAdvance: TimeInterval = 0

  /// Queues one press.
  ///
  /// A press against the pending direction replaces the pending distance and restarts the hold.
  ///
  /// - Returns: The signed distance this press queued, px, and whether it started a glide.
  mutating func press(
    _ press: ScrollButtonPress,
    settings: PipelineSettings.ButtonScroll
  ) -> (pixels: Double, startedGlide: Bool) {
    let sign: Double = (press.direction == .up) != settings.isReversed ? 1 : -1
    let reverses = isActive && pending * sign < 0
    let isHold = !reverses && previousPress.map {
      $0.direction == press.direction && press.time - $0.time <= settings.holdInterval
    } ?? false
    if !isHold {
      holdStart = press.time
    }
    let ramp = settings.holdRampTime > 0
      ? min(1, max(0, (press.time - holdStart) / settings.holdRampTime)) : 1
    let multiplier = 1 + (settings.maxHoldMultiplier - 1) * ramp
    let pixels = sign * settings.step * multiplier
    previousPress = press

    let startedGlide = !isActive
    if startedGlide {
      isActive = true
      pending = pixels
      scrolled = 0
      lastAdvance = press.time
    } else if reverses {
      pending = pixels
    } else {
      pending += pixels
    }
    return (pixels, startedGlide)
  }

  /// Releases the part of the pending distance due by `time`. Times not after the previous
  /// advance do nothing.
  ///
  /// - Parameter time: An input's arrival time.
  /// - Returns: The signed distance to scroll now, px.
  mutating func advance(to time: TimeInterval, settings: PipelineSettings.ButtonScroll) -> Double {
    guard isActive, time > lastAdvance else { return 0 }
    let interval = time - lastAdvance
    lastAdvance = time
    let fraction = settings.glideTime > 0 ? 1 - exp(-interval / settings.glideTime) : 1
    var distance = pending * fraction
    pending -= distance
    if abs(pending) < Self.finishThreshold {
      distance += pending
      pending = 0
      isActive = false
    }
    scrolled += distance
    return distance
  }

  /// The glide's current rate, px/s, signed like `MouseState.scroll.y`.
  func speed(glideTime: TimeInterval) -> Double {
    isActive && glideTime > 0 ? pending / glideTime : 0
  }

  /// Drops whatever is pending.
  mutating func end() {
    isActive = false
    pending = 0
  }
}
