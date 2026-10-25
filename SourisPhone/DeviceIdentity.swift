import Foundation
import UIKit

/// Who this phone says it is in its hello packet.
struct DeviceIdentity: Sendable {
  var id: UUID
  var name: String

  private static let idKey = "souris.deviceID"

  /// Loads the stored ID, creating and storing one on first use.
  @MainActor
  static func load() -> DeviceIdentity {
    let defaults = UserDefaults.standard
    let id: UUID
    if let stored = defaults.string(forKey: idKey), let existing = UUID(uuidString: stored) {
      id = existing
    } else {
      id = UUID()
      defaults.set(id.uuidString, forKey: idKey)
    }
    return DeviceIdentity(id: id, name: UIDevice.current.name)
  }
}
