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

  private static let missionControlApp = URL(
    fileURLWithPath: "/System/Applications/Mission Control.app")

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

  /// Presses `combo` once: key down, then key up, with its modifiers on both.
  func post(_ combo: KeyCombo) {
    for isDown in [true, false] {
      guard
        let event = CGEvent(
          keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: isDown)
      else { return }
      event.flags = combo.flags
      event.post(tap: .cghidEventTap)
    }
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
