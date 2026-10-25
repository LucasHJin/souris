import CoreGraphics
import Testing

@testable import SourisCore

/// The classifier uses a 0.25 s two-finger window and a 0.125 s minimum press, so every expected
/// time is exact in binary floating point.
struct TouchClassifierTests {
  let surface = CGSize(width: 400, height: 800)
  let top = CGPoint(x: 200, y: 100)
  let bottom = CGPoint(x: 200, y: 600)
  let noButtons = MouseButtons()

  func makeClassifier() -> TouchClassifier {
    var settings = TouchSettings()
    settings.twoFingerWindow = 0.25
    settings.minimumPressDuration = 0.125
    return TouchClassifier(settings: settings)
  }

  @Test func singleTapPressesAtDeadlineAndReleasesAtLift() {
    var classifier = makeClassifier()

    let began = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    #expect(began == [.contact(time: 0)])
    #expect(classifier.nextDeadline == 0.25)

    let deadline = classifier.advance(to: 0.25)
    #expect(deadline == [.button(.left, isDown: true, time: 0.25)])
    #expect(classifier.heldButtons == .left)

    let ended = classifier.touchEnded(id: 1, time: 0.5)
    #expect(
      ended == [
        .contact(time: 0.5),
        .button(.left, isDown: false, time: 0.5),
      ])
    #expect(classifier.heldButtons == noButtons)
    #expect(classifier.nextDeadline == nil)
  }

  @Test func quickTapPressesAtLiftAndReleasesAfterMinimumPressDuration() {
    var classifier = makeClassifier()

    let began = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    #expect(began == [.contact(time: 0)])

    let ended = classifier.touchEnded(id: 1, time: 0.0625)
    #expect(
      ended == [
        .button(.left, isDown: true, time: 0.0625),
        .contact(time: 0.0625),
      ])
    #expect(classifier.heldButtons == .left)
    #expect(classifier.nextDeadline == 0.1875)

    #expect(classifier.advance(to: 0.1) == [])
    #expect(classifier.heldButtons == .left)

    #expect(classifier.advance(to: 0.1875) == [.button(.left, isDown: false, time: 0.1875)])
    #expect(classifier.heldButtons == noButtons)
    #expect(classifier.nextDeadline == nil)
  }

  @Test func holdForDragPressesAtDeadlineAndWaitsForLift() {
    var classifier = makeClassifier()

    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    #expect(classifier.advance(to: 0.25) == [.button(.left, isDown: true, time: 0.25)])
    #expect(classifier.advance(to: 2.0) == [])

    let ended = classifier.touchEnded(id: 1, time: 2.0)
    #expect(
      ended == [
        .contact(time: 2.0),
        .button(.left, isDown: false, time: 2.0),
      ])
  }

  @Test func twoFingersWithinWindowMakeRightClick() {
    var classifier = makeClassifier()

    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    let second = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.0625)
    #expect(
      second == [
        .contact(time: 0.0625),
        .button(.right, isDown: true, time: 0.0625),
      ])
    #expect(classifier.heldButtons == .right)
    #expect(classifier.nextDeadline == nil)

    // No left press follows, even well after the window would have closed.
    #expect(classifier.advance(to: 1.0) == [])

    #expect(classifier.touchEnded(id: 1, time: 0.125) == [.contact(time: 0.125)])
    #expect(classifier.heldButtons == .right)

    let released = classifier.touchEnded(id: 2, time: 0.1875)
    #expect(
      released == [
        .contact(time: 0.1875),
        .button(.right, isDown: false, time: 0.1875),
      ])
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func rightButtonReleasesOnlyAfterBothFingersLiftWhenFirstFingerLiftsFirst() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    _ = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.0625)

    #expect(classifier.touchEnded(id: 1, time: 0.125) == [.contact(time: 0.125)])
    #expect(classifier.heldButtons == .right)

    #expect(
      classifier.touchEnded(id: 2, time: 0.1875) == [
        .contact(time: 0.1875),
        .button(.right, isDown: false, time: 0.1875),
      ])
  }

  @Test func rightButtonReleasesOnlyAfterBothFingersLiftWhenSecondFingerLiftsFirst() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    _ = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.0625)

    #expect(classifier.touchEnded(id: 2, time: 0.125) == [.contact(time: 0.125)])
    #expect(classifier.heldButtons == .right)

    #expect(
      classifier.touchEnded(id: 1, time: 0.1875) == [
        .contact(time: 0.1875),
        .button(.right, isDown: false, time: 0.1875),
      ])
  }

  @Test func secondFingerAfterWindowIsIgnoredAndLeftPressStays() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)

    // The window closed at 0.25, so the left press is emitted first and this finger is an extra.
    let late = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.5)
    #expect(late == [.button(.left, isDown: true, time: 0.25)])
    #expect(classifier.heldButtons == .left)

    #expect(classifier.touchEnded(id: 2, time: 0.75) == [])
    #expect(classifier.heldButtons == .left)

    #expect(
      classifier.touchEnded(id: 1, time: 1.0) == [
        .contact(time: 1.0),
        .button(.left, isDown: false, time: 1.0),
      ])
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func secondFingerExactlyAtDeadlineStillMakesRightClick() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)

    let second = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.25)
    #expect(
      second == [
        .contact(time: 0.25),
        .button(.right, isDown: true, time: 0.25),
      ])
  }

  @Test func bottomHalfTouchIsIgnoredEntirely() {
    var classifier = makeClassifier()

    #expect(classifier.touchBegan(id: 1, location: bottom, in: surface, time: 0) == [])
    #expect(classifier.touchEnded(id: 1, time: 0.0625) == [])
    #expect(classifier.touchEnded(id: 99, time: 0.0625) == [])
    #expect(classifier.nextDeadline == nil)

    // The bottom touch isn't a finger, so this one opens a window alone and makes a left press.
    #expect(classifier.touchBegan(id: 2, location: top, in: surface, time: 0.125) == [
      .contact(time: 0.125)
    ])
    #expect(classifier.advance(to: 0.375) == [.button(.left, isDown: true, time: 0.375)])
    #expect(
      classifier.touchEnded(id: 2, time: 0.5) == [
        .contact(time: 0.5),
        .button(.left, isDown: false, time: 0.5),
      ])
  }

  @Test func palmRestingInBottomHalfDoesNotBlockTap() {
    var classifier = makeClassifier()

    _ = classifier.touchBegan(id: 1, location: bottom, in: surface, time: 0)
    _ = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.0625)
    #expect(
      classifier.touchEnded(id: 2, time: 0.125) == [
        .button(.left, isDown: true, time: 0.125),
        .contact(time: 0.125),
      ])
    #expect(classifier.advance(to: 0.25) == [.button(.left, isDown: false, time: 0.25)])

    #expect(classifier.touchEnded(id: 1, time: 0.5) == [])
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func sideBandTouchIsIgnored() {
    var classifier = makeClassifier()
    let leftEdge = CGPoint(x: 2, y: 100)
    let rightEdge = CGPoint(x: 398, y: 100)

    #expect(classifier.touchBegan(id: 1, location: leftEdge, in: surface, time: 0) == [])
    #expect(classifier.touchBegan(id: 2, location: rightEdge, in: surface, time: 0) == [])
    #expect(classifier.touchEnded(id: 1, time: 0.0625) == [])
    #expect(classifier.touchEnded(id: 2, time: 0.0625) == [])
    #expect(classifier.nextDeadline == nil)
  }

  @Test func touchExactlyOnSideBandEdgeIsAccepted() {
    var classifier = makeClassifier()
    let edge = CGPoint(x: 6, y: 100)

    #expect(classifier.touchBegan(id: 1, location: edge, in: surface, time: 0) == [
      .contact(time: 0)
    ])
  }

  @Test func extraFingerDuringHeldLeftButtonIsIgnored() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    _ = classifier.advance(to: 0.25)

    #expect(classifier.touchBegan(id: 2, location: top, in: surface, time: 0.3) == [])
    #expect(classifier.touchBegan(id: 3, location: top, in: surface, time: 0.4) == [])
    #expect(classifier.heldButtons == .left)

    #expect(
      classifier.touchEnded(id: 1, time: 0.5) == [
        .contact(time: 0.5),
        .button(.left, isDown: false, time: 0.5),
      ])
    #expect(classifier.touchEnded(id: 2, time: 0.6) == [])
    #expect(classifier.touchEnded(id: 3, time: 0.7) == [])
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func extraFingersAreIgnoredOnlyUntilTheyLiftAfterRelease() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    _ = classifier.advance(to: 0.25)
    _ = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.3)

    _ = classifier.touchEnded(id: 1, time: 0.5)

    // Finger 2 is still down, but the button is released, so a new touch opens a new window.
    #expect(classifier.touchBegan(id: 3, location: top, in: surface, time: 0.6) == [
      .contact(time: 0.6)
    ])
    #expect(classifier.advance(to: 0.85) == [.button(.left, isDown: true, time: 0.85)])
    #expect(classifier.touchEnded(id: 2, time: 0.9) == [])
    #expect(classifier.heldButtons == .left)
  }

  @Test func cancelAllWhileHeldReleasesImmediatelyAndForgetsTouches() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    _ = classifier.advance(to: 0.25)

    #expect(classifier.cancelAll(time: 0.3) == [.button(.left, isDown: false, time: 0.3)])
    #expect(classifier.heldButtons == noButtons)
    #expect(classifier.nextDeadline == nil)

    // The touch still on screen stays ignored until it lifts.
    #expect(classifier.touchEnded(id: 1, time: 0.4) == [])

    // A new touch starts a fresh gesture.
    #expect(classifier.touchBegan(id: 2, location: top, in: surface, time: 0.5) == [
      .contact(time: 0.5)
    ])
  }

  @Test func cancelAllWhileWindowOpenEmitsNothing() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)

    #expect(classifier.cancelAll(time: 0.1) == [])
    #expect(classifier.heldButtons == noButtons)
    #expect(classifier.nextDeadline == nil)
    #expect(classifier.advance(to: 1.0) == [])
    #expect(classifier.touchEnded(id: 1, time: 1.0) == [])
  }

  @Test func cancelAllDuringScheduledReleaseReleasesNow() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    _ = classifier.touchEnded(id: 1, time: 0.0625)
    #expect(classifier.nextDeadline == 0.1875)

    #expect(classifier.cancelAll(time: 0.1) == [.button(.left, isDown: false, time: 0.1)])
    #expect(classifier.nextDeadline == nil)
    #expect(classifier.advance(to: 0.5) == [])
  }

  @Test func overdueDeadlineIsEmittedBeforeTheNextTouch() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)

    let next = classifier.touchBegan(id: 2, location: top, in: surface, time: 0.5)
    #expect(next == [.button(.left, isDown: true, time: 0.25)])

    // Finger 2 is an extra, so nothing else is emitted for it.
    #expect(classifier.touchEnded(id: 2, time: 0.6) == [])
    #expect(
      classifier.touchEnded(id: 1, time: 0.7) == [
        .contact(time: 0.7),
        .button(.left, isDown: false, time: 0.7),
      ])
  }

  @Test func nextDeadlineFollowsTheSequence() {
    var classifier = makeClassifier()
    #expect(classifier.nextDeadline == nil)

    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 1.0)
    #expect(classifier.nextDeadline == 1.25)

    _ = classifier.touchEnded(id: 1, time: 1.0625)
    #expect(classifier.nextDeadline == 1.1875)

    _ = classifier.advance(to: 1.1875)
    #expect(classifier.nextDeadline == nil)

    _ = classifier.touchBegan(id: 2, location: top, in: surface, time: 2.0)
    #expect(classifier.nextDeadline == 2.25)

    _ = classifier.advance(to: 2.25)
    #expect(classifier.nextDeadline == nil)

    _ = classifier.touchEnded(id: 2, time: 3.0)
    #expect(classifier.nextDeadline == nil)
  }

  @Test func cancelledTouchesBehaveLikeLifts() {
    // `touchesCancelled` calls `touchEnded`, so a cancelled tap matches a lifted one.
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)

    #expect(
      classifier.touchEnded(id: 1, time: 0.0625) == [
        .button(.left, isDown: true, time: 0.0625),
        .contact(time: 0.0625),
      ])
    #expect(classifier.advance(to: 0.1875) == [.button(.left, isDown: false, time: 0.1875)])
  }

  @Test func heldButtonsOnlyReflectsEmittedEvents() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)
    #expect(classifier.heldButtons == noButtons)

    _ = classifier.advance(to: 0.25)
    #expect(classifier.heldButtons == .left)

    // The release is scheduled but not yet emitted, so the button still counts as held.
    _ = classifier.touchEnded(id: 1, time: 0.3125)
    #expect(classifier.heldButtons == .left)

    _ = classifier.advance(to: 0.4375)
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func settingsChangedMidGestureApplyToTheNextDecision() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: top, in: surface, time: 0)

    // The open window keeps the deadline it was given.
    classifier.settings.twoFingerWindow = 1.0
    #expect(classifier.advance(to: 0.25) == [.button(.left, isDown: true, time: 0.25)])

    // The release decision reads the minimum press duration when the last finger lifts.
    classifier.settings.minimumPressDuration = 0
    #expect(
      classifier.touchEnded(id: 1, time: 0.5) == [
        .contact(time: 0.5),
        .button(.left, isDown: false, time: 0.5),
      ])

    // The accepted area is read on each touch: y = 300 is now below the top quarter.
    classifier.settings.acceptedFraction = 0.25
    let lowered = CGPoint(x: 200, y: 300)
    let rejected = classifier.touchBegan(id: 2, location: lowered, in: surface, time: 1.0)
    #expect(rejected == [])

    let accepted = classifier.touchBegan(id: 3, location: top, in: surface, time: 1.0)
    #expect(accepted == [.contact(time: 1.0)])
  }
}
