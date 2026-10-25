import AppKit
import CoreGraphics

import SourisCore

/// Presses the Mac's own keyboard shortcuts for what the phone asks for.
///
/// The keys come from System Settings → Keyboard → Keyboard Shortcuts, read afresh for each
/// press from the `com.apple.symbolichotkeys` defaults, which list only shortcuts someone has
/// changed; the rest have macOS's defaults. A keyboard's own Mission Control and Spotlight keys
/// can't be pressed instead: they send hardware codes an app can't synthesize.
///
/// Not thread-safe: use it only on the input queue.
final class ShortcutPoster {
  /// A key and the modifiers held with it.
  struct KeyCombo: Equatable {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
  }

  /// What a press did, for the log.
  enum Outcome {
    case pressed(KeyCombo)
    case openedMissionControl
    case disabled
  }

  /// Dictation's custom shortcut, ⌃⌥D, which Souris presses when the 🎤 key starts nothing. Set
  /// the same shortcut in System Settings → Keyboard → Dictation → Shortcut → Customize; ⌃⌥Space
  /// switches input sources. Spotlight never passes it to Dictation.
  static let dictation = KeyCombo(keyCode: 0x02, flags: [.maskControl, .maskAlternate])

  /// The keyboard's 🎤 key (F5 on the M1 Pro) as macOS sees it. Unlike ⌃⌥D it reaches Dictation
  /// in Spotlight too: the Siri process takes it and, for a press shorter than its 0.42 s hold
  /// threshold (holding asks Siri), passes it on to Dictation.
  private static let microphoneKeyCode: CGKeyCode = 0xB0

  private static let missionControlApp = URL(
    fileURLWithPath: "/System/Applications/Mission Control.app")

  /// The modifier keys, in the order they go down, with their key codes. Fn isn't one: it rides
  /// on the arrow and function keys as a flag, and pressing it alone can open the emoji picker
  /// or start dictation.
  private static let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
    (.maskControl, 0x3B),
    (.maskAlternate, 0x3A),
    (.maskShift, 0x38),
    (.maskCommand, 0x37),
  ]

  private let source = CGEventSource(stateID: .hidSystemState)

  func press(_ shortcut: MacShortcut) -> Outcome {
    if let combo = Self.keys(for: shortcut) {
      post(combo)
      return .pressed(combo)
    }
    switch shortcut {
    case .missionControl, .appWindows:
      // Mission Control's app opens it whatever the shortcuts are; "2" asks for one app's
      // windows.
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.arguments = shortcut == .appWindows ? ["2"] : []
      NSWorkspace.shared.openApplication(
        at: Self.missionControlApp, configuration: configuration)
      return .openedMissionControl
    case .spotlight:
      // With Spotlight's shortcut off, a launcher such as Raycast usually has ⌘Space.
      let combo = Self.defaultHotKey(for: shortcut).keys
      post(combo)
      return .pressed(combo)
    case .showDesktop:
      return .disabled
    }
  }

  /// Presses `combo` the way a keyboard does: its modifiers down, the key down and up, then the
  /// modifiers up, so none is left held.
  ///
  /// macOS takes the modifiers of the last posted event as held, and the mouse events posted
  /// after it carry them. Posting only the key, with its modifiers as flags, left Control held
  /// after ⌃↑ and ⌃⌥D, so every later left click was a Control-click and opened a context menu.
  func post(_ combo: KeyCombo) {
    let modifiers = Self.modifierKeys.filter { combo.flags.contains($0.flag) }
    var held: CGEventFlags = []
    for modifier in modifiers {
      held.insert(modifier.flag)
      post(key: modifier.keyCode, isDown: true, flags: held)
    }
    post(key: combo.keyCode, isDown: true, flags: combo.flags)
    // Fn belongs to the key itself, so it lifts with it.
    post(key: combo.keyCode, isDown: false, flags: held)
    for modifier in modifiers.reversed() {
      held.remove(modifier.flag)
      post(key: modifier.keyCode, isDown: false, flags: held)
    }
  }

  /// Presses the 🎤 key, down and up back to back so it never reads as held. Both carry the Fn
  /// flag, as a real press's do: without it the release might not count as the key's, and the
  /// press would then turn into a hold.
  func pressMicrophoneKey() {
    post(key: Self.microphoneKeyCode, isDown: true, flags: .maskSecondaryFn)
    post(key: Self.microphoneKeyCode, isDown: false, flags: .maskSecondaryFn)
  }

  private func post(key: CGKeyCode, isDown: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
    else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
  }

  // MARK: - System shortcuts

  /// macOS's id for the shortcut in `AppleSymbolicHotKeys`, and its keys until someone changes
  /// them. Arrow and function keys carry the Fn flag, as a real keyboard's do.
  private static func defaultHotKey(for shortcut: MacShortcut) -> (id: Int, keys: KeyCombo) {
    switch shortcut {
    case .missionControl:
      (32, KeyCombo(keyCode: 0x7E, flags: [.maskControl, .maskSecondaryFn]))  // ⌃↑
    case .appWindows:
      (33, KeyCombo(keyCode: 0x7D, flags: [.maskControl, .maskSecondaryFn]))  // ⌃↓
    case .showDesktop:
      (36, KeyCombo(keyCode: 0x67, flags: [.maskSecondaryFn]))  // F11
    case .spotlight:
      (64, KeyCombo(keyCode: 0x31, flags: [.maskCommand]))  // ⌘Space
    }
  }

  /// The keys System Settings has for `shortcut`, or nil if it is turned off there.
  ///
  /// An entry's `parameters` are the character, the virtual key code (0xFFFF for none) and the
  /// modifier flags, whose bits are the same as `CGEventFlags`.
  private static func keys(for shortcut: MacShortcut) -> KeyCombo? {
    let (id, fallback) = defaultHotKey(for: shortcut)
    guard
      let hotKeys = CFPreferencesCopyAppValue(
        "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        as? [String: Any],
      let entry = hotKeys[String(id)] as? [String: Any]
    else { return fallback }
    if let isEnabled = entry["enabled"] as? Bool, !isEnabled {
      return nil
    }
    guard let value = entry["value"] as? [String: Any],
      let parameters = value["parameters"] as? [Int], parameters.count >= 3
    else { return fallback }
    guard parameters[1] != 0xFFFF else { return nil }
    return KeyCombo(
      keyCode: CGKeyCode(parameters[1]), flags: CGEventFlags(rawValue: UInt64(parameters[2])))
  }
}

extension CGEventFlags {
  /// Control, Option, Shift, Command and Fn: the flags a held key sets.
  static let modifierKeys: CGEventFlags = [
    .maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn,
  ]

  /// The held modifier keys, for the log, such as "control+option"; nil when none is held.
  var modifierNames: String? {
    let names: [(CGEventFlags, String)] = [
      (.maskControl, "control"),
      (.maskAlternate, "option"),
      (.maskShift, "shift"),
      (.maskCommand, "command"),
      (.maskSecondaryFn, "fn"),
    ]
    let held = names.filter { contains($0.0) }.map(\.1)
    return held.isEmpty ? nil : held.joined(separator: "+")
  }
}
