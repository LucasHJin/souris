// ARKit's session and frame types aren't annotated Sendable, and the delegate runs on our queue.
@preconcurrency import ARKit
import AVFoundation
import Foundation
import simd

import SourisCore

/// A headless `ARSession` that turns each frame into an `ARSample` and releases the frame.
///
/// Everything runs on the queue given at init: the delegate callbacks, and the calls to `run`
/// and `pause` must come from it too.
final class ARTracker: NSObject, ARSessionDelegate, @unchecked Sendable {
  enum Event: Sendable {
    case interrupted

    /// The session was re-run with a fresh world origin.
    case interruptionEnded
    case failed(CameraProblem)
  }

  private let session = ARSession()
  private let queue: DispatchQueue
  private let onSample: @Sendable (ARSample) -> Void
  private let onEvent: @Sendable (Event) -> Void
  private var configuration: ARWorldTrackingConfiguration?
  private var isWanted = false

  static var isSupported: Bool {
    ARWorldTrackingConfiguration.isSupported
  }

  init(
    queue: DispatchQueue,
    onSample: @escaping @Sendable (ARSample) -> Void,
    onEvent: @escaping @Sendable (Event) -> Void
  ) {
    self.queue = queue
    self.onSample = onSample
    self.onEvent = onEvent
    super.init()
    session.delegate = self
    session.delegateQueue = queue
  }

  /// Starts or reconfigures the session and returns the video format it uses.
  func run(autoFocus: Bool, resetTracking: Bool) -> VideoFormatInfo {
    let configuration = Self.makeConfiguration(autoFocus: autoFocus)
    self.configuration = configuration
    isWanted = true
    session.run(configuration, options: resetTracking ? Self.resetOptions : [])
    let format = configuration.videoFormat
    return VideoFormatInfo(
      width: Int(format.imageResolution.width),
      height: Int(format.imageResolution.height),
      framesPerSecond: format.framesPerSecond)
  }

  func pause() {
    isWanted = false
    session.pause()
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    onSample(Self.sample(from: frame))
  }

  func session(_ session: ARSession, didFailWithError error: any Error) {
    if (error as? ARError)?.code == .cameraUnauthorized {
      onEvent(.failed(.denied))
      return
    }
    onEvent(.failed(.unavailable(error.localizedDescription)))
    queue.asyncAfter(deadline: .now() + 1) { [self] in
      guard isWanted, let configuration else { return }
      self.session.run(configuration, options: Self.resetOptions)
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    onEvent(.interrupted)
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    guard isWanted, let configuration else { return }
    session.run(configuration, options: Self.resetOptions)
    onEvent(.interruptionEnded)
  }

  // MARK: - Helpers

  private static let resetOptions: ARSession.RunOptions = [.resetTracking, .removeExistingAnchors]

  private static func makeConfiguration(autoFocus: Bool) -> ARWorldTrackingConfiguration {
    let configuration = ARWorldTrackingConfiguration()
    configuration.worldAlignment = .gravity
    configuration.planeDetection = []
    configuration.environmentTexturing = .none
    configuration.isLightEstimationEnabled = false
    configuration.frameSemantics = []
    configuration.providesAudioData = false
    configuration.isAutoFocusEnabled = autoFocus
    if let format = lowestCostFormat() {
      configuration.videoFormat = format
    }
    return configuration
  }

  /// The smallest 60 fps format of the back wide camera, to keep ARKit's per-frame cost down.
  private static func lowestCostFormat() -> ARConfiguration.VideoFormat? {
    ARWorldTrackingConfiguration.supportedVideoFormats
      .filter {
        $0.captureDevicePosition == .back
          && $0.captureDeviceType == .builtInWideAngleCamera
          && $0.framesPerSecond == 60
      }
      .min { pixelCount($0) < pixelCount($1) }
  }

  private static func pixelCount(_ format: ARConfiguration.VideoFormat) -> CGFloat {
    format.imageResolution.width * format.imageResolution.height
  }

  private static func sample(from frame: ARFrame) -> ARSample {
    let arrival = ProcessInfo.processInfo.systemUptime
    let camera = frame.camera
    let transform = camera.transform
    let rotation = simd_double3x3(
      vector(transform.columns.0), vector(transform.columns.1), vector(transform.columns.2))
    return ARSample(
      timestamp: frame.timestamp,
      arrival: arrival,
      position: vector(transform.columns.3),
      orientation: simd_quatd(rotation).vector,
      tracking: trackingStatus(of: camera.trackingState))
  }

  private static func vector(_ column: SIMD4<Float>) -> SIMD3<Double> {
    SIMD3(Double(column.x), Double(column.y), Double(column.z))
  }

  private static func trackingStatus(of state: ARCamera.TrackingState) -> TrackingStatus {
    switch state {
    case .normal:
      return .normal
    case .notAvailable:
      return .notAvailable
    case .limited(let reason):
      switch reason {
      case .initializing: return .initializing
      case .excessiveMotion: return .excessiveMotion
      case .insufficientFeatures: return .insufficientFeatures
      case .relocalizing: return .relocalizing
      @unknown default: return .notAvailable
      }
    }
  }
}
