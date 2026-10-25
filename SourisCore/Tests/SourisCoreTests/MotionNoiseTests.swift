import Foundation
import Testing
import simd

@testable import SourisCore

/// The pipeline against realistic ARKit noise: 1 mm Gaussian position noise on each axis and
/// 0.2° of orientation noise, from fixed seeds.
@Suite struct MotionNoiseTests {
  static let seeds: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8]

  /// A front-edge-up tilt about a pivot `pivot` metres behind the camera.
  struct Tilt: Sendable {
    var pivot: Double
    var degrees: Double
  }

  static let tilts = [
    Tilt(pivot: 0, degrees: 8),
    Tilt(pivot: 0, degrees: -8),
    Tilt(pivot: 0.15, degrees: 8),
    Tilt(pivot: 0.15, degrees: -6),
  ]

  static func noisy(duration: Double, seed: UInt64) -> SyntheticSession {
    var session = SyntheticSession(duration: duration)
    session.positionNoise = 0.001
    session.attitudeNoiseDegrees = 0.2
    session.seed = seed
    return session
  }

  /// The arrival time at which the freeze that began at `touch` let go.
  static func freezeEnd(_ steps: [RecordingReplay.Step], after touch: Double) -> Double {
    steps.first { $0.time > touch + 0.01 && !$0.diagnostics.isFrozen }?.time ?? .infinity
  }

  /// The arrival time of the first unlifted step after `time`.
  static func reengageTime(_ steps: [RecordingReplay.Step], after time: Double) -> Double {
    steps.first { $0.time > time && !$0.state.flags.contains(.lifted) }?.time ?? .infinity
  }

  @Test(arguments: seeds)
  func aStillPhoneStaysQuiet(seed: UInt64) {
    var session = Self.noisy(duration: 5, seed: seed)
    session.touch(.contact(time: 2.5))
    session.touch(.button(.left, isDown: true, time: 2.55))
    let settings = PipelineSettings()
    let steps = session.replay(settings)

    #expect(steps.allSatisfy { !$0.state.flags.contains(.lifted) })
    #expect(steps.allSatisfy { !$0.state.flags.contains(.scrollActive) })
    // The cursor wobbles with the jitter but doesn't wander: the mean of the last second stays
    // near the mean of the first. The tap's filter restart re-bases on a smoothed point that
    // still carries about 0.5 mm of jitter, so allow about 2 mm (1 mm is 2.5 pt at slow gain).
    // The 0.2° orientation noise swings the 10 cm sensor reach by another 0.35 mm, so every bound
    // here leaves about 10% more than the 1 mm position noise alone would need.
    func meanCursor(_ from: Double, _ to: Double) -> SIMD2<Double> {
      let window = steps.filter { $0.time >= from && $0.time < to }.map(\.state.cursor)
      return window.reduce(.zero, +) / Double(window.count)
    }
    let drift = simd_length(meanCursor(4, 5) - meanCursor(0.5, 1.5))
    #expect(drift < 6, "drift \(drift) pt")
    let resting = steps.filter { $0.time > 0.5 }
    let center = meanCursor(0.5, 5)
    let spread = (resting.map { simd_length_squared($0.state.cursor - center) }.reduce(0, +)
      / Double(resting.count)).squareRoot()
    #expect(spread < 3.5, "spread \(spread) pt")
    // ARKit delivers the 80 ms window by about 2.5 + 0.08 + 0.045 s; noise alone mustn't end the
    // freeze sooner.
    #expect(Self.freezeEnd(steps, after: 2.5) > 2.6)

    // At rest the gain's speed stays under slowSpeed, so the gain stays slow. The 3 Hz cutoffs let
    // more of this 1 mm noise through than the phone's real sub-millimetre wobble would.
    let speeds = resting.map(\.diagnostics.speedMmPerSecond)
    let meanSpeed = speeds.reduce(0, +) / Double(speeds.count)
    let slow = settings.pointer.slowGain * settings.pointer.speedScale
    let meanGain = resting.map(\.diagnostics.gain).reduce(0, +) / Double(resting.count)
    #expect(meanSpeed < settings.pointer.slowSpeed * 0.85, "mean speed \(meanSpeed) mm/s")
    #expect(meanGain < slow * 1.02, "mean gain \(meanGain)")
    #expect(abs((steps.last?.diagnostics.jitterMm ?? 0) - 1.41) < 0.5)
  }

  @Test(arguments: seeds)
  func aNoisyLiftReengagesSoonAfterSettingDown(seed: UInt64) {
    var session = Self.noisy(duration: 4, seed: seed)
    session.path.position = { time in
      let up = 0.05 * Synthetic.ramp(time, 1, 1.15) - 0.03 * Synthetic.ramp(time, 2, 2.2)
      return Synthetic.rest + SIMD3(0, up, 0)
    }
    let steps = session.replay()
    #expect(steps.step(at: 1.5).state.flags.contains(.lifted))
    #expect(steps.step(at: 1.95).state.flags.contains(.lifted))
    // Stopped at 2.2 s (capture); ARKit delivers 45 ms later.
    let reengaged = Self.reengageTime(steps, after: 1.5)
    #expect(reengaged < 2.2 + 0.045 + 0.3, "re-engaged at \(reengaged)")
    #expect(reengaged > 2.1, "re-engaged at \(reengaged)")
    #expect(steps.filter { $0.time > reengaged }.allSatisfy {
      !$0.state.flags.contains(.lifted)
    })
  }

  /// A front-edge-up tilt of `degrees` over 0.2 s from 1 s, held, and back from 2.5 s, about a
  /// pivot `pivotDistance` behind the camera.
  static func tilting(
    to degrees: Double,
    aboutPivot pivotDistance: Double,
    seed: UInt64
  ) -> SyntheticSession {
    var session = noisy(duration: 4, seed: seed)
    let pitch = { (time: Double) in
      degrees * .pi / 180 * (Synthetic.ramp(time, 1, 1.2) - Synthetic.ramp(time, 2.5, 2.7))
    }
    session.path.pitch = pitch
    session.path.position = { Synthetic.position(pitching: pitch($0), about: pivotDistance) }
    return session
  }

  @Test(arguments: seeds)
  func aWristTiltScrollsWithoutLifting(seed: UInt64) {
    // The wrist sits 15 cm behind the camera along the phone's long axis and stays put, so the
    // camera rises more than 6 cm.
    let session = Self.tilting(to: 25, aboutPivot: 0.15, seed: seed)
    let cameraRise = session.path.position(2).y - Synthetic.rest.y
    #expect(cameraRise > 0.06)
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(steps.allSatisfy { !$0.state.flags.contains(.lifted) })
    #expect(steps.step(at: 1.5).state.flags.contains(.scrollActive))
    #expect((steps.last?.state.scroll.y ?? 0) > 100)
    #expect(!(steps.last?.state.flags.contains(.scrollActive) ?? true))
  }

  // Without tilt scroll nothing holds the clutch engaged, so the lift height alone has to stay
  // quiet. Tilting about the camera drops the back point 13 cm × sin 8° = 1.8 cm; the same tilt
  // about the wrist drops the front point 18 cm × sin 6° = 1.9 cm.
  @Test(arguments: seeds, tilts)
  func aTiltAboutTheCameraOrWristNeverLifts(seed: UInt64, tilt: Tilt) {
    let session = Self.tilting(to: tilt.degrees, aboutPivot: tilt.pivot, seed: seed)
    let steps = session.replay()
    #expect(steps.allSatisfy { !$0.state.flags.contains(.lifted) })
  }

  @Test(arguments: seeds, [0.0, 10.0, -10.0])
  func aRealLiftStillLiftsWhileTilted(seed: UInt64, degrees: Double) {
    var session = Self.noisy(duration: 2, seed: seed)
    session.path.pitch = { _ in degrees * .pi / 180 }
    session.path.position = { time in
      Synthetic.rest + SIMD3(0, 0.04 * Synthetic.ramp(time, 1, 1.15), 0)
    }
    let steps = session.replay()
    #expect(!steps.step(at: 0.95).state.flags.contains(.lifted))
    #expect(steps.step(at: 1.3).state.flags.contains(.lifted))
  }

  @Test(arguments: seeds)
  func aRealLiftStillLifts(seed: UInt64) {
    var session = Self.noisy(duration: 2, seed: seed)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0, 0.04 * Synthetic.ramp(time, 1, 1.15), 0)
    }
    let steps = session.replay()
    #expect(!steps.step(at: 0.95).state.flags.contains(.lifted))
    #expect(steps.step(at: 1.3).state.flags.contains(.lifted))
  }
}
