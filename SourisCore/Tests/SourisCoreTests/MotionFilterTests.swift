import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct MotionFilterTests {
  static let pointer = PipelineSettings.Pointer()

  static func update(
    _ filter: inout OneEuroFilter2D,
    _ point: SIMD2<Double>,
    _ time: Double,
    beta: Double = pointer.filterBeta
  ) -> SIMD2<Double> {
    filter.update(
      point,
      time: time,
      minimumCutoff: pointer.filterMinCutoff,
      beta: beta,
      derivativeCutoff: pointer.filterDerivativeCutoff)
  }

  @Test func convergesOnAConstant() {
    var filter = OneEuroFilter2D()
    _ = Self.update(&filter, .zero, 0)
    let target = SIMD2<Double>(5, -3)
    var value = SIMD2<Double>.zero
    for index in 1...200 {
      value = Self.update(&filter, target, Double(index) * 0.01)
    }
    #expect(simd_length(value - target) < 1e-3)
    #expect(filter.speed < 0.1)
  }

  @Test func ignoresUpdatesWithoutTimePassing() {
    var filter = OneEuroFilter2D()
    _ = Self.update(&filter, SIMD2(1, 1), 1)
    let same = Self.update(&filter, SIMD2(50, 50), 1)
    let tiny = Self.update(&filter, SIMD2(50, 50), 1 + 5e-5)
    let backwards = Self.update(&filter, SIMD2(50, 50), 0.5)
    #expect(same == SIMD2(1, 1))
    #expect(tiny == SIMD2(1, 1))
    #expect(backwards == SIMD2(1, 1))
    #expect(filter.speed == 0)
  }

  @Test func cutoffRisesWithSpeed() {
    let slow = OneEuroFilter2D.cutoff(speed: 10, minimumCutoff: 1.5, beta: 0.05)
    let fast = OneEuroFilter2D.cutoff(speed: 200, minimumCutoff: 1.5, beta: 0.05)
    #expect(OneEuroFilter2D.cutoff(speed: 0, minimumCutoff: 1.5, beta: 0.05) == 1.5)
    #expect(fast > slow)
  }

  @Test func speedShortensTheLag() {
    // A 100 mm/s diagonal ramp: with beta the filter tracks it more closely.
    var adaptive = OneEuroFilter2D()
    var fixed = OneEuroFilter2D()
    var lastAdaptive = SIMD2<Double>.zero
    var lastFixed = SIMD2<Double>.zero
    var input = SIMD2<Double>.zero
    for index in 0...50 {
      let time = Double(index) * 0.01
      input = SIMD2(70.71, 70.71) * time
      lastAdaptive = Self.update(&adaptive, input, time)
      lastFixed = Self.update(&fixed, input, time, beta: 0)
    }
    #expect(simd_length(input - lastAdaptive) < 0.6 * simd_length(input - lastFixed))
    // One shared cutoff keeps a diagonal on the diagonal.
    #expect(abs(lastAdaptive.x - lastAdaptive.y) < 1e-9)
  }

  @Test func gainCurveEndpoints() {
    var pointer = PipelineSettings.Pointer()
    pointer.speedScale = 2
    let slow = pointer.slowGain * pointer.speedScale
    #expect(GainCurve.gain(speed: 0, settings: pointer) == slow)
    #expect(GainCurve.gain(speed: pointer.slowSpeed, settings: pointer) == slow)
    let fast = slow * pointer.accelerationRatio
    #expect(abs(GainCurve.gain(speed: pointer.fastSpeed, settings: pointer) - fast) < 1e-12)
    #expect(abs(GainCurve.gain(speed: 10_000, settings: pointer) - fast) < 1e-12)
  }

  @Test func gainCurveIsMonotonic() {
    let pointer = PipelineSettings.Pointer()
    var previous = 0.0
    for speed in stride(from: 0.0, through: 400, by: 0.5) {
      let gain = GainCurve.gain(speed: speed, settings: pointer)
      #expect(gain >= previous)
      previous = gain
    }
  }

  @Test func gainCurveWithCrossedEdgesIsAStep() {
    #expect(GainCurve.smoothstep(50, 50, 49) == 0)
    #expect(GainCurve.smoothstep(50, 50, 50) == 1)
    #expect(GainCurve.smoothstep(0, 10, 5) == 0.5)
  }

  @Test(arguments: [true, false])
  func aFlickReachesFastGainPromptly(gyroAssist: Bool) {
    // A step from rest to 300 mm/s at 1 s (capture); ARKit delivers 45 ms later.
    var session = SyntheticSession(duration: 1.6)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.3 * min(max(time - 1, 0), 0.4), 0, 0)
    }
    var settings = PipelineSettings()
    settings.pointer.gyroAssist = gyroAssist
    let steps = session.replay(settings)
    let slow = settings.pointer.slowGain * settings.pointer.speedScale
    let fast = slow * settings.pointer.accelerationRatio
    #expect(abs(steps.step(at: 1.04).diagnostics.gain - slow) < 1e-9)
    let gain = steps.step(at: 1.045 + 0.1).diagnostics.gain
    #expect(gain > 0.8 * fast, "gain \(gain) of \(fast) after 100 ms")
    // ARKit's 60 Hz staircase makes the speed wobble between frames, so average it.
    let cruising = steps.filter { $0.time > 1.2 && $0.time < 1.4 }
    let speed = cruising.map(\.diagnostics.speedMmPerSecond).reduce(0, +)
      / Double(cruising.count)
    #expect(abs(speed - 300) < 15, "speed \(speed) mm/s")
  }

  @Test func ringBufferKeepsTheNewestElements() {
    var buffer = RingBuffer<Int>(capacity: 3)
    for value in 1...5 {
      buffer.append(value)
    }
    #expect(buffer.count == 3)
    #expect(buffer.first == 3)
    #expect(buffer.last == 5)
    buffer.removeFirst()
    #expect(buffer[0] == 4)
    buffer.removeAll()
    #expect(buffer.isEmpty)
  }

  @Test func jitterMeterReadsTheRMSSpread() {
    var meter = JitterMeter()
    // ±1 mm along x, alternating: RMS about the mean is 1 mm.
    for index in 0..<40 {
      let x: Double = index.isMultiple(of: 2) ? 1001 : 999
      meter.record(SIMD2(x, 2000), time: Double(index) * 0.01)
    }
    #expect(abs(meter.rms - 1) < 1e-6)
  }
}
