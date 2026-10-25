import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionFrameTests {
  static let headings: [Double] = [0, .pi / 2, -3 * .pi / 4]

  @Test func cameraFromDeviceMatchesARKitAxes() {
    let c = Frames.cameraFromDevice
    #expect(simd_length(c.act(SIMD3(1, 0, 0)) - SIMD3(0, 1, 0)) < 1e-12)
    #expect(simd_length(c.act(SIMD3(0, 1, 0)) - SIMD3(-1, 0, 0)) < 1e-12)
    #expect(simd_length(c.act(SIMD3(0, 0, 1)) - SIMD3(0, 0, 1)) < 1e-12)
    #expect(simd_length(c.act(SIMD3(0, 1, 0)) - Frames.topEdgeInCamera) < 1e-12)
    #expect(Synthetic.angle(c, Synthetic.cameraFromDevice) < 1e-9)
  }

  @Test func flatPhoneTopEdgePointsAlongItsHeading() {
    let orientation = PhonePath().cameraOrientation(at: 0)
    let topEdge = orientation.act(Frames.topEdgeInCamera)
    #expect(simd_length(topEdge - SIMD3(0, 0, -1)) < 1e-12)
  }

  @Test func nearVerticalPhoneHasNoHeading() {
    var path = PhonePath()
    path.pitch = { _ in 80 * .pi / 180 }
    #expect(Frames.heading(of: path.cameraOrientation(at: 0)) == nil)
  }

  @Test(arguments: [0, Double.pi / 2])
  func engageCapturesForwardAndRight(yaw: Double) {
    var session = SyntheticSession(duration: 0.5)
    session.path.yaw = { _ in yaw }
    var pipeline = MotionPipeline(settings: Synthetic.flatGainSettings)
    for event in session.events() {
      pipeline.feed(event)
    }
    #expect(pipeline.isEngaged)
    #expect(simd_length(pipeline.forward - Synthetic.forward(yaw: yaw)) < 1e-9)
    #expect(simd_length(pipeline.right - Synthetic.right(yaw: yaw)) < 1e-9)
    if yaw == 0 {
      #expect(simd_length(pipeline.forward - SIMD3(0, 0, -1)) < 1e-9)
      #expect(simd_length(pipeline.right - SIMD3(1, 0, 0)) < 1e-9)
    }
  }

  @Test(arguments: headings)
  func slidingTowardTheTopEdgeMovesTheCursorUp(yaw: Double) {
    var session = SyntheticSession(duration: 2.5)
    let start = SIMD3<Double>(0.1, 0.3, -0.2)
    session.path.yaw = { _ in yaw }
    session.path.position = { time in
      start + Synthetic.forward(yaw: yaw) * 0.02 * Synthetic.ramp(time, 0.5, 1.0)
    }
    let cursor = session.replay().finalCursor
    // 20 mm at 2.5 pt/mm, up the screen.
    #expect(abs(cursor.y + 50) < 0.3, "cursor \(cursor)")
    #expect(abs(cursor.x) < 0.3, "cursor \(cursor)")
  }

  @Test(arguments: headings)
  func slidingRightMovesTheCursorRight(yaw: Double) {
    var session = SyntheticSession(duration: 2.5)
    let start = SIMD3<Double>(0.1, 0.3, -0.2)
    session.path.yaw = { _ in yaw }
    session.path.position = { time in
      start + Synthetic.right(yaw: yaw) * 0.02 * Synthetic.ramp(time, 0.5, 1.0)
    }
    let cursor = session.replay().finalCursor
    #expect(abs(cursor.x - 50) < 0.3, "cursor \(cursor)")
    #expect(abs(cursor.y) < 0.3, "cursor \(cursor)")
  }

  @Test func heightChangesDontMoveTheCursor() {
    var session = SyntheticSession(duration: 2.5)
    session.path.position = { time in SIMD3(0, 0.3 + 0.02 * Synthetic.ramp(time, 0.5, 1.5), 0) }
    let cursor = session.replay().finalCursor
    #expect(simd_length(cursor) < 1e-6, "cursor \(cursor)")
  }

  @Test(arguments: [true, false])
  func swivelMovesTheCursorAlongTheLeverArc(gyroAssist: Bool) {
    let turn = 0.2
    var session = SyntheticSession(duration: 2.5)
    session.path.yaw = { time in -turn * Synthetic.ramp(time, 0.5, 1.0) }
    var settings = Synthetic.flatGainSettings
    settings.pointer.gyroAssist = gyroAssist
    let cursor = session.replay(settings).finalCursor
    let reachInMm = settings.pointer.sensorReach * 1000
    let gain = settings.pointer.slowGain
    // The sensor point swings on a circle of radius `reach` about the camera.
    #expect(abs(cursor.x - gain * reachInMm * sin(turn)) < 0.2, "cursor \(cursor)")
    #expect(abs(cursor.y - gain * reachInMm * (1 - cos(turn))) < 0.2, "cursor \(cursor)")
    #expect(cursor.x > 14)
  }
}
