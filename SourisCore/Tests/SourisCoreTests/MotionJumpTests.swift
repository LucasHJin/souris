import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionJumpTests {
  @Test(arguments: [true, false])
  func aTeleportIsRejected(gyroAssist: Bool) {
    var session = SyntheticSession(duration: 2)
    session.path.position = { time in
      time >= 1 ? Synthetic.rest + SIMD3(0.1, 0, 0.05) : Synthetic.rest
    }
    var settings = Synthetic.flatGainSettings
    settings.pointer.gyroAssist = gyroAssist
    let steps = session.replay(settings)
    #expect(steps.last?.diagnostics.rejectedJumps == 1)
    #expect(simd_length(steps.finalCursor) < 1e-6, "cursor \(steps.finalCursor)")
  }

  @Test func aOneFrameSpikeIsRejectedBothWays() {
    var session = SyntheticSession(duration: 2)
    session.path.position = { time in
      abs(time - 1) < 0.001 ? Synthetic.rest + SIMD3(0.1, 0, 0) : Synthetic.rest
    }
    let steps = session.replay()
    #expect(steps.last?.diagnostics.rejectedJumps == 2)
    #expect(simd_length(steps.finalCursor) < 1e-6)
  }

  @Test func slidingAfterAJumpStillWorks() {
    var session = SyntheticSession(duration: 3)
    session.path.position = { time in
      let jump = time >= 1 ? SIMD3<Double>(0.1, 0, 0) : .zero
      return Synthetic.rest + jump + SIMD3(0.02 * Synthetic.ramp(time, 1.5, 2), 0, 0)
    }
    let cursor = session.replay().finalCursor
    #expect(abs(cursor.x - 50) < 0.3, "cursor \(cursor)")
  }

  @Test(arguments: [true, false])
  func limitedTrackingFreezesTranslationWithoutAJumpAfter(gyroAssist: Bool) {
    var session = SyntheticSession(duration: 4)
    session.path.tracking = { time in
      time >= 1 && time < 1.6 ? .insufficientFeatures : .normal
    }
    session.path.position = { time in
      let lost = 0.03 * Synthetic.ramp(time, 1.1, 1.5)
      let after = 0.02 * Synthetic.ramp(time, 2.5, 3)
      return Synthetic.rest + SIMD3(lost + after, 0, 0)
    }
    var settings = Synthetic.flatGainSettings
    settings.pointer.gyroAssist = gyroAssist
    let steps = session.replay(settings)

    #expect(steps.step(at: 1.3).state.flags.contains(.trackingLimited))
    #expect(!steps.step(at: 2).state.flags.contains(.trackingLimited))
    // The 3 cm made while tracking was lost never shows up, then or after recovery.
    let beforeLoss = steps.cursor(at: 1)
    let afterRecovery = steps.cursor(at: 2.4)
    #expect(simd_length(afterRecovery - beforeLoss) < 0.01, "moved \(afterRecovery - beforeLoss)")
    // Only the 2 cm made after recovery moves the cursor.
    #expect(abs(steps.finalCursor.x - 50) < 0.3, "cursor \(steps.finalCursor)")
  }

  @Test func recoveryFramesAreDropped() {
    var session = SyntheticSession(duration: 2.5)
    session.path.tracking = { time in time >= 1 && time < 1.5 ? .relocalizing : .normal }
    // 1 cm made entirely within the first three frames after tracking returns.
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.01 * min(max((time - 1.49) / 0.04, 0), 1), 0, 0)
    }
    let cursor = session.replay().finalCursor
    #expect(abs(cursor.x) < 0.05, "cursor \(cursor)")
  }

  @Test func trackingIsLimitedWhenARKitGoesQuiet() {
    var session = SyntheticSession(duration: 1)
    let events = session.events().filter { event in
      if case .ar(let sample) = event { return sample.timestamp < 0.5 }
      return true
    }
    session.duration = 1
    let steps = RecordingReplay.run(events, settings: Synthetic.flatGainSettings)
    #expect(!steps.step(at: 0.6).state.flags.contains(.trackingLimited))
    #expect(steps.step(at: 0.95).state.flags.contains(.trackingLimited))
  }
}
