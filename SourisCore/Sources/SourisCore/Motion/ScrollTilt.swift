import Foundation
import simd

/// Tilt-to-scroll: the pitch beyond a dead zone around the captured level angle sets a scroll
/// speed, like a joystick.
struct ScrollTilt: Sendable {
  /// The longest IMU interval integrated in one step, against a stall turning into a jump.
  static let maximumInterval: TimeInterval = 0.05

  /// The resting pitch, degrees, captured at engage.
  var level: Double = 0

  /// A scroll is in progress.
  private(set) var isActive = false

  /// Current speed, px/s, signed like `MouseState.scroll.y`.
  private(set) var speed: Double = 0

  /// The latest pitch relative to `level`, degrees, front edge up positive.
  private(set) var relativePitch: Double = 0

  private var lastTime: TimeInterval?

  /// The phone's pitch in degrees from Core Motion's gravity: 0 flat and screen up, positive with
  /// the front (top) edge raised.
  static func pitch(gravity: SIMD3<Double>) -> Double {
    // Raising the top edge by φ turns gravity in the device frame to (0, −sin φ, −cos φ).
    atan2(-gravity.y, -gravity.z) * 180 / .pi
  }

  /// The scroll speed (px/s) for a pitch `angle` degrees from level, ignoring hysteresis.
  static func speed(angle: Double, settings: PipelineSettings.TiltScroll) -> Double {
    let excess = max(0, abs(angle) - settings.deadZone)
    let magnitude = min(settings.maxSpeed, settings.speedFactor * pow(excess, settings.exponent))
    let signed = angle < 0 ? -magnitude : magnitude
    return settings.isReversed ? -signed : signed
  }

  /// Advances by one IMU sample.
  ///
  /// - Parameters:
  ///   - pitch: The phone's pitch, degrees (see `pitch(gravity:)`).
  ///   - time: The sample's timestamp.
  ///   - isAllowed: False ends any scroll and keeps it off for this sample.
  /// - Returns: The scroll distance for this sample, px.
  mutating func update(
    pitch: Double,
    time: TimeInterval,
    isAllowed: Bool,
    settings: PipelineSettings.TiltScroll
  ) -> Double {
    let interval = lastTime.map { min(max(time - $0, 0), Self.maximumInterval) } ?? 0
    lastTime = time
    relativePitch = pitch - level
    guard isAllowed else {
      end()
      return 0
    }
    let magnitude = abs(relativePitch)
    if isActive {
      isActive = magnitude >= settings.deadZone - settings.hysteresis
    } else {
      isActive = magnitude > settings.deadZone
    }
    guard isActive else {
      speed = 0
      return 0
    }
    speed = Self.speed(angle: relativePitch, settings: settings)
    return speed * interval
  }

  mutating func end() {
    isActive = false
    speed = 0
  }
}
