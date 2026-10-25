import Network

// Log fields for Network.framework values, shared by the client's and the server's logging.

extension NWError {
  /// `error` (the description), `errorDomain` and `errorCode`, plus `localNetworkDenied` when
  /// that's the cause.
  var logFields: [String: LogValue] {
    var fields: [String: LogValue] = ["error": .string(debugDescription)]
    switch self {
    case .posix(let code):
      fields["errorDomain"] = "posix"
      fields["errorCode"] = .int(Int(code.rawValue))
    case .dns(let code):
      fields["errorDomain"] = "dns"
      fields["errorCode"] = .int(Int(code))
    case .tls(let status):
      fields["errorDomain"] = "tls"
      fields["errorCode"] = .int(Int(status))
    case .wifiAware(let code):
      fields["errorDomain"] = "wifiAware"
      fields["errorCode"] = .int(Int(code))
    @unknown default:
      fields["errorDomain"] = "unknown"
    }
    if isLocalNetworkDenied {
      fields["localNetworkDenied"] = true
    }
    return fields
  }
}

extension NWPath {
  /// Status, unsatisfied reason, interfaces with their types, cost flags, link quality and
  /// endpoints.
  var logFields: [String: LogValue] {
    var fields: [String: LogValue] = [
      "pathStatus": .string(statusName),
      "interfaces": .string(availableInterfaces.map(\.logName).joined(separator: ",")),
      "expensive": .bool(isExpensive),
      "constrained": .bool(isConstrained),
      "linkQuality": .string(linkQualityName),
    ]
    if status != .satisfied {
      fields["unsatisfiedReason"] = .string(unsatisfiedReasonName)
    }
    if let localEndpoint {
      fields["local"] = .string(localEndpoint.debugDescription)
    }
    if let remoteEndpoint {
      fields["remote"] = .string(remoteEndpoint.debugDescription)
    }
    return fields
  }

  private var statusName: String {
    switch status {
    case .satisfied: "satisfied"
    case .unsatisfied: "unsatisfied"
    case .requiresConnection: "requiresConnection"
    @unknown default: "unknown"
    }
  }

  private var unsatisfiedReasonName: String {
    switch unsatisfiedReason {
    case .notAvailable: "notAvailable"
    case .cellularDenied: "cellularDenied"
    case .wifiDenied: "wifiDenied"
    case .localNetworkDenied: "localNetworkDenied"
    case .vpnInactive: "vpnInactive"
    @unknown default: "unknown"
    }
  }

  private var linkQualityName: String {
    switch linkQuality {
    case .unknown: "unknown"
    case .minimal: "minimal"
    case .moderate: "moderate"
    case .good: "good"
    @unknown default: "unknown"
    }
  }
}

extension NWInterface {
  /// The name and type, such as `en0(wifi)`.
  var logName: String {
    let typeName =
      switch type {
      case .wifi: "wifi"
      case .cellular: "cellular"
      case .wiredEthernet: "wired"
      case .loopback: "loopback"
      case .other: "other"
      @unknown default: "unknown"
      }
    return "\(name)(\(typeName))"
  }
}

extension NWConnection.State {
  /// The state's name, and the error's fields for `waiting` and `failed`.
  var logFields: [String: LogValue] {
    switch self {
    case .setup:
      return ["state": "setup"]
    case .preparing:
      return ["state": "preparing"]
    case .ready:
      return ["state": "ready"]
    case .waiting(let error):
      return error.logFields.merging(["state": "waiting"]) { $1 }
    case .failed(let error):
      return error.logFields.merging(["state": "failed"]) { $1 }
    case .cancelled:
      return ["state": "cancelled"]
    @unknown default:
      return ["state": "unknown"]
    }
  }
}

extension NWBrowser.State {
  /// The state's name, and the error's fields for `waiting` and `failed`.
  var logFields: [String: LogValue] {
    switch self {
    case .setup:
      return ["state": "setup"]
    case .ready:
      return ["state": "ready"]
    case .waiting(let error):
      return error.logFields.merging(["state": "waiting"]) { $1 }
    case .failed(let error):
      return error.logFields.merging(["state": "failed"]) { $1 }
    case .cancelled:
      return ["state": "cancelled"]
    @unknown default:
      return ["state": "unknown"]
    }
  }
}

extension NWListener.State {
  /// The state's name, and the error's fields for `waiting` and `failed`.
  var logFields: [String: LogValue] {
    switch self {
    case .setup:
      return ["state": "setup"]
    case .ready:
      return ["state": "ready"]
    case .waiting(let error):
      return error.logFields.merging(["state": "waiting"]) { $1 }
    case .failed(let error):
      return error.logFields.merging(["state": "failed"]) { $1 }
    case .cancelled:
      return ["state": "cancelled"]
    @unknown default:
      return ["state": "unknown"]
    }
  }
}
