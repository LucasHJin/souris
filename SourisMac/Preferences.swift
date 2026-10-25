import Foundation

import SourisCore

/// The settings that survive a relaunch, stored in `UserDefaults`.
struct Preferences {
  private let defaults = UserDefaults.standard

  /// Whether the server listens. On by default.
  var acceptsConnections: Bool {
    get { defaults.object(forKey: "acceptsConnections") as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: "acceptsConnections") }
  }

  /// Whether peer-to-peer Wi-Fi (AWDL) is allowed. Off by default because it adds latency.
  var allowsPeerToPeer: Bool {
    get { defaults.object(forKey: "allowsPeerToPeer") as? Bool ?? false }
    nonmutating set { defaults.set(newValue, forKey: "allowsPeerToPeer") }
  }

  /// How the pointer's motion is paced. Smooth by default.
  var pointerPacing: PointerPacing {
    get { defaults.string(forKey: "pointerPacing").flatMap(PointerPacing.init) ?? .smooth }
    nonmutating set { defaults.set(newValue.rawValue, forKey: "pointerPacing") }
  }

  /// The IDs of the phones the user allowed to control the pointer.
  var approvedDeviceIDs: Set<UUID> {
    get {
      let strings = defaults.stringArray(forKey: "approvedDeviceIDs") ?? []
      return Set(strings.compactMap { UUID(uuidString: $0) })
    }
    nonmutating set {
      defaults.set(newValue.map(\.uuidString).sorted(), forKey: "approvedDeviceIDs")
    }
  }
}
