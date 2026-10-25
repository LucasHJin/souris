import Darwin
import Foundation
import SystemConfiguration

/// Facts about this Mac that the phone and the menu show.
enum SystemInfo {
  /// The name from System Settings > General > About, or "Mac" if it can't be read.
  ///
  /// This avoids `Host.current()`, which can block on a DNS lookup.
  static func computerName() -> String {
    let name = SCDynamicStoreCopyComputerName(nil, nil) as String?
    guard let name, !name.isEmpty else { return "Mac" }
    return name
  }

  /// This Mac's IPv4 address on the local network, for typing into the phone when Bonjour is
  /// blocked. Prefers Wi-Fi/Ethernet (`en0` first) and skips loopback, link-local and tunnel
  /// interfaces.
  static func localIPv4Address() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }

    var best: (rank: Int, address: String)?
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(bitPattern: entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
      guard let socketAddress = entry.pointee.ifa_addr,
        socketAddress.pointee.sa_family == sa_family_t(AF_INET)
      else { continue }
      guard let rank = rank(ofInterface: String(cString: entry.pointee.ifa_name)) else {
        continue
      }
      guard let address = numericHost(of: socketAddress), !address.hasPrefix("169.254.") else {
        continue
      }
      if let current = best, current.rank <= rank { continue }
      best = (rank, address)
    }
    return best?.address
  }

  /// Lower is better. `nil` excludes interfaces a phone can't reach.
  private static func rank(ofInterface name: String) -> Int? {
    if name == "en0" { return 0 }
    if name.hasPrefix("en") { return 1 }
    let unreachable = ["utun", "awdl", "llw", "ap", "gif", "stf", "anpi"]
    if unreachable.contains(where: { name.hasPrefix($0) }) { return nil }
    return 2
  }

  private static func numericHost(of address: UnsafePointer<sockaddr>) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let status = getnameinfo(
      address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
      NI_NUMERICHOST)
    guard status == 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
