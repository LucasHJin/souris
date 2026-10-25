import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionGateTests {
  /// The `gateChanged` events as (from, to) pairs.
  static func transitions(_ steps: [RecordingReplay.Step]) -> [(from: CursorGate, to: CursorGate)] {
    steps.events.compactMap {
      if case .gateChanged(let from, let to) = $0.kind { return (from, to) }
      return nil
    }
  }

  static func isTransition(
    _ transition: (from: CursorGate, to: CursorGate),
    _ from: CursorGate,
    _ to: CursorGate
  ) -> Bool {
    transition.from == from && transition.to == to
  }

  // MARK: - Precedence

  @Test func gatesFollowThePrecedenceOrder() {
    // paused > waitingForTracking > notEngaged > lifted > trackingLost > tiltScrolling
    // > wheelHeld > clickFreeze > open
    let order: [(CursorGate.Conditions, CursorGate)] = [
      (.paused, .paused),
      (.waitingForTracking, .waitingForTracking),
      (.notEngaged, .notEngaged),
      (.lifted, .lifted),
      (.trackingLost, .trackingLost),
      (.tiltScrolling, .tiltScrolling),
      (.wheelHeld, .wheelHeld),
      (.clickFreeze, .clickFreeze),
    ]
    #expect(CursorGate(highestOf: []) == .open)
    // Every combination of the eight conditions resolves to the first one present.
    for bits in 0..<(1 << order.count) {
      let conditions = CursorGate.Conditions(rawValue: bits)
      let expected = order.first { conditions.contains($0.0) }?.1 ?? .open
      #expect(CursorGate(highestOf: conditions) == expected, "conditions \(bits)")
    }
  }

  @Test func theGateListIsStable() {
    // The raw values reach logs and replay CSVs.
    #expect(CursorGate.allCases.map(\.rawValue) == [
      "open", "paused", "waitingForTracking", "notEngaged", "lifted", "trackingLost",
      "tiltScrolling", "wheelHeld", "clickFreeze",
    ])
  }

  @Test func gateSecondsKeepsEachGateApart() {
    var seconds = GateSeconds()
    #expect(seconds.total == 0)
    for (index, gate) in CursorGate.allCases.enumerated() {
      seconds[gate] += Double(index + 1)
    }
    for (index, gate) in CursorGate.allCases.enumerated() {
      #expect(seconds[gate] == Double(index + 1))
    }
    #expect(seconds.total == 45)
    seconds[.lifted] = 0.5
    #expect(seconds[.lifted] == 0.5)
    #expect(seconds[.trackingLost] == 6)
  }

  // MARK: - Real transitions

  @Test func theGateStartsWaitingAndOpensOnTheFirstGoodFrame() {
    #expect(MotionPipeline().diagnostics.cursorGate == .waitingForTracking)
    var session = SyntheticSession(duration: 2)
    session.path.tracking = { $0 < 0.5 ? .initializing : .normal }
    let steps = session.replay()
    #expect(steps.step(at: 0.3).diagnostics.cursorGate == .waitingForTracking)
    // The first normal frame (captured at 0.5, arrived at 0.545) gives an anchor, but the
    // pipeline skips the next three frames' deltas before engaging.
    #expect(steps.step(at: 0.57).diagnostics.cursorGate == .notEngaged)
    #expect(steps.step(at: 1).diagnostics.cursorGate == .open)
    let transitions = Self.transitions(steps)
    #expect(transitions.count == 2)
    #expect(Self.isTransition(transitions[0], .waitingForTracking, .notEngaged))
    #expect(Self.isTransition(transitions[1], .notEngaged, .open))
  }

  @Test func aSessionThatStartsNormalOpensOnTheFirstFrame() {
    let steps = SyntheticSession(duration: 1).replay()
    let transitions = Self.transitions(steps)
    #expect(transitions.count == 1)
    #expect(Self.isTransition(transitions[0], .waitingForTracking, .open))
    let opened = steps.events.first { if case .gateChanged = $0.kind { true } else { false } }
    // The first frame, arriving 45 ms after its capture at 0.
    #expect(abs((opened?.time ?? 0) - 0.045) < 1e-9)
  }

  @Test func trackingChangesAreEvents() {
    var session = SyntheticSession(duration: 3)
    session.path.tracking = { time in
      if time < 0.5 { return .initializing }
      return time >= 1.5 && time < 2 ? .relocalizing : .normal
    }
    let changes = session.replay().events.compactMap { event -> TrackingStatus? in
      if case .trackingChanged(let status) = event.kind { return status }
      return nil
    }
    #expect(changes == [.initializing, .normal, .relocalizing, .normal])
  }

  @Test func pausingClosesTheGateAtOnce() {
    let session = SyntheticSession(duration: 1)
    var pipeline = MotionPipeline(settings: Synthetic.flatGainSettings)
    for event in session.events() {
      pipeline.feed(event)
    }
    _ = pipeline.drainEvents()
    #expect(pipeline.diagnostics.cursorGate == .open)

    pipeline.setPaused(true)
    // No sample has arrived since the call.
    #expect(pipeline.diagnostics.cursorGate == .paused)
    let kinds = pipeline.drainEvents().map(\.kind)
    #expect(kinds == [.paused(true), .gateChanged(from: .open, to: .paused)])

    // Unpausing re-engages, so the gate sits at notEngaged until the next good frame.
    pipeline.setPaused(false)
    #expect(pipeline.diagnostics.cursorGate == .notEngaged)
    #expect(pipeline.drainEvents().map(\.kind)
      == [.paused(false), .gateChanged(from: .paused, to: .notEngaged)])
    // Repeating the call changes nothing.
    pipeline.setPaused(false)
    #expect(pipeline.drainEvents().isEmpty)

    pipeline.process(session.arSample(at: 1.1))
    #expect(pipeline.diagnostics.cursorGate == .open)
  }

  @Test func callsBeforeTheFirstInputBookNoTime() {
    let session = SyntheticSession(duration: 1)
    var pipeline = MotionPipeline(settings: Synthetic.flatGainSettings)
    pipeline.setPaused(true)
    pipeline.setPaused(false)
    // Arrival times are uptime, so the first frame must not book the time since 0.
    pipeline.process(session.arSample(at: 5000))
    pipeline.process(session.arSample(at: 5000.1))
    #expect(abs(pipeline.diagnostics.gateSeconds.total - 0.1) < 1e-9)
    #expect(pipeline.diagnostics.cursorGate == .open)
  }

  @Test func recenterShowsNotEngagedUntilTheNextGoodFrame() {
    let session = SyntheticSession(duration: 1)
    var pipeline = MotionPipeline(settings: Synthetic.flatGainSettings)
    for event in session.events() {
      pipeline.feed(event)
    }
    _ = pipeline.drainEvents()
    pipeline.recenter()
    #expect(pipeline.drainEvents().map(\.kind) == [.recentered])
    pipeline.process(session.imuSample(at: 1.1))
    #expect(pipeline.diagnostics.cursorGate == .notEngaged)
    pipeline.process(session.arSample(at: 1.12))
    #expect(pipeline.diagnostics.cursorGate == .open)
    let transitions = pipeline.drainEvents().compactMap { event -> CursorGate? in
      if case .gateChanged(_, let to) = event.kind { return to }
      return nil
    }
    #expect(transitions == [.notEngaged, .open])
  }

  @Test func liftingClosesTheGateAndSettingDownOpensIt() {
    let steps = MotionLiftTests.liftAndReposition().replay()
    #expect(steps.step(at: 1).diagnostics.cursorGate == .open)
    #expect(steps.step(at: 2.5).diagnostics.cursorGate == .lifted)
    #expect(steps.step(at: 4).diagnostics.cursorGate == .open)
    let transitions = Self.transitions(steps)
    #expect(transitions.count == 3)
    #expect(Self.isTransition(transitions[1], .open, .lifted))
    #expect(Self.isTransition(transitions[2], .lifted, .open))
  }

  @Test func losingTrackingClosesTheGateAfterTheGyroGracePeriod() {
    var session = SyntheticSession(duration: 4)
    session.path.tracking = { time in
      time >= 1 && time < 1.6 ? .insufficientFeatures : .normal
    }
    let steps = session.replay()
    // The gyro keeps the cursor going for 0.3 s past the last good frame.
    #expect(steps.step(at: 1.2).diagnostics.cursorGate == .open)
    #expect(steps.step(at: 1.5).diagnostics.cursorGate == .trackingLost)
    #expect(steps.step(at: 2.5).diagnostics.cursorGate == .open)
    let transitions = Array(Self.transitions(steps).dropFirst())
    #expect(transitions.count == 2)
    #expect(Self.isTransition(transitions[0], .open, .trackingLost))
    #expect(Self.isTransition(transitions[1], .trackingLost, .open))
    let reanchors = steps.events.filter {
      if case .reanchored(.trackingRecovered) = $0.kind { true } else { false }
    }
    #expect(reanchors.count == 1)
  }

  @Test func aRejectedJumpIsAnEventAndReanchors() {
    var session = SyntheticSession(duration: 2)
    session.path.position = { time in
      time >= 1 ? Synthetic.rest + SIMD3(0.1, 0, 0.05) : Synthetic.rest
    }
    let events = session.replay().events
    let speeds = events.compactMap { event -> Double? in
      if case .jumpRejected(let speed) = event.kind { return speed }
      return nil
    }
    #expect(speeds.count == 1)
    // 11 cm in one 1/60 s frame.
    #expect(abs((speeds.first ?? 0) - 0.1118 * 60) < 0.1)
    #expect(events.contains {
      if case .reanchored(.jump) = $0.kind { true } else { false }
    })
  }

  @Test func tiltScrollingClosesTheGateAndEmitsItsBounds() {
    var session = SyntheticSession(duration: 4)
    let pitch = { (time: Double) in
      20 * .pi / 180 * (Synthetic.ramp(time, 0.5, 1) - Synthetic.ramp(time, 2.5, 2.8))
    }
    // Tilt scrolling pivots at the wrist, 15 cm behind the camera.
    session.path.pitch = pitch
    session.path.position = { Synthetic.position(pitching: pitch($0), about: 0.15) }
    let steps = session.replay(Synthetic.tiltSettings)
    #expect(steps.step(at: 0.3).diagnostics.cursorGate == .open)
    #expect(steps.step(at: 1.5).diagnostics.cursorGate == .tiltScrolling)
    #expect(steps.step(at: 3.5).diagnostics.cursorGate == .open)

    let bounds = steps.events.compactMap { event -> String? in
      switch event.kind {
      case .scrollStarted(.tilt): "started"
      case .scrollEnded(.tilt, let pixels): "ended \(pixels > 100)"
      default: nil
      }
    }
    #expect(bounds == ["started", "ended true"])
    let ended = steps.events.compactMap { event -> Double? in
      if case .scrollEnded(.tilt, let pixels) = event.kind { return pixels }
      return nil
    }
    // The event reports what the tilt scrolled: all of the state's scroll.
    #expect(abs((ended.first ?? 0) - (steps.last?.state.scroll.y ?? 0)) < 1e-9)
    let gates = Self.transitions(steps).dropFirst().map { $0.to }
    #expect(gates == [.tiltScrolling, .open])
  }

  @Test func aTapIsOneFreezeNotAFlicker() {
    // Gyro assist interleaves ARKit frames captured before the touch (which still count) with
    // IMU samples after it. The gate follows the freeze window, not each sample.
    var session = SyntheticSession(duration: 4)
    session.touch(.contact(time: 2))
    session.touch(.button(.left, isDown: true, time: 2.05))
    session.touch(.contact(time: 2.5))
    session.touch(.button(.left, isDown: false, time: 2.5))
    let steps = session.replay()
    let transitions = Self.transitions(steps).dropFirst()
    #expect(transitions.map { $0.to } == [.clickFreeze, .open, .clickFreeze, .open])
    #expect(steps.step(at: 2.05).diagnostics.cursorGate == .clickFreeze)
    #expect(steps.step(at: 2.4).diagnostics.cursorGate == .open)
  }

  @Test func aTiltScrollOutranksAClickFreeze() {
    var session = SyntheticSession(duration: 2)
    session.path.pitch = { time in 20 * .pi / 180 * Synthetic.ramp(time, 0.5, 1) }
    var pipeline = MotionPipeline(settings: Synthetic.tiltSettings)
    for event in session.events() {
      pipeline.feed(event)
    }
    #expect(pipeline.diagnostics.cursorGate == .tiltScrolling)
    // A touch lands; the next ARKit frame arrives before any IMU sample can end the scroll.
    pipeline.handle(.contact(time: 2.05))
    pipeline.process(session.arSample(at: 2.02))
    #expect(pipeline.diagnostics.isFrozen)
    #expect(pipeline.state.flags.contains(.scrollActive))
    #expect(pipeline.diagnostics.cursorGate == .tiltScrolling)
  }

  @Test func pausingWhileLiftedShowsPaused() {
    var session = MotionLiftTests.liftAndReposition()
    session.pause(true, at: 2.5)
    session.pause(false, at: 2.8)
    let steps = session.replay()
    #expect(steps.step(at: 2.4).diagnostics.cursorGate == .lifted)
    #expect(steps.step(at: 2.6).diagnostics.cursorGate == .paused)
    #expect(steps.step(at: 2.6).state.flags.contains(.lifted))
  }

  // MARK: - Time accounting

  @Test func gateSecondsCoverTheTimeBetweenCursorSteps() {
    let session = MotionLiftTests.liftAndReposition()
    let events = session.events()
    let steps = RecordingReplay.run(events, settings: Synthetic.flatGainSettings)
    let seconds = steps.last?.diagnostics.gateSeconds ?? GateSeconds()
    // Every AR frame and IMU sample from the first AR frame on books its interval.
    let arrivals = events.compactMap { event -> Double? in
      switch event {
      case .ar(let sample): sample.arrival
      case .imu(let sample): sample.arrival
      default: nil
      }
    }
    let firstAR = events.compactMap { event -> Double? in
      if case .ar(let sample) = event { sample.arrival } else { nil }
    }.min() ?? 0
    #expect(abs(seconds.total - ((arrivals.max() ?? 0) - firstAR)) < 1e-9)
    #expect(seconds[.lifted] > 1)
    #expect(seconds[.open] > 3)
    #expect(seconds[.paused] == 0)
    #expect(seconds[.tiltScrolling] == 0)
  }

  @Test func gateSecondsMatchAnIndependentCountOfTheSteps() {
    var session = MotionLiftTests.liftAndReposition()
    session.touch(.contact(time: 0.7))
    session.touch(.button(.left, isDown: true, time: 0.75))
    session.pause(true, at: 4.5)
    session.pause(false, at: 5)
    session.scrollPress(.up, at: 5.5)
    let events = session.events()
    let steps = RecordingReplay.run(events, settings: Synthetic.flatGainSettings)

    // Book each AR/IMU interval to the gate shown after the previous step.
    var expected = GateSeconds()
    var clock: Double?
    var gate = CursorGate.waitingForTracking
    for (event, step) in zip(events, steps) {
      var arrival: Double?
      switch event {
      case .ar(let sample): arrival = sample.arrival
      case .imu(let sample): arrival = clock == nil ? nil : sample.arrival
      default: break
      }
      if let arrival {
        if let current = clock, arrival > current {
          expected[gate] += arrival - current
          clock = arrival
        } else if clock == nil {
          clock = arrival
        }
      }
      gate = step.diagnostics.cursorGate
    }
    let seconds = steps.last?.diagnostics.gateSeconds ?? GateSeconds()
    for gate in CursorGate.allCases {
      #expect(
        abs(seconds[gate] - expected[gate]) < 1e-9,
        "\(gate): \(seconds[gate]) vs \(expected[gate])")
    }
    #expect(seconds[.paused] > 0.4)
    #expect(seconds[.clickFreeze] > 0.1)
  }

  @Test func timeInEachGateMatchesTheScenario() {
    var session = SyntheticSession(duration: 5)
    session.pause(true, at: 1)
    session.pause(false, at: 2)
    session.touch(.contact(time: 3))
    let seconds = session.replay().last?.diagnostics.gateSeconds ?? GateSeconds()
    // Paused for 1 s, give or take the sample interval that the call is stamped with.
    #expect(abs(seconds[.paused] - 1) < 0.03, "paused \(seconds[.paused])")
    // The freeze runs from the touch until ARKit delivers a frame past its 80 ms window.
    #expect(seconds[.clickFreeze] > 0.1 && seconds[.clickFreeze] < 0.17)
    #expect(seconds[.notEngaged] < 0.03)
    #expect(seconds[.waitingForTracking] == 0)
    // From the first frame (45 ms in) to the last sample: 5 s.
    #expect(abs(seconds.total - 5) < 1e-9)
    let rest = 5 - seconds[.paused] - seconds[.clickFreeze] - seconds[.notEngaged]
    #expect(abs(seconds[.open] - rest) < 1e-9)
  }

  // MARK: - Travel counters

  @Test func travelCountersGiveTheEffectiveGain() {
    var session = SyntheticSession(duration: 4)
    session.path.position = { time in
      let travel = Synthetic.ramp(time, 1, 2)
      return Synthetic.rest + SIMD3(0.04 * travel, 0, -0.02 * travel)
    }
    let steps = session.replay()
    let diagnostics = steps.last?.diagnostics ?? PipelineDiagnostics()
    // 44.7 mm of travel at the flat 2.5 pt/mm.
    let travel = (0.04 * 0.04 + 0.02 * 0.02).squareRoot() * 1000
    #expect(abs(diagnostics.sensorTravelMm - travel) < 1.5, "sensor \(diagnostics.sensorTravelMm)")
    #expect(abs(diagnostics.cursorTravelPoints / diagnostics.sensorTravelMm - 2.5) < 1e-6)
  }

  @Test func travelIsCountedOnlyWhereTheCursorFollows() {
    var session = SyntheticSession(duration: 5)
    // 2 cm right while paused: the sensor moved, the cursor didn't follow, and neither counts.
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.02 * Synthetic.ramp(time, 1.2, 1.8), 0, 0)
    }
    session.pause(true, at: 1)
    session.pause(false, at: 2)
    let diagnostics = session.replay().last?.diagnostics ?? PipelineDiagnostics()
    #expect(diagnostics.sensorTravelMm < 3, "sensor \(diagnostics.sensorTravelMm)")
    #expect(diagnostics.cursorTravelPoints < 8)
  }

  // MARK: - Event buffer

  @Test func theEventBufferKeepsTheNewest512() {
    var pipeline = MotionPipeline(settings: Synthetic.flatGainSettings)
    for index in 0..<600 {
      pipeline.handle(ScrollButtonPress(direction: .up, time: Double(index) * 0.01))
    }
    // One scrollStarted plus 600 scrollPress events, 89 of them over the cap.
    #expect(pipeline.diagnostics.droppedEvents == 89)
    let drained = pipeline.drainEvents()
    #expect(drained.count == 512)
    #expect(abs((drained.first?.time ?? 0) - 0.88) < 1e-9)
    #expect(abs((drained.last?.time ?? 0) - 5.99) < 1e-9)
    #expect(drained.map(\.time) == drained.map(\.time).sorted())
    #expect(pipeline.drainEvents().isEmpty)
    #expect(pipeline.diagnostics.droppedEvents == 89)
  }

  @Test func drainingEmptiesTheBufferInOrder() {
    var pipeline = MotionPipeline(settings: Synthetic.flatGainSettings)
    pipeline.handle(ScrollButtonPress(direction: .down, time: 3))
    pipeline.recenter()
    pipeline.handle(ScrollButtonPress(direction: .down, time: 3.125))
    let events = pipeline.drainEvents()
    #expect(events.map(\.kind) == [
      .scrollStarted(source: .buttons),
      .scrollPress(direction: .down, pixels: -100),
      .recentered,
      .scrollPress(direction: .down, pixels: -125),
    ])
    // A recenter has no time of its own: it takes the previous input's.
    #expect(events.map(\.time) == [3, 3, 3, 3.125])
    #expect(pipeline.drainEvents().isEmpty)
    #expect(pipeline.diagnostics.droppedEvents == 0)
  }

  @Test func eventsRoundTripThroughJSON() throws {
    let events = [
      PipelineEvent(time: 1.5, kind: .engaged(pitchDegrees: nil, levelCaptured: false)),
      PipelineEvent(time: 2, kind: .engaged(pitchDegrees: 12.5, levelCaptured: true)),
      PipelineEvent(time: 2.1, kind: .levelRejected(pitchDegrees: -33)),
      PipelineEvent(time: 3, kind: .reanchored(reason: .jump)),
      PipelineEvent(time: 3.1, kind: .lifted(riseCm: 3.2, rolledBackPoints: 7)),
      PipelineEvent(time: 3.2, kind: .setDown(dropCm: 2)),
      PipelineEvent(time: 3.3, kind: .jumpRejected(speedMetresPerSecond: 6.5)),
      PipelineEvent(time: 3.4, kind: .trackingChanged(.relocalizing)),
      PipelineEvent(time: 3.5, kind: .gateChanged(from: .open, to: .trackingLost)),
      PipelineEvent(time: 4, kind: .scrollStarted(source: .tilt)),
      PipelineEvent(time: 4.1, kind: .scrollEnded(source: .buttons, pixels: -120)),
      PipelineEvent(time: 4.2, kind: .scrollPress(direction: .up, pixels: 100)),
      PipelineEvent(time: 5, kind: .paused(true)),
      PipelineEvent(time: 5.1, kind: .recentered),
    ]
    let data = try JSONEncoder().encode(events)
    #expect(try JSONDecoder().decode([PipelineEvent].self, from: data) == events)
  }
}
