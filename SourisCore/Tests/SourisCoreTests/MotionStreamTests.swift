import Foundation
import Testing
import simd

@testable import SourisCore

// Synthetic sensor streams for the motion tests, built from first principles so they check the
// pipeline's frame conventions rather than repeat them.

/// A scripted phone motion. Every closure takes seconds since the start of the session.
struct PhonePath {
  /// Camera position in ARKit's world frame (+y up), metres.
  var position: (Double) -> SIMD3<Double> = { _ in SIMD3(0, 0.3, 0) }

  /// Heading, radians about world +y. 0 points the top edge along −z; positive turns it toward
  /// −x (counterclockwise seen from above), so a negative change swivels the top edge right.
  var yaw: (Double) -> Double = { _ in 0 }

  /// Radians, front (top) edge up positive.
  var pitch: (Double) -> Double = { _ in 0 }

  /// Radians about the phone's long axis.
  var roll: (Double) -> Double = { _ in 0 }

  var tracking: (Double) -> TrackingStatus = { _ in .normal }

  /// The device's orientation, device frame → ARKit world: lying flat and screen up with the
  /// given heading, then pitched and rolled in its own frame.
  func deviceOrientation(at time: Double) -> simd_quatd {
    let heading = simd_quatd(angle: yaw(time), axis: SIMD3(0, 1, 0))
    let flat = simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
    let pitched = simd_quatd(angle: pitch(time), axis: SIMD3(1, 0, 0))
    let rolled = simd_quatd(angle: roll(time), axis: SIMD3(0, 1, 0))
    return heading * flat * pitched * rolled
  }

  /// The camera orientation ARKit reports, camera frame → world.
  func cameraOrientation(at time: Double) -> simd_quatd {
    deviceOrientation(at: time) * Synthetic.cameraFromDevice.inverse
  }
}

enum Synthetic {
  /// `v_cam = C · v_dev`, written out as a matrix independently of `Frames`: camera x is device
  /// −y, camera y is device +x, camera z is device z.
  static let cameraFromDevice = simd_quatd(
    simd_double3x3(rows: [
      SIMD3(0, -1, 0),
      SIMD3(1, 0, 0),
      SIMD3(0, 0, 1),
    ]))

  /// Core Motion's reference frame from ARKit's world: world up becomes reference +z.
  static let referenceFromWorld = simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0))

  /// Where the camera rests unless a test moves it: 30 cm above the world origin.
  static let rest = SIMD3<Double>(0, 0.3, 0)

  /// A smooth 0 → 1 ease between `start` and `end`.
  static func ramp(_ time: Double, _ start: Double, _ end: Double) -> Double {
    guard time > start else { return 0 }
    guard time < end else { return 1 }
    return 0.5 - 0.5 * cos(.pi * (time - start) / (end - start))
  }

  /// The heading direction (top edge, horizontal) for a yaw.
  static func forward(yaw: Double) -> SIMD3<Double> {
    SIMD3(-sin(yaw), 0, -cos(yaw))
  }

  static func right(yaw: Double) -> SIMD3<Double> {
    SIMD3(cos(yaw), 0, -sin(yaw))
  }

  /// The angle between two orientations, radians.
  static func angle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
    2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
  }

  /// Settings with a constant gain of 2.5 pt/mm, so expected cursor motion is exact.
  /// Constant gain, and volume buttons that scroll, as the button-scroll tests expect.
  static var flatGainSettings: PipelineSettings {
    var settings = PipelineSettings()
    settings.pointer.accelerationRatio = 1
    settings.volumeButtons.up = .scroll
    settings.volumeButtons.down = .scroll
    return settings
  }

  /// `flatGainSettings` with tilt-to-scroll turned on (it is off by default).
  static var tiltSettings: PipelineSettings {
    var settings = flatGainSettings
    settings.tiltScroll.isEnabled = true
    return settings
  }

  /// The camera position while the phone pitches by `pitch` radians (front edge up positive)
  /// about a pivot that stays still `distance` metres behind the camera's rest position along the
  /// long axis. A distance of 0 pitches about the camera itself.
  static func position(pitching pitch: Double, about distance: Double) -> SIMD3<Double> {
    let pivot = rest + SIMD3(0, 0, distance)
    return pivot + distance * SIMD3(0, sin(pitch), -cos(pitch))
  }
}

/// A session of ARKit frames and Core Motion samples following a `PhonePath`, merged in arrival
/// order, plus any extra events (touches, pauses) at given arrival times.
struct SyntheticSession {
  var duration: Double
  var path = PhonePath()
  var arRate: Double = 60
  var imuRate: Double = 100
  var arDelay: Double = 0.045
  var imuDelay: Double = 0.004

  /// Added to IMU timestamps only, to fake two clocks that disagree.
  var imuClockOffset: Double = 0

  /// Core Motion's arbitrary reference yaw; the pipeline must not depend on it.
  var referenceYaw: Double = 0.6

  /// Extra events and their arrival times.
  var inserts: [(arrival: Double, event: RecordedEvent)] = []

  /// Gaussian noise on ARKit positions, metres, each axis independently.
  var positionNoise: Double = 0

  /// Gaussian noise on ARKit orientations, degrees about each axis.
  var attitudeNoiseDegrees: Double = 0

  /// Seeds the noise, so every run of a test sees the same noise.
  var seed: UInt64 = 1

  /// Fill in `userAcceleration` from the path. Off, it stays zero, so the prediction's sign
  /// check never sees motion and prediction stays out of the way of tests about other things.
  var providesAcceleration = false

  /// Multiplies the `userAcceleration` the physics gives, to fake hardware with the other sign.
  var accelerationSign: Double = 1

  mutating func touch(_ event: TouchEvent) {
    inserts.append((event.time + 0.002, .touch(event)))
  }

  mutating func scrollPress(_ direction: ScrollButtonPress.Direction, at time: Double) {
    let press = ScrollButtonPress(direction: direction, time: time)
    inserts.append((time + 0.002, .scrollPress(press)))
  }

  mutating func pause(_ isPaused: Bool, at time: Double) {
    inserts.append((time, .paused(isPaused)))
  }

  func arSample(at time: Double) -> ARSample {
    ARSample(
      timestamp: time,
      arrival: time + arDelay,
      position: path.position(time),
      orientation: path.cameraOrientation(at: time).vector,
      tracking: path.tracking(time))
  }

  func imuSample(at time: Double) -> IMUSample {
    let device = path.deviceOrientation(at: time)
    let reference = simd_quatd(angle: referenceYaw, axis: SIMD3(0, 0, 1))
    let attitude = reference * Synthetic.referenceFromWorld * device
    let gravity = device.inverse.act(SIMD3(0, -1, 0))
    let step = 1e-4
    let turn = device.inverse * path.deviceOrientation(at: time + step)
    let rate = turn.angle < 1e-12 ? SIMD3<Double>.zero : turn.axis * (turn.angle / step)
    return IMUSample(
      timestamp: time + imuClockOffset,
      arrival: time + imuDelay,
      attitude: attitude.vector,
      rotationRate: rate,
      gravity: gravity,
      userAcceleration: providesAcceleration ? userAcceleration(at: time) : .zero)
  }

  /// The accelerometer reads minus the specific force (−1 g along the screen normal flat and at
  /// rest), and Core Motion takes gravity (pointing down) off that, which leaves minus the
  /// camera's kinematic acceleration, in g, device frame.
  func userAcceleration(at time: Double) -> SIMD3<Double> {
    let step = 1e-3
    let before = path.position(time - step)
    let here = path.position(time)
    let after = path.position(time + step)
    let acceleration = (after - 2 * here + before) / (step * step)
    let device = path.deviceOrientation(at: time)
    return -accelerationSign * device.inverse.act(acceleration) / 9.80665
  }

  func events() -> [RecordedEvent] {
    var timed: [(arrival: Double, order: Int, event: RecordedEvent)] = []
    var random = SeededRandom(seed: seed)
    let frames = Int(duration * arRate)
    for index in 0...frames {
      var sample = arSample(at: Double(index) / arRate)
      if positionNoise > 0 {
        sample.position += random.gaussianVector() * positionNoise
      }
      if attitudeNoiseDegrees > 0 {
        let turn = random.gaussianVector() * (attitudeNoiseDegrees * .pi / 180)
        let wobble = simd_quatd(angle: simd_length(turn), axis: simd_normalize(turn))
        sample.orientation = (sample.quaternion * wobble).vector
      }
      timed.append((sample.arrival, timed.count, .ar(sample)))
    }
    let samples = Int(duration * imuRate)
    for index in 0...samples {
      let time = Double(index) / imuRate
      timed.append((time + imuDelay, timed.count, .imu(imuSample(at: time))))
    }
    for insert in inserts {
      timed.append((insert.arrival, timed.count, insert.event))
    }
    timed.sort { ($0.arrival, $0.order) < ($1.arrival, $1.order) }
    return timed.map(\.event)
  }

  func replay(_ settings: PipelineSettings = Synthetic.flatGainSettings) -> [RecordingReplay.Step] {
    RecordingReplay.run(events(), settings: settings)
  }
}

/// SplitMix64 with Box–Muller Gaussians: deterministic noise for tests.
struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in (0, 1].
  mutating func uniform() -> Double {
    (Double(next() >> 11) + 1) / 9_007_199_254_740_992
  }

  /// Standard normal.
  mutating func gaussian() -> Double {
    (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
  }

  mutating func gaussianVector() -> SIMD3<Double> {
    SIMD3(gaussian(), gaussian(), gaussian())
  }
}

extension MotionPipeline {
  mutating func feed(_ event: RecordedEvent) {
    switch event {
    case .settings(let settings): self.settings = settings
    case .ar(let sample): process(sample)
    case .imu(let sample): process(sample)
    case .touch(let touch): handle(touch)
    case .scrollPress(let press): handle(press)
    case .wheel(let wheel): handle(wheel)
    case .paused(let isPaused): setPaused(isPaused)
    case .recenter: recenter()
    }
  }
}

extension [RecordingReplay.Step] {
  /// Every event the steps carry, in order.
  var events: [PipelineEvent] {
    flatMap(\.events)
  }

  /// The `engaged` events as (pitch, level captured) pairs.
  var engagements: [(pitch: Double?, isLevelCaptured: Bool)] {
    events.compactMap {
      if case .engaged(let pitch, let isCaptured) = $0.kind { return (pitch, isCaptured) }
      return nil
    }
  }

  /// The pitches of the `levelRejected` events.
  var levelRejections: [Double] {
    events.compactMap {
      if case .levelRejected(let pitch) = $0.kind { return pitch }
      return nil
    }
  }

  /// The last step at or before `time`.
  func step(at time: Double) -> RecordingReplay.Step {
    last { $0.time <= time } ?? self[0]
  }

  func cursor(at time: Double) -> SIMD2<Double> {
    step(at: time).state.cursor
  }

  var finalCursor: SIMD2<Double> {
    last?.state.cursor ?? .zero
  }
}

@Suite struct MotionStreamTests {
  @Test func syntheticGravityMatchesAttitudeAndPitchConvention() {
    var session = SyntheticSession(duration: 1)
    session.path.pitch = { _ in 20 * .pi / 180 }
    let sample = session.imuSample(at: 0.5)
    // Gravity in the reference frame is straight down whatever the reference yaw.
    let gravityInReference = sample.quaternion.act(sample.gravity)
    #expect(simd_length(gravityInReference - SIMD3(0, 0, -1)) < 1e-12)
    #expect(abs(ScrollTilt.pitch(gravity: sample.gravity) - 20) < 1e-9)
  }

  @Test func flatPhoneReadsGravityDownTheScreenNormal() {
    let sample = SyntheticSession(duration: 1).imuSample(at: 0)
    #expect(simd_length(sample.gravity - SIMD3(0, 0, -1)) < 1e-12)
  }

  @Test func syntheticRotationRateIsBodyFrame() {
    var session = SyntheticSession(duration: 1)
    session.path.yaw = { time in -0.5 * time }
    let sample = session.imuSample(at: 0.5)
    // Flat and screen up, a clockwise swivel seen from above turns about device −z.
    #expect(simd_length(sample.rotationRate - SIMD3(0, 0, -0.5)) < 1e-6)
  }
}
