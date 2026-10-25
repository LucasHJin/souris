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

  /// The Enter and Delete keys below the buttons.
  public var keys = KeySettings()

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
    keys = (try? container.decodeIfPresent(KeySettings.self, forKey: .keys)) ?? defaults.keys
  }
}

/// Tunables for the keys below the buttons: Enter in the left half, where a tap presses Return on
/// the Mac, and Delete in the right half, where a tap presses Delete and a hold keeps deleting.
public struct KeySettings: Codable, Equatable, Sendable {
  public var isReturnEnabled = true
  public var isDeleteEnabled = true

  /// Where the keys start and end, as fractions of the surface's height from the top. A button
  /// with its key on ends where the key starts. The keys reach below `acceptedFraction`, into what
  /// is otherwise the palm's area.
  public var top: Double = 0.4
  public var bottom: Double = 0.6

  /// The longest touch on Enter that counts as a tap, seconds. A longer one is a resting palm or
  /// thumb and presses nothing.
  public var maxTapDuration: TimeInterval = 0.5

  /// How long Delete is held before it presses again, and the time between its repeats after
  /// that, seconds. Lifting before the first repeat presses it once.
  public var repeatDelay: TimeInterval = 0.4
  public var repeatInterval: TimeInterval = 1.0 / 30

  public init() {}

  /// Decodes field by field, so settings saved before a field existed keep the rest.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = KeySettings()
    isReturnEnabled = try container.decode(.isReturnEnabled, default: defaults.isReturnEnabled)
    isDeleteEnabled = try container.decode(.isDeleteEnabled, default: defaults.isDeleteEnabled)
    top = try container.decode(.top, default: defaults.top)
    bottom = try container.decode(.bottom, default: defaults.bottom)
    maxTapDuration = try container.decode(.maxTapDuration, default: defaults.maxTapDuration)
    repeatDelay = try container.decode(.repeatDelay, default: defaults.repeatDelay)
    repeatInterval = try container.decode(.repeatInterval, default: defaults.repeatInterval)
  }

  /// Whether `key` is on and has some height.
  func isActive(_ key: TouchKey) -> Bool {
    let isEnabled =
      switch key {
      case .returnKey: isReturnEnabled
      case .deleteKey: isDeleteEnabled
      }
    return isEnabled && bottom > top
  }
}

/// Turns raw touches on the phone's surface into mouse-button events.
///
/// Rules (see `docs/architecture.md`, touch state machine):
/// - A touch is accepted when it begins in the top `acceptedFraction` of the surface, or on a key,
///   and outside the side bands. Touches that begin anywhere else are ignored for their whole
///   life: they emit nothing and never count as a finger.
/// - The accepted area is split down the middle: a touch that begins in the left half is the left
///   button, one in the right half the right button. Its `.contact` and press are emitted at once,
///   at the touch's time. Each button ends where the key below it starts, while that key is on.
/// - A touch that begins on the scroll wheel (`wheelRect(in:)`, when the wheel is on) is no
///   button; the caller rolls the `ScrollWheel` with it, and reports a tap on it with
///   `middleClick(at:)`.
/// - A touch that begins on a key (`keyRect(_:in:)`) is no button either. It emits `.contact` when
///   it lands and when it lifts. Enter emits `.key` at the lift if it was down no longer than
///   `KeySettings.maxTapDuration`. Delete emits `.key` at the lift if it hasn't repeated yet, and
///   repeats while held: `repeatDelay` after it landed and every `repeatInterval` after that
///   (from `advance(to:)`). Another touch on a held key is ignored.
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

  /// A finger on a key.
  private struct KeyTouch {
    var id: Int
    var landedAt: TimeInterval

    /// How many times Delete has repeated during this touch.
    var repeats = 0
  }

  /// Delete's repeats are never closer together than this, whatever the settings say.
  private static let minimumRepeatInterval: TimeInterval = 0.01

  private var presses: [MouseButton: Press] = [:]
  private var keyTouches: [TouchKey: KeyTouch] = [:]

  public init(settings: TouchSettings = TouchSettings()) {
    self.settings = settings
  }

  /// Buttons currently pressed, as far as the events emitted so far say.
  public var heldButtons: MouseButtons {
    presses.keys.reduce(into: MouseButtons()) { $0.insert($1.mask) }
  }

  /// The keys a finger is on.
  public var touchedKeys: Set<TouchKey> {
    Set(keyTouches.keys)
  }

  /// The next time `advance(to:)` must be called, or `nil` when nothing is pending.
  public var nextDeadline: TimeInterval? {
    (presses.values.compactMap(\.scheduledRelease) + [nextDeleteRepeat].compactMap { $0 }).min()
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
      !keyTouches.values.contains(where: { $0.id == id })
    else { return events }
    if let key = key(at: location, in: size) {
      guard keyTouches[key] == nil else { return events }
      keyTouches[key] = KeyTouch(id: id, landedAt: time)
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
    if let (key, touch) = keyTouches.first(where: { $0.value.id == id }) {
      keyTouches[key] = nil
      events.append(.contact(time: time))
      let heldFor = time - touch.landedAt
      let isTap =
        switch key {
        case .returnKey: heldFor <= settings.keys.maxTapDuration
        case .deleteKey: touch.repeats == 0
        }
      if isTap {
        events.append(.key(key, heldFor: heldFor, isRepeat: false, time: time))
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

  /// Emits every release and Delete repeat that's due at or before `time`, in time order.
  public mutating func advance(to time: TimeInterval) -> [TouchEvent] {
    let due = presses
      .compactMap { button, press in
        press.scheduledRelease.flatMap { $0 <= time ? (button, $0) : nil }
      }
      .sorted { ($0.1, $0.0.rawValue) < ($1.1, $1.0.rawValue) }
    var events = due.map { button, releaseTime in release(button, at: releaseTime) }
    if var touch = keyTouches[.deleteKey] {
      var repeatTime = nextRepeat(of: touch)
      while repeatTime <= time {
        touch.repeats += 1
        events.append(
          .key(.deleteKey, heldFor: repeatTime - touch.landedAt, isRepeat: true, time: repeatTime))
        repeatTime = nextRepeat(of: touch)
      }
      keyTouches[.deleteKey] = touch
    }
    return events.enumerated()
      .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
      .map(\.element)
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

  /// A key, in the surface's coordinates: Enter is the left half between `KeySettings.top` and
  /// `bottom`, Delete the right half. Nil when it's off.
  public func keyRect(_ key: TouchKey, in size: CGSize) -> CGRect? {
    let keys = settings.keys
    guard keys.isActive(key) else { return nil }
    let half = size.width / 2
    let top = size.height * CGFloat(keys.top)
    return CGRect(
      x: key == .returnKey ? 0 : half, y: top, width: half,
      height: size.height * CGFloat(keys.bottom) - top)
  }

  /// The key a touch beginning at `location` presses rather than a button, if any. The wheel comes
  /// first where they meet.
  public func key(at location: CGPoint, in size: CGSize) -> TouchKey? {
    guard isBetweenSideBands(location, in: size), !isOnWheel(location, in: size) else {
      return nil
    }
    return TouchKey.allCases.first { keyRect($0, in: size)?.contains(location) == true }
  }

  /// Releases every held button at `time` and forgets every touch, e.g. when the app goes
  /// inactive. Touches still on the screen stay ignored until they lift.
  public mutating func cancelAll(time: TimeInterval) -> [TouchEvent] {
    var events = advance(to: time)
    for button in MouseButton.allCases where presses[button] != nil {
      events.append(release(button, at: time))
    }
    keyTouches.removeAll()
    return events
  }

  // MARK: - Helpers

  /// Whether `location` is in the touch area: the top `acceptedFraction`, between the side bands.
  private func isAccepted(_ location: CGPoint, in size: CGSize) -> Bool {
    location.y < size.height * CGFloat(settings.acceptedFraction)
      && isBetweenSideBands(location, in: size)
  }

  /// Whether a touch at `location` may press `button`: each button ends where the key below it
  /// starts.
  private func isAccepted(_ location: CGPoint, for button: MouseButton, in size: CGSize) -> Bool {
    let keyBelow: TouchKey = button == .left ? .returnKey : .deleteKey
    guard settings.keys.isActive(keyBelow) else {
      return isAccepted(location, in: size)
    }
    return location.y < size.height * CGFloat(settings.keys.top)
      && isBetweenSideBands(location, in: size)
  }

  /// When Delete presses next while `touch` holds it.
  private func nextRepeat(of touch: KeyTouch) -> TimeInterval {
    let keys = settings.keys
    return touch.landedAt + keys.repeatDelay
      + Double(touch.repeats) * max(Self.minimumRepeatInterval, keys.repeatInterval)
  }

  /// When the held Delete key presses next, or nil when no finger is on it.
  private var nextDeleteRepeat: TimeInterval? {
    keyTouches[.deleteKey].map(nextRepeat(of:))
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
