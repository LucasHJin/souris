/// One scroll event the Mac should post.
public struct ScrollEvent: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case began
    case changed
    case ended
  }

  public var phase: Phase

  /// Pixels to scroll, with the sign convention of `MouseState.scroll`. Zero for `.ended`.
  public var delta: SIMD2<Double>

  public init(phase: Phase, delta: SIMD2<Double>) {
    self.phase = phase
    self.delta = delta
  }
}

/// A button press or release the Mac should post.
public struct ButtonChange: Equatable, Sendable {
  public var button: MouseButton
  public var isDown: Bool

  public init(button: MouseButton, isDown: Bool) {
    self.button = button
    self.isDown = isDown
  }
}

/// What the Mac should do in response to one state packet.
///
/// Apply in this order: `cursorDelta`, then `buttonChanges` in array order (releases come before
/// presses), then `scrollEvents` in array order.
public struct InputUpdate: Equatable, Sendable {
  /// Screen points to move, +y down.
  public var cursorDelta: SIMD2<Double>

  public var buttonChanges: [ButtonChange]

  public var scrollEvents: [ScrollEvent]

  public init(
    cursorDelta: SIMD2<Double> = .zero,
    buttonChanges: [ButtonChange] = [],
    scrollEvents: [ScrollEvent] = []
  ) {
    self.cursorDelta = cursorDelta
    self.buttonChanges = buttonChanges
    self.scrollEvents = scrollEvents
  }

  /// True when there's nothing to post.
  public var isEmpty: Bool {
    cursorDelta == .zero && buttonChanges.isEmpty && scrollEvents.isEmpty
  }
}

/// Counters for the packets one phone has sent, for the menu's loss readout.
public struct PacketStats: Equatable, Sendable {
  /// State packets applied.
  public var received = 0

  /// State packets that never arrived, inferred from gaps in `seq` within an epoch.
  public var lost = 0

  /// State packets dropped because they weren't newer than the last one applied.
  public var stale = 0

  /// How many times the phone started a new epoch after its first.
  public var epochChanges = 0

  public init() {}

  /// Lost packets as a fraction of those expected, 0 when nothing was expected.
  public var lossFraction: Double {
    let expected = received + lost
    return expected == 0 ? 0 : Double(lost) / Double(expected)
  }
}

/// Turns the phone's absolute state packets into the input events the Mac should post.
///
/// Rules (see `docs/architecture.md`, wire protocol):
/// - The first packet of an epoch sets the baseline for the motion totals and moves nothing.
/// - Within an epoch, packets whose `seq` isn't newer (wrapping comparison) are stale and return
///   `nil`.
/// - Motion is `new totals − last applied totals`. A backlog is never replayed.
/// - Buttons are absolute: the tracker compares the packet's buttons with what it has posted and
///   emits the difference. Across an epoch change the posted button state is kept, so a button
///   held when the phone restarted is released by the new epoch's first packet.
/// - Scroll phases come from `StateFlags.scrollActive`: off → on is `.began` (with that packet's
///   delta), on → on is `.changed` (only when the delta isn't zero), on → off is `.changed` for any
///   remaining delta and then `.ended`.
/// - A packet whose cursor or scroll totals aren't finite is dropped and counted as stale, so one
///   bad packet can't poison the baseline.
public struct RemoteStateTracker: Sendable {
  /// Buttons the Mac has posted as down and not yet released.
  public private(set) var heldButtons: MouseButtons = []

  /// True between a posted `.began` and its `.ended`.
  public private(set) var isScrolling = false

  public private(set) var stats = PacketStats()

  /// Epoch of the last applied packet, `nil` before the first one.
  private var epoch: UInt16?

  private var lastSeq: UInt32 = 0
  private var lastCursor: SIMD2<Double> = .zero
  private var lastScroll: SIMD2<Double> = .zero

  /// True until the next applied packet has set a new baseline for the motion totals.
  private var needsBaseline = true

  private static let postableButtons: MouseButtons = [.left, .right, .middle]

  public init() {}

  /// Returns the events to post for `packet`, or `nil` if the packet is stale.
  public mutating func apply(_ packet: StatePacket) -> InputUpdate? {
    let state = packet.state
    guard state.cursor.x.isFinite, state.cursor.y.isFinite,
          state.scroll.x.isFinite, state.scroll.y.isFinite
    else {
      stats.stale += 1
      return nil
    }

    let isNewEpoch = packet.epoch != epoch
    let seqStep = Int32(bitPattern: packet.seq &- lastSeq)
    if !isNewEpoch && seqStep <= 0 {
      stats.stale += 1
      return nil
    }

    if isNewEpoch {
      if epoch != nil { stats.epochChanges += 1 }
      epoch = packet.epoch
      needsBaseline = true
    } else if !needsBaseline {
      stats.lost += Int(seqStep) - 1
    }

    var update = InputUpdate()
    var scrollDelta: SIMD2<Double> = .zero
    if !needsBaseline {
      update.cursorDelta = state.cursor - lastCursor
      scrollDelta = state.scroll - lastScroll
    }
    needsBaseline = false
    lastSeq = packet.seq
    lastCursor = state.cursor
    lastScroll = state.scroll
    stats.received += 1

    update.buttonChanges = updateButtons(to: state.buttons.intersection(Self.postableButtons))
    update.scrollEvents = updateScroll(
      isActive: state.flags.contains(.scrollActive), delta: scrollDelta)
    return update
  }

  /// Releases every held button and ends any scroll. Use when the phone goes silent, says bye or
  /// is disconnected. The next packet starts a fresh baseline.
  public mutating func releaseAll() -> InputUpdate {
    var update = InputUpdate()
    update.buttonChanges = updateButtons(to: [])
    update.scrollEvents = updateScroll(isActive: false, delta: .zero)
    needsBaseline = true
    return update
  }

  /// Moves `heldButtons` to `target` and returns the changes, releases first.
  private mutating func updateButtons(to target: MouseButtons) -> [ButtonChange] {
    guard target != heldButtons else { return [] }
    var changes: [ButtonChange] = []
    for button in MouseButton.allCases where heldButtons.contains(button.mask) {
      if !target.contains(button.mask) {
        changes.append(ButtonChange(button: button, isDown: false))
      }
    }
    for button in MouseButton.allCases where target.contains(button.mask) {
      if !heldButtons.contains(button.mask) {
        changes.append(ButtonChange(button: button, isDown: true))
      }
    }
    heldButtons = target
    return changes
  }

  private mutating func updateScroll(isActive: Bool, delta: SIMD2<Double>) -> [ScrollEvent] {
    switch (isScrolling, isActive) {
    case (false, true):
      isScrolling = true
      return [ScrollEvent(phase: .began, delta: delta)]
    case (true, true):
      return delta == .zero ? [] : [ScrollEvent(phase: .changed, delta: delta)]
    case (true, false):
      isScrolling = false
      var events: [ScrollEvent] = []
      if delta != .zero {
        events.append(ScrollEvent(phase: .changed, delta: delta))
      }
      events.append(ScrollEvent(phase: .ended, delta: .zero))
      return events
    case (false, false):
      return []
    }
  }
}
