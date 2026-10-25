import Foundation

/// Every tunable of the phone's motion pipeline. Starting values come from
/// `docs/implementation.md`; tune them live from the settings screen.
public struct PipelineSettings: Codable, Equatable, Sendable {
  /// How phone motion becomes cursor motion.
  public struct Pointer: Codable, Equatable, Sendable {
    /// Gain at slow speeds, in screen points per millimetre of sensor-point travel.
    public var slowGain: Double = 2.5

    /// Gain at fast speeds is `slowGain × accelerationRatio`. 1 turns acceleration off.
    public var accelerationRatio: Double = 4.5

    /// Below this sensor-point speed (mm/s) the gain is `slowGain`.
    public var slowSpeed: Double = 20

    /// Above this speed (mm/s) the gain is the full fast gain. In between it eases smoothly.
    public var fastSpeed: Double = 250

    /// Overall multiplier on both gains, the "Speed" slider.
    public var speedScale: Double = 1

    /// 1€ filter minimum cutoff in Hz. Lower is smoother at rest, laggier when slow. At 1.5 Hz the
    /// filter added an estimated 65–105 ms of lag on slow moves; ARKit's rest wobble is under
    /// 1 mm, quiet enough for 3 Hz.
    public var filterMinCutoff: Double = 3

    /// 1€ filter speed coefficient, for positions in millimetres. Higher is less lag at speed.
    public var filterBeta: Double = 0.05

    /// 1€ filter derivative cutoff in Hz. It sets how fast the speed estimate, and so the cutoff,
    /// ramps up at the start of a move.
    public var filterDerivativeCutoff: Double = 3

    /// How far ahead of the camera, along the phone's long axis toward the top edge, the virtual
    /// sensor point sits, in metres. A longer reach makes a flat swivel move the cursor more, at
    /// the cost of a little sideways drift from small twists while pushing. At 10 cm a 10° turn
    /// about the phone's middle moves the cursor about 70 pt slow and up to about 300 pt fast; at
    /// the old 3 cm it was about 40 pt and barely registered. The 13 Pro Max's camera sits 2–4 cm
    /// below the top edge.
    public var sensorReach: Double = 0.1

    /// Use the gyro for the swivel part of the motion (fresher than ARKit), and to keep swivel
    /// working through brief tracking dropouts.
    public var gyroAssist = true

    public init() {}
  }

  /// Tilt-to-scroll.
  public struct TiltScroll: Codable, Equatable, Sendable {
    public var isEnabled = false

    /// The level angle is captured only while the absolute pitch is at most this many degrees.
    /// Past it the previous level stays (flat, until a capture succeeds), so a phone held tilted
    /// toward the face at engage can't become the new "level".
    public var levelCaptureLimit: Double = 20

    /// Degrees of pitch either side of the level angle that do nothing.
    public var deadZone: Double = 10

    /// Degrees inside the dead-zone edge at which an active scroll ends.
    public var hysteresis: Double = 2

    /// Speed = `speedFactor × (|θ| − deadZone)^exponent` px/s, θ in degrees.
    public var speedFactor: Double = 11

    public var exponent: Double = 1.5

    /// Cap in px/s.
    public var maxSpeed: Double = 3000

    /// Front edge up scrolls up (toward the top of the page) unless this is on.
    public var isReversed = false

    /// Seconds after a touch lands or lifts during which tilt is ignored.
    public var touchSuppression: TimeInterval = 0.15

    public init() {}

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let defaults = TiltScroll()
      isEnabled = try container.decode(.isEnabled, default: defaults.isEnabled)
      levelCaptureLimit = try container.decode(
        .levelCaptureLimit, default: defaults.levelCaptureLimit)
      deadZone = try container.decode(.deadZone, default: defaults.deadZone)
      hysteresis = try container.decode(.hysteresis, default: defaults.hysteresis)
      speedFactor = try container.decode(.speedFactor, default: defaults.speedFactor)
      exponent = try container.decode(.exponent, default: defaults.exponent)
      maxSpeed = try container.decode(.maxSpeed, default: defaults.maxSpeed)
      isReversed = try container.decode(.isReversed, default: defaults.isReversed)
      touchSuppression = try container.decode(
        .touchSuppression, default: defaults.touchSuppression)
    }
  }

  /// Volume-button scrolling: each press queues a distance that glides out over a fraction of a
  /// second.
  public struct ButtonScroll: Codable, Equatable, Sendable {
    public var isEnabled = true

    /// Pixels queued by one press.
    public var step: Double = 100

    /// Time constant of the exponential glide that releases a queued distance, seconds.
    public var glideTime: TimeInterval = 0.08

    /// Volume up scrolls toward the top of the page unless this is on.
    public var isReversed = false

    /// A press in the same direction within this many seconds of the previous one counts as the
    /// button being held, since iOS repeats a held volume button.
    public var holdInterval: TimeInterval = 0.3

    /// Seconds a hold takes to ramp its step up to `maxHoldMultiplier`.
    public var holdRampTime: TimeInterval = 1

    /// The multiplier on `step` once a hold has lasted `holdRampTime`. It rises linearly from 1
    /// at the hold's first press.
    public var maxHoldMultiplier: Double = 3

    public init() {}

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let defaults = ButtonScroll()
      isEnabled = try container.decode(.isEnabled, default: defaults.isEnabled)
      step = try container.decode(.step, default: defaults.step)
      glideTime = try container.decode(.glideTime, default: defaults.glideTime)
      isReversed = try container.decode(.isReversed, default: defaults.isReversed)
      holdInterval = try container.decode(.holdInterval, default: defaults.holdInterval)
      holdRampTime = try container.decode(.holdRampTime, default: defaults.holdRampTime)
      maxHoldMultiplier = try container.decode(
        .maxHoldMultiplier, default: defaults.maxHoldMultiplier)
    }
  }

  /// Click freeze, against the cursor jumping when a finger hits the screen.
  public struct Click: Codable, Equatable, Sendable {
    /// Seconds the cursor holds still after each touch landing, press and release.
    public var freezeDuration: TimeInterval = 0.08

    /// Sensor-point travel (mm) that ends a freeze early, so drags start promptly.
    public var freezeBreakout: Double = 3

    public init() {}
  }

  /// Lift-to-reposition clutch.
  public struct Lift: Codable, Equatable, Sendable {
    public var isEnabled = true

    /// Rise above the lowest height of the last `window` seconds that counts as a lift, metres.
    public var threshold: Double = 0.03

    public var window: TimeInterval = 0.3

    /// Time constant of the slow low-pass that tracks the resting ("desk") height, seconds.
    public var deskTimeConstant: TimeInterval = 2

    /// Descent from the lift's peak needed before the phone can re-engage, metres.
    public var reengageDescent: Double = 0.015

    /// The phone counts as set down when the height's least-squares slope over the last
    /// `reengageHold` seconds is under this, m/s.
    public var reengageSpeed: Double = 0.05

    /// Seconds of height history the set-down slope is fitted over.
    public var reengageHold: TimeInterval = 0.12

    /// On a lift, take back the cursor motion made since the rise began.
    public var rollsBackCursor = true

    /// The most a lift takes back, screen points. A lift made while moving fast would otherwise
    /// undo the whole fast stroke (over 1,000 pt has been seen). At 100 pt, 18 of 20 lifts in one
    /// session hit the cap, so most of what it took back was the end of a deliberate stroke. It
    /// was saved as `maxRollback` with that 100 pt default and no slider, so the new name lets
    /// saved settings pick up this default.
    public var rollbackLimit: Double = 40

    /// How far from the camera, along the phone's long axis toward the top edge, the front
    /// height point sits, metres.
    public var frontDistance: Double = 0.03

    /// How far from the camera, along the phone's long axis toward the bottom edge, the back
    /// height point sits, metres. A lift needs both points to rise past `threshold`, and a tilt
    /// (or the return from one) moves them in opposite directions, so it never reads as a lift.
    public var backDistance: Double = 0.13

    public init() {}

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let defaults = Lift()
      isEnabled = try container.decode(.isEnabled, default: defaults.isEnabled)
      threshold = try container.decode(.threshold, default: defaults.threshold)
      window = try container.decode(.window, default: defaults.window)
      deskTimeConstant = try container.decode(
        .deskTimeConstant, default: defaults.deskTimeConstant)
      reengageDescent = try container.decode(.reengageDescent, default: defaults.reengageDescent)
      reengageSpeed = try container.decode(.reengageSpeed, default: defaults.reengageSpeed)
      reengageHold = try container.decode(.reengageHold, default: defaults.reengageHold)
      rollsBackCursor = try container.decode(.rollsBackCursor, default: defaults.rollsBackCursor)
      rollbackLimit = try container.decode(.rollbackLimit, default: defaults.rollbackLimit)
      frontDistance = try container.decode(.frontDistance, default: defaults.frontDistance)
      backDistance = try container.decode(.backDistance, default: defaults.backDistance)
    }
  }

  /// Tracking-quality guards.
  public struct Tracking: Codable, Equatable, Sendable {
    /// ARKit deltas faster than this (m/s) are treated as pose jumps and dropped.
    public var maxPlausibleSpeed: Double = 3

    /// After tracking returns to normal, this many frames' deltas are dropped.
    public var recoveryFrames = 3

    /// Seconds the gyro keeps swivel going after ARKit stops delivering good frames.
    public var gyroGracePeriod: TimeInterval = 0.3

    public init() {}
  }

  public var pointer = Pointer()
  public var tiltScroll = TiltScroll()
  public var buttonScroll = ButtonScroll()
  public var click = Click()
  public var lift = Lift()
  public var tracking = Tracking()

  public init() {}

  /// Decodes each group on its own, so a group that is missing, was saved in an older shape or
  /// fails to decode falls back to its defaults without losing the other groups. A saved `scroll`
  /// group (the old name of `tiltScroll`) is ignored.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = PipelineSettings()
    pointer = (try? container.decodeIfPresent(Pointer.self, forKey: .pointer))
      ?? defaults.pointer
    tiltScroll = (try? container.decodeIfPresent(TiltScroll.self, forKey: .tiltScroll))
      ?? defaults.tiltScroll
    buttonScroll = (try? container.decodeIfPresent(ButtonScroll.self, forKey: .buttonScroll))
      ?? defaults.buttonScroll
    click = (try? container.decodeIfPresent(Click.self, forKey: .click)) ?? defaults.click
    lift = (try? container.decodeIfPresent(Lift.self, forKey: .lift)) ?? defaults.lift
    tracking = (try? container.decodeIfPresent(Tracking.self, forKey: .tracking))
      ?? defaults.tracking
  }
}

extension KeyedDecodingContainer {
  /// The value stored under `key`, or `fallback` if the key is absent. The settings decoders read
  /// field by field with this, so settings saved before a field existed still load.
  fileprivate func decode<Value: Decodable>(_ key: Key, default fallback: Value) throws -> Value {
    try decodeIfPresent(Value.self, forKey: key) ?? fallback
  }
}
