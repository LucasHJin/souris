import Testing

@testable import SourisCore

@Suite("Remote state tracker")
struct RemoteStateTrackerTests {
  private func packet(
    seq: UInt32,
    epoch: UInt16 = 1,
    buttons: MouseButtons = [],
    flags: StateFlags = [],
    cursor: SIMD2<Double> = .zero,
    scroll: SIMD2<Double> = .zero,
    shortcuts: ShortcutPresses = ShortcutPresses()
  ) -> StatePacket {
    StatePacket(
      epoch: epoch,
      seq: seq,
      phoneTimeMicros: 0,
      state: MouseState(
        buttons: buttons, flags: flags, cursor: cursor, scroll: scroll, shortcuts: shortcuts))
  }

  /// Applies `packet` and returns the update, recording an issue if the tracker called it stale.
  private func applied(
    _ tracker: inout RemoteStateTracker, _ packet: StatePacket
  ) throws -> InputUpdate {
    let update = tracker.apply(packet)
    return try #require(update)
  }

  private func isStale(_ tracker: inout RemoteStateTracker, _ packet: StatePacket) -> Bool {
    tracker.apply(packet) == nil
  }

  // MARK: - Baseline and deltas

  @Test func firstPacketSetsBaselineAndMovesNothing() throws {
    var tracker = RemoteStateTracker()
    let update = try applied(&tracker, packet(seq: 10, cursor: SIMD2(500, -300)))
    #expect(update.isEmpty)
    #expect(tracker.stats.received == 1)
    #expect(tracker.stats.lost == 0)
  }

  @Test func laterPacketsApplyTheDifferenceFromTheLastTotals() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, cursor: SIMD2(100, 100)))
    let first = try applied(&tracker, packet(seq: 2, cursor: SIMD2(103, 99)))
    #expect(first.cursorDelta == SIMD2(3, -1))
    let second = try applied(&tracker, packet(seq: 3, cursor: SIMD2(103.5, 99)))
    #expect(second.cursorDelta == SIMD2(0.5, 0))
    #expect(tracker.stats.received == 3)
  }

  @Test func aSkippedPacketLosesNoMotion() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, cursor: SIMD2(0, 0)))
    let update = try applied(&tracker, packet(seq: 4, cursor: SIMD2(30, 60)))
    #expect(update.cursorDelta == SIMD2(30, 60))
    #expect(update.missedPackets == 2)
    #expect(tracker.stats.lost == 2)
  }

  @Test func theBaselineAfterAnEpochChangeMissesNothing() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let update = try applied(&tracker, packet(seq: 9, epoch: 2))
    #expect(update.missedPackets == 0)
    #expect(try applied(&tracker, packet(seq: 10, epoch: 2)).missedPackets == 0)
  }

  // MARK: - Shortcuts

  @Test func shortcutsArePressedOncePerCountedPress() throws {
    var tracker = RemoteStateTracker()
    var presses = ShortcutPresses(counts: [5, 0, 0, 9])
    // The baseline presses nothing, whatever the counts.
    #expect(try applied(&tracker, packet(seq: 1, shortcuts: presses)).shortcuts.isEmpty)
    presses.press(.missionControl)
    #expect(try applied(&tracker, packet(seq: 2, shortcuts: presses)).shortcuts == [.missionControl])
    // A keepalive repeats the counts: nothing more.
    #expect(try applied(&tracker, packet(seq: 3, shortcuts: presses)).shortcuts.isEmpty)
    // A press in a lost packet still comes through with the next one.
    presses.press(.spotlight)
    presses.press(.missionControl)
    let update = try applied(&tracker, packet(seq: 6, shortcuts: presses))
    #expect(update.shortcuts == [.missionControl, .spotlight])
  }

  @Test func aNewEpochReplaysNoShortcuts() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let restarted = ShortcutPresses(counts: [3, 1, 0, 0])
    #expect(try applied(&tracker, packet(seq: 1, epoch: 2, shortcuts: restarted)).shortcuts.isEmpty)
  }

  // MARK: - Stale packets

  @Test func duplicateIsStale() {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 5, cursor: SIMD2(1, 1)))
    #expect(isStale(&tracker, packet(seq: 5, cursor: SIMD2(9, 9))))
    #expect(tracker.stats.stale == 1)
    #expect(tracker.stats.received == 1)
  }

  @Test func outOfOrderPacketIsStaleAndDoesNotMoveTheBaselineBack() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, cursor: SIMD2(0, 0)))
    _ = tracker.apply(packet(seq: 3, cursor: SIMD2(30, 0)))
    #expect(isStale(&tracker, packet(seq: 2, cursor: SIMD2(20, 0))))
    let next = try applied(&tracker, packet(seq: 4, cursor: SIMD2(40, 0)))
    #expect(next.cursorDelta == SIMD2(10, 0))
    #expect(tracker.stats.stale == 1)
    #expect(tracker.stats.lost == 1)
  }

  @Test func sequenceNumbersWrapAround() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: UInt32.max - 1, cursor: SIMD2(0, 0)))
    let atMax = try applied(&tracker, packet(seq: UInt32.max, cursor: SIMD2(1, 0)))
    #expect(atMax.cursorDelta == SIMD2(1, 0))
    let wrapped = try applied(&tracker, packet(seq: 0, cursor: SIMD2(2, 0)))
    #expect(wrapped.cursorDelta == SIMD2(1, 0))
    let after = try applied(&tracker, packet(seq: 1, cursor: SIMD2(3, 0)))
    #expect(after.cursorDelta == SIMD2(1, 0))
    #expect(isStale(&tracker, packet(seq: UInt32.max, cursor: SIMD2(9, 0))))
    #expect(tracker.stats.lost == 0)
    #expect(tracker.stats.stale == 1)
  }

  @Test func gapAcrossTheWrapCountsAsLoss() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: UInt32.max - 1))
    _ = tracker.apply(packet(seq: 2))
    #expect(tracker.stats.lost == 3)
  }

  @Test func nonFiniteTotalsAreDroppedWithoutPoisoningTheBaseline() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, cursor: SIMD2(0, 0)))
    #expect(isStale(&tracker, packet(seq: 2, cursor: SIMD2(.nan, 0))))
    #expect(isStale(&tracker, packet(seq: 3, scroll: SIMD2(0, .infinity))))
    let next = try applied(&tracker, packet(seq: 4, cursor: SIMD2(4, 0)))
    #expect(next.cursorDelta == SIMD2(4, 0))
    #expect(tracker.stats.stale == 2)
  }

  // MARK: - Loss statistics

  @Test func lossIsCountedPerGapAndFractionUsesExpectedPackets() {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    _ = tracker.apply(packet(seq: 2))
    _ = tracker.apply(packet(seq: 5))  // 3, 4 lost
    _ = tracker.apply(packet(seq: 6))
    _ = tracker.apply(packet(seq: 8))  // 7 lost
    #expect(tracker.stats.received == 5)
    #expect(tracker.stats.lost == 3)
    #expect(tracker.stats.lossFraction == 3.0 / 8.0)
  }

  @Test func lossFractionIsZeroBeforeAnyPacket() {
    #expect(RemoteStateTracker().stats.lossFraction == 0)
  }

  // MARK: - Epochs

  @Test func newEpochRebaselinesWithoutMotion() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 100, epoch: 1, cursor: SIMD2(1000, 1000)))
    _ = tracker.apply(packet(seq: 101, epoch: 1, cursor: SIMD2(1010, 1000)))
    let restart = try applied(&tracker, packet(seq: 1, epoch: 2, cursor: SIMD2(5, 5)))
    #expect(restart.cursorDelta == .zero)
    #expect(tracker.stats.epochChanges == 1)
    #expect(tracker.stats.lost == 0)
    let next = try applied(&tracker, packet(seq: 2, epoch: 2, cursor: SIMD2(6, 5)))
    #expect(next.cursorDelta == SIMD2(1, 0))
  }

  @Test func firstEpochIsNotCountedAsAChange() {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, epoch: 9))
    #expect(tracker.stats.epochChanges == 0)
  }

  @Test func newEpochAcceptsLowerSequenceNumbers() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 5000, epoch: 1))
    #expect(!isStale(&tracker, packet(seq: 1, epoch: 2)))
    #expect(tracker.stats.stale == 0)
  }

  @Test func newEpochReleasesButtonsTheNewStateDoesNotHold() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, epoch: 1, buttons: [.left, .right]))
    #expect(tracker.heldButtons == [.left, .right])
    let restart = try applied(&tracker, packet(seq: 1, epoch: 2, buttons: [.right]))
    #expect(restart.buttonChanges == [ButtonChange(button: .left, isDown: false)])
    #expect(tracker.heldButtons == [.right])
  }

  @Test func newEpochEndsAScrollTheNewStateIsNotIn() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, epoch: 1, flags: .scrollActive))
    #expect(tracker.isScrolling)
    let restart = try applied(&tracker, packet(seq: 1, epoch: 2, scroll: SIMD2(50, 50)))
    #expect(restart.scrollEvents == [ScrollEvent(phase: .ended, delta: .zero)])
    #expect(!tracker.isScrolling)
  }

  // MARK: - Buttons

  @Test func buttonPressAndReleaseFollowTheAbsoluteState() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let down = try applied(&tracker, packet(seq: 2, buttons: .left))
    #expect(down.buttonChanges == [ButtonChange(button: .left, isDown: true)])
    let held = try applied(&tracker, packet(seq: 3, buttons: .left))
    #expect(held.buttonChanges.isEmpty)
    let up = try applied(&tracker, packet(seq: 4))
    #expect(up.buttonChanges == [ButtonChange(button: .left, isDown: false)])
    #expect(tracker.heldButtons.isEmpty)
  }

  @Test func aLostPacketCannotLeaveAButtonStuck() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, buttons: .left))
    let update = try applied(&tracker, packet(seq: 9, buttons: []))
    #expect(update.buttonChanges == [ButtonChange(button: .left, isDown: false)])
  }

  @Test func releasesComeBeforePresses() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, buttons: .left))
    let swap = try applied(&tracker, packet(seq: 2, buttons: [.right, .middle]))
    #expect(
      swap.buttonChanges == [
        ButtonChange(button: .left, isDown: false),
        ButtonChange(button: .right, isDown: true),
        ButtonChange(button: .middle, isDown: true),
      ])
  }

  @Test func unknownButtonBitsAreNotPosted() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let update = try applied(&tracker, packet(seq: 2, buttons: MouseButtons(rawValue: 0b1000_0001)))
    #expect(update.buttonChanges == [ButtonChange(button: .left, isDown: true)])
    #expect(tracker.heldButtons == .left)
  }

  @Test func buttonOnTheFirstPacketIsPressedImmediately() throws {
    var tracker = RemoteStateTracker()
    let update = try applied(&tracker, packet(seq: 1, buttons: .left))
    #expect(update.buttonChanges == [ButtonChange(button: .left, isDown: true)])
  }

  // MARK: - Scroll

  @Test func scrollBeginsChangesAndEnds() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let began = try applied(&tracker, packet(seq: 2, flags: .scrollActive, scroll: SIMD2(0, 4)))
    #expect(began.scrollEvents == [ScrollEvent(phase: .began, delta: SIMD2(0, 4))])
    #expect(tracker.isScrolling)

    let changed = try applied(&tracker, packet(seq: 3, flags: .scrollActive, scroll: SIMD2(1, 10)))
    #expect(changed.scrollEvents == [ScrollEvent(phase: .changed, delta: SIMD2(1, 6))])

    let ended = try applied(&tracker, packet(seq: 4, scroll: SIMD2(1, 10)))
    #expect(ended.scrollEvents == [ScrollEvent(phase: .ended, delta: .zero)])
    #expect(!tracker.isScrolling)
  }

  @Test func endedCarriesTheRemainingDeltaAsAChangedFirst() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    _ = tracker.apply(packet(seq: 2, flags: .scrollActive, scroll: SIMD2(0, 4)))
    let ended = try applied(&tracker, packet(seq: 3, scroll: SIMD2(0, 9)))
    #expect(
      ended.scrollEvents == [
        ScrollEvent(phase: .changed, delta: SIMD2(0, 5)),
        ScrollEvent(phase: .ended, delta: .zero),
      ])
  }

  @Test func zeroDeltaChangedIsSuppressed() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    _ = tracker.apply(packet(seq: 2, flags: .scrollActive, scroll: SIMD2(0, 4)))
    let idle = try applied(&tracker, packet(seq: 3, flags: .scrollActive, scroll: SIMD2(0, 4)))
    #expect(idle.scrollEvents.isEmpty)
    #expect(idle.isEmpty)
    #expect(tracker.isScrolling)
  }

  @Test func beganWithZeroDeltaIsStillPosted() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let began = try applied(&tracker, packet(seq: 2, flags: .scrollActive))
    #expect(began.scrollEvents == [ScrollEvent(phase: .began, delta: .zero)])
  }

  @Test func lostPacketBetweenBeganAndEndedLosesNoScroll() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    _ = tracker.apply(packet(seq: 2, flags: .scrollActive, scroll: SIMD2(0, 3)))
    // Packets 3 (still scrolling) and 4 (scroll ended) never arrive.
    let ended = try applied(&tracker, packet(seq: 5, scroll: SIMD2(0, 12)))
    #expect(
      ended.scrollEvents == [
        ScrollEvent(phase: .changed, delta: SIMD2(0, 9)),
        ScrollEvent(phase: .ended, delta: .zero),
      ])
    #expect(tracker.stats.lost == 2)
  }

  @Test func scrollTotalsMovingWhileInactiveAreNotPosted() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let drift = try applied(&tracker, packet(seq: 2, scroll: SIMD2(0, 7)))
    #expect(drift.scrollEvents.isEmpty)
    let began = try applied(&tracker, packet(seq: 3, flags: .scrollActive, scroll: SIMD2(0, 9)))
    #expect(began.scrollEvents == [ScrollEvent(phase: .began, delta: SIMD2(0, 2))])
  }

  @Test func cursorAndScrollAndButtonsAreReportedTogether() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    let combined = packet(
      seq: 2,
      buttons: .right,
      flags: .scrollActive,
      cursor: SIMD2(2, 3),
      scroll: SIMD2(0, 1))
    let update = try applied(&tracker, combined)
    #expect(update.cursorDelta == SIMD2(2, 3))
    #expect(update.buttonChanges == [ButtonChange(button: .right, isDown: true)])
    #expect(update.scrollEvents == [ScrollEvent(phase: .began, delta: SIMD2(0, 1))])
    #expect(!update.isEmpty)
  }

  // MARK: - releaseAll

  @Test func releaseAllReleasesButtonsAndEndsScroll() {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    _ = tracker.apply(packet(seq: 2, buttons: [.left, .right], flags: .scrollActive))
    let update = tracker.releaseAll()
    #expect(
      update.buttonChanges == [
        ButtonChange(button: .left, isDown: false),
        ButtonChange(button: .right, isDown: false),
      ])
    #expect(update.scrollEvents == [ScrollEvent(phase: .ended, delta: .zero)])
    #expect(update.cursorDelta == .zero)
    #expect(tracker.heldButtons.isEmpty)
    #expect(!tracker.isScrolling)
  }

  @Test func releaseAllWhenIdleDoesNothing() {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    #expect(tracker.releaseAll().isEmpty)
  }

  @Test func packetAfterReleaseAllRebaselinesAndReappliesHeldButtons() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1, cursor: SIMD2(0, 0)))
    _ = tracker.apply(packet(seq: 2, buttons: .left, cursor: SIMD2(10, 0)))
    _ = tracker.releaseAll()

    let resumed = try applied(&tracker, packet(seq: 30, buttons: .left, cursor: SIMD2(90, 0)))
    #expect(resumed.cursorDelta == .zero)
    #expect(resumed.buttonChanges == [ButtonChange(button: .left, isDown: true)])
    #expect(tracker.stats.lost == 0)

    let next = try applied(&tracker, packet(seq: 31, buttons: .left, cursor: SIMD2(95, 0)))
    #expect(next.cursorDelta == SIMD2(5, 0))
    #expect(next.buttonChanges.isEmpty)
  }

  @Test func packetsOlderThanBeforeReleaseAllRemainStale() {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 10))
    _ = tracker.releaseAll()
    #expect(isStale(&tracker, packet(seq: 9)))
    #expect(!isStale(&tracker, packet(seq: 11)))
  }

  @Test func scrollStillActiveAfterReleaseAllBeginsAgain() throws {
    var tracker = RemoteStateTracker()
    _ = tracker.apply(packet(seq: 1))
    _ = tracker.apply(packet(seq: 2, flags: .scrollActive, scroll: SIMD2(0, 5)))
    _ = tracker.releaseAll()
    let resumed = try applied(&tracker, packet(seq: 3, flags: .scrollActive, scroll: SIMD2(0, 8)))
    #expect(resumed.scrollEvents == [ScrollEvent(phase: .began, delta: .zero)])
  }
}
