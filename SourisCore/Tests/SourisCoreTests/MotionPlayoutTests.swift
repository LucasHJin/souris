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
    limits: MotionPlayout.Limits = .forLink(.wifi),
    position: (Double) -> Double = { $0 * speed }
  ) -> (frames: [(time: Double, x: Double)], playout: MotionPlayout) {
    var playout = MotionPlayout(pacing: pacing, limits: limits)
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
      if let shown = playout.frame(at: time) {
        frames.append((time, shown.cursor.x))
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
    let maxDelay = MotionPlayout.Limits.forLink(.wifi).maxSmoothingDelay
    let limit = (1.2 - 0.003 - 0.01 - maxDelay) * Self.speed
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
      if let shown = playout.frame(at: time) {
        frames.append((time, shown.cursor.x))
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
    #expect(playout.flush()?.cursor == SIMD2(20, 0))
    #expect(playout.frame(at: 0.024)?.cursor == SIMD2(20, 0))
  }

  @Test func resetForgetsEverything() {
    var playout = MotionPlayout()
    playout.add(total: SIMD2(5, 5), phoneTime: 1, arrival: 1.01)
    playout.reset()
    #expect(playout.frame(at: 2) == nil)
    #expect(playout.newest == nil)
  }

  @Test func autoIsResponsiveOnTheCableAndSmoothElsewhere() {
    #expect(PointerPacing.auto.resolved(for: .usb) == .responsive)
    #expect(PointerPacing.auto.resolved(for: .bluetooth) == .smooth)
    #expect(PointerPacing.auto.resolved(for: .wifi) == .smooth)
    #expect(PointerPacing.smooth.resolved(for: .usb) == .smooth)
    #expect(PointerPacing.immediate.resolved(for: .bluetooth) == .immediate)
  }

  /// Bluetooth-like delivery: samples every 10 ms, each held until the next 30 ms connection
  /// event, and every tenth event missed.
  static func bluetoothFeed() -> Feed {
    var feed = Feed()
    feed.delay = { time in
      let event = (time / 0.03).rounded(.up)
      let next = Int(event) % 10 == 0 ? event + 1 : event
      return next * 0.03 - time
    }
    return feed
  }

  @Test func bluetoothMayDelayMoreThanWiFi() {
    let (_, bluetooth) = Self.play(
      Self.bluetoothFeed(), pacing: .smooth, limits: .forLink(.bluetooth))
    let (_, wifi) = Self.play(Self.bluetoothFeed(), pacing: .smooth, limits: .forLink(.wifi))
    #expect(wifi.targetDelay <= 0.03 + 1e-9)
    #expect(bluetooth.targetDelay > 0.03, "delay \(bluetooth.targetDelay)")
    #expect(bluetooth.targetDelay <= 0.08 + 1e-9)
  }

  @Test func coastingKeepsTheCursorMovingThroughAMissedEvent() {
    var limits = MotionPlayout.Limits.forLink(.bluetooth)
    // A delay too short for the missed events, so the playhead runs out at each one.
    limits.maxSmoothingDelay = 0.035
    let coasting = Self.play(Self.bluetoothFeed(), pacing: .smooth, limits: limits)
    limits.maxCoast = 0
    let holding = Self.play(Self.bluetoothFeed(), pacing: .smooth, limits: limits)
    let normal = Self.speed / 120
    func stalls(_ frames: [(time: Double, x: Double)]) -> Int {
      Self.steps(frames, from: 0.3, to: 1.8).filter { $0 < normal * 0.3 }.count
    }
    #expect(coasting.playout.stats.coastFrames > 0)
    #expect(stalls(coasting.frames) < stalls(holding.frames), "\(stalls(coasting.frames))")
    // Never runs backwards while the hand moves steadily.
    #expect(Self.steps(coasting.frames, from: 0.3, to: 1.8).allSatisfy { $0 > -0.01 })
  }

  @Test func skippedPacketsPlayOutAsMotionNotRests() {
    // The phone builds a state every 10 ms but Bluetooth sends only the newest every 60 ms, as in
    // the 2026-10-25 test, so five of every six never arrive. Read as rests, each gap froze the
    // cursor and then crammed its motion into 10 ms, and coasts ran on six times the real speed.
    var playout = MotionPlayout(pacing: .smooth, limits: .forLink(.bluetooth))
    var frames: [(time: Double, x: Double)] = []
    var phoneTime = 0.0
    for frame in 0...300 {
      let time = Double(frame) / 120
      while phoneTime + 0.02 <= time {
        playout.add(
          total: SIMD2(phoneTime * Self.speed, 0), phoneTime: phoneTime,
          arrival: phoneTime + 0.02, missedPackets: phoneTime == 0 ? 0 : 5)
        phoneTime += 0.06
      }
      if let shown = playout.frame(at: time) {
        frames.append((time, shown.cursor.x))
      }
    }
    let normal = Self.speed / 120
    let steps = Self.steps(frames, from: 0.5, to: 2.2)
    #expect(steps.allSatisfy { abs($0 - normal) < normal * 0.25 }, "steps \(steps)")
    #expect(
      playout.stats.maxCoastOffset <= Self.speed * MotionPlayout.coastDamping + 0.5,
      "coast \(playout.stats.maxCoastOffset) pt")
  }

  @Test func aCoastPastAStopSettlesBackWhereThePhoneStopped() {
    // Moving at 600 pt/s until 1 s, then still: the phone sends nothing more.
    var feed = Feed()
    feed.duration = 1
    let (frames, _) = Self.play(feed, pacing: .smooth, limits: .forLink(.bluetooth))
    let stop = Self.speed * 1
    let overshoot = (frames.map(\.x).max() ?? 0) - stop
    // At most the speed times the damping time.
    #expect(overshoot <= Self.speed * MotionPlayout.coastDamping + 0.5, "\(overshoot) pt")
    #expect(abs((frames.last?.x ?? 0) - stop) < 0.05)
  }

  @Test func theCableNeverCoasts() {
    let (_, playout) = Self.play(
      Self.bluetoothFeed(), pacing: .smooth, limits: .forLink(.usb))
    #expect(playout.stats.coastFrames == 0)
  }

  @Test func relinkMeasuresTheNewLinkAfresh() {
    // 3 ms trips, then a link whose trips are 40 ms: without relinking, every packet looks 37 ms
    // late and the delay sits at its cap.
    var playout = MotionPlayout(pacing: .smooth, limits: .forLink(.bluetooth))
    var time = 0.0
    while time < 1 {
      playout.add(total: SIMD2(time * 600, 0), phoneTime: time, arrival: time + 0.003)
      time += 0.01
    }
    playout.relink()
    while time < 2 {
      playout.add(total: SIMD2(time * 600, 0), phoneTime: time, arrival: time + 0.04)
      time += 0.01
    }
    #expect(playout.targetDelay < 0.015, "delay \(playout.targetDelay)")
  }

  @Test func scrollingIsInterpolatedLikeTheCursor() {
    // 1000 px/s of scrolling in 100 Hz samples: on a 120 Hz display every frame scrolls 8.3 px.
    let (frames, _) = Self.play(Feed(), pacing: .smooth, position: { _ in 0 })
    #expect(frames.allSatisfy { $0.x == 0 })
    var playout = MotionPlayout(pacing: .smooth)
    var scrolled: [Double] = []
    var next = 0.0
    for frame in 0...240 {
      let time = Double(frame) / 120
      while next + 0.003 <= time {
        playout.add(
          total: .zero, scroll: SIMD2(0, next * 1000), phoneTime: next, arrival: next + 0.003)
        next += 0.01
      }
      if let shown = playout.frame(at: time), time > 0.3 {
        scrolled.append(shown.scroll.y)
      }
    }
    let steps = zip(scrolled, scrolled.dropFirst()).map { $1 - $0 }
    #expect(steps.allSatisfy { abs($0 - 1000.0 / 120) < 0.1 }, "steps \(steps)")
  }
}

@Suite struct PacedScrollTests {
  @Test func aGestureIsBracketedByBeganAndEndedOnceShown() {
    var scroll = PacedScroll()
    scroll.receive([ScrollEvent(phase: .began, delta: SIMD2(0, 10))])
    scroll.receive([ScrollEvent(phase: .changed, delta: SIMD2(0, 10))])
    scroll.receive([ScrollEvent(phase: .ended, delta: .zero)])
    #expect(scroll.show(SIMD2(0, 5)) == [ScrollEvent(phase: .began, delta: SIMD2(0, 5))])
    // Ended only once everything received is shown.
    #expect(scroll.show(SIMD2(0, 12)) == [ScrollEvent(phase: .changed, delta: SIMD2(0, 7))])
    #expect(
      scroll.show(SIMD2(0, 20)) == [
        ScrollEvent(phase: .changed, delta: SIMD2(0, 8)),
        ScrollEvent(phase: .ended, delta: .zero),
      ])
    #expect(scroll.show(SIMD2(0, 20)).isEmpty)
  }

  @Test func aGestureThatBeginsDuringThePlayoutContinuesTheLastOne() {
    var scroll = PacedScroll()
    scroll.receive([ScrollEvent(phase: .began, delta: SIMD2(0, 10))])
    scroll.receive([ScrollEvent(phase: .ended, delta: .zero)])
    _ = scroll.show(SIMD2(0, 4))
    scroll.receive([ScrollEvent(phase: .began, delta: SIMD2(0, 10))])
    #expect(scroll.show(SIMD2(0, 20)) == [ScrollEvent(phase: .changed, delta: SIMD2(0, 16))])
  }

  @Test func cancelEndsAnOpenGestureAndStartsOver() {
    var scroll = PacedScroll()
    scroll.receive([ScrollEvent(phase: .began, delta: SIMD2(0, 10))])
    _ = scroll.show(SIMD2(0, 4))
    #expect(scroll.cancel() == [ScrollEvent(phase: .ended, delta: .zero)])
    #expect(scroll.received == .zero)
    #expect(scroll.cancel().isEmpty)
  }
}
