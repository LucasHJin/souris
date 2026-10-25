import CoreGraphics
import Testing

@testable import SourisCore

struct CursorTrackerTests {
  let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]

  @Test func positionIsNilBeforeFirstMove() {
    let tracker = CursorTracker()
    #expect(tracker.position == nil)
  }

  @Test func firstMoveStartsFromActualCursor() {
    var tracker = CursorTracker()
    let moved = tracker.target(
      applying: SIMD2(5, -3),
      actual: CGPoint(x: 100, y: 100),
      displays: displays,
      time: 0)
    #expect(moved == CGPoint(x: 105, y: 97))
    #expect(tracker.position == moved)
  }

  @Test func fractionalDeltasAccumulateExactlyWhenActualIsRounded() {
    var tracker = CursorTracker()
    var actual = CGPoint(x: 100, y: 500)
    var posted = actual
    for _ in 0..<100 {
      posted = tracker.target(applying: SIMD2(0.3, 0), actual: actual, displays: displays, time: 0)
      // macOS reports the posted location rounded to whole points.
      actual = CGPoint(x: posted.x.rounded(), y: posted.y.rounded())
    }
    #expect(abs(posted.x - 130) < 1e-9)
    #expect(posted.y == 500)
  }

  @Test func fractionalDeltasAccumulateExactlyWhenActualLagsOneEvent() {
    var tracker = CursorTracker()
    var lagged = CGPoint(x: 100, y: 500)
    var posted = lagged
    for _ in 0..<100 {
      let next = tracker.target(
        applying: SIMD2(0.3, 0),
        actual: lagged,
        displays: displays,
        time: 0)
      // macOS reports the location from one event earlier.
      lagged = posted
      posted = next
    }
    #expect(abs(posted.x - 130) < 1e-9)
  }

  @Test func burstAtOneTimestampKeepsEveryMove() {
    var tracker = CursorTracker()
    _ = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 100, y: 100),
      displays: displays,
      time: 0)

    // macOS still reports the position from before the burst while all 30 moves are posted.
    var posted = CGPoint.zero
    for _ in 0..<30 {
      posted = tracker.target(
        applying: SIMD2(1, 0),
        actual: CGPoint(x: 101, y: 100),
        displays: displays,
        time: 0)
    }
    #expect(posted == CGPoint(x: 131, y: 100))
    #expect(tracker.resyncCount == 0)
  }

  @Test func earlierPostedPositionWithinToleranceStillCountsAsOurs() {
    var tracker = CursorTracker()
    _ = tracker.target(
      applying: SIMD2(100, 0),
      actual: CGPoint(x: 0, y: 0),
      displays: displays,
      time: 0)
    _ = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 100, y: 0),
      displays: displays,
      time: 0)

    // 100.5 is within 1.5 of the earlier post at 100, so the tracker continues from 110.
    let moved = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 100.5, y: 0),
      displays: displays,
      time: 0)
    #expect(moved == CGPoint(x: 111, y: 0))
  }

  @Test func externalMoveBeyondToleranceResyncsToActualCursor() {
    var tracker = CursorTracker()
    _ = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 100, y: 100),
      displays: displays,
      time: 0)

    let moved = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 300, y: 200),
      displays: displays,
      time: 0)
    #expect(moved == CGPoint(x: 301, y: 200))

    // The old positions were dropped, so a cursor back at the old spot resyncs as well.
    let back = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 101, y: 100),
      displays: displays,
      time: 0)
    #expect(back == CGPoint(x: 102, y: 100))
  }

  @Test func farAwayCursorResyncsAndIsCounted() {
    var tracker = CursorTracker()
    _ = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 100, y: 100),
      displays: displays,
      time: 0)
    #expect(tracker.resyncCount == 0)

    let moved = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 300, y: 200),
      displays: displays,
      time: 0.1)
    #expect(moved == CGPoint(x: 301, y: 200))
    #expect(tracker.resyncCount == 1)

    // The first move after reset() starts from the real cursor without counting.
    tracker.reset()
    _ = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 500, y: 500),
      displays: displays,
      time: 0.2)
    #expect(tracker.resyncCount == 1)
  }

  @Test func positionOlderThanHistoryDurationNoLongerCounts() {
    var tracker = CursorTracker(historyDuration: 0.5)
    _ = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 0, y: 0),
      displays: displays,
      time: 0)
    _ = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 10, y: 0),
      displays: displays,
      time: 0.1)

    // The post at 10 is 1 s old, so the real 10 is external. The post at 20 is kept, but 10 is
    // 10 points away from it.
    let moved = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 10, y: 0),
      displays: displays,
      time: 1.0)
    #expect(moved == CGPoint(x: 11, y: 0))
    #expect(tracker.resyncCount == 1)
  }

  @Test func latestPositionCountsEvenWhenOld() {
    var tracker = CursorTracker(historyDuration: 0.5)
    _ = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 0, y: 0),
      displays: displays,
      time: 0)

    // The only post is 5 s old, but it is still the latest, so the real cursor at it is ours.
    let moved = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 10, y: 0),
      displays: displays,
      time: 5)
    #expect(moved == CGPoint(x: 11, y: 0))
    #expect(tracker.resyncCount == 0)
  }

  @Test func positionsBeyondMaxHistoryNoLongerCount() {
    var tracker = CursorTracker(maxHistory: 2)
    _ = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 0, y: 0),
      displays: displays,
      time: 0)
    _ = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 10, y: 0),
      displays: displays,
      time: 0)
    _ = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 20, y: 0),
      displays: displays,
      time: 0)

    // The cap keeps 20 and 30, so the real 10 matches nothing and resyncs.
    let moved = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 10, y: 0),
      displays: displays,
      time: 0)
    #expect(moved == CGPoint(x: 20, y: 0))
    #expect(tracker.resyncCount == 1)
  }

  @Test func clampsAtScreenEdge() {
    var tracker = CursorTracker()
    let atEdge = tracker.target(
      applying: SIMD2(10, 0),
      actual: CGPoint(x: 1915, y: 500),
      displays: displays,
      time: 0)
    #expect(atEdge == CGPoint(x: 1919, y: 500))

    let back = tracker.target(
      applying: SIMD2(-5, 0),
      actual: atEdge,
      displays: displays,
      time: 0)
    #expect(back == CGPoint(x: 1914, y: 500))
  }

  @Test func resetStartsOverFromActualCursor() {
    var tracker = CursorTracker()
    _ = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 100, y: 100),
      displays: displays,
      time: 0)

    tracker.reset()
    #expect(tracker.position == nil)

    let moved = tracker.target(
      applying: SIMD2(1, 0),
      actual: CGPoint(x: 500, y: 500),
      displays: displays,
      time: 0)
    #expect(moved == CGPoint(x: 501, y: 500))
  }
}
