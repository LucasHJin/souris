import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionClickFreezeTests {
  static func settings(gyroAssist: Bool) -> PipelineSettings {
    var settings = Synthetic.flatGainSettings
    settings.pointer.gyroAssist = gyroAssist
    return settings
  }

  @Test(arguments: [true, false])
  func aJoltInsideTheWindowIsDroppedAndNeverLeaksOut(gyroAssist: Bool) {
    var session = SyntheticSession(duration: 3)
    // A 2 mm shift (under the 3 mm breakout) right after the touch, which then stays.
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.0015, 0, -0.0013) * Synthetic.ramp(time, 1.005, 1.05)
    }
    session.touch(.contact(time: 1))
    let steps = session.replay(Self.settings(gyroAssist: gyroAssist))
    #expect(steps.step(at: 1.03).diagnostics.isFrozen)
    // The filter restarts from a lightly smoothed point (against jitter), which still lags the
    // shift a little when the freeze ends: under a quarter of the 2 mm (5 pt) comes through.
    #expect(simd_length(steps.finalCursor) < 1.25, "cursor \(steps.finalCursor)")
    let afterFreeze = steps.cursor(at: 1.8)
    #expect(simd_length(steps.finalCursor - afterFreeze) < 0.01, "no drift after the freeze")
    #expect(!(steps.last?.diagnostics.isFrozen ?? true))
  }

  @Test func motionCapturedBeforeTheTouchStillApplies() {
    var session = SyntheticSession(duration: 3)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.002 * Synthetic.ramp(time, 0.9, 0.98), 0, 0)
    }
    let untouched = session.replay(Self.settings(gyroAssist: false))
    session.touch(.contact(time: 1))
    let touched = session.replay(Self.settings(gyroAssist: false))
    // By 1.03 s every frame captured before the touch has arrived, after the touch event.
    let late = touched.cursor(at: 1.03).x
    #expect(late == untouched.cursor(at: 1.03).x)
    #expect(late > 2, "cursor x \(late)")
  }

  /// A quick 10 mm drag starting with the touch, with and without the breakout.
  static func quickDrag(breakout: Double, gyroAssist: Bool) -> [RecordingReplay.Step] {
    var session = SyntheticSession(duration: 3)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.01 * Synthetic.ramp(time, 1.0, 1.1), 0, 0)
    }
    session.touch(.contact(time: 1))
    session.touch(.button(.left, isDown: true, time: 1.05))
    var settings = Self.settings(gyroAssist: gyroAssist)
    settings.click.freezeBreakout = breakout
    return session.replay(settings)
  }

  /// The arrival time at which the freeze from the 1 s touch let go.
  static func freezeEnd(_ steps: [RecordingReplay.Step]) -> Double {
    steps.first { $0.time > 1.01 && !$0.diagnostics.isFrozen }?.time ?? .infinity
  }

  @Test(arguments: [true, false])
  func movingPastTheBreakoutStartsADragPromptly(gyroAssist: Bool) {
    let brokenOut = Self.quickDrag(breakout: 3, gyroAssist: gyroAssist)
    let held = Self.quickDrag(breakout: 1000, gyroAssist: gyroAssist)
    #expect(brokenOut.last?.state.buttons == [.left])
    // The breakout lets go well before ARKit has delivered the whole 80 ms window.
    #expect(Self.freezeEnd(brokenOut) < Self.freezeEnd(held) - 0.01)
    // The travel up to the breakout is held back, and the rest of the drag comes through.
    let draggedMm = brokenOut.finalCursor.x / 2.5
    let heldMm = held.finalCursor.x / 2.5
    #expect(draggedMm > heldMm + 1.5, "dragged \(draggedMm) mm, held \(heldMm) mm")
    #expect(heldMm < 2, "held \(heldMm) mm")
    #expect(draggedMm < 7, "dragged \(draggedMm) mm")
  }

  @Test func pressAndReleaseEachFreeze() {
    var session = SyntheticSession(duration: 3)
    session.touch(.contact(time: 1))
    session.touch(.button(.left, isDown: true, time: 1.05))
    session.touch(.contact(time: 1.5))
    session.touch(.button(.left, isDown: false, time: 1.5))
    let steps = session.replay()
    #expect(steps.step(at: 1.1).diagnostics.isFrozen)
    #expect(steps.step(at: 1.1).state.buttons == [.left])
    #expect(!steps.step(at: 1.4).diagnostics.isFrozen)
    #expect(steps.step(at: 1.55).diagnostics.isFrozen)
    #expect(steps.step(at: 1.55).state.buttons.isEmpty)
    #expect(!steps.step(at: 2).diagnostics.isFrozen)
  }
}
