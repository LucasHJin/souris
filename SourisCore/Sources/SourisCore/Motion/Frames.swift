import simd

/// The coordinate frames the pipeline works across, and the one fixed rotation between them.
///
/// - Core Motion's device frame: +x toward the right edge (portrait, screen facing you), +y toward
///   the top edge, +z out of the screen.
/// - ARKit's camera frame: +x along the long axis toward the bottom (Home) end, +y toward the
///   right edge, +z out of the screen.
/// - ARKit's world frame: gravity-aligned, +y up. The pipeline works in this frame.
enum Frames {
  /// `C`, which takes device-frame vectors to camera-frame vectors: `v_cam = C · v_dev`, so
  /// `x_cam = −y_dev`, `y_cam = +x_dev`, `z_cam = +z_dev`. That is a +90° turn about z.
  static let cameraFromDevice = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))

  /// World up.
  static let up = SIMD3<Double>(0, 1, 0)

  /// The direction of the phone's top edge in the camera frame, `C · (0, 1, 0)`.
  static let topEdgeInCamera = SIMD3<Double>(-1, 0, 0)

  /// Below this horizontal length of the top-edge direction the phone is too close to vertical
  /// for its heading to mean anything.
  static let minimumHeadingLength = 0.3

  /// Converts a body-frame rotation measured in the device frame into the camera frame:
  /// `C · ΔR · Cᵀ`.
  static func cameraRotation(fromDeviceRotation rotation: simd_quatd) -> simd_quatd {
    cameraFromDevice * rotation * cameraFromDevice.inverse
  }

  /// The phone's heading: its top-edge direction projected onto the horizontal plane and
  /// normalized, or nil when the phone is too close to vertical.
  ///
  /// - Parameter orientation: The camera's orientation, camera frame → world frame.
  static func heading(of orientation: simd_quatd) -> SIMD3<Double>? {
    let topEdge = orientation.act(topEdgeInCamera)
    let horizontal = SIMD3(topEdge.x, 0, topEdge.z)
    let horizontalLength = simd_length(horizontal)
    guard horizontalLength >= minimumHeadingLength else { return nil }
    return horizontal / horizontalLength
  }

  /// The world direction to the user's right for a given heading: `forward × up`.
  static func right(ofHeading forward: SIMD3<Double>) -> SIMD3<Double> {
    simd_cross(forward, up)
  }
}
