import Foundation
import simd

/// ARKit's tracking state, flattened.
public enum TrackingStatus: String, Codable, Sendable {
  case normal
  case initializing
  case excessiveMotion
  case insufficientFeatures
  case relocalizing
  case notAvailable
}

/// What the app copies out of one `ARFrame` before releasing it.
public struct ARSample: Equatable, Codable, Sendable {
  /// `ARFrame.timestamp`: capture time on the uptime clock, in seconds.
  public var timestamp: TimeInterval

  /// `ProcessInfo.systemUptime` when the delegate received the frame.
  public var arrival: TimeInterval

  /// The camera's position in the gravity-aligned world frame (+y up), in metres.
  public var position: SIMD3<Double>

  /// The camera's orientation (camera frame → world frame) as quaternion `(ix, iy, iz, r)`.
  ///
  /// ARKit's camera frame: +x runs along the long axis from the top of the phone toward the
  /// bottom, +y toward the phone's right edge (portrait, screen facing you), +z out of the screen.
  public var orientation: SIMD4<Double>

  public var tracking: TrackingStatus

  public init(
    timestamp: TimeInterval,
    arrival: TimeInterval,
    position: SIMD3<Double>,
    orientation: SIMD4<Double>,
    tracking: TrackingStatus
  ) {
    self.timestamp = timestamp
    self.arrival = arrival
    self.position = position
    self.orientation = orientation
    self.tracking = tracking
  }

  public var quaternion: simd_quatd {
    simd_quatd(vector: orientation)
  }
}

/// What the app copies out of one `CMDeviceMotion`.
///
/// Core Motion's device frame: +x toward the phone's right edge (portrait, screen facing you), +y
/// toward the top edge, +z out of the screen.
public struct IMUSample: Equatable, Codable, Sendable {
  /// `CMLogItem.timestamp`: uptime seconds.
  public var timestamp: TimeInterval

  /// `ProcessInfo.systemUptime` when the handler ran.
  public var arrival: TimeInterval

  /// `CMAttitude.quaternion` (device frame → reference frame, z vertical) as `(x, y, z, w)`.
  public var attitude: SIMD4<Double>

  /// Radians per second, device frame.
  public var rotationRate: SIMD3<Double>

  /// In g, device frame. Flat and screen up reads about `(0, 0, -1)`.
  public var gravity: SIMD3<Double>

  /// In g, device frame, gravity removed.
  public var userAcceleration: SIMD3<Double>

  public init(
    timestamp: TimeInterval,
    arrival: TimeInterval,
    attitude: SIMD4<Double>,
    rotationRate: SIMD3<Double>,
    gravity: SIMD3<Double>,
    userAcceleration: SIMD3<Double>
  ) {
    self.timestamp = timestamp
    self.arrival = arrival
    self.attitude = attitude
    self.rotationRate = rotationRate
    self.gravity = gravity
    self.userAcceleration = userAcceleration
  }

  public var quaternion: simd_quatd {
    simd_quatd(vector: attitude)
  }
}
