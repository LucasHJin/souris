import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionLiftTests {
  /// Slide 1 cm right; lift 4 cm quickly while sliding another 1 cm; slide 5 cm right in the air;
  /// set down 3 cm lower and hold; slide 1 cm right again.
  static func liftAndReposition() -> SyntheticSession {
    var session = SyntheticSession(duration: 6)
    session.path.position = { time in
      let right = 0.01 * Synthetic.ramp(time, 0.5, 1)
        + 0.01 * Synthetic.ramp(time, 1.5, 1.65)
        + 0.05 * Synthetic.ramp(time, 2, 2.5)
        + 0.01 * Synthetic.ramp(time, 4.5, 5)
      let up = 0.04 * Synthetic.ramp(time, 1.5, 1.65) - 0.03 * Synthetic.ramp(time, 3, 3.2)
      return Synthetic.rest + SIMD3(right, up, 0)
    }
    return session
  }

  @Test func aQuickRiseLiftsAndRollsTheCursorBack() {
    let steps = Self.liftAndReposition().replay()
    let beforeRise = steps.cursor(at: 1.5)
    #expect(abs(beforeRise.x - 25) < 0.5, "before rise \(beforeRise)")
    let lifted = steps.step(at: 1.8)
    #expect(lifted.state.flags.contains(.lifted))
    // The motion made during the rise is taken back.
    #expect(simd_length(lifted.state.cursor - beforeRise) < 0.3, "lifted at \(lifted.state.cursor)")
    // Nothing moves while lifted.
    #expect(steps.cursor(at: 1.8) == steps.cursor(at: 2.9))
  }

  @Test func settingDownReengagesAtTheNewHeight() {
    let steps = Self.liftAndReposition().replay()
    let down = steps.step(at: 4)
    #expect(!down.state.flags.contains(.lifted))
    // The desk is now where it was set down, 1 cm above where it started.
    #expect(abs(down.diagnostics.heightAboveDeskCm) < 0.05)
    #expect(simd_length(steps.cursor(at: 4) - steps.cursor(at: 1.8)) < 1e-6)
    let moved = steps.finalCursor - steps.cursor(at: 4)
    #expect(abs(moved.x - 25) < 0.5, "moved \(moved)")
    #expect(steps.filter { $0.state.flags.contains(.lifted) }.isEmpty == false)
  }

  @Test func aSlowDriftNeverLifts() {
    var session = SyntheticSession(duration: 6)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0, 0.04 * min(max((time - 0.5) / 5, 0), 1), 0)
    }
    let steps = session.replay()
    #expect(steps.allSatisfy { !$0.state.flags.contains(.lifted) })
  }

  @Test func disabledLiftNeverLifts() {
    var settings = Synthetic.flatGainSettings
    settings.lift.isEnabled = false
    let steps = Self.liftAndReposition().replay(settings)
    #expect(steps.allSatisfy { !$0.state.flags.contains(.lifted) })
    // Every slide then moves the cursor, the air move included.
    #expect(abs(steps.finalCursor.x - 2.5 * 80) < 1, "cursor \(steps.finalCursor)")
  }

  @Test func aLiftDuringAFastStrokeTakesBackAtMostMaxRollback() {
    // Slide 10 cm right during the 0.15 s rise: 250 pt at slow gain, far past the 100 pt cap.
    var session = SyntheticSession(duration: 3)
    session.path.position = { time in
      let right = 0.1 * Synthetic.ramp(time, 1, 1.15)
      let up = 0.04 * Synthetic.ramp(time, 1, 1.15)
      return Synthetic.rest + SIMD3(right, up, 0)
    }
    let steps = session.replay()
    #expect(steps.step(at: 1.4).state.flags.contains(.lifted))
    let rolledBack = steps.events.compactMap { event -> Double? in
      if case .lifted(_, let rolledBack) = event.kind { return rolledBack }
      return nil
    }
    #expect(rolledBack.count == 1)
    let limit = PipelineSettings.Lift().maxRollback
    #expect(abs((rolledBack.first ?? 0) - limit) < 1e-6, "rolled back \(rolledBack)")
    // The cursor stays well right of where the rise began.
    #expect(steps.cursor(at: 1.4).x - steps.cursor(at: 0.9).x > 20)
  }

  @Test func withoutRollbackTheRiseMotionStays() {
    var settings = Synthetic.flatGainSettings
    settings.lift.rollsBackCursor = false
    let steps = Self.liftAndReposition().replay(settings)
    #expect(steps.cursor(at: 1.8).x > steps.cursor(at: 1.5).x + 2)
  }

  @Test func aRiseDuringATiltScrollDoesNotLift() {
    // A tilt scroll holds the clutch engaged.
    var session = Self.liftAndReposition()
    session.path.pitch = { time in 20 * .pi / 180 * Synthetic.ramp(time, 1.2, 1.4) }
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(steps.step(at: 1.45).state.flags.contains(.scrollActive))
    #expect(steps.allSatisfy { !$0.state.flags.contains(.lifted) })
    #expect(steps.step(at: 1.8).state.flags.contains(.scrollActive))
  }

  @Test func aRiseDuringAButtonScrollStillLifts() {
    var session = Self.liftAndReposition()
    session.scrollPress(.up, at: 1.4)
    let steps = session.replay()
    #expect(steps.step(at: 1.5).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 1.8).state.flags.contains(.lifted))
  }

  // MARK: - Lift height

  /// A front-edge-up tilt of `degrees` about a pivot `pivotDistance` behind the camera, over
  /// 0.25 s from 1 s, held until 3 s, then back the same way. The pivot stays put.
  static func tilting(to degrees: Double, aboutPivot pivotDistance: Double) -> SyntheticSession {
    var session = SyntheticSession(duration: 5)
    let pitch = { (time: Double) in
      degrees * .pi / 180 * (Synthetic.ramp(time, 1, 1.25) - Synthetic.ramp(time, 3, 3.25))
    }
    session.path.pitch = pitch
    session.path.position = { Synthetic.position(pitching: pitch($0), about: pivotDistance) }
    return session
  }

  // A lift needs the points 3 cm ahead of and 13 cm behind the camera to each rise past 3 cm. A
  // tilt, and the quick return from it, moves them in opposite directions, so even 20° tilts
  // about the camera or a wrist 15 cm behind it never lift.
  @Test(arguments: [(0.0, 20.0), (0.0, -20.0), (0.15, 20.0), (0.15, -20.0)])
  func tiltingAboutTheCameraOrTheWristDoesNotLift(pivotDistance: Double, degrees: Double) {
    let steps = Self.tilting(to: degrees, aboutPivot: pivotDistance).replay()
    #expect(steps.allSatisfy { !$0.state.flags.contains(.lifted) })
    #expect(steps.events.allSatisfy {
      if case .lifted = $0.kind { return false } else { return true }
    })
  }

  @Test func aForwardDipAboutTheCameraNeverReadsAsARise() {
    // The camera and sensor point barely move, but a point 15 cm behind the camera would rise
    // 15 cm × sin 10° = 2.6 cm. The lift height only dips (by 3 cm × sin 10° = 0.5 cm).
    let session = Self.tilting(to: -10, aboutPivot: 0)
    var pipeline = MotionPipeline(settings: Synthetic.flatGainSettings)
    var highest = -Double.infinity
    for event in session.events() {
      pipeline.feed(event)
      if case .ar = event {
        highest = max(highest, pipeline.diagnostics.heightAboveDeskCm)
      }
    }
    #expect(highest < 0.6, "highest \(highest) cm")
  }

  @Test(arguments: [0.0, 15.0, -15.0])
  func aRealRiseLiftsWhateverThePitch(degrees: Double) {
    var session = SyntheticSession(duration: 3)
    session.path.pitch = { _ in degrees * .pi / 180 }
    session.path.position = { time in
      Synthetic.rest + SIMD3(0, 0.035 * Synthetic.ramp(time, 1, 1.15), 0)
    }
    let steps = session.replay()
    #expect(!steps.step(at: 0.95).state.flags.contains(.lifted))
    #expect(steps.step(at: 1.4).state.flags.contains(.lifted))
  }

  @Test func aRiseUnderTheThresholdDoesNotLift() {
    var session = SyntheticSession(duration: 3)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0, 0.025 * Synthetic.ramp(time, 1, 1.15), 0)
    }
    #expect(session.replay().allSatisfy { !$0.state.flags.contains(.lifted) })
  }

  @Test func reengagingWorksWhileTheTopEdgeIsTilted() {
    var session = Self.liftAndReposition()
    session.path.pitch = { _ in 12 * .pi / 180 }
    let steps = session.replay()
    #expect(steps.step(at: 1.8).state.flags.contains(.lifted))
    let down = steps.step(at: 4)
    #expect(!down.state.flags.contains(.lifted))
    #expect(abs(down.diagnostics.heightAboveDeskCm) < 0.05)
    let moved = steps.finalCursor - steps.cursor(at: 4)
    #expect(abs(moved.x - 25) < 1, "moved \(moved)")
  }

  @Test func liftAndSetDownEventsCarryTheRiseAndTheDrop() {
    let steps = Self.liftAndReposition().replay()
    let lifts = steps.events.compactMap { event -> (rise: Double, rolledBack: Double)? in
      if case .lifted(let rise, let rolledBack) = event.kind { return (rise, rolledBack) }
      return nil
    }
    #expect(lifts.count == 1)
    // Detected just past the 3 cm threshold, with the cursor set back over the rise's slide.
    #expect((3...4).contains(lifts.first?.rise ?? 0), "rise \(lifts.first?.rise ?? 0)")
    #expect((lifts.first?.rolledBack ?? 0) > 0.5)

    let drops = steps.events.compactMap { event -> Double? in
      if case .setDown(let drop) = event.kind { return drop }
      return nil
    }
    #expect(drops.count == 1)
    #expect((2...4).contains(drops.first ?? 0), "drop \(drops.first ?? 0)")

    // The set-down is followed by a fresh engage.
    let kinds = steps.events.map(\.kind)
    let setDown = kinds.firstIndex { if case .setDown = $0 { true } else { false } }
    let engaged = kinds.lastIndex { if case .engaged = $0 { true } else { false } }
    #expect((setDown ?? .max) < (engaged ?? -1))
  }
}
