import Foundation
import simd

/// A two-dimensional 1€ filter (Casiez et al., CHI 2012) with one cutoff shared by both axes.
///
/// The cutoff follows the 2D speed, not each axis's own speed, so a diagonal stroke is smoothed
/// equally on both axes and doesn't bend.
struct OneEuroFilter2D: Sendable {
  /// Updates closer together than this (seconds) are skipped, against division by a zero dt.
  static let minimumInterval: TimeInterval = 1e-4

  /// The filtered value, nil until the first update.
  private(set) var value: SIMD2<Double>?

  /// The low-passed derivative of the input, units per second.
  private(set) var derivative = SIMD2<Double>.zero

  private var lastTime: TimeInterval = 0

  /// The speed the cutoff follows: the length of the smoothed derivative.
  var speed: Double { simd_length(derivative) }

  /// The smoothing factor of a first-order low-pass with cutoff `cutoff` (Hz) over `interval`
  /// seconds.
  static func smoothingFactor(cutoff: Double, interval: TimeInterval) -> Double {
    let timeConstant = 1 / (2 * Double.pi * max(cutoff, 1e-6))
    return 1 / (1 + timeConstant / interval)
  }

  /// The position cutoff in Hz for a given speed.
  static func cutoff(speed: Double, minimumCutoff: Double, beta: Double) -> Double {
    minimumCutoff + beta * speed
  }

  /// Restarts the filter at `point` with zero speed.
  mutating func reset(to point: SIMD2<Double>, time: TimeInterval) {
    value = point
    derivative = .zero
    lastTime = time
  }

  /// Filters `point` taken at `time`.
  ///
  /// - Parameters:
  ///   - minimumCutoff: The position cutoff at rest, Hz.
  ///   - beta: How much the cutoff rises per unit of speed.
  ///   - derivativeCutoff: The cutoff of the derivative's own low-pass, Hz.
  /// - Returns: The filtered value. Unchanged if `time` is not past the previous update.
  @discardableResult
  mutating func update(
    _ point: SIMD2<Double>,
    time: TimeInterval,
    minimumCutoff: Double,
    beta: Double,
    derivativeCutoff: Double
  ) -> SIMD2<Double> {
    guard let previous = value else {
      reset(to: point, time: time)
      return point
    }
    let interval = time - lastTime
    guard interval > Self.minimumInterval else { return previous }
    lastTime = time

    let rawDerivative = (point - previous) / interval
    let derivativeFactor = Self.smoothingFactor(cutoff: derivativeCutoff, interval: interval)
    derivative += derivativeFactor * (rawDerivative - derivative)

    let cutoff = Self.cutoff(speed: speed, minimumCutoff: minimumCutoff, beta: beta)
    let filtered = previous + Self.smoothingFactor(cutoff: cutoff, interval: interval)
      * (point - previous)
    value = filtered
    return filtered
  }
}
