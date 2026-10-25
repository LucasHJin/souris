import Foundation
import simd

/// Whether motion prediction is moving the cursor, for the debug overlay and the log.
public enum PredictionStatus: String, Codable, Sendable {
  /// Turned off in settings, or the clocks disagree.
  case off

  /// Waiting for enough motion to confirm which way Core Motion's acceleration points.
  case checking

  /// Predicting.
  case on

  /// Plenty of motion and Core Motion's acceleration still didn't match ARKit's, so prediction
  /// stays off until the app restarts.
  case failed
}

/// Works out from the data which way Core Motion's `userAcceleration` points in ARKit's world,
/// by correlating it with the acceleration ARKit's positions imply.
///
/// The physics says `userAcceleration` is minus the kinematic acceleration: the accelerometer reads
/// −1 g along the screen normal when the phone lies face up at rest, which is the negative of the
/// specific force, and Core Motion subtracts gravity (pointing down) from that. Apple doesn't
/// document the sign, and a wrong one would push the cursor the wrong way, so the pipeline only
/// predicts once this check agrees. It also catches a wrong frame conversion, which shows up as
/// no correlation at all.
///
/// Each window compares ARKit's second difference over `baseline` spacing (long enough that 1 mm
/// of position noise becomes about 1 m/s², not 9 m/s² as it would frame to frame) with Core
/// Motion's acceleration averaged over the same span. Only windows where the phone is clearly
/// accelerating count.
struct AccelerationSignCheck: Sendable {
  enum Result: Equatable, Sendable {
    case pending

    /// Core Motion's acceleration in ARKit's world, times `sign`, matches ARKit's.
    case confirmed(sign: Double, correlation: Double)

    case failed(correlation: Double)
  }

  /// The spacing of the three ARKit positions in each window, seconds.
  static let baseline: TimeInterval = 0.05

  /// Horizontal Core Motion acceleration a window needs to count, m/s².
  static let minimumAcceleration = 0.5

  /// Windows needed before deciding. Neighbouring windows overlap, so 30 is about half a second
  /// of pushing.
  static let decisionWindows = 30

  /// Correlation needed to decide.
  static let decisiveCorrelation = 0.5

  /// Windows after which an undecided check gives up.
  static let giveUpWindows = 400

  private(set) var result = Result.pending
  private(set) var windows = 0
  private var sumProduct: Double = 0
  private var sumARKit: Double = 0
  private var sumMotion: Double = 0

  /// The correlation so far, 0 before any window.
  var correlation: Double {
    let scale = (sumARKit * sumMotion).squareRoot()
    return scale > 0 ? sumProduct / scale : 0
  }

  /// Adds one window: the horizontal acceleration ARKit implies and the average Core Motion
  /// acceleration (as the physics says, before any sign correction) over the same span, both in
  /// ARKit's world frame, m/s².
  mutating func add(arkit: SIMD2<Double>, motion: SIMD2<Double>) {
    guard result == .pending, simd_length(motion) >= Self.minimumAcceleration else { return }
    sumProduct += simd_dot(arkit, motion)
    sumARKit += simd_length_squared(arkit)
    sumMotion += simd_length_squared(motion)
    windows += 1
    let correlation = correlation
    if windows >= Self.decisionWindows && abs(correlation) >= Self.decisiveCorrelation {
      result = .confirmed(sign: correlation > 0 ? 1 : -1, correlation: correlation)
    } else if windows >= Self.giveUpWindows {
      result = .failed(correlation: correlation)
    }
  }
}

/// Predicts where the camera is now from ARKit's positions, which arrive about 40 ms after
/// capture, and Core Motion's accelerations, which arrive within a few milliseconds.
///
/// A Kalman filter per world axis (position and velocity, sharing one covariance because every
/// axis sees the same noise and timing) is propagated through the accelerations and corrected by
/// each ARKit position at its capture time. The prediction carries that estimate forward through
/// the accelerations received since, so translation updates with every Core Motion sample (100 Hz)
/// instead of every ARKit frame (60 Hz), and without ARKit's delay.
///
/// Positions are in metres, accelerations in m/s², both in ARKit's world frame. Times are uptime
/// seconds, and each input must not be older than the previous one of its kind.
struct TranslationPredictor: Sendable {
  /// Core Motion's nominal sample period, which turns the per-sample acceleration noise into a
  /// noise density.
  static let samplePeriod: TimeInterval = 0.01

  /// Velocity uncertainty when the filter starts, m/s.
  static let initialSpeedUncertainty = 0.3

  /// An innovation larger than this (metres) restarts the filter from the ARKit position.
  static let restartDistance = 0.03

  /// Time constant of the innovation readout, seconds.
  static let readoutTimeConstant: TimeInterval = 1

  private struct Reading: Sendable {
    var time: TimeInterval

    /// As the physics says (`−userAcceleration`), before any sign correction.
    var acceleration: SIMD3<Double>
  }

  private struct Fix: Sendable {
    var time: TimeInterval
    var position: SIMD3<Double>
  }

  private struct Estimate: Sendable {
    var time: TimeInterval
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
  }

  /// The 2 × 2 position/velocity covariance, shared by the three axes.
  private struct Covariance: Sendable {
    var positionPosition: Double
    var positionVelocity: Double
    var velocityVelocity: Double
  }

  private var readings = RingBuffer<Reading>(capacity: 128)
  private var fixes = RingBuffer<Fix>(capacity: 16)
  private var estimate: Estimate?
  private var covariance = Covariance(positionPosition: 0, positionVelocity: 0, velocityVelocity: 0)
  private(set) var signCheck = AccelerationSignCheck()

  /// RMS of the horizontal innovations (ARKit position minus the prediction for its capture time),
  /// millimetres, smoothed over about a second. With a good sign and frame this is about ARKit's
  /// own noise.
  private(set) var innovationMm: Double = 0

  /// The sign that turns a stored acceleration into the kinematic one, once confirmed.
  var sign: Double? {
    if case .confirmed(let sign, _) = signCheck.result { return sign }
    return nil
  }

  mutating func add(acceleration: SIMD3<Double>, at time: TimeInterval) {
    if let newest = readings.last, time <= newest.time { return }
    readings.append(Reading(time: time, acceleration: acceleration))
  }

  /// Corrects the estimate with an ARKit position captured at `time`.
  mutating func add(
    fix position: SIMD3<Double>,
    at time: TimeInterval,
    settings: PipelineSettings.Prediction
  ) {
    if let newest = fixes.last, time <= newest.time { return }
    fixes.append(Fix(time: time, position: position))
    checkSign(at: time)

    let measurementVariance = settings.positionNoise * settings.positionNoise
    guard let estimate, let sign else {
      restart(at: time, position: position, measurementVariance: measurementVariance)
      return
    }
    let predicted = propagate(estimate, to: time, sign: sign)
    let innovation = position - predicted.position
    guard simd_length(innovation) <= Self.restartDistance else {
      restart(at: time, position: position, measurementVariance: measurementVariance)
      return
    }
    propagateCovariance(
      over: time - estimate.time,
      noiseDensity: settings.accelerationNoise * settings.accelerationNoise * Self.samplePeriod)
    let total = covariance.positionPosition + measurementVariance
    let positionGain = covariance.positionPosition / total
    let velocityGain = covariance.positionVelocity / total
    self.estimate = Estimate(
      time: time,
      position: predicted.position + positionGain * innovation,
      velocity: predicted.velocity + velocityGain * innovation)
    covariance = Covariance(
      positionPosition: (1 - positionGain) * covariance.positionPosition,
      positionVelocity: (1 - positionGain) * covariance.positionVelocity,
      velocityVelocity: covariance.velocityVelocity
        - velocityGain * covariance.positionVelocity)

    let horizontal = SIMD2(innovation.x, innovation.z) * 1000
    let previousTime = fixes.count > 1 ? fixes[fixes.count - 2].time : time
    let elapsed: TimeInterval = max(0, time - previousTime)
    let blend: Double = 1 - exp(-elapsed / Self.readoutTimeConstant)
    let squared = innovationMm * innovationMm
    innovationMm = (squared + blend * (simd_length_squared(horizontal) - squared)).squareRoot()
  }

  /// The camera position at `time`, or nil when the sign isn't confirmed yet, there is no
  /// estimate, or `time` is outside `0...maxHorizon` after the latest fix.
  func position(at time: TimeInterval, maxHorizon: TimeInterval) -> SIMD3<Double>? {
    guard let estimate, let sign else { return nil }
    let horizon = time - estimate.time
    guard horizon >= 0, horizon <= maxHorizon else { return nil }
    return propagate(estimate, to: time, sign: sign).position
  }

  /// Forgets the estimate and the recent fixes, e.g. while tracking isn't normal. The next fix
  /// starts afresh. The accelerations and the sign check stay.
  mutating func reset() {
    estimate = nil
    fixes.removeAll()
  }

  // MARK: - Filter

  private mutating func restart(
    at time: TimeInterval,
    position: SIMD3<Double>,
    measurementVariance: Double
  ) {
    estimate = Estimate(time: time, position: position, velocity: .zero)
    covariance = Covariance(
      positionPosition: measurementVariance,
      positionVelocity: 0,
      velocityVelocity: Self.initialSpeedUncertainty * Self.initialSpeedUncertainty)
  }

  /// `P ← F P Fᵀ + Q` for a constant-velocity step of `interval` seconds driven by white
  /// acceleration noise of density `noiseDensity` (m²/s³).
  private mutating func propagateCovariance(over interval: TimeInterval, noiseDensity: Double) {
    let dt = max(0, interval)
    let old = covariance
    covariance.positionPosition = old.positionPosition + 2 * dt * old.positionVelocity
      + dt * dt * old.velocityVelocity + noiseDensity * dt * dt * dt / 3
    covariance.positionVelocity = old.positionVelocity + dt * old.velocityVelocity
      + noiseDensity * dt * dt / 2
    covariance.velocityVelocity = old.velocityVelocity + noiseDensity * dt
  }

  /// Carries `estimate` forward to `time` through the stored accelerations, taken as linear
  /// between readings and held past either end.
  private func propagate(_ estimate: Estimate, to time: TimeInterval, sign: Double) -> Estimate {
    guard time > estimate.time else { return estimate }
    var state = estimate
    var acceleration = sign * self.acceleration(at: state.time)
    var index = firstReading(after: state.time)
    while index < readings.count && readings[index].time < time {
      let reading = readings[index]
      let next = sign * reading.acceleration
      Self.advance(&state, to: reading.time, from: acceleration, to: next)
      acceleration = next
      index += 1
    }
    Self.advance(&state, to: time, from: acceleration, to: sign * self.acceleration(at: time))
    return state
  }

  /// Exact integration over one step whose acceleration changes linearly from `start` to `end`.
  private static func advance(
    _ state: inout Estimate,
    to time: TimeInterval,
    from start: SIMD3<Double>,
    to end: SIMD3<Double>
  ) {
    let dt = time - state.time
    guard dt > 0 else { return }
    let drift: SIMD3<Double> = state.velocity * dt
    let push: SIMD3<Double> = (2 * start + end) * (dt * dt / 6)
    state.position += drift + push
    state.velocity += (start + end) * (dt / 2)
    state.time = time
  }

  /// The index of the oldest reading newer than `time`, or `readings.count` if none is.
  private func firstReading(after time: TimeInterval) -> Int {
    // The times asked about are recent, so search from the newest end.
    var index = readings.count
    while index > 0 && readings[index - 1].time > time {
      index -= 1
    }
    return index
  }

  /// The stored acceleration at `time`, interpolated, or the nearest end's outside the history.
  private func acceleration(at time: TimeInterval) -> SIMD3<Double> {
    guard let first = readings.first, let last = readings.last else { return .zero }
    if time <= first.time { return first.acceleration }
    if time >= last.time { return last.acceleration }
    let index = firstReading(after: time)
    let before = readings[index - 1]
    let after = readings[index]
    let fraction = (time - before.time) / (after.time - before.time)
    return before.acceleration + (after.acceleration - before.acceleration) * fraction
  }

  // MARK: - Sign check

  /// Feeds the sign check one window ending at the fix just added, when the fixes and readings
  /// cover it.
  private mutating func checkSign(at time: TimeInterval) {
    guard signCheck.result == .pending,
      let middle = fix(near: time - AccelerationSignCheck.baseline),
      let start = fix(near: time - 2 * AccelerationSignCheck.baseline),
      let end = fixes.last,
      let oldest = readings.first, oldest.time <= start.time,
      let newest = readings.last, newest.time >= end.time
    else { return }
    let earlySpan = middle.time - start.time
    let lateSpan = end.time - middle.time
    guard earlySpan > 0, lateSpan > 0 else { return }
    // The second divided difference: the average acceleration over the window, weighted by a hat
    // that peaks at the middle fix.
    let lateVelocity: SIMD3<Double> = (end.position - middle.position) / lateSpan
    let earlyVelocity: SIMD3<Double> = (middle.position - start.position) / earlySpan
    let arkit: SIMD3<Double> = (lateVelocity - earlyVelocity) * (2 / (end.time - start.time))

    var weighted = SIMD3<Double>.zero
    var totalWeight: Double = 0
    for index in firstReading(after: start.time)..<readings.count {
      let reading = readings[index]
      guard reading.time < end.time else { break }
      let weight = reading.time <= middle.time
        ? (reading.time - start.time) / earlySpan
        : (end.time - reading.time) / lateSpan
      weighted += weight * reading.acceleration
      totalWeight += weight
    }
    guard totalWeight > 0 else { return }
    let motion = weighted / totalWeight
    signCheck.add(arkit: SIMD2(arkit.x, arkit.z), motion: SIMD2(motion.x, motion.z))
  }

  /// The fix captured closest to `time`, if one is within a third of the baseline of it.
  private func fix(near time: TimeInterval) -> Fix? {
    var best: Fix?
    for index in 0..<fixes.count {
      let candidate = fixes[index]
      if abs(candidate.time - time) < abs((best?.time ?? .infinity) - time) {
        best = candidate
      }
    }
    guard let best, abs(best.time - time) <= AccelerationSignCheck.baseline / 3 else { return nil }
    return best
  }
}
