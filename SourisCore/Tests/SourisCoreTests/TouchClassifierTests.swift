import CoreGraphics
import Foundation
import Testing

@testable import SourisCore

/// The classifier uses a 0.125 s minimum press, so every expected time is exact in binary floating
/// point. The surface is 400 × 800 with the touch area in its top half, split at x = 200, and the
/// Enter key in the left half from y = 320 to 480.
struct TouchClassifierTests {
  let surface = CGSize(width: 400, height: 800)
  let left = CGPoint(x: 100, y: 100)
  let right = CGPoint(x: 300, y: 100)
  let bottom = CGPoint(x: 200, y: 600)
  let noButtons = MouseButtons()

  func makeClassifier() -> TouchClassifier {
    var settings = TouchSettings()
    settings.minimumPressDuration = 0.125
    return TouchClassifier(settings: settings)
  }

  @Test func leftHalfPressesLeftAtOnceAndReleasesAtLift() {
    var classifier = makeClassifier()

    let began = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    #expect(began == [.contact(time: 0), .button(.left, isDown: true, time: 0)])
    #expect(classifier.heldButtons == .left)
    #expect(classifier.nextDeadline == nil)

    let ended = classifier.touchEnded(id: 1, time: 0.5)
    #expect(ended == [.contact(time: 0.5), .button(.left, isDown: false, time: 0.5)])
    #expect(classifier.heldButtons == noButtons)
    #expect(classifier.nextDeadline == nil)
  }

  @Test func rightHalfPressesRight() {
    var classifier = makeClassifier()

    let began = classifier.touchBegan(id: 1, location: right, in: surface, time: 0)
    #expect(began == [.contact(time: 0), .button(.right, isDown: true, time: 0)])
    #expect(classifier.heldButtons == .right)

    let ended = classifier.touchEnded(id: 1, time: 0.25)
    #expect(ended == [.contact(time: 0.25), .button(.right, isDown: false, time: 0.25)])
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func theMiddleBelongsToTheRightHalf() {
    #expect(TouchClassifier.button(at: CGPoint(x: 199.5, y: 10), in: surface) == .left)
    #expect(TouchClassifier.button(at: CGPoint(x: 200, y: 10), in: surface) == .right)
  }

  @Test func quickTapReleasesAfterMinimumPressDuration() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)

    #expect(classifier.touchEnded(id: 1, time: 0.0625) == [.contact(time: 0.0625)])
    #expect(classifier.heldButtons == .left)
    #expect(classifier.nextDeadline == 0.125)

    #expect(classifier.advance(to: 0.1) == [])
    #expect(classifier.advance(to: 0.125) == [.button(.left, isDown: false, time: 0.125)])
    #expect(classifier.heldButtons == noButtons)
    #expect(classifier.nextDeadline == nil)
  }

  @Test func twoQuickTapsAreTwoSeparateClicks() {
    // The Mac counts the second as a double-click from the timing.
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    _ = classifier.touchEnded(id: 1, time: 0.25)
    let second = classifier.touchBegan(id: 2, location: left, in: surface, time: 0.375)
    #expect(second == [.contact(time: 0.375), .button(.left, isDown: true, time: 0.375)])
  }

  @Test func oneFingerInEachHalfHoldsBothButtons() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    let second = classifier.touchBegan(id: 2, location: right, in: surface, time: 0.0625)
    #expect(second == [.contact(time: 0.0625), .button(.right, isDown: true, time: 0.0625)])
    #expect(classifier.heldButtons == [.left, .right])

    #expect(
      classifier.touchEnded(id: 1, time: 0.5) == [
        .contact(time: 0.5), .button(.left, isDown: false, time: 0.5),
      ])
    #expect(classifier.heldButtons == .right)
    #expect(
      classifier.touchEnded(id: 2, time: 0.75) == [
        .contact(time: 0.75), .button(.right, isDown: false, time: 0.75),
      ])
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func extraFingerOnAHeldButtonIsIgnored() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)

    #expect(classifier.touchBegan(id: 2, location: left, in: surface, time: 0.25) == [])
    #expect(classifier.touchEnded(id: 2, time: 0.375) == [])
    #expect(classifier.heldButtons == .left)

    #expect(
      classifier.touchEnded(id: 1, time: 0.5) == [
        .contact(time: 0.5), .button(.left, isDown: false, time: 0.5),
      ])
  }

  @Test func extraFingerStaysIgnoredAfterTheButtonIsReleased() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    _ = classifier.touchBegan(id: 2, location: left, in: surface, time: 0.25)
    _ = classifier.touchEnded(id: 1, time: 0.5)

    // Finger 2 is still down, but a new touch presses again.
    let third = classifier.touchBegan(id: 3, location: left, in: surface, time: 0.625)
    #expect(third == [.contact(time: 0.625), .button(.left, isDown: true, time: 0.625)])
    #expect(classifier.touchEnded(id: 2, time: 0.75) == [])
    #expect(classifier.heldButtons == .left)
  }

  @Test func aTouchDuringAPendingReleaseIsIgnored() {
    // Pressing again before the release has gone out would put the release and the press in the
    // same packet, and the Mac would never see the click.
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    _ = classifier.touchEnded(id: 1, time: 0.0625)

    #expect(classifier.touchBegan(id: 2, location: left, in: surface, time: 0.09375) == [])
    #expect(classifier.advance(to: 0.125) == [.button(.left, isDown: false, time: 0.125)])
    #expect(classifier.touchEnded(id: 2, time: 0.25) == [])
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func bottomHalfTouchIsIgnoredEntirely() {
    var classifier = makeClassifier()

    #expect(classifier.touchBegan(id: 1, location: bottom, in: surface, time: 0) == [])
    #expect(classifier.touchEnded(id: 1, time: 0.0625) == [])
    #expect(classifier.touchEnded(id: 99, time: 0.0625) == [])
    #expect(classifier.nextDeadline == nil)
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func palmRestingInBottomHalfDoesNotBlockTap() {
    var classifier = makeClassifier()

    _ = classifier.touchBegan(id: 1, location: bottom, in: surface, time: 0)
    #expect(
      classifier.touchBegan(id: 2, location: left, in: surface, time: 0.0625) == [
        .contact(time: 0.0625), .button(.left, isDown: true, time: 0.0625),
      ])
    #expect(
      classifier.touchEnded(id: 2, time: 0.25) == [
        .contact(time: 0.25), .button(.left, isDown: false, time: 0.25),
      ])
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
    #expect(classifier.heldButtons == noButtons)
  }

  @Test func touchExactlyOnSideBandEdgeIsAccepted() {
    var classifier = makeClassifier()
    let edge = CGPoint(x: 6, y: 100)

    #expect(
      classifier.touchBegan(id: 1, location: edge, in: surface, time: 0) == [
        .contact(time: 0), .button(.left, isDown: true, time: 0),
      ])
  }

  @Test func cancelAllWhileHeldReleasesImmediatelyAndForgetsTouches() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    _ = classifier.touchBegan(id: 2, location: right, in: surface, time: 0)

    #expect(
      classifier.cancelAll(time: 0.25) == [
        .button(.left, isDown: false, time: 0.25),
        .button(.right, isDown: false, time: 0.25),
      ])
    #expect(classifier.heldButtons == noButtons)
    #expect(classifier.nextDeadline == nil)

    // The touches still on screen stay ignored until they lift.
    #expect(classifier.touchEnded(id: 1, time: 0.375) == [])
    #expect(classifier.touchEnded(id: 2, time: 0.375) == [])

    // A new touch starts a fresh press.
    #expect(
      classifier.touchBegan(id: 3, location: left, in: surface, time: 0.5) == [
        .contact(time: 0.5), .button(.left, isDown: true, time: 0.5),
      ])
  }

  @Test func cancelAllDuringScheduledReleaseReleasesNow() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    _ = classifier.touchEnded(id: 1, time: 0.0625)
    #expect(classifier.nextDeadline == 0.125)

    #expect(classifier.cancelAll(time: 0.09375) == [.button(.left, isDown: false, time: 0.09375)])
    #expect(classifier.nextDeadline == nil)
    #expect(classifier.advance(to: 0.5) == [])
  }

  @Test func overdueReleasesComeOutInTimeOrderBeforeTheNextTouch() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: right, in: surface, time: 0)
    _ = classifier.touchBegan(id: 2, location: left, in: surface, time: 0.0625)
    _ = classifier.touchEnded(id: 1, time: 0.09375)
    _ = classifier.touchEnded(id: 2, time: 0.09375)
    #expect(classifier.nextDeadline == 0.125)

    let next = classifier.touchBegan(id: 3, location: left, in: surface, time: 0.5)
    #expect(
      next == [
        .button(.right, isDown: false, time: 0.125),
        .button(.left, isDown: false, time: 0.1875),
        .contact(time: 0.5),
        .button(.left, isDown: true, time: 0.5),
      ])
  }

  @Test func settingsChangedMidGestureApplyToTheNextDecision() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)

    // The release decision reads the minimum press duration when the finger lifts.
    classifier.settings.minimumPressDuration = 0
    #expect(
      classifier.touchEnded(id: 1, time: 0.0625) == [
        .contact(time: 0.0625), .button(.left, isDown: false, time: 0.0625),
      ])

    // The accepted area is read on each touch: y = 300 is now below the top quarter. (The left
    // button reaches down to the Enter key whatever the area is, so this uses the right.)
    classifier.settings.acceptedFraction = 0.25
    let lowered = CGPoint(x: 300, y: 300)
    #expect(classifier.touchBegan(id: 2, location: lowered, in: surface, time: 1.0) == [])
    #expect(
      classifier.touchBegan(id: 3, location: left, in: surface, time: 1.0) == [
        .contact(time: 1.0), .button(.left, isDown: true, time: 1.0),
      ])
  }

  // MARK: - Enter key

  let enterKey = CGPoint(x: 100, y: 400)

  @Test func anEnterKeyTapPressesReturnWhenItLifts() {
    var classifier = makeClassifier()

    let began = classifier.touchBegan(id: 1, location: enterKey, in: surface, time: 0)
    #expect(began == [.contact(time: 0)])
    #expect(classifier.isReturnKeyTouched)
    #expect(classifier.heldButtons == noButtons)

    #expect(
      classifier.touchEnded(id: 1, time: 0.25) == [
        .contact(time: 0.25), .returnKey(heldFor: 0.25, time: 0.25),
      ])
    #expect(!classifier.isReturnKeyTouched)
  }

  @Test func aTouchRestingOnTheEnterKeyPressesNothing() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: enterKey, in: surface, time: 0)
    #expect(classifier.touchEnded(id: 1, time: 0.625) == [.contact(time: 0.625)])
  }

  @Test func theLeftButtonEndsWhereTheEnterKeyStarts() {
    var classifier = makeClassifier()
    let leftDown = classifier.touchBegan(
      id: 1, location: CGPoint(x: 100, y: 319), in: surface, time: 0)
    #expect(leftDown == [.contact(time: 0), .button(.left, isDown: true, time: 0)])
    let onKey = classifier.touchBegan(
      id: 2, location: CGPoint(x: 100, y: 321), in: surface, time: 0)
    #expect(onKey == [.contact(time: 0)])
    // Below the key is the palm's.
    #expect(
      classifier.touchBegan(id: 3, location: CGPoint(x: 100, y: 481), in: surface, time: 0) == [])
    // The right button keeps the top half.
    let rightDown = classifier.touchBegan(
      id: 4, location: CGPoint(x: 300, y: 399), in: surface, time: 0)
    #expect(rightDown == [.contact(time: 0), .button(.right, isDown: true, time: 0)])
    #expect(
      classifier.touchBegan(id: 5, location: CGPoint(x: 300, y: 401), in: surface, time: 0) == [])
    // Nor does the side band take touches on the key.
    #expect(
      classifier.touchBegan(id: 6, location: CGPoint(x: 2, y: 400), in: surface, time: 0) == [])
  }

  @Test func aDragFromTheLeftButtonOntoTheEnterKeyStaysADrag() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: left, in: surface, time: 0)
    // Only where a touch begins counts, so lifting it over the key just releases the button.
    #expect(
      classifier.touchEnded(id: 1, time: 0.25) == [
        .contact(time: 0.25), .button(.left, isDown: false, time: 0.25),
      ])
  }

  @Test func withTheEnterKeyOffTheLeftButtonFillsTheTopHalf() {
    var classifier = makeClassifier()
    classifier.settings.returnKey.isEnabled = false
    #expect(classifier.returnKeyRect(in: surface) == nil)
    let low = classifier.touchBegan(id: 1, location: CGPoint(x: 100, y: 399), in: surface, time: 0)
    #expect(low == [.contact(time: 0), .button(.left, isDown: true, time: 0)])
    #expect(classifier.touchBegan(id: 2, location: enterKey, in: surface, time: 0) == [])
  }

  @Test func aSecondTouchOnTheEnterKeyIsIgnored() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: enterKey, in: surface, time: 0)
    #expect(classifier.touchBegan(id: 2, location: enterKey, in: surface, time: 0.0625) == [])
    #expect(classifier.touchEnded(id: 2, time: 0.125) == [])
    #expect(
      classifier.touchEnded(id: 1, time: 0.25) == [
        .contact(time: 0.25), .returnKey(heldFor: 0.25, time: 0.25),
      ])
  }

  @Test func cancellingForgetsATouchOnTheEnterKey() {
    var classifier = makeClassifier()
    _ = classifier.touchBegan(id: 1, location: enterKey, in: surface, time: 0)
    #expect(classifier.cancelAll(time: 0.125) == [])
    #expect(!classifier.isReturnKeyTouched)
    #expect(classifier.touchEnded(id: 1, time: 0.25) == [])
  }

  @Test func oldSettingsWithoutAnEnterKeyGetTheDefaultOne() throws {
    let saved = Data(#"{"acceptedFraction":0.5,"returnKey":{"top":0.35}}"#.utf8)
    let settings = try JSONDecoder().decode(TouchSettings.self, from: saved)
    #expect(settings.returnKey.top == 0.35)
    #expect(settings.returnKey.bottom == ReturnKeySettings().bottom)
    let older = try JSONDecoder().decode(TouchSettings.self, from: Data("{}".utf8))
    #expect(older.returnKey == ReturnKeySettings())
  }
}
