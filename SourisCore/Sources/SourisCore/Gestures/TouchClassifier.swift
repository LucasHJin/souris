import CoreGraphics
import Foundation

/// Tunables for the touch surface.
public struct TouchSettings: Codable, Equatable, Sendable {
  /// A second touch landing within this many seconds of the first makes a right click.
  public var twoFingerWindow: TimeInterval = 0.05

  /// The fraction of the surface's height, from the top, that accepts touches. The rest is where
  /// the palm rests and is ignored.
  public var acceptedFraction: Double = 0.5

  /// Points along each long (left and right) edge where touches are ignored, against grip contact.
  public var sideRejectBand: Double = 6

  /// A press is held at least this long before its release is reported, so a very quick tap still
  /// reaches the Mac as a press and a release in separate packets.
  public var minimumPressDuration: TimeInterval = 0.03

  public init() {}
}

/// Turns raw touches on the phone's surface into mouse-button events.
///
/// Rules (see `docs/architecture.md`, touch state machine):
/// - A touch is accepted when it begins in the top `acceptedFraction` of the surface and outside
///   the side bands. Touches that begin anywhere else are ignored for their whole life: they emit
///   nothing and never count as a finger.
/// - With no button held, the first accepted touch emits `.contact` and opens the two-finger
///   window. A second accepted touch inside the window emits `.contact` and a right press at its
///   own time. If the window closes first, a left press is emitted with the window's deadline as
///   its time (from `advance(to:)`).
/// - If the first touch lifts before the window closes, the left press is emitted at the lift's
///   time, followed by `.contact`, and the release is due `minimumPressDuration` later.
/// - Accepted touches that begin while a button is held, or while the window is open after a
///   second finger, are extras: ignored for their whole life.
/// - A button is released when every touch that started it has lifted, emitting `.contact` at the
///   lift and the release at the lift's time, or at press time + `minimumPressDuration` if that is
///   later (then from `advance(to:)`).
/// - Cancelled touches are treated as lifts.
public struct TouchClassifier: Sendable {
  public var settings: TouchSettings

  /// Where the gesture is. The touches it depends on are in `owners`, and a pending release is
  /// in `scheduledRelease`.
  private enum Phase {
    case idle

    /// The first accepted touch is down. A left press is due at `deadline` unless a second touch
    /// joins first.
    case windowOpen(deadline: TimeInterval)

    /// The button is down. It is released once `owners` is empty and `minimumPressDuration` has
    /// passed since the press.
    case buttonHeld(MouseButton, pressedAt: TimeInterval)
  }

  private var phase = Phase.idle

  /// Accepted touches that started the open window or the held button and are still down. Any
  /// other touch is ignored, so it never appears here, and lifting it emits nothing.
  private var owners: Set<Int> = []

  /// When the held button is released, while its last owner has lifted and the minimum press
  /// duration hasn't passed yet.
  private var scheduledRelease: TimeInterval?

  /// The buttons whose press has been emitted and whose release hasn't been.
  private var emittedButtons: MouseButtons = []

  public init(settings: TouchSettings = TouchSettings()) {
    self.settings = settings
  }

  /// Buttons currently pressed, as far as the events emitted so far say.
  public var heldButtons: MouseButtons {
    emittedButtons
  }

  /// The next time `advance(to:)` must be called, or `nil` when nothing is pending.
  public var nextDeadline: TimeInterval? {
    switch phase {
    case .idle: nil
    case .windowOpen(let deadline): deadline
    case .buttonHeld: scheduledRelease
    }
  }

  /// Call from `touchesBegan` for each new touch.
  ///
  /// - Parameters:
  ///   - id: Stable for the touch's lifetime, e.g. `ObjectIdentifier(touch).hashValue`.
  ///   - location: In the surface's coordinates, origin at the top-left.
  ///   - size: The surface's size.
  ///   - time: `UITouch.timestamp`.
  public mutating func touchBegan(
    id: Int,
    location: CGPoint,
    in size: CGSize,
    time: TimeInterval
  ) -> [TouchEvent] {
    // A second finger may land exactly on the deadline and still count, so an open window only
    // closes here once the deadline is strictly past.
    var events = emitDue(by: time, closeWindowAtDeadline: false)
    guard isAccepted(location, in: size), !owners.contains(id) else { return events }

    switch phase {
    case .idle:
      owners.insert(id)
      phase = .windowOpen(deadline: time + settings.twoFingerWindow)
      events.append(.contact(time: time))

    case .windowOpen:
      owners.insert(id)
      phase = .buttonHeld(.right, pressedAt: time)
      emittedButtons.insert(.right)
      events.append(.contact(time: time))
      events.append(.button(.right, isDown: true, time: time))

    case .buttonHeld:
      // An extra touch: it stays ignored until it lifts.
      break
    }
    return events
  }

  /// Call from `touchesEnded` and `touchesCancelled` for each lifted touch.
  public mutating func touchEnded(id: Int, time: TimeInterval) -> [TouchEvent] {
    var events = emitDue(by: time, closeWindowAtDeadline: true)
    guard owners.remove(id) != nil else { return events }

    if case .windowOpen = phase {
      // Lifted before the window closed, so this is a quick tap. The press lands at the lift.
      phase = .buttonHeld(.left, pressedAt: time)
      emittedButtons.insert(.left)
      events.append(.button(.left, isDown: true, time: time))
    }
    events.append(.contact(time: time))
    events += releaseAfterLastOwnerLifts(at: time)
    return events
  }

  /// Emits every event that's due at or before `time` (window closing, delayed release).
  public mutating func advance(to time: TimeInterval) -> [TouchEvent] {
    emitDue(by: time, closeWindowAtDeadline: true)
  }

  /// Releases any held button at `time` and forgets every touch, e.g. when the app goes inactive.
  /// Touches still on the screen stay ignored until they lift.
  public mutating func cancelAll(time: TimeInterval) -> [TouchEvent] {
    var events = emitDue(by: time, closeWindowAtDeadline: true)
    if case .buttonHeld(let button, _) = phase {
      events.append(release(button, at: time))
    }
    owners = []
    scheduledRelease = nil
    phase = .idle
    return events
  }

  // MARK: - Helpers

  private func isAccepted(_ location: CGPoint, in size: CGSize) -> Bool {
    let fraction = CGFloat(settings.acceptedFraction)
    let band = CGFloat(settings.sideRejectBand)
    return location.y < size.height * fraction
      && location.x >= band
      && location.x <= size.width - band
  }

  /// Emits what is due by `time`, in time order: the left press of a window whose deadline has
  /// passed, and the release of a button whose scheduled release has come.
  private mutating func emitDue(
    by time: TimeInterval,
    closeWindowAtDeadline: Bool
  ) -> [TouchEvent] {
    var events: [TouchEvent] = []

    if case .windowOpen(let deadline) = phase {
      let closed = closeWindowAtDeadline ? deadline <= time : deadline < time
      if closed {
        phase = .buttonHeld(.left, pressedAt: deadline)
        emittedButtons.insert(.left)
        events.append(.button(.left, isDown: true, time: deadline))
      }
    }

    if case .buttonHeld(let button, _) = phase,
      let releaseTime = scheduledRelease,
      releaseTime <= time
    {
      events.append(release(button, at: releaseTime))
    }
    return events
  }

  /// Called when the last owner of a held button lifts at `time`. Releases at once if the minimum
  /// press duration has already passed, otherwise schedules the release for when it has.
  private mutating func releaseAfterLastOwnerLifts(at time: TimeInterval) -> [TouchEvent] {
    guard owners.isEmpty, case .buttonHeld(let button, let pressedAt) = phase else {
      return []
    }
    let releaseTime = max(time, pressedAt + settings.minimumPressDuration)
    if releaseTime > time {
      scheduledRelease = releaseTime
      return []
    }
    return [release(button, at: releaseTime)]
  }

  private mutating func release(_ button: MouseButton, at time: TimeInterval) -> TouchEvent {
    emittedButtons.subtract(button.mask)
    scheduledRelease = nil
    phase = .idle
    return .button(button, isDown: false, time: time)
  }
}
