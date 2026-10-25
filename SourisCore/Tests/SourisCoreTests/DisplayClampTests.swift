import CoreGraphics
import Testing

@testable import SourisCore

struct DisplayClampTests {
  let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)

  @Test func pointInsideDisplayIsUnchanged() {
    let point = CGPoint(x: 100, y: 200)
    #expect(DisplayClamp.clamp(point, previous: point, displays: [main]) == point)
  }

  @Test func pointPastRightEdgeClampsToLastColumn() {
    let result = DisplayClamp.clamp(
      CGPoint(x: 2000, y: 500),
      previous: CGPoint(x: 1900, y: 500),
      displays: [main])
    #expect(result == CGPoint(x: 1919, y: 500))
  }

  @Test func pointOnRightEdgeOfPixelRangeIsOutside() {
    // maxX is one past the last column, so x == 1920 is off the display.
    let result = DisplayClamp.clamp(
      CGPoint(x: 1920, y: 500),
      previous: CGPoint(x: 1900, y: 500),
      displays: [main])
    #expect(result == CGPoint(x: 1919, y: 500))
  }

  @Test func pointPastTopEdgeClampsToMinY() {
    let result = DisplayClamp.clamp(
      CGPoint(x: 500, y: -20),
      previous: CGPoint(x: 500, y: 10),
      displays: [main])
    #expect(result == CGPoint(x: 500, y: 0))
  }

  @Test func pointPastDiagonalCornerClampsBothAxes() {
    let result = DisplayClamp.clamp(
      CGPoint(x: -50, y: 2000),
      previous: CGPoint(x: 10, y: 10),
      displays: [main])
    #expect(result == CGPoint(x: 0, y: 1079))
  }

  @Test func crossingIntoSecondSideBySideDisplayIsAllowed() {
    let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    let point = CGPoint(x: 2000, y: 500)
    let result = DisplayClamp.clamp(
      point,
      previous: CGPoint(x: 1900, y: 500),
      displays: [main, right])
    #expect(result == point)
  }

  @Test func movingIntoGapBetweenOffsetDisplaysClampsToPreviousDisplay() {
    let first = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let second = CGRect(x: 1500, y: 0, width: 1000, height: 1000)

    // Coming from the first display, the point stops at its right edge.
    let fromFirst = DisplayClamp.clamp(
      CGPoint(x: 1200, y: 500),
      previous: CGPoint(x: 990, y: 500),
      displays: [first, second])
    #expect(fromFirst == CGPoint(x: 999, y: 500))

    // Coming from the second display, it stops at that display's left edge.
    let fromSecond = DisplayClamp.clamp(
      CGPoint(x: 1200, y: 500),
      previous: CGPoint(x: 1600, y: 500),
      displays: [first, second])
    #expect(fromSecond == CGPoint(x: 1500, y: 500))
  }

  @Test func offScreenPreviousUsesNearestDisplay() {
    let first = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let second = CGRect(x: 1500, y: 0, width: 1000, height: 1000)
    let previous = CGPoint(x: 1200, y: 500)

    // In the gap, 1300 is 200 from the second display and 301 from the first.
    let towardSecond = DisplayClamp.clamp(
      CGPoint(x: 1300, y: 500),
      previous: previous,
      displays: [first, second])
    #expect(towardSecond == CGPoint(x: 1500, y: 500))

    // In the gap, 1100 is 101 from the first display and 400 from the second.
    let towardFirst = DisplayClamp.clamp(
      CGPoint(x: 1100, y: 500),
      previous: previous,
      displays: [first, second])
    #expect(towardFirst == CGPoint(x: 999, y: 500))
  }

  @Test func displayWithNegativeOriginToTheLeftIsUsed() {
    let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let mainDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let displays = [left, mainDisplay]

    #expect(
      DisplayClamp.clamp(
        CGPoint(x: -2000, y: 500),
        previous: CGPoint(x: -1000, y: 500),
        displays: displays) == CGPoint(x: -1920, y: 500))

    let inside = CGPoint(x: -1000, y: 300)
    #expect(DisplayClamp.clamp(inside, previous: inside, displays: displays) == inside)
  }

  @Test func displayAboveMainWithNegativeYIsUsed() {
    let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    let displays = [main, above]

    let result = DisplayClamp.clamp(
      CGPoint(x: 500, y: -2000),
      previous: CGPoint(x: 500, y: -500),
      displays: displays)
    #expect(result == CGPoint(x: 500, y: -1080))
  }

  @Test func noDisplaysLeavesPointUnchanged() {
    let point = CGPoint(x: 5000, y: -300)
    #expect(DisplayClamp.clamp(point, previous: .zero, displays: []) == point)
  }
}
