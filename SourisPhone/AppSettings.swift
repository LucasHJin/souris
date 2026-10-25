import Foundation

import SourisCore

/// Where and how the phone talks to the Mac, as the engine needs it.
struct NetworkSettings: Equatable, Sendable {
  var target: ClientTarget
  var includesPeerToPeer: Bool
  var usesVoiceServiceClass: Bool
  var usesBluetooth: Bool
  var pausesPeerToPeerOnBluetooth: Bool
}

/// Everything the user can change, persisted as JSON in `UserDefaults`.
struct AppSettings: Codable, Equatable, Sendable {
  var pipeline = PipelineSettings()
  var touch = TouchSettings()
  var hapticsEnabled = true

  /// On while tuning, so the numbers are always in view.
  var showsDebugOverlay = true
  var autoFocus = true

  /// The Mac picked from the Bonjour list. `nil` takes the first one found.
  var macName: String?

  /// `host` or `host:port`. Empty (or unreadable) means find the Mac with Bonjour.
  var manualAddress = ""

  var includesPeerToPeer = false
  var usesVoiceServiceClass = true

  /// Carry the link over Bluetooth LE when the Mac connects that way, in preference to Wi-Fi.
  var usesBluetooth = true

  /// Stop peer-to-peer Wi-Fi browsing while Bluetooth carries the link, which may steady
  /// Bluetooth at the cost of a slower fall back to Wi-Fi. Off until the logs show it helps.
  var pausesPeerToPeerOnBluetooth = false

  init() {}

  /// Decodes field by field, keeping every field that still reads and defaulting the rest, so
  /// a field added to `SourisCore` doesn't wipe the tuned values.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pipeline = container.value(.pipeline, default: PipelineSettings())
    touch = container.value(.touch, default: TouchSettings())
    hapticsEnabled = container.value(.hapticsEnabled, default: true)
    showsDebugOverlay = container.value(.showsDebugOverlay, default: true)
    autoFocus = container.value(.autoFocus, default: true)
    macName = try? container.decodeIfPresent(String.self, forKey: .macName)
    manualAddress = container.value(.manualAddress, default: "")
    includesPeerToPeer = container.value(.includesPeerToPeer, default: false)
    usesVoiceServiceClass = container.value(.usesVoiceServiceClass, default: true)
    usesBluetooth = container.value(.usesBluetooth, default: true)
    pausesPeerToPeerOnBluetooth = container.value(.pausesPeerToPeerOnBluetooth, default: false)
  }

  /// Where the client connects: the manual address when it parses, otherwise Bonjour.
  var target: ClientTarget {
    if let address = ManualAddress.parse(manualAddress) {
      return .host(address.host, port: address.port)
    }
    return .bonjour(name: macName)
  }

  var network: NetworkSettings {
    NetworkSettings(
      target: target,
      includesPeerToPeer: includesPeerToPeer,
      usesVoiceServiceClass: usesVoiceServiceClass,
      usesBluetooth: usesBluetooth,
      pausesPeerToPeerOnBluetooth: pausesPeerToPeerOnBluetooth)
  }
}

extension KeyedDecodingContainer {
  fileprivate func value<Value: Decodable>(_ key: Key, default fallback: Value) -> Value {
    (try? decode(Value.self, forKey: key)) ?? fallback
  }
}
