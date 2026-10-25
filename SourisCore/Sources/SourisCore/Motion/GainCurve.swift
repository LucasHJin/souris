import Foundation
import simd

/// The pointer acceleration curve: screen points per millimetre of sensor-point travel as a
/// function of speed.
enum GainCurve {
  /// `slowGain · speedScale · (1 + (accelerationRatio − 1) · smoothstep(slowSpeed, fastSpeed,
  /// speed))`.
  ///
  /// - Parameter speed: Filtered sensor-point speed, mm/s.
  static func gain(speed: Double, settings: PipelineSettings.Pointer) -> Double {
    let blend = smoothstep(settings.slowSpeed, settings.fastSpeed, speed)
    return settings.slowGain * settings.speedScale
      * (1 + (settings.accelerationRatio - 1) * blend)
  }

  /// 0 below `lower`, 1 above `upper`, and a cubic ease in between. A step when the edges meet
  /// or cross.
  static func smoothstep(_ lower: Double, _ upper: Double, _ x: Double) -> Double {
    guard upper > lower else { return x < lower ? 0 : 1 }
    let t = min(max((x - lower) / (upper - lower), 0), 1)
    return t * t * (3 - 2 * t)
  }
}

/// The low-passed velocity of a 2D point, for the gain curve's speed.
struct VelocityMeter: Sendable {
  private var last: SIMD2<Double>?
  private var lastTime: TimeInterval = 0
  private var velocity = SIMD2<Double>.zero

  /// The length of the smoothed velocity, units per second.
  var speed: Double { simd_length(velocity) }

  /// Restarts at `point` with zero velocity.
  mutating func reset(to point: SIMD2<Double>, time: TimeInterval) {
    last = point
    lastTime = time
    velocity = .zero
  }

  /// Adds `point` at `time` and returns the speed. The velocity is low-passed as a vector, so
  /// jitter in opposite directions cancels instead of adding up to a speed.
  mutating func update(_ point: SIMD2<Double>, time: TimeInterval, cutoff: Double) -> Double {
    guard let last else {
      reset(to: point, time: time)
      return 0
    }
    let interval = time - lastTime
    guard interval > OneEuroFilter2D.minimumInterval else { return speed }
    let factor = OneEuroFilter2D.smoothingFactor(cutoff: cutoff, interval: interval)
    velocity += factor * ((point - last) / interval - velocity)
    self.last = point
    lastTime = time
    return speed
  }
}
