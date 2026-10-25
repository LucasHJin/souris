import Foundation

/// Tunables for the scroll wheel: a strip between the two buttons that a fingertip rolls like a
/// notched mouse wheel.
public struct ScrollWheelSettings: Codable, Equatable, Sendable {
  public var isEnabled = true

  /// The strip's width, points, centred between the buttons.
  public var width: Double = 44

  /// The fraction of the touch area's height the strip spans, centred in it.
  public var heightFraction: Double = 0.6

  /// Finger travel per notch, points.
  public var notchSpacing: Double = 12

  /// Pixels one notch scrolls while the finger moves slowly.
  public var pixelsPerNotch: Double = 40

  /// The most a fast roll multiplies `pixelsPerNotch` by. 1 turns acceleration off.
  public var maxAcceleration: Double = 4

  /// Finger speed, pt/s, up to which a notch scrolls `pixelsPerNotch`.
  public var slowSpeed: Double = 150

  /// Finger speed, pt/s, from which a notch scrolls `maxAcceleration` times that. In between it
  /// eases smoothly.
  public var fastSpeed: Double = 1500

  /// A flick leaves the wheel spinning after the finger lifts.
  public var hasMomentum = true

  /// The slowest release that sets the wheel spinning, pt/s of finger travel.
  public var flickSpeed: Double = 400

  /// How long a spin takes to slow by a factor of e, seconds.
  public var momentumTime: TimeInterval = 0.35

  /// Time constant of the glide that lets out each notch's scrolling, seconds.
  public var glideTime: TimeInterval = 0.04

  /// Rolling the wheel toward the top edge (away from the palm) scrolls toward the top of the
  /// page unless this is on.
  public var isReversed = false

  /// A short tap that doesn't roll the wheel is a middle click, as pressing a mouse wheel is.
  public var tapClicksMiddle = true

  /// Strength of the haptic tick each notch makes, 0–1. 0 turns the ticks off.
  public var tickIntensity: Double = 0.7

  /// The wheel keeps ticking while it spins on after a flick.
  public var ticksWhileSpinning = true

  public init() {}

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = ScrollWheelSettings()
    isEnabled = try container.decode(.isEnabled, default: defaults.isEnabled)
    width = try container.decode(.width, default: defaults.width)
    heightFraction = try container.decode(.heightFraction, default: defaults.heightFraction)
    notchSpacing = try container.decode(.notchSpacing, default: defaults.notchSpacing)
    pixelsPerNotch = try container.decode(.pixelsPerNotch, default: defaults.pixelsPerNotch)
    maxAcceleration = try container.decode(.maxAcceleration, default: defaults.maxAcceleration)
    slowSpeed = try container.decode(.slowSpeed, default: defaults.slowSpeed)
    fastSpeed = try container.decode(.fastSpeed, default: defaults.fastSpeed)
    hasMomentum = try container.decode(.hasMomentum, default: defaults.hasMomentum)
    flickSpeed = try container.decode(.flickSpeed, default: defaults.flickSpeed)
    momentumTime = try container.decode(.momentumTime, default: defaults.momentumTime)
    glideTime = try container.decode(.glideTime, default: defaults.glideTime)
    isReversed = try container.decode(.isReversed, default: defaults.isReversed)
    tapClicksMiddle = try container.decode(.tapClicksMiddle, default: defaults.tapClicksMiddle)
    tickIntensity = try container.decode(.tickIntensity, default: defaults.tickIntensity)
    ticksWhileSpinning = try container.decode(
      .ticksWhileSpinning, default: defaults.ticksWhileSpinning)
  }
}

/// What the scroll wheel tells the motion pipeline.
public enum ScrollWheelEvent: Equatable, Codable, Sendable {
  /// A finger landed on the wheel (`isDown`) or lifted off it. The cursor holds still in between,
  /// since rolling the wheel pushes the phone.
  case touch(isDown: Bool, time: TimeInterval)

  /// The wheel scrolled `pixels`, signed like `MouseState.scroll.y` (positive toward the top of
  /// the page).
  case turn(pixels: Double, time: TimeInterval)

  /// The wheel came to rest and everything it queued has scrolled.
  case stop(time: TimeInterval)

  public var time: TimeInterval {
    switch self {
    case .touch(_, let time): time
    case .turn(_, let time): time
    case .stop(let time): time
    }
  }
}

/// A notched mouse wheel rolled by a fingertip.
///
/// - Rolling: every `notchSpacing` points of finger travel along the strip is a notch: one haptic
///   tick, and `pixelsPerNotch` of scrolling times up to `maxAcceleration` the faster the finger
///   moves. Moving toward the top edge scrolls toward the top of the page. Each notch's scrolling
///   glides out over about `glideTime` instead of jumping.
/// - Momentum: a finger that lifts while moving faster than `flickSpeed` leaves the wheel spinning
///   at the matching notch rate. The spin slows by e every `momentumTime`, ticking and scrolling
///   notch by notch, and stops below `stopRate`. A finger landing on the wheel stops it.
/// - A touch that moves less than `tapSlop` and lifts within `tapDuration`, on a wheel that wasn't
///   spinning, is a tap: a middle click.
/// - `.stop` follows once the wheel is at rest, its scrolling has glided out, and the finger has
///   lifted or held still for `restTime`.
///
/// Call `advance(to:settings:)` every display refresh while `needsFrames`. Positions are the
/// touch's y in points (down the screen); times are uptime seconds.
public struct ScrollWheel: Sendable {
  public static let tapSlop: Double = 8
  public static let tapDuration: TimeInterval = 0.25

  /// The slowest spin, notches per second, before momentum stops.
  public static let stopRate: Double = 3

  /// A finger held still on the wheel this long ends the scroll, seconds.
  public static let restTime: TimeInterval = 0.25

  /// Time constant of the finger-speed estimate, seconds.
  static let speedSmoothing: TimeInterval = 0.03

  /// A lift this long after the finger last moved isn't a flick, seconds.
  static let flickWindow: TimeInterval = 0.05

  /// What one call produced.
  public struct Update: Equatable, Sendable {
    public var events: [ScrollWheelEvent] = []

    /// Notches passed, one haptic tick each.
    public var ticks = 0

    /// The touch was a tap: a middle click.
    public var isTap = false

    public init() {}
  }

  public private(set) var isTouching = false

  /// How far the wheel has turned, notches, positive toward the top edge. The ridges drawn on it
  /// follow this, so they move with the finger and keep moving through a spin.
  public private(set) var rotation: Double = 0

  private var touchStart: (y: Double, time: TimeInterval)?
  private var lastMove: (y: Double, time: TimeInterval)?

  /// Finger velocity down the screen, pt/s, smoothed.
  private var fingerVelocity: Double = 0

  /// Finger travel since the last notch, points, positive toward the top edge.
  private var travel: Double = 0

  /// The furthest the finger has been from where it landed, points.
  private var farthest: Double = 0
  private var wasSpinningAtTouch = false

  /// Spin rate, notches per second, positive toward the top edge, and the part of a notch it has
  /// turned since the last one.
  private var spin: Double = 0
  private var spinPhase: Double = 0

  /// Scrolling queued by notches and not yet let out, pixels.
  private var pending: Double = 0

  /// A `.turn` has gone out and its `.stop` hasn't.
  private var isTurning = false
  private var lastNotchTime: TimeInterval?
  private var lastAdvance: TimeInterval?

  public init() {}

  /// The wheel is spinning or has scrolling to let out, so `advance(to:settings:)` must run.
  public var needsFrames: Bool {
    spin != 0 || pending != 0 || isTurning
  }

  public var isSpinning: Bool {
    spin != 0
  }

  /// A finger landed on the wheel at `y`.
  public mutating func touchBegan(y: Double, time: TimeInterval) -> Update {
    var update = Update()
    wasSpinningAtTouch = spin != 0
    spin = 0
    spinPhase = 0
    isTouching = true
    touchStart = (y, time)
    lastMove = (y, time)
    fingerVelocity = 0
    travel = 0
    farthest = 0
    if lastAdvance == nil {
      lastAdvance = time
    }
    update.events.append(.touch(isDown: true, time: time))
    return update
  }

  /// The finger on the wheel moved to `y`.
  public mutating func touchMoved(
    y: Double, time: TimeInterval, settings: ScrollWheelSettings
  ) -> Update {
    var update = Update()
    guard isTouching, let last = lastMove else { return update }
    let step = y - last.y
    let interval = time - last.time
    if interval > 0 {
      let weight = 1 - exp(-interval / Self.speedSmoothing)
      fingerVelocity += (step / interval - fingerVelocity) * weight
    }
    lastMove = (y, time)
    if let touchStart {
      farthest = max(farthest, abs(y - touchStart.y))
    }
    let spacing = max(1, settings.notchSpacing)
    rotation -= step / spacing
    travel -= step
    while abs(travel) >= spacing {
      let sign: Double = travel > 0 ? 1 : -1
      travel -= sign * spacing
      queueNotch(sign, speed: abs(fingerVelocity), settings: settings)
      update.ticks += 1
      lastNotchTime = time
    }
    return update
  }

  /// The finger lifted off the wheel.
  public mutating func touchEnded(time: TimeInterval, settings: ScrollWheelSettings) -> Update {
    var update = Update()
    guard isTouching else { return update }
    isTouching = false
    update.events.append(.touch(isDown: false, time: time))
    let duration = time - (touchStart?.time ?? time)
    update.isTap = settings.tapClicksMiddle && !wasSpinningAtTouch
      && duration < Self.tapDuration && farthest < Self.tapSlop
    let isFresh = lastMove.map { time - $0.time <= Self.flickWindow } ?? false
    if settings.hasMomentum && isFresh && abs(fingerVelocity) >= settings.flickSpeed {
      let spacing = max(1, settings.notchSpacing)
      spin = -fingerVelocity / spacing
      spinPhase = travel / spacing
      travel = 0
    }
    touchStart = nil
    lastMove = nil
    return update
  }

  /// Turns the spin and lets out queued scrolling up to `time`, a display refresh.
  public mutating func advance(to time: TimeInterval, settings: ScrollWheelSettings) -> Update {
    var update = Update()
    let interval = max(0, time - (lastAdvance ?? time))
    lastAdvance = time

    if spin != 0 && interval > 0 {
      let momentumTime = max(0.01, settings.momentumTime)
      let decay = exp(-interval / momentumTime)
      let turned = spin * momentumTime * (1 - decay)
      let speed = abs(spin) * max(1, settings.notchSpacing)
      spin *= decay
      rotation += turned
      spinPhase += turned
      while abs(spinPhase) >= 1 {
        let sign: Double = spinPhase > 0 ? 1 : -1
        spinPhase -= sign
        queueNotch(sign, speed: speed, settings: settings)
        if settings.ticksWhileSpinning {
          update.ticks += 1
        }
        lastNotchTime = time
      }
      if abs(spin) < Self.stopRate {
        spin = 0
        spinPhase = 0
      }
    }

    if pending != 0 {
      var release = settings.glideTime > 0
        ? pending * (1 - exp(-interval / settings.glideTime)) : pending
      if abs(pending - release) < 0.5 {
        release = pending
      }
      pending -= release
      if release != 0 {
        isTurning = true
        update.events.append(.turn(pixels: release, time: time))
      }
    }

    if isTurning && pending == 0 && spin == 0 {
      let isResting = !isTouching || (lastNotchTime.map { time - $0 >= Self.restTime } ?? true)
      if isResting {
        isTurning = false
        update.events.append(.stop(time: time))
      }
    }
    return update
  }

  /// Lifts any finger and stops the wheel at once, dropping scrolling not yet let out, e.g. when
  /// the app goes inactive.
  public mutating func cancel(time: TimeInterval) -> Update {
    var update = Update()
    if isTouching {
      update.events.append(.touch(isDown: false, time: time))
    }
    if isTurning {
      update.events.append(.stop(time: time))
    }
    let rotation = rotation
    self = ScrollWheel()
    self.rotation = rotation
    return update
  }

  // MARK: - Private

  private mutating func queueNotch(
    _ sign: Double, speed: Double, settings: ScrollWheelSettings
  ) {
    let direction: Double = settings.isReversed ? -1 : 1
    pending += sign * direction * settings.pixelsPerNotch * Self.acceleration(
      speed: speed, settings: settings)
  }

  /// The multiplier on `pixelsPerNotch` at a finger speed, pt/s.
  static func acceleration(speed: Double, settings: ScrollWheelSettings) -> Double {
    guard settings.maxAcceleration > 1, settings.fastSpeed > settings.slowSpeed else { return 1 }
    let progress = min(1, max(0, (speed - settings.slowSpeed)
      / (settings.fastSpeed - settings.slowSpeed)))
    let eased = progress * progress * (3 - 2 * progress)
    return 1 + (settings.maxAcceleration - 1) * eased
  }
}

extension KeyedDecodingContainer {
  /// The value stored under `key`, or `fallback` if the key is absent.
  fileprivate func decode<Value: Decodable>(_ key: Key, default fallback: Value) throws -> Value {
    try decodeIfPresent(Value.self, forKey: key) ?? fallback
  }
}
