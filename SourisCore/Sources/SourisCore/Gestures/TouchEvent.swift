import Foundation

/// A key below the buttons: Enter below the left button, Delete below the right.
public enum TouchKey: CaseIterable, Codable, Sendable {
  case returnKey
  case deleteKey

  /// The Mac key it presses.
  public var shortcut: MacShortcut {
    switch self {
    case .returnKey: .returnKey
    case .deleteKey: .deleteKey
    }
  }
}

/// What the touch classifier tells the motion pipeline.
public enum TouchEvent: Equatable, Codable, Sendable {
  /// An accepted touch landed or lifted. The impact jolts the phone, so the pipeline starts a click
  /// freeze and suppresses tilt scroll around it. `time` is `UITouch.timestamp` (uptime seconds).
  case contact(time: TimeInterval)

  /// A mouse button changed. `time` is when the change took effect, on the same clock.
  case button(MouseButton, isDown: Bool, time: TimeInterval)

  /// A press of a key below the buttons, which presses Return or Delete on the Mac: a tap when it
  /// lifts, or a repeat while Delete is held. `heldFor` is how long the finger has been down;
  /// `time` is when the key pressed.
  case key(TouchKey, heldFor: TimeInterval, isRepeat: Bool, time: TimeInterval)

  /// The event's time.
  public var time: TimeInterval {
    switch self {
    case .contact(let time): time
    case .button(_, _, let time): time
    case .key(_, _, _, let time): time
    }
  }
}
