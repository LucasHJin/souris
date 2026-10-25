import Network
import dnssd

extension NWError {
  /// True when the system refused Bonjour or local-network access: the user turned off Local
  /// Network for the app.
  var isLocalNetworkDenied: Bool {
    guard case .dns(let code) = self else { return false }
    return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
  }
}

extension Error {
  /// A readable one-line description, for status messages.
  var networkDescription: String {
    (self as? NWError)?.debugDescription ?? localizedDescription
  }
}
