/// Re-times the phone's scroll gestures to the `MotionPlayout`'s frames.
///
/// The phone's `.began`, `.changed` and `.ended` arrive with its packets, but the scrolling they
/// carry is shown frame by frame from the playout's scroll total. This posts each frame's share as
/// a `.changed` (the first one as `.began`) and holds the `.ended` back until the playout has shown
/// everything the gesture scrolled.
///
/// A gesture that begins while the previous one is still playing out continues it rather than
/// ending it early, so the posted scroll never runs backwards.
public struct PacedScroll: Sendable {
  /// Scroll received from the phone, pixels, as a cumulative total.
  public private(set) var received = SIMD2<Double>.zero

  /// Scroll posted so far, pixels.
  private var posted = SIMD2<Double>.zero

  /// A `.began` has been posted and its `.ended` hasn't.
  private var isOpen = false

  /// The phone has ended the gesture; `.ended` follows once everything is shown.
  private var isEnding = false

  public init() {}

  /// Adds one packet's scroll events.
  public mutating func receive(_ events: [ScrollEvent]) {
    for event in events {
      received += event.delta
      switch event.phase {
      case .began, .changed:
        isEnding = false
      case .ended:
        isEnding = true
      }
    }
  }

  /// The events to post for a frame that shows `total` scrolled.
  public mutating func show(_ total: SIMD2<Double>) -> [ScrollEvent] {
    var events: [ScrollEvent] = []
    let delta = total - posted
    if delta != .zero {
      posted = total
      events.append(ScrollEvent(phase: isOpen ? .changed : .began, delta: delta))
      isOpen = true
    }
    if isEnding && posted == received {
      if isOpen {
        events.append(ScrollEvent(phase: .ended, delta: .zero))
      }
      isOpen = false
      isEnding = false
    }
    return events
  }

  /// Ends any open gesture without showing the rest and starts the totals over from zero, e.g.
  /// when the phone goes silent and the playout is reset.
  public mutating func cancel() -> [ScrollEvent] {
    let events = isOpen ? [ScrollEvent(phase: .ended, delta: .zero)] : []
    self = PacedScroll()
    return events
  }
}
