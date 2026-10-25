import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionTiltPointingTests {
  /// The phone tilts to `degrees`, front edge up positive, about the camera between 1 and 1.3 s.
  static func tilting(to degrees: Double) -> SyntheticSession {
    var session = SyntheticSession(duration: 2)
    session.path.pitch = { time in degrees * .pi / 180 * Synthetic.ramp(time, 1, 1.3) }
    return session
  }

  /// Forward travel the sensor point and the tilt point make between level and `degrees`, mm:
  /// the tilt point's rise, and the sensor point swinging back as its reach tips up.
  static func forwardTravel(degrees: Double, settings: PipelineSettings) -> Double {
    let angle = degrees * .pi / 180
    let rise = settings.pointer.tiltPointing ? settings.pointer.tiltReach * sin(angle) : 0
    let swing = settings.pointer.sensorReach * (cos(angle) - 1)
    return (rise + swing) * 1000
  }

  @Test(arguments: [5.0, -5.0, 12.0])
  func tiltingTheFrontEdgeMovesTheCursorVertically(degrees: Double) {
    let settings = Synthetic.flatGainSettings
    let steps = Self.tilting(to: degrees).replay(settings)
    // Forward is cursor up, and screen y grows downward.
    let expected = -2.5 * Self.forwardTravel(degrees: degrees, settings: settings)
    #expect(abs(steps.finalCursor.y - expected) < 0.5, "\(steps.finalCursor.y) vs \(expected)")
    #expect(abs(steps.finalCursor.x) < 0.1)
    if degrees > 0 {
      #expect(steps.finalCursor.y < -15, "front edge up moves the cursor up")
    }
  }

  @Test func theReachScalesTheTilt() {
    var settings = Synthetic.flatGainSettings
    settings.pointer.tiltReach = 0.05
    let steps = Self.tilting(to: 8).replay(settings)
    let expected = -2.5 * Self.forwardTravel(degrees: 8, settings: settings)
    #expect(abs(steps.finalCursor.y - expected) < 0.5, "\(steps.finalCursor.y) vs \(expected)")
  }

  @Test func turnedOffTiltOnlySwingsTheSensorPoint() {
    var settings = Synthetic.flatGainSettings
    settings.pointer.tiltPointing = false
    let steps = Self.tilting(to: 8).replay(settings)
    let expected = -2.5 * Self.forwardTravel(degrees: 8, settings: settings)
    #expect(abs(steps.finalCursor.y - expected) < 0.5)
    #expect(abs(steps.finalCursor.y) < 3)
  }

  @Test func tiltScrollTakesTheTiltInstead() {
    var settings = Synthetic.tiltSettings
    settings.pointer.tiltPointing = true
    let steps = Self.tilting(to: 5).replay(settings)
    // Under the dead zone tilt-to-scroll does nothing, and tilt pointing stands aside for it.
    let expected = -2.5 * 100 * (cos(5 * .pi / 180) - 1)
    #expect(abs(steps.finalCursor.y - expected) < 0.5, "\(steps.finalCursor.y)")
  }

  @Test func settingsSavedBeforeTiltPointingKeepTheirPointerValues() throws {
    let json = #"{ "pointer": { "slowGain": 3.25, "sensorReach": 0.05, "gyroAssist": false } }"#
    let settings = try JSONDecoder().decode(PipelineSettings.self, from: Data(json.utf8))
    #expect(settings.pointer.slowGain == 3.25)
    #expect(settings.pointer.sensorReach == 0.05)
    #expect(!settings.pointer.gyroAssist)
    #expect(settings.pointer.tiltPointing)
    #expect(settings.pointer.tiltReach == 0.1)
  }
}
