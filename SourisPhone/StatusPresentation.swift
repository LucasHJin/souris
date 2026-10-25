import Foundation

/// How worried the status dot should look.
enum StatusLevel {
  /// Connected and tracking.
  case good

  /// Connecting, waiting, limited tracking or lifted.
  case caution

  /// Something is wrong that the user may need to fix.
  case problem
}

/// The connection half of the status: text plus severity.
struct ConnectionLine: Equatable {
  var text: String
  var level: StatusLevel
}

/// The two status lines on the main screen.
struct StatusPresentation: Equatable {
  var level: StatusLevel
  var connection: String
  var tracking: String
}

extension EngineSnapshot {
  /// The link to the Mac, ignoring the camera.
  var connectionLine: ConnectionLine {
    switch clientStatus {
    case .stopped:
      ConnectionLine(text: "Not connected", level: .caution)
    case .searching:
      ConnectionLine(text: "Looking for your Mac…", level: .caution)
    case .connecting:
      ConnectionLine(text: "Connecting…", level: .caution)
    case .waitingForApproval(let mac):
      ConnectionLine(text: "Allow this iPhone on \(mac)", level: .caution)
    case .connected(let mac):
      ConnectionLine(
        text: linkStats.isUSB ? "Connected to \(mac) over USB" : "Connected to \(mac)",
        level: .good)
    case .denied(let mac):
      ConnectionLine(text: "\(mac) refused this iPhone", level: .problem)
    case .busy(let mac):
      ConnectionLine(text: "\(mac) is in use by another iPhone", level: .caution)
    case .disconnected(let mac):
      ConnectionLine(
        text: "\(mac) disconnected this iPhone. Reconnect in Settings.", level: .caution)
    case .notResponding(let mac):
      ConnectionLine(text: "\(mac) isn’t responding", level: .problem)
    case .localNetworkDenied:
      ConnectionLine(text: "Turn on Local Network for Souris in Settings", level: .problem)
    case .failed(let message):
      ConnectionLine(text: message, level: .problem)
    }
  }

  var presentation: StatusPresentation {
    var line = connectionLine
    if cameraProblem == .denied {
      line = ConnectionLine(text: "Allow Camera for Souris in Settings", level: .problem)
    } else if cameraProblem != nil {
      line.level = .problem
    } else if line.level == .good && isDegraded {
      line.level = .caution
    }
    return StatusPresentation(level: line.level, connection: line.text, tracking: trackingText)
  }

  private var isDegraded: Bool {
    isCameraInterrupted
      || isPaused
      || flags.contains(.lifted)
      || diagnostics.tracking != .normal
  }

  private var trackingText: String {
    if cameraProblem != nil || isCameraInterrupted { return "Camera unavailable" }
    if isPaused { return "Paused" }
    if flags.contains(.lifted) { return "Lifted — set down to continue" }
    if flags.contains(.scrollActive) { return "Scrolling" }
    switch diagnostics.tracking {
    case .normal:
      return "Tracking"
    case .initializing, .relocalizing, .notAvailable:
      return "Starting tracking — move slowly"
    case .excessiveMotion:
      return "Moving too fast"
    case .insufficientFeatures:
      return "Not enough detail — point the camera at a textured surface"
    }
  }
}
