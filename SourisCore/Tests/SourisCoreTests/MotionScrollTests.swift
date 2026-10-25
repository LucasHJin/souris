import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionScrollTests {
  static let degree = Double.pi / 180

  /// A session that tilts the front edge up to `degrees` between 0.5 and 1 s and holds it.
  static func tilted(to degrees: Double, duration: Double = 3) -> SyntheticSession {
    var session = SyntheticSession(duration: duration)
    session.path.pitch = { time in degrees * degree * Synthetic.ramp(time, 0.5, 1) }
    return session
  }

  static func expectedSpeed(_ angle: Double, _ settings: PipelineSettings.TiltScroll) -> Double {
    settings.speedFactor * pow(abs(angle) - settings.deadZone, settings.exponent)
  }

  @Test func tiltInsideTheDeadZoneDoesNothing() {
    let steps = Self.tilted(to: 8).replay(Synthetic.tiltSettings)
    #expect(steps.allSatisfy { !$0.state.flags.contains(.scrollActive) })
    #expect(steps.last?.state.scroll == .zero)
    #expect(abs((steps.last?.diagnostics.pitchDegrees ?? 0) - 8) < 1e-6)
  }

  @Test func frontEdgeUpScrollsUpAtTheSpeedLaw() {
    let settings = Synthetic.tiltSettings
    let steps = Self.tilted(to: 20).replay(settings)
    let speed = Self.expectedSpeed(20, settings.tiltScroll)
    let held = steps.step(at: 1.5)
    #expect(held.state.flags.contains(.scrollActive))
    #expect(abs(held.diagnostics.scrollSpeed - speed) < 1e-6)
    let scrolled = steps.step(at: 2).state.scroll.y - steps.step(at: 1.5).state.scroll.y
    // Integrated at 100 Hz, so within one sample of speed × 0.5 s.
    #expect(abs(scrolled - speed * 0.5) < speed * 0.011, "scrolled \(scrolled)")
    #expect(scrolled > 0)
  }

  @Test func frontEdgeDownScrollsDown() {
    let steps = Self.tilted(to: -20).replay(Synthetic.tiltSettings)
    #expect((steps.last?.state.scroll.y ?? 0) < -100)
  }

  @Test func reversedFlipsTheDirection() {
    var settings = Synthetic.tiltSettings
    settings.tiltScroll.isReversed = true
    let steps = Self.tilted(to: 20).replay(settings)
    #expect((steps.last?.state.scroll.y ?? 0) < -100)
    #expect((steps.last?.diagnostics.scrollSpeed ?? 0) < 0)
  }

  @Test func speedIsCapped() {
    let settings = Synthetic.tiltSettings
    let steps = Self.tilted(to: 75).replay(settings)
    #expect(abs((steps.last?.diagnostics.scrollSpeed ?? 0) - settings.tiltScroll.maxSpeed) < 1e-9)
  }

  @Test func tiltScrollIsOffByDefault() {
    #expect(!PipelineSettings().tiltScroll.isEnabled)
    let steps = Self.tilted(to: 30).replay()
    #expect(steps.last?.state.scroll == .zero)
    #expect(steps.allSatisfy { !$0.state.flags.contains(.scrollActive) })
  }

  @Test func disabledScrollDoesNothing() {
    var settings = Synthetic.tiltSettings
    settings.tiltScroll.isEnabled = false
    let steps = Self.tilted(to: 30).replay(settings)
    #expect(steps.last?.state.scroll == .zero)
  }

  @Test func hysteresisHoldsTheScrollUntilWellInsideTheDeadZone() {
    var session = SyntheticSession(duration: 4)
    // 11° (on), then 9° (still on, no speed), then 7.5° (off).
    session.path.pitch = { time in
      let angle = 11 - 2 * Synthetic.ramp(time, 1.5, 1.7) - 1.5 * Synthetic.ramp(time, 2.5, 2.7)
      return angle * Self.degree * Synthetic.ramp(time, 0.5, 1)
    }
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(steps.step(at: 1.3).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 2.2).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 2.2).diagnostics.scrollSpeed == 0)
    #expect(!steps.step(at: 3).state.flags.contains(.scrollActive))
  }

  @Test func aContactSuppressesTiltBriefly() {
    var session = Self.tilted(to: 20)
    session.touch(.contact(time: 2))
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(steps.step(at: 1.9).state.flags.contains(.scrollActive))
    #expect(!steps.step(at: 2.1).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 2.3).state.flags.contains(.scrollActive))
  }

  @Test func holdingAButtonTurnsScrollOff() {
    var session = Self.tilted(to: 20, duration: 4)
    session.touch(.button(.left, isDown: true, time: 2))
    session.touch(.button(.left, isDown: false, time: 3))
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(!steps.step(at: 2.01).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 2.1).state.scroll == steps.step(at: 2.9).state.scroll)
    #expect(!steps.step(at: 3.1).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 3.3).state.flags.contains(.scrollActive))
  }

  @Test(arguments: [true, false])
  func theCursorHoldsStillWhileScrolling(gyroAssist: Bool) {
    var session = Self.tilted(to: 20, duration: 4)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.02 * Synthetic.ramp(time, 1.5, 2.5), 0, 0)
    }
    var settings = Synthetic.tiltSettings
    settings.pointer.gyroAssist = gyroAssist
    let steps = session.replay(settings)
    #expect(steps.step(at: 1.2).state.flags.contains(.scrollActive))
    #expect(steps.cursor(at: 1.2) == steps.cursor(at: 3.9))
  }

  @Test func theLevelIsTheAngleAtEngage() {
    // Resting at 15° when tracking starts: that is level, so nothing scrolls until it tilts more.
    var session = SyntheticSession(duration: 3)
    session.path.pitch = { time in (15 + 15 * Synthetic.ramp(time, 1.5, 2)) * Self.degree }
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(!steps.step(at: 1.4).state.flags.contains(.scrollActive))
    #expect(abs(steps.step(at: 1.4).diagnostics.pitchDegrees) < 1e-6)
    #expect(steps.step(at: 2.5).state.flags.contains(.scrollActive))
    let engagement = steps.engagements.first
    #expect(abs((engagement?.pitch ?? 0) - 15) < 1e-6)
    #expect(engagement?.isLevelCaptured == true)
    #expect(steps.levelRejections.isEmpty)
  }

  // MARK: - Level capture limit

  @Test func aTiltPastTheCaptureLimitIsNotTakenAsLevel() {
    // Tracking starts with the phone tipped 35° toward the face; it is then laid flat.
    var session = SyntheticSession(duration: 4)
    session.path.pitch = { time in (35 - 35 * Synthetic.ramp(time, 2, 2.5)) * Self.degree }
    let steps = session.replay(Synthetic.tiltSettings)
    // The level stays flat, so the 35° reads as a 35° tilt and scrolls...
    #expect(abs(steps.step(at: 1).diagnostics.pitchDegrees - 35) < 1e-6)
    #expect(steps.step(at: 1).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 1).state.scroll.y > 100)
    // ...and laying it flat ends the scroll instead of trapping it.
    #expect(abs(steps.step(at: 3.5).diagnostics.pitchDegrees) < 1e-6)
    #expect(!steps.step(at: 3.5).state.flags.contains(.scrollActive))
    let engagement = steps.engagements.first
    #expect(abs((engagement?.pitch ?? 0) - 35) < 1e-6)
    #expect(engagement?.isLevelCaptured == false)
    #expect(steps.levelRejections.count == 1)
    #expect(abs((steps.levelRejections.first ?? 0) - 35) < 1e-6)
  }

  @Test(arguments: [(19.5, true), (20.5, false), (-19.5, true), (-20.5, false)])
  func theLimitAppliesToThePitchEitherWay(pitch: Double, isCaptured: Bool) {
    var session = SyntheticSession(duration: 1)
    session.path.pitch = { _ in pitch * Self.degree }
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(isCaptured == (abs(steps.step(at: 0.5).diagnostics.pitchDegrees) < 1e-6))
    #expect(steps.levelRejections.isEmpty == isCaptured)
  }

  @Test func theCaptureLimitIsASetting() {
    var settings = Synthetic.tiltSettings
    settings.tiltScroll.levelCaptureLimit = 45
    var session = SyntheticSession(duration: 1)
    session.path.pitch = { _ in 35 * Self.degree }
    let steps = session.replay(settings)
    #expect(abs(steps.step(at: 0.5).diagnostics.pitchDegrees) < 1e-6)
    #expect(steps.levelRejections.isEmpty)
  }

  @Test func aRejectedCaptureKeepsThePreviousLevel() {
    // Level 15° from the first engage. Laid at 40° while paused, the re-engage rejects it, so the
    // level stays 15° and the tilt reads 25°, not 40° and not 0°.
    var session = SyntheticSession(duration: 4)
    session.path.pitch = { time in (15 + 25 * Synthetic.ramp(time, 1.2, 1.4)) * Self.degree }
    session.pause(true, at: 1)
    session.pause(false, at: 2)
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(abs(steps.step(at: 0.9).diagnostics.pitchDegrees) < 1e-6)
    #expect(abs(steps.step(at: 3).diagnostics.pitchDegrees - 25) < 1e-6)
    #expect(steps.step(at: 3).state.flags.contains(.scrollActive))
    #expect(steps.levelRejections.count == 1)
  }

  @Test(arguments: [(30.0, false), (10.0, true)])
  func theLevelIsCapturedOnTheFirstMotionSampleWhenARKitComesFirst(
    pitch: Double,
    isCaptured: Bool
  ) {
    var session = SyntheticSession(duration: 1)
    session.path.pitch = { _ in pitch * Self.degree }
    // No Core Motion sample until 0.2 s, so the engage at the first ARKit frame has no pitch.
    let events = session.events().filter {
      if case .imu(let sample) = $0 { return sample.arrival > 0.2 }
      return true
    }
    let steps = RecordingReplay.run(events, settings: Synthetic.tiltSettings)
    #expect(steps.engagements.first?.pitch == nil)
    #expect(steps.engagements.first?.isLevelCaptured == false)
    #expect((abs(steps.step(at: 0.9).diagnostics.pitchDegrees) < 1e-6) == isCaptured)
    let rejected = steps.events.filter {
      if case .levelRejected = $0.kind { return true }
      return false
    }
    #expect(rejected.isEmpty == isCaptured)
    if let time = rejected.first?.time {
      #expect(time > 0.2 && time < 0.3, "rejected at \(time)")
    }
  }
}
