import CoreGraphics
import Foundation

import SourisCore

/// What an `EventPoster` has posted since it was created, for the input log.
struct PostCounters: Equatable, Sendable {
  var moves = 0

  /// Total cursor travel posted, points.
  var travel: Double = 0
  var buttonEvents = 0
  var scrollEvents = 0

  /// Moves that started from the real cursor because something else had moved it, or because
  /// macOS's reported location had fallen behind (see `CursorTracker`).
  var resyncs = 0
}

/// Posts the phone's input as synthetic Core Graphics events.
///
/// Not thread-safe: create it and use it only on the input queue.
final class EventPoster {
  private let source: CGEventSource?
  private let displayLayout: DisplayLayout
  private var cursorTracker = CursorTracker()
  private var clickCounter: ClickCounter

  /// Buttons this poster has pressed and not yet released, which decide the drag event type.
  private var heldButtons: MouseButtons = []

  /// Scroll pixels not yet posted because events carry whole pixels only.
  private var scrollRemainder = SIMD2<Double>.zero

  private(set) var counters = PostCounters()

  init(clickInterval: TimeInterval, displayLayout: DisplayLayout) {
    self.displayLayout = displayLayout
    clickCounter = ClickCounter(maxInterval: clickInterval)
    source = CGEventSource(stateID: .hidSystemState)
    // Without this, macOS ignores the real mouse for 0.25 s after each posted event.
    source?.localEventsSuppressionInterval = 0
  }

  /// Posts one update in its documented order: movement, button changes, then scrolling.
  func post(_ update: InputUpdate) {
    move(by: update.cursorDelta)
    for change in update.buttonChanges {
      post(change)
    }
    for event in update.scrollEvents {
      post(event)
    }
  }

  /// Forgets the tracked cursor position and any partial scroll, so the next move starts from
  /// the real cursor.
  func reset() {
    cursorTracker.reset()
    scrollRemainder = .zero
    heldButtons = []
  }

  // MARK: - Movement

  private func move(by delta: SIMD2<Double>) {
    guard delta != .zero else { return }
    let previous = cursorTracker.position
    guard let actual = CGEvent(source: nil)?.location ?? previous else { return }
    let target = cursorTracker.target(
      applying: delta, actual: actual, displays: displayLayout.bounds,
      time: ProcessInfo.processInfo.systemUptime)
    let origin = movementOrigin(previous: previous, actual: actual, target: target, delta: delta)

    let (type, button) = moveType()
    guard
      let event = CGEvent(
        mouseEventSource: source, mouseType: type, mouseCursorPosition: target,
        mouseButton: button)
    else { return }
    // Synthesized events leave the delta fields at zero; apps that read them (games, some
    // canvases) would otherwise see a cursor that doesn't move.
    event.setDoubleValueField(.mouseEventDeltaX, value: target.x - origin.x)
    event.setDoubleValueField(.mouseEventDeltaY, value: target.y - origin.y)
    event.post(tap: .cghidEventTap)
    counters.moves += 1
    counters.travel += hypot(target.x - origin.x, target.y - origin.y)
    counters.resyncs = cursorTracker.resyncCount
  }

  /// Where the cursor was before this move, for the event's delta fields.
  ///
  /// The tracker resyncs to the real cursor when something else moved it, so whichever of the
  /// two start points explains `delta` is the one it used.
  private func movementOrigin(
    previous: CGPoint?,
    actual: CGPoint,
    target: CGPoint,
    delta: SIMD2<Double>
  ) -> CGPoint {
    guard let previous else { return actual }
    func error(from origin: CGPoint) -> Double {
      hypot(target.x - origin.x - delta.x, target.y - origin.y - delta.y)
    }
    return error(from: previous) <= error(from: actual) ? previous : actual
  }

  /// Dragging with a button held needs the matching dragged event type, or apps drop the drag.
  private func moveType() -> (CGEventType, CGMouseButton) {
    if heldButtons.contains(.left) { return (.leftMouseDragged, .left) }
    if heldButtons.contains(.right) { return (.rightMouseDragged, .right) }
    if heldButtons.contains(.middle) { return (.otherMouseDragged, .center) }
    return (.mouseMoved, .left)
  }

  // MARK: - Buttons

  private func post(_ change: ButtonChange) {
    guard let position = buttonPosition() else { return }
    let button = change.button

    let clickState: Int64
    if change.isDown {
      clickState = clickCounter.press(
        button, at: position, time: ProcessInfo.processInfo.systemUptime)
      heldButtons.insert(button.mask)
    } else {
      clickState = clickCounter.releaseClickState(for: button)
      heldButtons.remove(button.mask)
    }

    guard
      let event = CGEvent(
        mouseEventSource: source,
        mouseType: change.isDown ? button.downType : button.upType,
        mouseCursorPosition: position,
        mouseButton: button.coreGraphicsButton)
    else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    if button == .middle {
      event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    }
    event.post(tap: .cghidEventTap)
    counters.buttonEvents += 1
  }

  /// Where to press or release: the tracked fractional position, unless something else (the
  /// trackpad) has moved the cursor since our last move. A button event at a stale position would
  /// jump the cursor back there.
  private func buttonPosition() -> CGPoint? {
    let actual = CGEvent(source: nil)?.location
    guard let tracked = cursorTracker.position else { return actual }
    guard let actual else { return tracked }
    return hypot(tracked.x - actual.x, tracked.y - actual.y) <= 2 ? tracked : actual
  }

  // MARK: - Scrolling

  private func post(_ scroll: ScrollEvent) {
    let phase: Int64
    var pixels = SIMD2<Int32>.zero

    switch scroll.phase {
    case .began:
      scrollRemainder = .zero
      phase = Self.scrollPhaseBegan
      pixels = takeWholePixels(adding: scroll.delta)
    case .changed:
      phase = Self.scrollPhaseChanged
      pixels = takeWholePixels(adding: scroll.delta)
      // Posting a zero-delta change would only add noise; the remainder waits for the next one.
      if pixels == .zero { return }
    case .ended:
      scrollRemainder = .zero
      phase = Self.scrollPhaseEnded
    }

    guard
      let event = CGEvent(
        scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
        wheel1: pixels.y, wheel2: pixels.x, wheel3: 0)
    else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    event.post(tap: .cghidEventTap)
    counters.scrollEvents += 1
  }

  /// Adds `delta` to the carried remainder and returns the whole pixels, keeping the rest.
  private func takeWholePixels(adding delta: SIMD2<Double>) -> SIMD2<Int32> {
    let total = scrollRemainder + delta
    let whole = SIMD2(total.x.rounded(.towardZero), total.y.rounded(.towardZero))
    scrollRemainder = total - whole
    return SIMD2(Self.clampedInt32(whole.x), Self.clampedInt32(whole.y))
  }

  private static func clampedInt32(_ value: Double) -> Int32 {
    guard value.isFinite else { return 0 }
    return Int32(max(Double(Int32.min), min(Double(Int32.max), value)))
  }

  // `CGScrollPhase` raw values, which the field takes as plain integers.
  private static let scrollPhaseBegan: Int64 = 1
  private static let scrollPhaseChanged: Int64 = 2
  private static let scrollPhaseEnded: Int64 = 4
}

extension MouseButton {
  fileprivate var coreGraphicsButton: CGMouseButton {
    switch self {
    case .left: .left
    case .right: .right
    case .middle: .center
    }
  }

  fileprivate var downType: CGEventType {
    switch self {
    case .left: .leftMouseDown
    case .right: .rightMouseDown
    case .middle: .otherMouseDown
    }
  }

  fileprivate var upType: CGEventType {
    switch self {
    case .left: .leftMouseUp
    case .right: .rightMouseUp
    case .middle: .otherMouseUp
    }
  }
}
