import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct TranslationPredictorTests {
  /// Constant acceleration from rest: linear between readings, so integration is exact.
  static let acceleration = SIMD3<Double>(1, 0, -0.6)

  static func truth(_ time: Double) -> SIMD3<Double> {
    0.5 * acceleration * time * time
  }

  /// Feeds 100 Hz readings and 60 Hz fixes up to `duration`, each fix arriving 40 ms after its
  /// capture, and returns the worst prediction error (metres) at the readings after `settle`.
  static func run(
    readingSign: Double,
    duration: Double = 1.5,
    settle: Double = 1
  ) -> (predictor: TranslationPredictor, worstError: Double) {
    var predictor = TranslationPredictor()
    var settings = PipelineSettings.Prediction()
    settings.positionNoise = 0.0001
    var worst: Double = 0
    var nextFix = 0
    for index in 0...Int(duration * 100) {
      let time = Double(index) / 100
      predictor.add(acceleration: readingSign * acceleration, at: time)
      while Double(nextFix) / 60 + 0.04 <= time {
        let capture = Double(nextFix) / 60
        predictor.add(fix: truth(capture), at: capture, settings: settings)
        nextFix += 1
      }
      if time > settle, let predicted = predictor.position(at: time, maxHorizon: 0.1) {
        worst = max(worst, simd_length(predicted - truth(time)))
      }
    }
    return (predictor, worst)
  }

  @Test func theSignCheckConfirmsThePhysicsSign() {
    let (predictor, _) = Self.run(readingSign: 1)
    #expect(predictor.sign == 1)
    if case .confirmed(_, let correlation) = predictor.signCheck.result {
      #expect(correlation > 0.99)
    } else {
      Issue.record("not confirmed: \(predictor.signCheck.result)")
    }
  }

  @Test func theSignCheckCatchesTheOtherSign() {
    let (predictor, _) = Self.run(readingSign: -1)
    #expect(predictor.sign == -1)
  }

  @Test func thePredictionMatchesTheTruthNow() {
    let (_, worst) = Self.run(readingSign: 1)
    #expect(worst < 0.0002, "worst \(worst * 1000) mm")
  }

  @Test func theOtherSignPredictsJustAsWellOnceDetected() {
    let (_, worst) = Self.run(readingSign: -1)
    #expect(worst < 0.0002, "worst \(worst * 1000) mm")
  }

  @Test func withoutMotionTheCheckWaitsAndNothingIsPredicted() {
    var predictor = TranslationPredictor()
    for index in 0...200 {
      let time = Double(index) / 100
      predictor.add(acceleration: .zero, at: time)
      if index % 2 == 0 {
        predictor.add(fix: .zero, at: time, settings: PipelineSettings.Prediction())
      }
    }
    #expect(predictor.signCheck.result == .pending)
    #expect(predictor.position(at: 2, maxHorizon: 0.1) == nil)
  }

  @Test func uncorrelatedAccelerationFailsTheCheck() {
    // Readings that turn a quarter turn away from the real motion never line up with it.
    var check = AccelerationSignCheck()
    for index in 0..<AccelerationSignCheck.giveUpWindows {
      let angle = Double(index) * 0.7
      let arkit = SIMD2(cos(angle), sin(angle))
      check.add(arkit: arkit, motion: SIMD2(-arkit.y, arkit.x))
    }
    if case .failed(let correlation) = check.result {
      #expect(abs(correlation) < 0.1)
    } else {
      Issue.record("expected failed, got \(check.result)")
    }
  }

  @Test func predictionStopsPastTheHorizon() {
    let (predictor, _) = Self.run(readingSign: 1)
    // The last fix was captured at 1.45 s (it arrived by 1.49 s).
    #expect(predictor.position(at: 1.5, maxHorizon: 0.1) != nil)
    #expect(predictor.position(at: 1.6, maxHorizon: 0.1) == nil)
  }
}

@Suite struct MotionPredictionTests {
  /// Side to side for two seconds (about 1.7 m/s² peaks, enough for the sign check), still until
  /// 2.5 s, then a 10 cm slide right that ends at 3 s.
  static func wiggleThenSlide(duration: Double = 4) -> SyntheticSession {
    var session = SyntheticSession(duration: duration)
    session.providesAcceleration = true
    session.path.position = { time in
      let wiggle = time < 2 ? 0.03 * sin(2 * .pi * 1.2 * time) : 0
      let slide = 0.1 * Synthetic.ramp(time, 2.5, 3)
      return Synthetic.rest + SIMD3(wiggle + slide, 0, 0)
    }
    return session
  }

  static var unpredicted: PipelineSettings {
    var settings = Synthetic.flatGainSettings
    settings.prediction.isEnabled = false
    return settings
  }

  @Test func theWiggleConfirmsTheSignAndTurnsPredictionOn() {
    let steps = Self.wiggleThenSlide().replay()
    let checks = steps.events.compactMap { event -> Double?? in
      if case .predictionChecked(let sign, _) = event.kind { return sign }
      return nil
    }
    #expect(checks == [1])
    #expect(steps.last?.diagnostics.prediction == .on)
    #expect(steps.step(at: 0.3).diagnostics.prediction == .checking)
  }

  @Test(arguments: [1.0, -1.0])
  func predictionLeadsTheSlideAndEndsInTheSamePlace(sign: Double) {
    var session = Self.wiggleThenSlide()
    session.accelerationSign = sign
    let predicted = session.replay()
    let plain = session.replay(Self.unpredicted)
    // At the slide's peak speed (0.31 m/s), 45 ms of ARKit delay is 14 mm, 35 pt at 2.5 pt/mm.
    for time in stride(from: 2.65, through: 2.85, by: 0.05) {
      let lead = (predicted.cursor(at: time).x - predicted.cursor(at: 2.45).x)
        - (plain.cursor(at: time).x - plain.cursor(at: 2.45).x)
      #expect(lead > 15, "lead \(lead) pt at \(time) s")
    }
    let travel = predicted.finalCursor.x - predicted.cursor(at: 2.45).x
    let plainTravel = plain.finalCursor.x - plain.cursor(at: 2.45).x
    #expect(abs(travel - plainTravel) < 1, "\(travel) vs \(plainTravel) pt")
  }

  @Test func predictionUpdatesTheSlideOnEveryCoreMotionSample() {
    // Without gyro assist only ARKit frames moved the cursor; with prediction, the Core Motion
    // samples between them do too.
    var settings = Synthetic.flatGainSettings
    settings.pointer.gyroAssist = false
    let steps = Self.wiggleThenSlide().replay(settings)
    let slide = steps.filter { $0.time > 2.6 && $0.time < 2.9 }
    var moves = 0
    for (previous, step) in zip(slide, slide.dropFirst())
    where step.state.cursor != previous.state.cursor {
      moves += 1
    }
    // 0.3 s holds 18 ARKit frames and 30 Core Motion samples.
    #expect(moves > 40, "\(moves) moves")
  }

  @Test func withoutAccelerationNothingChanges() {
    var session = Self.wiggleThenSlide()
    session.providesAcceleration = false
    let predicted = session.replay()
    let plain = session.replay(Self.unpredicted)
    #expect(predicted.last?.diagnostics.prediction == .checking)
    for time in stride(from: 0.5, through: 4, by: 0.25) {
      #expect(simd_length(predicted.cursor(at: time) - plain.cursor(at: time)) < 1e-9)
    }
  }

  @Test func predictionDoesNotAddRestJitter() {
    // With 1 mm of ARKit noise and an exact accelerometer, the resting cursor after the slide is
    // steadier with prediction on average. The prediction's leftover noise is slow, so 1.5 s holds
    // few independent swings and one seed can still come out up to 20% shakier.
    var ratios: [Double] = []
    for seed in MotionNoiseTests.seeds {
      var session = Self.wiggleThenSlide(duration: 5)
      session.positionNoise = 0.001
      session.seed = seed
      let predicted = session.replay()
      let plain = session.replay(Self.unpredicted)
      #expect(predicted.last?.diagnostics.prediction == .on)
      ratios.append(Self.restingSpread(predicted) / Self.restingSpread(plain))
    }
    #expect(ratios.allSatisfy { $0 < 1.2 }, "ratios \(ratios)")
    #expect(ratios.reduce(0, +) / Double(ratios.count) < 1, "ratios \(ratios)")
  }

  /// RMS distance of the cursor from its mean once the slide has settled, points.
  static func restingSpread(_ steps: [RecordingReplay.Step]) -> Double {
    let resting = steps.filter { $0.time > 3.5 }.map(\.state.cursor)
    let center = resting.reduce(.zero, +) / Double(resting.count)
    let total = resting.map { simd_length_squared($0 - center) }.reduce(0, +)
    return (total / Double(resting.count)).squareRoot()
  }

  @Test func turningPredictionOffMidSlideFadesRatherThanJumps() {
    var session = Self.wiggleThenSlide()
    var off = Synthetic.flatGainSettings
    off.prediction.isEnabled = false
    session.inserts.append((2.7, .settings(off)))
    let steps = session.replay()
    let around = steps.filter { $0.time > 2.6 && $0.time < 3.0 }
    var largest: Double = 0
    for (previous, step) in zip(around, around.dropFirst()) {
      largest = max(largest, abs(step.state.cursor.x - previous.state.cursor.x))
    }
    // Steps are about 5 pt at this speed; dropping the 35 pt lead at once would show as one.
    #expect(largest < 12, "largest step \(largest) pt")
  }
}
