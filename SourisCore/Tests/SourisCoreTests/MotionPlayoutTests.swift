import Foundation
import Testing

@testable import SourisCore

@Suite struct MotionPlayoutTests {
  /// 600 pt/s to the right.
  static let speed: Double = 600

  /// The phone's motion: samples every `interval` from 0 to `duration`, delivered `trip` later
  /// plus whatever `delay(phoneTime)` adds.
  struct Feed {
    var interval: Double = 0.01
    var duration: Double = 2
    var trip: Double = 0.003
    var delay: (Double) -> Double = { _ in 0 }

    var samples: [(phoneTime: Double, arrival: Double)] {
      stride(from: 0.0, through: duration, by: interval).map { time in
        (time, time + trip + delay(time))
      }
    }
  }

  /// Runs `feed` through a playout drawing frames at 120 Hz and returns the total shown at each
  /// frame, with the frame's Mac time.
  static func play(
    _ feed: Feed,
    pacing: PointerPacing,
    position: (Double) -> Double = { $0 * speed }
  ) -> (frames: [(time: Double, x: Double)], playout: MotionPlayout) {
    var playout = MotionPlayout(pacing: pacing)
    let samples = feed.samples.sorted { $0.arrival < $1.arrival }
    var next = 0
    var frames: [(Double, Double)] = []
    for frame in 0...Int((feed.duration + 0.5) * 120) {
      let time = Double(frame) / 120
      while next < samples.count && samples[next].arrival <= time {
        let sample = samples[next]
        playout.add(
          total: SIMD2(position(sample.phoneTime), 0), phoneTime: sample.phoneTime,
          arrival: sample.arrival)
        next += 1
      }
      if let total = playout.frame(at: time) {
        frames.append((time, total.x))
      }
    }
    return (frames, playout)
  }

  static func steps(_ frames: [(time: Double, x: Double)], from start: Double, to end: Double)
    -> [Double]
  {
    let window = frames.filter { $0.time >= start && $0.time <= end }
    return zip(window, window.dropFirst()).map { $1.x - $0.x }
  }

  @Test func smoothPacingMovesTheSameAmountEveryFrame() {
    // 100 Hz samples on a 120 Hz display: showing the newest would move 0 or 6 pt per frame in a
    // beat pattern; interpolating moves 5 pt every frame.
    let (frames, playout) = Self.play(Feed(), pacing: .smooth)
    let steps = Self.steps(frames, from: 0.3, to: 1.8)
    let expected = Self.speed / 120
    #expect(steps.allSatisfy { abs($0 - expected) < 0.05 }, "steps \(steps)")
    // It stays only a sample spacing behind on a steady link.
    #expect(playout.targetDelay < 0.0125, "delay \(playout.targetDelay)")
  }

  @Test func responsivePacingShowsTheNewestMotion() {
    let (frames, _) = Self.play(Feed(), pacing: .responsive)
    for frame in frames where frame.time > 0.3 && frame.time < 1.9 {
      // The newest sample to have arrived by this frame.
      let newest = ((frame.time - 0.003) / 0.01).rounded(.down) * 0.01
      #expect(abs(frame.x - newest * Self.speed) < 1e-6, "at \(frame.time)")
    }
  }

  @Test(arguments: [PointerPacing.smooth, .responsive])
  func aStallPlaysOutInsteadOfJumping(pacing: PointerPacing) {
    // Nothing arrives between 0.8 and 0.95 s; then the 150 ms backlog lands at once.
    var feed = Feed()
    feed.delay = { time in time >= 0.8 && time < 0.95 ? 0.95 - time : 0 }
    let (frames, _) = Self.play(feed, pacing: pacing)
    let steps = Self.steps(frames, from: 0.5, to: 1.5)
    let normal = Self.speed / 120
    let largest = steps.max() ?? 0
    // Played at no more than 3× real time: no 90 pt jump.
    #expect(largest <= normal * MotionPlayout.maxRate + 0.5, "largest \(largest) pt")
    // And within a quarter second of the backlog landing it is no further behind than smoothing
    // ever keeps it (a sample spacing plus the most delay smoothing adds, which it may use for a
    // while after a stall).
    let caughtUp = frames.first { $0.time >= 1.2 }?.x ?? 0
    let limit = (1.2 - 0.003 - 0.01 - MotionPlayout.maxSmoothingDelay) * Self.speed
    #expect(caughtUp >= limit, "\(caughtUp) vs \(limit) pt")
  }

  @Test func aLongStallSkipsAheadToStayWithinTheMaximumLag() {
    var feed = Feed()
    feed.delay = { time in time >= 0.5 && time < 1.1 ? 1.1 - time : 0 }
    let (frames, playout) = Self.play(feed, pacing: .responsive)
    // The backlog arrives at 1.103 s.
    let atLanding = frames.first { $0.time >= 1.105 }?.x ?? 0
    // The cursor jumps to no more than maxLag behind the newest.
    #expect(atLanding >= (1.1 - MotionPlayout.maxLag - 0.02) * Self.speed)
    #expect(playout.stats.skipped > 0.3)
  }

  @Test(arguments: [PointerPacing.smooth, .responsive])
  func motionAfterRestStartsAtOnce(pacing: PointerPacing) {
    // Still (no packets) from 0.2 to 1.2 s, then moving again.
    var feed = Feed()
    feed.duration = 1.6
    let samples = feed.samples.filter { $0.phoneTime <= 0.2 || $0.phoneTime >= 1.2 }
    var playout = MotionPlayout(pacing: pacing)
    var frames: [(time: Double, x: Double)] = []
    var next = 0
    for frame in 0...240 {
      let time = Double(frame) / 120
      while next < samples.count && samples[next].arrival <= time {
        let sample = samples[next]
        let x = sample.phoneTime <= 0.2 ? 0 : (sample.phoneTime - 1.2) * Self.speed
        playout.add(total: SIMD2(x, 0), phoneTime: sample.phoneTime, arrival: sample.arrival)
        next += 1
      }
      if let total = playout.frame(at: time) {
        frames.append((time, total.x))
      }
    }
    // By 30 ms after the motion starts the cursor is moving at full speed, not crawling through
    // the second of stillness.
    let at = { (time: Double) in frames.last { $0.time <= time }?.x ?? 0 }
    #expect(at(1.25) - at(1.2) > 0.03 * Self.speed * 0.6, "\(at(1.2)) → \(at(1.25))")
    #expect(at(1.4) > (1.4 - 1.2 - 0.03) * Self.speed)
  }

  @Test func flushJumpsToTheNewestMotion() {
    var playout = MotionPlayout(pacing: .smooth)
    playout.add(total: SIMD2(0, 0), phoneTime: 0, arrival: 0.003)
    _ = playout.frame(at: 0.004)
    playout.add(total: SIMD2(10, 0), phoneTime: 0.01, arrival: 0.013)
    playout.add(total: SIMD2(20, 0), phoneTime: 0.02, arrival: 0.023)
    #expect(playout.flush() == SIMD2(20, 0))
    #expect(playout.frame(at: 0.024) == SIMD2(20, 0))
  }

  @Test func resetForgetsEverything() {
    var playout = MotionPlayout()
    playout.add(total: SIMD2(5, 5), phoneTime: 1, arrival: 1.01)
    playout.reset()
    #expect(playout.frame(at: 2) == nil)
    #expect(playout.newestTotal == nil)
  }
}
