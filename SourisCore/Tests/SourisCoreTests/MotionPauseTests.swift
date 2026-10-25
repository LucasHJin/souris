import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionPauseTests {
  @Test func pauseReleasesButtonsStopsOutputAndUnpauseReengages() {
    var session = SyntheticSession(duration: 5.5)
    let turned = Double.pi / 2
    session.path.position = { time in
      // 2 cm right while paused, then 2 cm toward the new top edge after unpausing.
      Synthetic.rest + SIMD3(0.02 * Synthetic.ramp(time, 2, 2.5), 0, 0)
        + Synthetic.forward(yaw: turned) * 0.02 * Synthetic.ramp(time, 4, 4.5)
    }
    session.path.yaw = { time in turned * Synthetic.ramp(time, 2.6, 3) }
    session.path.pitch = { time in 15 * .pi / 180 * Synthetic.ramp(time, 2, 2.2) }
    session.touch(.button(.left, isDown: true, time: 1))
    session.pause(true, at: 1.5)
    session.touch(.button(.right, isDown: true, time: 1.7))
    session.pause(false, at: 3.5)
    let steps = session.replay(Synthetic.tiltSettings)

    #expect(steps.step(at: 1.4).state.buttons == [.left])
    let paused = steps.step(at: 1.6).state
    #expect(paused.buttons.isEmpty)
    #expect(paused.flags.contains(.paused))
    // Presses while paused are ignored, and nothing moves or scrolls.
    #expect(steps.step(at: 3.4).state.buttons.isEmpty)
    #expect(steps.cursor(at: 1.6) == steps.cursor(at: 3.4))
    #expect(steps.step(at: 1.6).state.scroll == steps.step(at: 3.4).state.scroll)
    #expect(!steps.step(at: 3.4).state.flags.contains(.scrollActive))

    #expect(!steps.step(at: 3.7).state.flags.contains(.paused))
    // The tilt held at unpause is the new level, so it doesn't scroll.
    #expect(!steps.step(at: 3.7).state.flags.contains(.scrollActive))
    // The heading was re-captured: pushing toward the turned top edge is cursor up.
    let moved = steps.finalCursor - steps.cursor(at: 3.9)
    #expect(abs(moved.y + 50) < 0.5, "moved \(moved)")
    #expect(abs(moved.x) < 0.5, "moved \(moved)")
  }

  @Test func recenterRecapturesTheHeading() {
    var session = SyntheticSession(duration: 4)
    let turned = -Double.pi / 3
    // Swivel 60° (which moves the cursor), recenter, then push toward the new top edge.
    session.path.yaw = { time in turned * Synthetic.ramp(time, 0.5, 1) }
    session.path.position = { time in
      Synthetic.rest + Synthetic.forward(yaw: turned) * 0.02 * Synthetic.ramp(time, 2.5, 3)
    }
    session.inserts.append((2, .recenter))
    let steps = session.replay()
    let moved = steps.finalCursor - steps.cursor(at: 2.4)
    #expect(abs(moved.y + 50) < 0.5, "moved \(moved)")
    #expect(abs(moved.x) < 0.5, "moved \(moved)")
  }
}
