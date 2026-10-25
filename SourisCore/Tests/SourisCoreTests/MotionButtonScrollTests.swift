import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionButtonScrollTests {
  /// An otherwise still session with a press at each of `times`.
  static func session(
    _ direction: ScrollButtonPress.Direction = .up,
    at times: [Double],
    duration: Double = 4
  ) -> SyntheticSession {
    var session = SyntheticSession(duration: duration)
    for time in times {
      session.scrollPress(direction, at: time)
    }
    return session
  }

  /// The `scrollPress` events' queued pixels, in order.
  static func queued(_ steps: [RecordingReplay.Step]) -> [Double] {
    steps.events.compactMap {
      if case .scrollPress(_, let pixels) = $0.kind { return pixels }
      return nil
    }
  }

  // MARK: - Distance and shape

  @Test func onePressScrollsExactlyOneStep() {
    let steps = Self.session(at: [1]).replay()
    let scroll = steps.map(\.state.scroll.y)
    #expect(abs((scroll.last ?? 0) - 100) < 1e-9)
    #expect(scroll.allSatisfy { $0 >= 0 && $0 <= 100 + 1e-9 })
    #expect(zip(scroll, scroll.dropFirst()).allSatisfy { $1 >= $0 })
    #expect(steps.last?.state.scroll.x == 0)
    #expect(steps.last?.diagnostics.scrollPresses == 1)
  }

  @Test func downScrollsTowardTheBottomAndReversedFlipsBoth() {
    let down = Self.session(.down, at: [1]).replay().last?.state.scroll.y ?? 0
    #expect(abs(down + 100) < 1e-9)

    var settings = Synthetic.flatGainSettings
    settings.buttonScroll.isReversed = true
    let up = Self.session(.up, at: [1]).replay(settings).last?.state.scroll.y ?? 0
    #expect(abs(up + 100) < 1e-9)
    let reversedDown = Self.session(.down, at: [1]).replay(settings).last?.state.scroll.y ?? 0
    #expect(abs(reversedDown - 100) < 1e-9)
  }

  @Test func theStepIsASetting() {
    var settings = Synthetic.flatGainSettings
    settings.buttonScroll.step = 240
    let scroll = Self.session(at: [1]).replay(settings).last?.state.scroll.y ?? 0
    #expect(abs(scroll - 240) < 1e-9)
  }

  @Test func theGlideIsAnExponentialFromThePress() {
    let settings = Synthetic.flatGainSettings
    let tau = settings.buttonScroll.glideTime
    let steps = Self.session(at: [1]).replay(settings)
    // 100 px × e^(−t/τ) is still above the 0.5 px finish threshold until t = τ ln 200 = 0.42 s.
    let gliding = steps.filter { $0.time > 1.01 && $0.time < 1.4 }
    #expect(gliding.count > 20)
    for step in gliding {
      let expected = 100 * (1 - exp(-(step.time - 1) / tau))
      #expect(abs(step.state.scroll.y - expected) < 1e-6, "at \(step.time)")
    }
    // Halfway through its first time constant it is 63% done; it never waits for a sample grid.
    #expect(abs(steps.step(at: 1 + tau).state.scroll.y - 63.2) < 3)
  }

  @Test func theGlideTimeConstantIsASetting() {
    var settings = Synthetic.flatGainSettings
    settings.buttonScroll.glideTime = 0.2
    let steps = Self.session(at: [1]).replay(settings)
    let expected = 100 * (1 - exp(-0.2 / 0.2))
    #expect(abs(steps.step(at: 1.2).state.scroll.y - expected) < 2)
    #expect(abs((steps.last?.state.scroll.y ?? 0) - 100) < 1e-9)
  }

  @Test func theGlideAdvancesOnEverySampleUsingArrivalTime() {
    // Only ARKit frames (60 Hz) and then only IMU samples (100 Hz): the total is the same.
    let events = Self.session(at: [1]).events()
    let arOnly = events.filter { if case .imu = $0 { false } else { true } }
    let imuOnly = events.filter { if case .ar = $0 { false } else { true } }
    for stream in [arOnly, imuOnly] {
      let scroll = RecordingReplay.run(stream, settings: Synthetic.flatGainSettings).last
      #expect(abs((scroll?.state.scroll.y ?? 0) - 100) < 1e-9)
    }
  }

  // MARK: - Holding, reversing, accumulating

  @Test func aHeldButtonRampsTheStepUpToTheMultiplier() {
    // iOS repeats a held volume button; the step ramps from 1× to 3× over 1 s.
    let times = (0...13).map { 1 + 0.1 * Double($0) }
    let steps = Self.session(at: times, duration: 5).replay()
    let queued = Self.queued(steps)
    #expect(queued.count == times.count)
    for (index, pixels) in queued.enumerated() {
      let expected = 100 * (1 + 2 * min(1, 0.1 * Double(index)))
      #expect(abs(pixels - expected) < 1e-9, "press \(index): \(pixels)")
    }
    let total = queued.reduce(0, +)
    #expect(abs((steps.last?.state.scroll.y ?? 0) - total) < 1e-9)
  }

  @Test func aGapPastTheHoldIntervalStartsANewHold() {
    let steps = Self.session(at: [1, 1.1, 1.2, 1.6]).replay()
    let queued = Self.queued(steps)
    #expect(queued.count == 4)
    #expect(abs(queued[0] - 100) < 1e-9)
    #expect(abs(queued[1] - 120) < 1e-9)
    #expect(abs(queued[2] - 140) < 1e-9)
    // 0.4 s after the previous press: a fresh hold, back to 1×.
    #expect(abs(queued[3] - 100) < 1e-9)
  }

  @Test func theHoldRampIsSettable() {
    var settings = Synthetic.flatGainSettings
    settings.buttonScroll.maxHoldMultiplier = 5
    settings.buttonScroll.holdRampTime = 0.5
    settings.buttonScroll.holdInterval = 0.2
    let steps = Self.session(at: [1, 1.15, 1.3, 1.45, 1.6, 1.75]).replay(settings)
    let queued = Self.queued(steps)
    // Presses 0.15 s apart ramp 4/0.5 × 0.15 = 1.2× per press, capped at 5× from 0.5 s.
    let expected: [Double] = [100, 220, 340, 460, 500, 500]
    for (pixels, wanted) in zip(queued, expected) {
      #expect(abs(pixels - wanted) < 1e-9, "got \(pixels), wanted \(wanted)")
    }
  }

  @Test func slowPressesAccumulateOneStepEach() {
    let steps = Self.session(at: [1, 1.8, 2.6], duration: 5).replay()
    #expect(Self.queued(steps) == [100, 100, 100])
    #expect(abs((steps.last?.state.scroll.y ?? 0) - 300) < 1e-9)
  }

  @Test func aPressAgainstTheGlideReplacesWhatIsPending() {
    var session = Self.session(.up, at: [1])
    session.scrollPress(.down, at: 1.1)
    let steps = session.replay()
    let reversal = steps.firstIndex { step in
      step.events.contains { if case .scrollPress(.down, _) = $0.kind { true } else { false } }
    }
    // About 70% of the first step has gone out by 1.1 s, and the rest is dropped.
    let emitted = steps[(reversal ?? 1)].state.scroll.y
    let lastSample = steps[(reversal ?? 1) - 1].time
    #expect(abs(emitted - 100 * (1 - exp(-(lastSample - 1) / 0.08))) < 1e-6)
    #expect(emitted > 60 && emitted < 75)
    #expect(Self.queued(steps) == [100, -100])
    #expect(abs((steps.last?.state.scroll.y ?? 0) - (emitted - 100)) < 1e-9)
  }

  @Test func aReversalRestartsTheHold() {
    var session = Self.session(.up, at: [1, 1.1, 1.2])
    session.scrollPress(.down, at: 1.25)
    session.scrollPress(.down, at: 1.35)
    let queued = Self.queued(session.replay())
    #expect(abs(queued[2] - 140) < 1e-9)
    // The first press the other way is a new hold at 1×; the next ramps from it.
    #expect(abs(queued[3] + 100) < 1e-9)
    #expect(abs(queued[4] + 120) < 1e-9)
  }

  @Test func aReversalFlipsTheSignOfThePendingDistance() {
    var session = Self.session(.down, at: [1])
    session.scrollPress(.up, at: 1.02)
    let steps = session.replay()
    let emitted = steps.step(at: 1.02).state.scroll.y
    #expect(emitted < 0)
    #expect(abs((steps.last?.state.scroll.y ?? 0) - (emitted + 100)) < 1e-9)
  }

  // MARK: - When it is ignored

  @Test func pressesWhilePausedAreIgnored() {
    var session = Self.session(at: [1.0])
    session.pause(true, at: 0.5)
    session.pause(false, at: 1.5)
    session.scrollPress(.up, at: 2.5)
    let steps = session.replay()
    #expect(steps.step(at: 1.4).state.scroll == .zero)
    #expect(!steps.step(at: 1.0).state.flags.contains(.scrollActive))
    #expect(!steps.step(at: 1.2).diagnostics.isFrozen)
    // Only the press after unpausing counts.
    #expect(Self.queued(steps) == [100])
    #expect(steps.last?.diagnostics.scrollPresses == 1)
    #expect(abs((steps.last?.state.scroll.y ?? 0) - 100) < 1e-9)
  }

  @Test func pressesWithTheVolumeButtonsOffAreIgnored() {
    var settings = Synthetic.flatGainSettings
    settings.volumeButtons.isEnabled = false
    let steps = Self.session(at: [1, 1.1]).replay(settings)
    #expect(steps.last?.state.scroll == .zero)
    #expect(steps.allSatisfy { !$0.state.flags.contains(.scrollActive) })
    #expect(steps.allSatisfy { !$0.diagnostics.isFrozen })
    #expect(steps.events.allSatisfy {
      if case .scrollPress = $0.kind { false } else { true }
    })
    #expect(steps.last?.diagnostics.scrollPresses == 0)
  }

  @Test func pausingDropsWhatIsStillPending() {
    var session = Self.session(at: [1])
    session.pause(true, at: 1.05)
    let steps = session.replay()
    let atPause = steps.step(at: 1.06).state.scroll.y
    #expect(atPause > 0 && atPause < 50)
    #expect(steps.last?.state.scroll.y == atPause)
    #expect(!steps.step(at: 1.06).state.flags.contains(.scrollActive))
    #expect(steps.last?.diagnostics.scrollSpeed == 0)
    let ended = steps.events.compactMap { event -> Double? in
      if case .scrollEnded(.buttons, let pixels) = event.kind { return pixels }
      return nil
    }
    #expect(ended.count == 1)
    #expect(abs((ended.first ?? 0) - atPause) < 1e-9)
  }

  // MARK: - Flags, speed and events

  @Test func scrollActiveRunsFromThePressUntilTheGlideEnds() {
    let steps = Self.session(at: [1]).replay()
    #expect(!steps.step(at: 0.9).state.flags.contains(.scrollActive))
    // Set by the press itself, before any glide has moved.
    let press = steps.first { !$0.events.isEmpty && $0.state.flags.contains(.scrollActive) }
    #expect(press?.time == 1)
    #expect(press?.state.scroll == .zero)
    #expect(steps.step(at: 1.2).state.flags.contains(.scrollActive))
    #expect(steps.step(at: 1.4).state.flags.contains(.scrollActive))
    #expect(!steps.step(at: 1.5).state.flags.contains(.scrollActive))
    #expect(!(steps.last?.state.flags.contains(.scrollActive) ?? true))
  }

  @Test func aHoldKeepsScrollActiveAcrossPresses() {
    let steps = Self.session(at: [1, 1.1, 1.2, 1.3]).replay()
    let active = steps.filter { $0.time > 1.0 && $0.time < 1.6 }
    #expect(active.allSatisfy { $0.state.flags.contains(.scrollActive) })
    let kinds = steps.events.map(\.kind)
    let starts = kinds.filter { if case .scrollStarted(.buttons) = $0 { true } else { false } }
    let ends = kinds.filter { if case .scrollEnded(.buttons, _) = $0 { true } else { false } }
    #expect(starts.count == 1)
    #expect(ends.count == 1)
  }

  @Test func theEventsMarkTheStartThePressAndTheEnd() throws {
    let steps = Self.session(at: [1]).replay()
    let kinds = steps.events.map(\.kind)
    #expect(kinds.count >= 3)
    #expect(kinds.contains(.scrollStarted(source: .buttons)))
    #expect(kinds.contains(.scrollPress(direction: .up, pixels: 100)))
    let order = kinds.compactMap { kind -> String? in
      switch kind {
      case .scrollStarted: "started"
      case .scrollPress: "press"
      case .scrollEnded: "ended"
      default: nil
      }
    }
    #expect(order == ["started", "press", "ended"])
    let end = try #require(steps.events.first {
      if case .scrollEnded = $0.kind { true } else { false }
    })
    guard case .scrollEnded(.buttons, let pixels) = end.kind else {
      Issue.record("not a button scroll end")
      return
    }
    #expect(abs(pixels - 100) < 1e-9)
    // Stamped with the arrival of the sample that finished it: 1 s + 0.08 s × ln 200 = 1.42 s.
    #expect(end.time > 1.42 && end.time < 1.45, "ended at \(end.time)")
    // The press carries its own time.
    let press = try #require(steps.events.first {
      if case .scrollPress = $0.kind { true } else { false }
    })
    #expect(press.time == 1)
  }

  @Test func scrollSpeedIsTheGlideRate() {
    let steps = Self.session(at: [1]).replay()
    let press = steps.first { $0.diagnostics.scrollSpeed > 0 }
    #expect(abs((press?.diagnostics.scrollSpeed ?? 0) - 100 / 0.08) < 1e-6)
    #expect(steps.step(at: 1.2).diagnostics.scrollSpeed < 100 / 0.08)
    #expect(steps.step(at: 1.2).diagnostics.scrollSpeed > 0)
    #expect(steps.last?.diagnostics.scrollSpeed == 0)
  }

  @Test func scrollSpeedAddsTiltAndButtonScroll() {
    var session = MotionScrollTests.tilted(to: 20, duration: 4)
    session.scrollPress(.up, at: 2)
    let settings = Synthetic.tiltSettings
    let steps = session.replay(settings)
    let tilt = MotionScrollTests.expectedSpeed(20, settings.tiltScroll)
    #expect(abs(steps.step(at: 1.9).diagnostics.scrollSpeed - tilt) < 1e-6)
    let pressed = steps.first { $0.time >= 2 && $0.diagnostics.scrollSpeed > tilt + 1 }
    #expect(abs((pressed?.diagnostics.scrollSpeed ?? 0) - (tilt + 100 / 0.08)) < 1e-6)
    #expect(steps.step(at: 3).state.flags.contains(.scrollActive))
  }

  // MARK: - The cursor

  @Test(arguments: [true, false])
  func aPressStartsAClickFreeze(gyroAssist: Bool) {
    var session = Self.session(at: [1])
    // A 1.7 mm shift (under the 3 mm breakout) right after the press, which then stays.
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.0015, 0, -0.0009) * Synthetic.ramp(time, 1.005, 1.05)
    }
    var settings = Synthetic.flatGainSettings
    settings.pointer.gyroAssist = gyroAssist
    let steps = session.replay(settings)
    #expect(steps.step(at: 1.03).diagnostics.isFrozen)
    #expect(steps.step(at: 1.03).diagnostics.cursorGate == .clickFreeze)
    #expect(!steps.step(at: 1.5).diagnostics.isFrozen)
    // The jolt never leaks out (a quarter of it at most, from the restart's smoothing).
    #expect(simd_length(steps.finalCursor) < 1.25, "cursor \(steps.finalCursor)")
    let afterFreeze = steps.cursor(at: 1.8)
    #expect(simd_length(steps.finalCursor - afterFreeze) < 0.01)
  }

  @Test(arguments: [true, false])
  func theCursorKeepsMovingWhileTheButtonScrollGlides(gyroAssist: Bool) {
    var session = Self.session(at: [1])
    // After the 80 ms freeze, slide 2 cm right from 1.2 to 1.6 s. The glide runs until 1.42 s.
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.02 * Synthetic.ramp(time, 1.2, 1.6), 0, 0)
    }
    var settings = Synthetic.flatGainSettings
    settings.pointer.gyroAssist = gyroAssist
    let steps = session.replay(settings)
    let during = steps.step(at: 1.38)
    #expect(during.state.flags.contains(.scrollActive))
    #expect(during.diagnostics.cursorGate != .tiltScrolling)
    #expect(during.state.cursor.x - steps.cursor(at: 1.25).x > 5, "cursor \(during.state.cursor)")
    #expect(abs(steps.finalCursor.x - 50) < 1, "cursor \(steps.finalCursor)")
    #expect(steps.allSatisfy { $0.diagnostics.cursorGate != .tiltScrolling })
    #expect(abs((steps.last?.state.scroll.y ?? 0) - 100) < 1e-9)
  }

  // MARK: - The engine alone

  @Test func advancingIgnoresTimesNotAfterTheLastAdvance() {
    let settings = PipelineSettings.ButtonScroll()
    var scroll = ButtonScroll()
    _ = scroll.press(ScrollButtonPress(direction: .up, time: 10), settings: settings)
    #expect(scroll.advance(to: 10, settings: settings) == 0)
    #expect(scroll.advance(to: 9.9, settings: settings) == 0)
    let first = scroll.advance(to: 10.04, settings: settings)
    #expect(abs(first - 100 * (1 - exp(-0.5))) < 1e-9)
    #expect(scroll.advance(to: 10.04, settings: settings) == 0)
    #expect(scroll.advance(to: 10.03, settings: settings) == 0)
    #expect(scroll.advance(to: 10.1, settings: settings) > 0)
  }

  @Test func lessThanHalfAPixelLeftIsEmittedWholeAndEndsTheGlide() {
    let settings = PipelineSettings.ButtonScroll()
    var scroll = ButtonScroll()
    _ = scroll.press(ScrollButtonPress(direction: .up, time: 0), settings: settings)
    var total = 0.0
    var time = 0.0
    while scroll.isActive && time < 2 {
      time += 0.01
      total += scroll.advance(to: time, settings: settings)
      if scroll.isActive {
        #expect(abs(scroll.pending) >= 0.5)
      }
    }
    // The tail is released at once the first time under 0.5 px is left: 100 px × e^(−t/0.08)
    // gets there at 0.42 s.
    #expect(!scroll.isActive)
    #expect(scroll.pending == 0)
    #expect(abs(total - 100) < 1e-9)
    #expect(time > 0.42 && time < 0.44, "finished at \(time)")
  }

  @Test func aZeroGlideTimeEmitsEverythingAtTheNextSample() {
    var settings = PipelineSettings.ButtonScroll()
    settings.glideTime = 0
    var scroll = ButtonScroll()
    let queued = scroll.press(ScrollButtonPress(direction: .down, time: 0), settings: settings)
    #expect(queued.pixels == -100)
    #expect(queued.startedGlide)
    #expect(scroll.advance(to: 0.01, settings: settings) == -100)
    #expect(!scroll.isActive)
    #expect(scroll.speed(glideTime: 0) == 0)
  }

  @Test func pressesRoundTripThroughJSON() throws {
    let press = ScrollButtonPress(direction: .down, time: 12.5)
    let data = try JSONEncoder().encode(press)
    #expect(try JSONDecoder().decode(ScrollButtonPress.self, from: data) == press)
    #expect(String(decoding: data, as: UTF8.self).contains("\"down\""))
  }

  // MARK: - Shortcuts

  /// `flatGainSettings` with the volume buttons on their default shortcuts.
  static var shortcutSettings: PipelineSettings {
    var settings = Synthetic.flatGainSettings
    settings.volumeButtons = PipelineSettings.VolumeButtons()
    return settings
  }

  @Test func byDefaultUpPressesMissionControlAndDownSpotlight() {
    var session = Self.session(.up, at: [1])
    session.scrollPress(.down, at: 2)
    let steps = session.replay(Self.shortcutSettings)
    #expect(steps.last?.state.shortcuts[.missionControl] == 1)
    #expect(steps.last?.state.shortcuts[.spotlight] == 1)
    #expect(steps.last?.state.shortcuts[.appWindows] == 0)
    #expect(steps.allSatisfy { $0.state.scroll == .zero })
    #expect(Self.queued(steps).isEmpty)
    // The thumb's push still freezes the cursor.
    #expect(steps.step(at: 1.02).diagnostics.isFrozen)
    let pressed = steps.events.compactMap { event -> MacShortcut? in
      if case .shortcutPressed(let shortcut) = event.kind { return shortcut }
      return nil
    }
    #expect(pressed == [.missionControl, .spotlight])
  }

  @Test func holdingAButtonPressesItsShortcutOnce() {
    // iOS repeats a held button 0.33 s after the press, then every 42 ms.
    let held = [1, 1.334] + (1...10).map { 1.334 + Double($0) * 0.042 }
    let steps = Self.session(.up, at: held + [3]).replay(Self.shortcutSettings)
    #expect(steps.step(at: 2).state.shortcuts[.missionControl] == 1)
    #expect(steps.last?.state.shortcuts[.missionControl] == 2)
  }

  @Test func eachButtonCanScrollOrPressAnyShortcut() {
    var settings = Self.shortcutSettings
    settings.volumeButtons.up = .scroll
    settings.volumeButtons.down = .appWindows
    var session = Self.session(.up, at: [1])
    session.scrollPress(.down, at: 2)
    let steps = session.replay(settings)
    #expect(abs((steps.last?.state.scroll.y ?? 0) - 100) < 1e-9)
    #expect(steps.last?.state.shortcuts == ShortcutPresses(counts: [0, 1, 0, 0]))
  }

  @Test func keyPressesPressTheirKeysUnlessPaused() {
    var session = SyntheticSession(duration: 4)
    session.touch(.key(.returnKey, heldFor: 0.1, isRepeat: false, time: 1))
    session.touch(.key(.deleteKey, heldFor: 0.5, isRepeat: true, time: 1.25))
    session.touch(.key(.deleteKey, heldFor: 0.55, isRepeat: true, time: 1.3))
    session.pause(true, at: 2)
    session.touch(.key(.returnKey, heldFor: 0.1, isRepeat: false, time: 2.5))
    session.touch(.key(.deleteKey, heldFor: 0.1, isRepeat: false, time: 2.75))
    let steps = session.replay(Self.shortcutSettings)
    #expect(steps.step(at: 1.5).state.shortcuts[.returnKey] == 1)
    #expect(steps.step(at: 1.5).state.shortcuts[.deleteKey] == 2)
    #expect(steps.last?.state.shortcuts[.returnKey] == 1)
    #expect(steps.last?.state.shortcuts[.deleteKey] == 2)
    #expect(steps.last?.state.shortcuts[.missionControl] == 0)
  }
}
