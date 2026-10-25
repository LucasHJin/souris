import Foundation
import Synchronization

import SourisCore

/// Why the camera can't be used.
enum CameraProblem: Equatable, Sendable {
  /// Camera access is off for the app.
  case denied

  /// ARKit failed for another reason; the text is its description.
  case unavailable(String)
}

/// The video format ARKit runs.
struct VideoFormatInfo: Equatable, Sendable {
  var width: Int
  var height: Int
  var framesPerSecond: Int
}

/// What the UI reads from the engine, refreshed at about 10 Hz so nothing on the hot path
/// touches SwiftUI.
struct EngineSnapshot: Equatable, Sendable {
  var clientStatus = ClientStatus.stopped
  var linkStats = LinkStats()

  /// The log queued for the Mac.
  var logStats = LogOutbox.Stats()
  var diagnostics = PipelineDiagnostics()
  var buttons: MouseButtons = []
  var flags: StateFlags = []

  /// The pipeline is paused (app inactive or settings open).
  var isPaused = false
  var thermalState = ProcessInfo.ThermalState.nominal
  var macNames: [String] = []
  var videoFormat: VideoFormatInfo?

  /// In millimetres.
  var minimumFocusDistance: Int?
  var cameraProblem: CameraProblem?
  var isCameraInterrupted = false

  /// `systemUptime` when the current recording began.
  var recordingStartedAt: TimeInterval?
  var recordingFailure: String?
}

/// A lock-protected `EngineSnapshot`, written by the engine's queue and read by the main thread.
final class SnapshotBox: Sendable {
  private let storage = Mutex(EngineSnapshot())

  var value: EngineSnapshot {
    storage.withLock { $0 }
  }

  func store(_ snapshot: EngineSnapshot) {
    storage.withLock { $0 = snapshot }
  }
}
