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

  /// The Enter key below the left button.
  public var returnKey = ReturnKeySettings()

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
    returnKey = (try? container.decodeIfPresent(ReturnKeySettings.self, forKey: .returnKey))
      ?? defaults.returnKey
  }
}

/// Tunables for the Enter key: the bottom of the left half's touch area, below the left button,
/// where a tap presses Return on the Mac.
public struct ReturnKeySettings: Codable, Equatable, Sendable {
  public var isEnabled = true

  /// Where the key starts and ends, as fractions of the surface's height from the top. The left
  /// button ends where it starts; the right button keeps the top `acceptedFraction`. The key
  /// reaches below that, into what is otherwise the palm's area.
  public var top: Double = 0.4
  public var bottom: Double = 0.6

  /// The longest touch that counts as a tap, seconds. A longer one is a resting palm or thumb and
  /// presses nothing.
  public var maxTapDuration: TimeInterval = 0.5

  public init() {}

  /// Decodes field by field, so settings saved before a field existed keep the rest.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = ReturnKeySettings()
    isEnabled = try container.decode(.isEnabled, default: defaults.isEnabled)
    top = try container.decode(.top, default: defaults.top)
    bottom = try container.decode(.bottom, default: defaults.bottom)
    maxTapDuration = try container.decode(.maxTapDuration, default: defaults.maxTapDuration)
  }

  /// Whether the key is on and has some height.
  var isActive: Bool {
    isEnabled && bottom > top
  }
}

/// Turns raw touches on the phone's surface into mouse-button events.
///
/// Rules (see `docs/architecture.md`, touch state machine):
/// - A touch is accepted when it begins in the top `acceptedFraction` of the surface, or on the
///   Enter key, and outside the side bands. Touches that begin anywhere else are ignored for their
///   whole life: they emit nothing and never count as a finger.
/// - The accepted area is split down the middle: a touch that begins in the left half is the left
///   button, one in the right half the right button. Its `.contact` and press are emitted at once,
///   at the touch's time. With the Enter key on, the left button ends where the key starts.
/// - A touch that begins on the scroll wheel (`wheelRect(in:)`, when the wheel is on) is no
///   button; the caller rolls the `ScrollWheel` with it, and reports a tap on it with
///   `middleClick(at:)`.
/// - A touch that begins on the Enter key (`returnKeyRect(in:)`) is no button either. It emits
///   `.contact` when it lands and when it lifts, and `.returnKey` at the lift if it was down no
///   longer than `ReturnKeySettings.maxTapDuration`. Another touch on the key meanwhile is
///   ignored.
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

  /// The touch on the Enter key and when it landed.
  private var returnKeyTouch: (id: Int, landedAt: TimeInterval)?

  public init(settings: TouchSettings = TouchSettings()) {
    self.settings = settings
  }

  /// Buttons currently pressed, as far as the events emitted so far say.
  public var heldButtons: MouseButtons {
    presses.keys.reduce(into: MouseButtons()) { $0.insert($1.mask) }
  }

  /// Whether a finger is on the Enter key.
  public var isReturnKeyTouched: Bool {
    returnKeyTouch != nil
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
    guard !isOnWheel(location, in: size), !presses.values.contains(where: { $0.owner == id }),
      returnKeyTouch?.id != id
    else { return events }
    if isOnReturnKey(location, in: size) {
      guard returnKeyTouch == nil else { return events }
      returnKeyTouch = (id, time)
      events.append(.contact(time: time))
      return events
    }
    let button = Self.button(at: location, in: size)
    guard isAccepted(location, for: button, in: size) else { return events }
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
    if let touch = returnKeyTouch, touch.id == id {
      returnKeyTouch = nil
      events.append(.contact(time: time))
      let heldFor = time - touch.landedAt
      if heldFor <= settings.returnKey.maxTapDuration {
        events.append(.returnKey(heldFor: heldFor, time: time))
      }
      return events
    }
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

  /// The Enter key, in the surface's coordinates: the left half between `ReturnKeySettings.top`
  /// and `bottom`. Nil when it's off.
  public func returnKeyRect(in size: CGSize) -> CGRect? {
    let key = settings.returnKey
    guard key.isActive else { return nil }
    let top = size.height * CGFloat(key.top)
    return CGRect(
      x: 0, y: top, width: size.width / 2, height: size.height * CGFloat(key.bottom) - top)
  }

  /// A touch beginning at `location` taps the Enter key rather than pressing a button. The wheel
  /// comes first where the two meet.
  public func isOnReturnKey(_ location: CGPoint, in size: CGSize) -> Bool {
    guard isBetweenSideBands(location, in: size), !isOnWheel(location, in: size),
      let rect = returnKeyRect(in: size)
    else { return false }
    return rect.contains(location)
  }

  /// Releases every held button at `time` and forgets every touch, e.g. when the app goes
  /// inactive. Touches still on the screen stay ignored until they lift.
  public mutating func cancelAll(time: TimeInterval) -> [TouchEvent] {
    var events = advance(to: time)
    for button in MouseButton.allCases where presses[button] != nil {
      events.append(release(button, at: time))
    }
    returnKeyTouch = nil
    return events
  }

  // MARK: - Helpers

  /// Whether `location` is in the touch area: the top `acceptedFraction`, between the side bands.
  private func isAccepted(_ location: CGPoint, in size: CGSize) -> Bool {
    location.y < size.height * CGFloat(settings.acceptedFraction)
      && isBetweenSideBands(location, in: size)
  }

  /// Whether a touch at `location` may press `button`: the left button ends where the Enter key
  /// starts.
  private func isAccepted(_ location: CGPoint, for button: MouseButton, in size: CGSize) -> Bool {
    guard button == .left, settings.returnKey.isActive else {
      return isAccepted(location, in: size)
    }
    return location.y < size.height * CGFloat(settings.returnKey.top)
      && isBetweenSideBands(location, in: size)
  }

  private func isBetweenSideBands(_ location: CGPoint, in size: CGSize) -> Bool {
    let band = CGFloat(settings.sideRejectBand)
    return location.x >= band && location.x <= size.width - band
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
