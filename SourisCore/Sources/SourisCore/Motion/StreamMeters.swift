import Foundation
import simd

/// Smoothed rate and delivery delay of one sensor stream, for the debug overlay.
struct StreamMeter: Sendable {
  /// Weight of each new reading in the moving averages.
  static let smoothing = 0.1

  /// Samples per second.
  private(set) var rate: Double = 0

  /// Arrival − capture timestamp, seconds.
  private(set) var delay: Double = 0

  private var lastTimestamp: TimeInterval?
  private var hasDelay = false

  mutating func record(timestamp: TimeInterval, arrival: TimeInterval) {
    let newDelay = arrival - timestamp
    delay = hasDelay ? delay + Self.smoothing * (newDelay - delay) : newDelay
    hasDelay = true
    if let lastTimestamp, timestamp > lastTimestamp {
      let newRate = 1 / (timestamp - lastTimestamp)
      rate = rate == 0 ? newRate : rate + Self.smoothing * (newRate - rate)
    }
    lastTimestamp = timestamp
  }
}

/// RMS spread of the sensor point's horizontal position over a short window. Held still, it reads
/// the tracking jitter.
struct JitterMeter: Sendable {
  private struct Sample: Sendable {
    var time: TimeInterval
    var point: SIMD2<Double>
  }

  static let window: TimeInterval = 0.5

  /// RMS distance from the window's mean, in the input's units.
  private(set) var rms: Double = 0

  private var samples = RingBuffer<Sample>(capacity: 128)

  /// Adds a horizontal position (any fixed horizontal axes; the RMS doesn't depend on them).
  mutating func record(_ point: SIMD2<Double>, time: TimeInterval) {
    samples.append(Sample(time: time, point: point))
    while let oldest = samples.first, oldest.time < time - Self.window {
      samples.removeFirst()
    }
    // Relative to the newest point, so large world coordinates don't cost precision.
    let reference = point
    var sum = SIMD2<Double>.zero
    var sumOfSquares: Double = 0
    for index in 0..<samples.count {
      let offset = samples[index].point - reference
      sum += offset
      sumOfSquares += simd_length_squared(offset)
    }
    let count = Double(samples.count)
    let mean = sum / count
    rms = (max(0, sumOfSquares / count - simd_length_squared(mean))).squareRoot()
  }
}
