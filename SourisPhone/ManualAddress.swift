import Foundation

import SourisCore

/// Parses the manual address field: an IP address or host name, with an optional `:port`.
enum ManualAddress {
  /// Returns `nil` for empty or unreadable text. Bare IPv6 addresses take the default port;
  /// put them in brackets to add a port, as in `[fe80::1]:47811`.
  static func parse(_ text: String) -> (host: String, port: UInt16)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

    if trimmed.hasPrefix("[") {
      guard let close = trimmed.firstIndex(of: "]") else { return nil }
      let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
      let rest = trimmed[trimmed.index(after: close)...]
      guard !host.isEmpty else { return nil }
      if rest.isEmpty { return (host, WireProtocol.defaultPort) }
      guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 else {
        return nil
      }
      return (host, port)
    }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    switch parts.count {
    case 1:
      return (trimmed, WireProtocol.defaultPort)
    case 2:
      guard !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0 else { return nil }
      return (String(parts[0]), port)
    default:
      return (trimmed, WireProtocol.defaultPort)
    }
  }
}
