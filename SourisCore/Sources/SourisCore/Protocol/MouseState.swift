/// The mouse buttons, as the bit set carried in every state packet.
public struct MouseButtons: OptionSet, Hashable, Codable, Sendable {
  public static let left = MouseButtons(rawValue: 1 << 0)
  public static let right = MouseButtons(rawValue: 1 << 1)
  public static let middle = MouseButtons(rawValue: 1 << 2)

  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }
}

/// A single mouse button.
public enum MouseButton: Int, CaseIterable, Codable, Sendable {
  case left
  case right
  case middle

  /// The button's bit in `MouseButtons`.
  public var mask: MouseButtons {
    switch self {
    case .left: .left
    case .right: .right
    case .middle: .middle
    }
  }
}

/// Status bits the phone reports alongside motion.
public struct StateFlags: OptionSet, Hashable, Codable, Sendable {
  /// The phone is lifted (clutch open); cursor output and tilt scroll are paused.
  public static let lifted = StateFlags(rawValue: 1 << 0)

  /// ARKit tracking is not `.normal`; translation is frozen.
  public static let trackingLimited = StateFlags(rawValue: 1 << 1)

  /// A scroll (volume buttons or tilt) is in progress. The Mac derives scroll phases from this
  /// bit.
  public static let scrollActive = StateFlags(rawValue: 1 << 2)

  /// The phone app is paused (settings open, app inactive). No output is produced.
  public static let paused = StateFlags(rawValue: 1 << 3)

  /// A finger holds the scroll wheel to dictate. The Mac presses its dictation shortcut when this
  /// sets and again when it clears.
  public static let dictating = StateFlags(rawValue: 1 << 4)

  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }
}

/// A Mac action the phone can ask for, which the Mac performs by pressing its own keyboard
/// shortcut for it, or a key. The raw value is the action's place in `ShortcutPresses` on the
/// wire, so new cases go at the end.
public enum MacShortcut: Int, CaseIterable, Codable, Sendable {
  case missionControl
  case appWindows
  case showDesktop
  case spotlight

  /// The Return key, from the phone's Enter key.
  case returnKey

  /// The name in logs, e.g. `missionControl`.
  public var logName: String {
    switch self {
    case .missionControl: "missionControl"
    case .appWindows: "appWindows"
    case .showDesktop: "showDesktop"
    case .spotlight: "spotlight"
    case .returnKey: "returnKey"
    }
  }
}

/// How many times the phone has asked for each `MacShortcut` this session, wrapping at 256.
///
/// Like the motion totals the counts are cumulative, so a lost or replaced packet loses no press
/// and a repeated one doesn't press twice: the Mac presses each shortcut as often as its count
/// went up.
public struct ShortcutPresses: Hashable, Codable, Sendable {
  /// Indexed by `MacShortcut.rawValue`.
  public private(set) var counts: [UInt8]

  public init() {
    counts = Array(repeating: 0, count: MacShortcut.allCases.count)
  }

  /// Counts read off the wire: missing ones are 0 and unknown ones are dropped.
  init(counts: some Sequence<UInt8>) {
    self.init()
    for (index, count) in zip(self.counts.indices, counts) {
      self.counts[index] = count
    }
  }

  public subscript(shortcut: MacShortcut) -> UInt8 {
    counts[shortcut.rawValue]
  }

  public mutating func press(_ shortcut: MacShortcut) {
    counts[shortcut.rawValue] &+= 1
  }

  /// The presses since `earlier`, in `MacShortcut` order.
  public func presses(since earlier: ShortcutPresses) -> [MacShortcut] {
    MacShortcut.allCases.flatMap { shortcut in
      Array(repeating: shortcut, count: Int(self[shortcut] &- earlier[shortcut]))
    }
  }
}

/// Everything the phone tells the Mac about the mouse, as absolute state.
///
/// Motion is cumulative so a lost packet loses nothing: the Mac applies the difference from the
/// last totals it applied.
public struct MouseState: Equatable, Codable, Sendable {
  /// Buttons currently held.
  public var buttons: MouseButtons

  /// Status bits.
  public var flags: StateFlags

  /// Cumulative cursor motion in screen points. +x is right, +y is down (toward the bottom of the
  /// screen), matching Core Graphics global coordinates.
  public var cursor: SIMD2<Double>

  /// Cumulative scroll in pixels. +y scrolls toward the top of the page (content moves down),
  /// which is the sign of `wheel1` in a pixel-unit `CGEvent`. +x scrolls toward the left edge of
  /// the page, the sign of `wheel2`.
  public var scroll: SIMD2<Double>

  public var shortcuts: ShortcutPresses

  public init(
    buttons: MouseButtons = [],
    flags: StateFlags = [],
    cursor: SIMD2<Double> = .zero,
    scroll: SIMD2<Double> = .zero,
    shortcuts: ShortcutPresses = ShortcutPresses()
  ) {
    self.buttons = buttons
    self.flags = flags
    self.cursor = cursor
    self.scroll = scroll
    self.shortcuts = shortcuts
  }
}
