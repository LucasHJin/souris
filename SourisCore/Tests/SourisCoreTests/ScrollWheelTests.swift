import CoreGraphics
import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct ScrollWheelTests {
  static let settings = ScrollWheelSettings()

  /// A finger rolling the wheel from `start` by `distance` points down the screen over
  /// `duration`, sampled at 120 Hz, then held there and, if `lifts`, lifted. Display refreshes
  /// run at 120 Hz until `until`.
  struct Roll {
    var start: Double = 200
    var distance: Double
    var duration: Double
    var lifts = true
    var until: Double = 3
    var settings = ScrollWheelSettings()
  }

  /// Everything a roll produced, in time order.
  struct Result {
    var updates: [ScrollWheel.Update] = []
    var times: [Double] = []
    var wheel = ScrollWheel()

    mutating func record(_ update: ScrollWheel.Update, at time: Double) {
      updates.append(update)
      times.append(time)
    }

    var events: [ScrollWheelEvent] { updates.flatMap(\.events) }
    var ticks: Int { updates.map(\.ticks).reduce(0, +) }
    var isTap: Bool { updates.contains { $0.isTap } }

    var scrolled: Double {
      events.reduce(0) { total, event in
        if case .turn(let pixels, _) = event { total + pixels } else { total }
      }
    }
  }

  static func perform(_ roll: Roll) -> Result {
    var result = Result()
    result.record(result.wheel.touchBegan(y: roll.start, time: 0), at: 0)
    let moves = Int((roll.duration * 120).rounded())
    for frame in 1...Int(roll.until * 120) {
      let time = Double(frame) / 120
      if frame <= moves {
        let y = roll.start + roll.distance * min(1, time / roll.duration)
        result.record(result.wheel.touchMoved(y: y, time: time, settings: roll.settings), at: time)
      } else if roll.lifts && result.wheel.isTouching {
        result.record(result.wheel.touchEnded(time: time, settings: roll.settings), at: time)
      }
      result.record(result.wheel.advance(to: time, settings: roll.settings), at: time)
    }
    return result
  }

  @Test func aSlowRollScrollsOneStepPerNotch() {
    // 36 pt down the screen in a second: three notches at 36 pt/s, under the slow speed.
    let result = Self.perform(Roll(distance: 36, duration: 1))
    #expect(result.ticks == 3)
    #expect(abs(result.scrolled - 3 * Self.settings.pixelsPerNotch) < 1e-6)
    #expect(result.events.first == .touch(isDown: true, time: 0))
    #expect(result.events.contains { if case .touch(false, _) = $0 { true } else { false } })
    // A notch every third of a second is slower than the rest time, so each one is its own
    // scroll; the last one stops too.
    let lastTurn = result.events.lastIndex { if case .turn = $0 { true } else { false } }
    let lastStop = result.events.lastIndex { if case .stop = $0 { true } else { false } }
    #expect((lastStop ?? -1) > (lastTurn ?? .max))
    #expect(!result.isTap)
    #expect(abs(result.wheel.rotation + 3) < 1e-9)
  }

  @Test func rollingTowardTheTopEdgeScrollsDownThePageAndReversedFlipsIt() {
    let down = Self.perform(Roll(distance: -36, duration: 1))
    #expect(abs(down.scrolled + 3 * Self.settings.pixelsPerNotch) < 1e-6)
    var reversed = Roll(distance: -36, duration: 1)
    reversed.settings.isReversed = true
    #expect(abs(Self.perform(reversed).scrolled - 3 * Self.settings.pixelsPerNotch) < 1e-6)
  }

  @Test func aFastRollScrollsMorePerNotch() {
    var roll = Roll(distance: 120, duration: 0.1, lifts: false)
    roll.settings.hasMomentum = false
    let fast = Self.perform(roll)
    #expect(fast.ticks == 10)
    let perNotch = fast.scrolled / Double(fast.ticks)
    #expect(perNotch > Self.settings.pixelsPerNotch * 2, "\(perNotch) px per notch")
    #expect(perNotch <= Self.settings.pixelsPerNotch * Self.settings.maxAcceleration + 1e-6)
  }

  @Test func aFlickKeepsTheWheelSpinningAndTickingThenStops() {
    let flick = Self.perform(Roll(distance: 120, duration: 0.1))
    var noMomentum = Roll(distance: 120, duration: 0.1)
    noMomentum.settings.hasMomentum = false
    let plain = Self.perform(noMomentum)
    #expect(flick.ticks > plain.ticks + 3, "\(flick.ticks) vs \(plain.ticks) ticks")
    #expect(flick.scrolled > plain.scrolled)
    #expect(!flick.wheel.isSpinning)
    #expect(!flick.wheel.needsFrames)
    let stops = flick.events.filter { if case .stop = $0 { true } else { false } }
    #expect(stops.count == 1)
    // The spin's ticks space out as it slows.
    let tickTimes = zip(flick.updates, flick.times).filter { $0.0.ticks > 0 && $0.1 > 0.12 }
      .map(\.1)
    let gaps = zip(tickTimes, tickTimes.dropFirst()).map { $1 - $0 }
    #expect(gaps.count > 3)
    #expect((gaps.last ?? 0) > (gaps.first ?? 0) * 2, "gaps \(gaps)")
  }

  @Test func touchingASpinningWheelStopsItWithoutAClick() {
    var wheel = ScrollWheel()
    let settings = Self.settings
    _ = wheel.touchBegan(y: 200, time: 0)
    var time = 0.0
    for step in 1...12 {
      time = Double(step) / 120
      _ = wheel.touchMoved(y: 200 - Double(step) * 10, time: time, settings: settings)
    }
    _ = wheel.touchEnded(time: time, settings: settings)
    _ = wheel.advance(to: time + 0.02, settings: settings)
    #expect(wheel.isSpinning)
    _ = wheel.touchBegan(y: 150, time: time + 0.03)
    #expect(!wheel.isSpinning)
    let lift = wheel.touchEnded(time: time + 0.08, settings: settings)
    #expect(!lift.isTap)
  }

  @Test func aShortStillTouchIsATap() {
    var wheel = ScrollWheel()
    _ = wheel.touchBegan(y: 200, time: 0)
    _ = wheel.touchMoved(y: 203, time: 0.05, settings: Self.settings)
    let lift = wheel.touchEnded(time: 0.12, settings: Self.settings)
    #expect(lift.isTap)
    #expect(lift.ticks == 0)

    var off = Self.settings
    off.tapClicksMiddle = false
    _ = wheel.touchBegan(y: 200, time: 1)
    #expect(!wheel.touchEnded(time: 1.1, settings: off).isTap)
    _ = wheel.touchBegan(y: 200, time: 2)
    #expect(!wheel.touchEnded(time: 2.5, settings: Self.settings).isTap, "too long")
  }

  @Test func holdingStillOnTheWheelEndsTheScroll() {
    let held = Self.perform(Roll(distance: -36, duration: 0.3, lifts: false, until: 1.5))
    let stops = held.events.filter { if case .stop = $0 { true } else { false } }
    #expect(stops.count == 1)
    #expect(held.wheel.isTouching)
  }

  @Test func cancelLiftsAndStops() {
    var wheel = ScrollWheel()
    _ = wheel.touchBegan(y: 200, time: 0)
    _ = wheel.touchMoved(y: 170, time: 0.2, settings: Self.settings)
    _ = wheel.advance(to: 0.21, settings: Self.settings)
    let cancelled = wheel.cancel(time: 0.3)
    #expect(cancelled.events == [.touch(isDown: false, time: 0.3), .stop(time: 0.3)])
    #expect(!wheel.needsFrames)
  }

  // MARK: - Dictation

  /// Holds a finger at y 200 from 0, advancing at 120 Hz until `until`, and returns every update.
  static func hold(
    _ wheel: inout ScrollWheel, until: Double, settings: ScrollWheelSettings = settings
  ) -> Result {
    var result = Result()
    result.record(wheel.touchBegan(y: 200, time: 0), at: 0)
    for frame in 1...Int(until * 120) {
      let time = Double(frame) / 120
      result.record(wheel.advance(to: time, settings: settings), at: time)
    }
    return result
  }

  static func dictationEvents(_ result: Result) -> [ScrollWheelEvent] {
    result.events.filter { if case .dictation = $0 { true } else { false } }
  }

  @Test func holdingStillDictatesUntilTheFingerLifts() {
    var wheel = ScrollWheel()
    let held = Self.hold(&wheel, until: 0.6)
    let started = Self.dictationEvents(held)
    #expect(started.count == 1)
    let startTime = started.first?.time ?? 0
    #expect(
      startTime >= Self.settings.dictationHold && startTime < Self.settings.dictationHold + 0.02,
      "\(startTime)")
    #expect(wheel.isDictating)
    // Rolling now neither turns nor ticks the wheel.
    let rolled = wheel.touchMoved(y: 260, time: 0.7, settings: Self.settings)
    #expect(rolled.ticks == 0)
    #expect(abs(wheel.rotation) < 1e-9)
    let lift = wheel.touchEnded(time: 0.8, settings: Self.settings)
    #expect(lift.events == [.dictation(isOn: false, time: 0.8), .touch(isDown: false, time: 0.8)])
    #expect(!lift.isTap)
    #expect(!wheel.isDictating)
    #expect(!wheel.isSpinning)
  }

  @Test func aRollThatComesToRestDoesNotDictate() {
    let held = Self.perform(Roll(distance: 36, duration: 0.3, lifts: false, until: 1.5))
    #expect(held.wheel.isTouching)
    #expect(Self.dictationEvents(held).isEmpty)
  }

  @Test func aTouchThatStopsASpinDoesNotDictate() {
    var wheel = ScrollWheel()
    _ = wheel.touchBegan(y: 200, time: 0)
    var time = 0.0
    for step in 1...12 {
      time = Double(step) / 120
      _ = wheel.touchMoved(y: 200 - Double(step) * 10, time: time, settings: Self.settings)
    }
    _ = wheel.touchEnded(time: time, settings: Self.settings)
    _ = wheel.advance(to: time + 0.02, settings: Self.settings)
    #expect(wheel.isSpinning)
    _ = wheel.touchBegan(y: 150, time: time + 0.03)
    var events: [ScrollWheelEvent] = []
    for frame in 1...120 {
      events += wheel.advance(to: time + 0.03 + Double(frame) / 120, settings: Self.settings).events
    }
    #expect(!events.contains { if case .dictation = $0 { true } else { false } })
  }

  @Test func holdToDictateOffNeverDictates() {
    var settings = Self.settings
    settings.holdsToDictate = false
    var wheel = ScrollWheel()
    #expect(Self.dictationEvents(Self.hold(&wheel, until: 2, settings: settings)).isEmpty)
  }

  @Test func cancelStopsDictation() {
    var wheel = ScrollWheel()
    _ = Self.hold(&wheel, until: 0.6)
    let cancelled = wheel.cancel(time: 0.7)
    #expect(cancelled.events.first == .dictation(isOn: false, time: 0.7))
    #expect(!wheel.isDictating)
  }

  @Test func accelerationEasesBetweenTheSpeeds() {
    let settings = Self.settings
    #expect(ScrollWheel.acceleration(speed: 0, settings: settings) == 1)
    #expect(ScrollWheel.acceleration(speed: settings.slowSpeed, settings: settings) == 1)
    #expect(
      ScrollWheel.acceleration(speed: settings.fastSpeed * 2, settings: settings)
        == settings.maxAcceleration)
    let middle = ScrollWheel.acceleration(
      speed: (settings.slowSpeed + settings.fastSpeed) / 2, settings: settings)
    #expect(abs(middle - (1 + settings.maxAcceleration) / 2) < 1e-9)
  }
}

@Suite struct TouchClassifierWheelTests {
  static let size = CGSize(width: 428, height: 926)

  @Test func theWheelSitsBetweenTheButtonsInTheTouchArea() throws {
    let classifier = TouchClassifier()
    let rect = try #require(classifier.wheelRect(in: Self.size))
    #expect(rect.midX == Self.size.width / 2)
    #expect(rect.width == 44)
    #expect(rect.minY > 0 && rect.maxY < Self.size.height / 2)
    #expect(classifier.isOnWheel(CGPoint(x: 214, y: 230), in: Self.size))
    #expect(!classifier.isOnWheel(CGPoint(x: 150, y: 230), in: Self.size))
    // The palm zone below the touch area is never the wheel.
    #expect(!classifier.isOnWheel(CGPoint(x: 214, y: 600), in: Self.size))
  }

  @Test func aTouchOnTheWheelPressesNothing() {
    var classifier = TouchClassifier()
    let events = classifier.touchBegan(
      id: 1, location: CGPoint(x: 214, y: 230), in: Self.size, time: 1)
    #expect(events.isEmpty)
    #expect(classifier.heldButtons.isEmpty)
  }

  @Test func turnedOffTheMiddleIsTheButtonsAgain() {
    var settings = TouchSettings()
    settings.wheel.isEnabled = false
    var classifier = TouchClassifier(settings: settings)
    #expect(classifier.wheelRect(in: Self.size) == nil)
    let events = classifier.touchBegan(
      id: 1, location: CGPoint(x: 215, y: 230), in: Self.size, time: 1)
    #expect(events.contains(.button(.right, isDown: true, time: 1)))
  }

  @Test func aMiddleClickPressesAndReleasesAfterTheMinimumDuration() {
    var classifier = TouchClassifier()
    let press = classifier.middleClick(at: 2)
    #expect(press == [.contact(time: 2), .button(.middle, isDown: true, time: 2)])
    #expect(classifier.heldButtons == .middle)
    #expect(classifier.nextDeadline == 2.03)
    #expect(classifier.advance(to: 2.03) == [.button(.middle, isDown: false, time: 2.03)])
    #expect(classifier.heldButtons.isEmpty)
  }

  @Test func touchSettingsSavedBeforeTheWheelKeepTheirValues() throws {
    let json = #"{ "acceptedFraction": 0.45, "sideRejectBand": 8, "minimumPressDuration": 0.04 }"#
    let settings = try JSONDecoder().decode(TouchSettings.self, from: Data(json.utf8))
    #expect(settings.acceptedFraction == 0.45)
    #expect(settings.sideRejectBand == 8)
    #expect(settings.wheel == ScrollWheelSettings())
  }
}

@Suite struct MotionWheelTests {
  @Test func turnsScrollAndKeepTheScrollActiveUntilTheWheelStops() {
    var pipeline = MotionPipeline()
    pipeline.handle(ScrollWheelEvent.touch(isDown: true, time: 1))
    pipeline.handle(ScrollWheelEvent.turn(pixels: 30, time: 1.1))
    #expect(pipeline.state.flags.contains(.scrollActive))
    pipeline.handle(ScrollWheelEvent.turn(pixels: 10, time: 1.12))
    #expect(pipeline.state.scroll.y == 40)
    pipeline.handle(ScrollWheelEvent.touch(isDown: false, time: 1.2))
    #expect(pipeline.state.flags.contains(.scrollActive))
    pipeline.handle(ScrollWheelEvent.stop(time: 1.3))
    #expect(!pipeline.state.flags.contains(.scrollActive))
    let kinds = pipeline.drainEvents().map(\.kind)
    #expect(kinds.contains(.scrollStarted(source: .wheel)))
    #expect(kinds.contains(.scrollEnded(source: .wheel, pixels: 40)))
  }

  @Test func aFingerOnTheWheelHoldsTheCursor() {
    // Sliding right at 10 cm/s from 0.5 s; the finger is on the wheel from 1 to 2 s.
    var session = SyntheticSession(duration: 3)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.1 * max(0, time - 0.5), 0, 0)
    }
    session.inserts.append((1, .wheel(.touch(isDown: true, time: 1))))
    session.inserts.append((2, .wheel(.touch(isDown: false, time: 2))))
    let steps = session.replay(Synthetic.flatGainSettings)
    let held = steps.step(at: 1.9).state.cursor.x - steps.step(at: 1.2).state.cursor.x
    #expect(abs(held) < 0.01, "moved \(held) pt while held")
    let after = steps.step(at: 2.8).state.cursor.x - steps.step(at: 2.3).state.cursor.x
    #expect(after > 100, "moved \(after) pt after")
    #expect(steps.step(at: 1.5).diagnostics.cursorGate == .wheelHeld)
  }

  @Test func aHoldSetsTheDictatingFlagUntilItLiftsOrThePhonePauses() {
    var pipeline = MotionPipeline()
    pipeline.handle(ScrollWheelEvent.touch(isDown: true, time: 1))
    pipeline.handle(ScrollWheelEvent.dictation(isOn: true, time: 1.4))
    #expect(pipeline.state.flags.contains(.dictating))
    #expect(!pipeline.state.flags.contains(.scrollActive))
    pipeline.handle(ScrollWheelEvent.dictation(isOn: false, time: 2))
    #expect(!pipeline.state.flags.contains(.dictating))

    pipeline.handle(ScrollWheelEvent.dictation(isOn: true, time: 3))
    pipeline.setPaused(true)
    #expect(!pipeline.state.flags.contains(.dictating))
    let kinds = pipeline.drainEvents().map(\.kind)
    #expect(kinds.filter { if case .dictation = $0 { true } else { false } } == [
      .dictation(true), .dictation(false), .dictation(true), .dictation(false),
    ])
  }

  @Test func pausingStopsTheWheelAndIgnoresItsEvents() {
    var pipeline = MotionPipeline()
    pipeline.handle(ScrollWheelEvent.touch(isDown: true, time: 1))
    pipeline.handle(ScrollWheelEvent.turn(pixels: 30, time: 1.1))
    pipeline.setPaused(true)
    #expect(!pipeline.state.flags.contains(.scrollActive))
    pipeline.handle(ScrollWheelEvent.turn(pixels: 30, time: 1.2))
    #expect(pipeline.state.scroll.y == 30)
  }
}
