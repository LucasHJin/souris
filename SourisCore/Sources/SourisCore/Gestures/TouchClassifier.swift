import CoreGraphics
import Foundation

/// Tunables for the touch surface.
public struct TouchSettings: Codable, Equatable, Sendable {
  /// The fraction of the surface's height, from the top, that accepts touches. The rest is where
  /// the palm rests and is ignored.
  public var acceptedFraction: Double = 0.5

  /// Points along each long (left and right) edge where touches are ignored, against grip contact.
  public var sideRejectBand: Double = 6

  /// A press is held at least this long before its release is reported, so a very quick tap still
  /// reaches the Mac as a press and a release in separate packets.
  public var minimumPressDuration: TimeInterval = 0.03

  /// The scroll wheel between the two buttons.
  public var wheel = ScrollWheelSettings()

  public init() {}

  /// Decodes field by field, so settings saved before a field existed keep the rest.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = TouchSettings()
    acceptedFraction = try container.decode(.acceptedFraction, default: defaults.acceptedFraction)
    sideRejectBand = try container.decode(.sideRejectBand, default: defaults.sideRejectBand)
    minimumPressDuration = try container.decode(
      .minimumPressDuration, default: defaults.minimumPressDuration)
    wheel = (try? container.decodeIfPresent(ScrollWheelSettings.self, forKey: .wheel))
      ?? defaults.wheel
  }
}

/// Turns raw touches on the phone's surface into mouse-button events.
///
/// Rules (see `docs/architecture.md`, touch state machine):
/// - A touch is accepted when it begins in the top `acceptedFraction` of the surface and outside
///   the side bands. Touches that begin anywhere else are ignored for their whole life: they emit
///   nothing and never count as a finger.
/// - The accepted area is split down the middle: a touch that begins in the left half is the left
///   button, one in the right half the right button. Its `.contact` and press are emitted at once,
///   at the touch's time.
/// - A touch that begins on the scroll wheel (`wheelRect(in:)`, when the wheel is on) is no
///   button; the caller rolls the `ScrollWheel` with it, and reports a tap on it with
///   `middleClick(at:)`.
/// - A touch that begins in a half whose button is already held (or whose release is still
///   pending) is an extra: ignored for its whole life. The two buttons are independent, so one
///   finger in each half holds both.
/// - A button is released when the touch that pressed it lifts, emitting `.contact` at the lift
///   and the release at the lift's time, or at press time + `minimumPressDuration` if that is
///   later (then from `advance(to:)`).
/// - Cancelled touches are treated as lifts.
public struct TouchClassifier: Sendable {
  public var settings: TouchSettings

  /// A button pressed by a touch that is still down, or whose release is waiting out the minimum
  /// press duration.
  private struct Press {
    /// The touch holding the button, nil once it has lifted.
    var owner: Int?
    var pressedAt: TimeInterval

    /// When the release is due, once the owner has lifted before the minimum press duration.
    var scheduledRelease: TimeInterval?
  }

  private var presses: [MouseButton: Press] = [:]

  public init(settings: TouchSettings = TouchSettings()) {
    self.settings = settings
  }

  /// Buttons currently pressed, as far as the events emitted so far say.
  public var heldButtons: MouseButtons {
    presses.keys.reduce(into: MouseButtons()) { $0.insert($1.mask) }
  }

  /// The next time `advance(to:)` must be called, or `nil` when nothing is pending.
  public var nextDeadline: TimeInterval? {
    presses.values.compactMap(\.scheduledRelease).min()
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
    var events = advance(to: time)
    guard isAccepted(location, in: size), !isOnWheel(location, in: size),
      !presses.values.contains(where: { $0.owner == id })
    else { return events }
    let button = Self.button(at: location, in: size)
    guard presses[button] == nil else {
      // An extra touch on a held button: it stays ignored until it lifts.
      return events
    }
    presses[button] = Press(owner: id, pressedAt: time)
    events.append(.contact(time: time))
    events.append(.button(button, isDown: true, time: time))
    return events
  }

  /// Call from `touchesEnded` and `touchesCancelled` for each lifted touch.
  public mutating func touchEnded(id: Int, time: TimeInterval) -> [TouchEvent] {
    var events = advance(to: time)
    guard let (button, press) = presses.first(where: { $0.value.owner == id }) else {
      return events
    }
    events.append(.contact(time: time))
    let releaseTime = max(time, press.pressedAt + settings.minimumPressDuration)
    if releaseTime > time {
      presses[button]?.owner = nil
      presses[button]?.scheduledRelease = releaseTime
    } else {
      events.append(release(button, at: time))
    }
    return events
  }

  /// Emits every release that's due at or before `time`, in time order.
  public mutating func advance(to time: TimeInterval) -> [TouchEvent] {
    let due = presses
      .compactMap { button, press in
        press.scheduledRelease.flatMap { $0 <= time ? (button, $0) : nil }
      }
      .sorted { ($0.1, $0.0.rawValue) < ($1.1, $1.0.rawValue) }
    return due.map { button, releaseTime in release(button, at: releaseTime) }
  }

  /// A tap on the scroll wheel: a middle click, pressed at `time` and released
  /// `minimumPressDuration` later (from `advance(to:)`). Ignored while the middle button is held.
  public mutating func middleClick(at time: TimeInterval) -> [TouchEvent] {
    var events = advance(to: time)
    guard presses[.middle] == nil else { return events }
    presses[.middle] = Press(
      owner: nil, pressedAt: time, scheduledRelease: time + settings.minimumPressDuration)
    events.append(.contact(time: time))
    events.append(.button(.middle, isDown: true, time: time))
    return events
  }

  /// The scroll wheel's strip, in the surface's coordinates, or nil with the wheel off.
  public func wheelRect(in size: CGSize) -> CGRect? {
    let wheel = settings.wheel
    guard wheel.isEnabled else { return nil }
    let areaHeight = size.height * CGFloat(settings.acceptedFraction)
    let height = areaHeight * CGFloat(min(1, max(0.1, wheel.heightFraction)))
    let width = CGFloat(wheel.width)
    return CGRect(
      x: (size.width - width) / 2, y: (areaHeight - height) / 2, width: width, height: height)
  }

  /// A touch beginning at `location` rolls the scroll wheel rather than pressing a button.
  public func isOnWheel(_ location: CGPoint, in size: CGSize) -> Bool {
    guard isAccepted(location, in: size), let rect = wheelRect(in: size) else { return false }
    return rect.contains(location)
  }

  /// Releases every held button at `time` and forgets every touch, e.g. when the app goes
  /// inactive. Touches still on the screen stay ignored until they lift.
  public mutating func cancelAll(time: TimeInterval) -> [TouchEvent] {
    var events = advance(to: time)
    for button in MouseButton.allCases where presses[button] != nil {
      events.append(release(button, at: time))
    }
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

  /// The button for a touch at `location`: left of the middle is left, the rest right.
  static func button(at location: CGPoint, in size: CGSize) -> MouseButton {
    location.x < size.width / 2 ? .left : .right
  }

  private mutating func release(_ button: MouseButton, at time: TimeInterval) -> TouchEvent {
    presses[button] = nil
    return .button(button, isDown: false, time: time)
  }
}

extension KeyedDecodingContainer {
  /// The value stored under `key`, or `fallback` if the key is absent.
  fileprivate func decode<Value: Decodable>(_ key: Key, default fallback: Value) throws -> Value {
    try decodeIfPresent(Value.self, forKey: key) ?? fallback
  }
}
