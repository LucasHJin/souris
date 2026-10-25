import Foundation
import simd

/// Holds the cursor still for a moment after each touch landing, press and release, so the tap's
/// jolt doesn't move it. Motion past a small threshold breaks the freeze so drags start promptly.
///
/// The window is judged by each sample's capture time, so motion captured before the touch still
/// counts even though ARKit delivers it after the touch event. The freeze ends once an ARKit frame
/// captured past the window arrives, since ARKit is the later of the two streams.
struct ClickFreeze: Sendable {
  /// If no ARKit frame ends the freeze, an IMU sample this long past the window does.
  static let staleStreamAllowance: TimeInterval = 0.25

  /// A freeze is holding the cursor (or waiting for ARKit to deliver past its window).
  private(set) var isActive = false

  private var start: TimeInterval = 0
  private var end: TimeInterval = 0

  /// Raw horizontal sensor-point travel during the freeze, mm.
  private var displacement = SIMD2<Double>.zero

  /// Starts a freeze at `time`, or extends the current one.
  mutating func trigger(at time: TimeInterval, duration: TimeInterval) {
    if isActive {
      start = min(start, time)
      end = max(end, time + duration)
    } else {
      isActive = true
      start = time
      end = time + duration
      displacement = .zero
    }
  }

  /// Whether a sample captured at `time` falls under the freeze.
  func isFrozen(at time: TimeInterval) -> Bool {
    isActive && time >= start
  }

  /// Ends the freeze once ARKit has delivered a frame captured at `time` past the window.
  ///
  /// - Returns: True if the freeze ended here.
  mutating func expire(arkitTime time: TimeInterval) -> Bool {
    guard isActive && time >= end else { return false }
    isActive = false
    return true
  }

  /// Ends the freeze when ARKit seems to have stopped delivering.
  ///
  /// - Returns: True if the freeze ended here.
  mutating func expire(imuTime time: TimeInterval) -> Bool {
    guard isActive && time >= end + Self.staleStreamAllowance else { return false }
    isActive = false
    return true
  }

  /// Adds one frozen step's raw travel (mm) and ends the freeze if the total passes `breakout`.
  ///
  /// - Returns: True if the freeze broke out here.
  mutating func accumulate(_ step: SIMD2<Double>, breakout: Double) -> Bool {
    guard isActive else { return false }
    displacement += step
    guard simd_length(displacement) > breakout else { return false }
    isActive = false
    return true
  }

  mutating func cancel() {
    isActive = false
  }
}

/// A lightly smoothed copy of the sensor point's horizontal position, for the breakout test and
/// for restarting the filter. ARKit's millimetre jitter would otherwise break a freeze from noise
/// alone on a fair share of taps, and shift the cursor by a sample's noise at every restart.
struct SmoothedPoint: Sendable {
  /// Time constant of the smoothing, seconds. Delays a drag's breakout by about this much.
  static let timeConstant: TimeInterval = 0.03

  /// The smoothed point, nil before the first update.
  private(set) var value: SIMD2<Double>?
  private var lastTime: TimeInterval = 0

  /// Adds `point` at `time` (arrival, monotonic).
  ///
  /// - Returns: How far the smoothed point moved.
  mutating func update(_ point: SIMD2<Double>, time: TimeInterval) -> SIMD2<Double> {
    guard let previous = value else {
      value = point
      lastTime = time
      return .zero
    }
    let interval = max(0, time - lastTime)
    lastTime = max(lastTime, time)
    let next = previous + (1 - exp(-interval / Self.timeConstant)) * (point - previous)
    value = next
    return next - previous
  }
}
