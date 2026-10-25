import CoreMotion
import Foundation

import SourisCore

/// Core Motion device motion at 100 Hz, delivered as `IMUSample`s on the queue given at init.
final class MotionTracker: @unchecked Sendable {
  private let manager = CMMotionManager()
  private let operations = OperationQueue()
  private let onSample: @Sendable (IMUSample) -> Void

  init(queue: DispatchQueue, onSample: @escaping @Sendable (IMUSample) -> Void) {
    self.onSample = onSample
    operations.maxConcurrentOperationCount = 1
    operations.underlyingQueue = queue
    manager.deviceMotionUpdateInterval = 1.0 / 100
  }

  func start() {
    guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
    let onSample = onSample
    manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: operations) { motion, _ in
      guard let motion else { return }
      let attitude = motion.attitude.quaternion
      let rate = motion.rotationRate
      let gravity = motion.gravity
      let acceleration = motion.userAcceleration
      onSample(
        IMUSample(
          timestamp: motion.timestamp,
          arrival: ProcessInfo.processInfo.systemUptime,
          attitude: SIMD4(attitude.x, attitude.y, attitude.z, attitude.w),
          rotationRate: SIMD3(rate.x, rate.y, rate.z),
          gravity: SIMD3(gravity.x, gravity.y, gravity.z),
          userAcceleration: SIMD3(acceleration.x, acceleration.y, acceleration.z)))
    }
  }

  func stop() {
    manager.stopDeviceMotionUpdates()
  }
}
