import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionGyroAssistTests {
  /// A tumble about all three axes, so a wrong composition order can't pass by commuting.
  static func tumble() -> PhonePath {
    var path = PhonePath()
    path.yaw = { time in 0.8 * sin(2.1 * time) }
    path.pitch = { time in 0.4 * sin(3.3 * time + 0.5) }
    path.roll = { time in 0.3 * sin(2.7 * time + 1) }
    return path
  }

  @Test func assistedOrientationMatchesTheTrueCurrentOrientation() {
    var session = SyntheticSession(duration: 2, path: Self.tumble())
    session.arDelay = 0.06
    var pipeline = MotionPipeline()
    var latestIMUTime: Double?
    var latestARTime: Double?
    var worstAssisted: Double = 0
    var worstUnassisted: Double = 0
    for event in session.events() {
      pipeline.feed(event)
      switch event {
      case .imu(let sample): latestIMUTime = sample.timestamp
      case .ar(let sample): latestARTime = sample.timestamp
      default: break
      }
      guard let latestIMUTime, let latestARTime, latestIMUTime > 0.5 else { continue }
      let truth = session.path.cameraOrientation(at: latestIMUTime)
      worstAssisted = max(worstAssisted, Synthetic.angle(pipeline.currentOrientation, truth))
      let unassisted = session.path.cameraOrientation(at: latestARTime)
      worstUnassisted = max(worstUnassisted, Synthetic.angle(unassisted, truth))
    }
    #expect(!pipeline.diagnostics.clockMismatch)
    // Slerp between 100 Hz samples is the only error left.
    #expect(worstAssisted < 0.1 * .pi / 180, "worst \(worstAssisted * 180 / .pi)°")
    #expect(worstUnassisted > 20 * worstAssisted)
  }

  @Test func assistedOutputLeadsUnassistedDuringASwivel() {
    var session = SyntheticSession(duration: 2.5)
    session.arDelay = 0.05
    session.path.yaw = { time in -0.6 * Synthetic.ramp(time, 0.5, 1.0) }
    var assisted = Synthetic.flatGainSettings
    assisted.pointer.gyroAssist = true
    var unassisted = assisted
    unassisted.pointer.gyroAssist = false
    let leading = session.replay(assisted)
    let lagging = session.replay(unassisted)
    for time in stride(from: 0.65, through: 0.95, by: 0.05) {
      let lead = leading.cursor(at: time).x - lagging.cursor(at: time).x
      #expect(lead > 1, "lead \(lead) pt at \(time) s")
    }
    #expect(abs(leading.finalCursor.x - lagging.finalCursor.x) < 0.2)
  }

  @Test(arguments: [2.0, -2.0])
  func clockMismatchFallsBackToUnassisted(offset: Double) {
    var session = SyntheticSession(duration: 2.5)
    session.imuClockOffset = offset
    session.path.yaw = { time in -0.4 * Synthetic.ramp(time, 0.8, 1.3) }
    var assisted = Synthetic.flatGainSettings
    assisted.pointer.gyroAssist = true
    var unassisted = assisted
    unassisted.pointer.gyroAssist = false
    let mismatched = session.replay(assisted)
    let plain = session.replay(unassisted)
    #expect(mismatched.last?.diagnostics.clockMismatch == true)
    for time in stride(from: 0.8, through: 2.5, by: 0.1) {
      let difference = simd_length(mismatched.cursor(at: time) - plain.cursor(at: time))
      #expect(difference < 1e-9, "difference \(difference) at \(time) s")
    }
  }

  @Test func matchingClocksReportNoMismatch() {
    var session = SyntheticSession(duration: 1.5, path: Self.tumble())
    session.arDelay = 0.08
    let steps = session.replay()
    #expect(steps.allSatisfy { !$0.diagnostics.clockMismatch })
  }

  @Test func gyroKeepsTheSwivelGoingThroughABriefDropout() {
    var session = SyntheticSession(duration: 2.5)
    session.path.tracking = { time in time >= 0.6 && time < 0.75 ? .excessiveMotion : .normal }
    session.path.yaw = { time in -0.2 * Synthetic.ramp(time, 0.5, 0.9) }
    var assisted = Synthetic.flatGainSettings
    assisted.pointer.gyroAssist = true
    var unassisted = assisted
    unassisted.pointer.gyroAssist = false
    let expected = 2.5 * 30 * sin(0.2)
    let withGyro = session.replay(assisted).finalCursor.x
    let without = session.replay(unassisted).finalCursor.x
    #expect(abs(withGyro - expected) < 0.5, "with gyro \(withGyro)")
    // Without the gyro the swivel made during the dropout is lost.
    #expect(without < expected - 3, "without gyro \(without)")
  }
}
