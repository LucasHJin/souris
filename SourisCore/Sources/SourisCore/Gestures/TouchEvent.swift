import Foundation

/// What the touch classifier tells the motion pipeline.
public enum TouchEvent: Equatable, Codable, Sendable {
  /// An accepted touch landed or lifted. The impact jolts the phone, so the pipeline starts a click
  /// freeze and suppresses tilt scroll around it. `time` is `UITouch.timestamp` (uptime seconds).
  case contact(time: TimeInterval)

  /// A mouse button changed. `time` is when the change took effect, on the same clock.
  case button(MouseButton, isDown: Bool, time: TimeInterval)

  /// The event's time.
  public var time: TimeInterval {
    switch self {
    case .contact(let time): time
    case .button(_, _, let time): time
    }
  }
}
