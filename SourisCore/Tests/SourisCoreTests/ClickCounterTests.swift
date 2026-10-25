import CoreGraphics
import Testing

@testable import SourisCore

struct ClickCounterTests {
  let spot = CGPoint(x: 100, y: 100)

  @Test func singleClickHasStateOne() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
  }

  @Test func doubleClickHasStateTwo() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
    #expect(counter.press(.left, at: spot, time: 0.3) == 2)
  }

  @Test func tripleClickHasStateThree() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
    #expect(counter.press(.left, at: spot, time: 0.2) == 2)
    #expect(counter.press(.left, at: spot, time: 0.4) == 3)
  }

  @Test func pressTooSlowRestartsSequence() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
    #expect(counter.press(.left, at: spot, time: 0.6) == 1)
    // The restarted sequence continues from the 0.6 press.
    #expect(counter.press(.left, at: spot, time: 0.7) == 2)
  }

  @Test func pressExactlyAtMaxIntervalStillContinues() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
    #expect(counter.press(.left, at: spot, time: 0.5) == 2)
  }

  @Test func pressTooFarRestartsSequence() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
    #expect(counter.press(.left, at: CGPoint(x: 120, y: 100), time: 0.1) == 1)
  }

  @Test func pressExactlyAtMaxDistanceStillContinues() {
    var counter = ClickCounter(maxInterval: 0.5, maxDistance: 8)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
    #expect(counter.press(.left, at: CGPoint(x: 108, y: 100), time: 0.1) == 2)
  }

  @Test func otherButtonRestartsSequence() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.press(.left, at: spot, time: 0) == 1)
    #expect(counter.press(.right, at: spot, time: 0.1) == 1)
    #expect(counter.press(.right, at: spot, time: 0.2) == 2)
    #expect(counter.press(.left, at: spot, time: 0.3) == 1)
  }

  @Test func releaseClickStateMatchesLatestPress() {
    var counter = ClickCounter(maxInterval: 0.5)
    #expect(counter.releaseClickState(for: .left) == 1)

    _ = counter.press(.left, at: spot, time: 0)
    #expect(counter.releaseClickState(for: .left) == 1)

    _ = counter.press(.left, at: spot, time: 0.2)
    #expect(counter.releaseClickState(for: .left) == 2)
    #expect(counter.releaseClickState(for: .right) == 1)

    _ = counter.press(.right, at: spot, time: 0.3)
    #expect(counter.releaseClickState(for: .right) == 1)
    #expect(counter.releaseClickState(for: .left) == 1)
  }
}
