import AppKit
import QuartzCore

/// Calls `onFrame` once per refresh of the main display (120 Hz on a ProMotion panel), while
/// running. The cursor is drawn once per refresh, so pacing moves to it is what makes them even.
///
/// The display link runs on the main run loop in every mode, so menu tracking doesn't stop it.
@MainActor
final class FrameClock: NSObject {
  private let onFrame: @Sendable () -> Void
  private var link: CADisplayLink?

  init(onFrame: @escaping @Sendable () -> Void) {
    self.onFrame = onFrame
  }

  var isRunning: Bool {
    link != nil
  }

  func start() {
    guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let link = screen.displayLink(target: self, selector: #selector(step(_:)))
    let fastest = Float(max(60, screen.maximumFramesPerSecond))
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: 60, maximum: fastest, preferred: fastest)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  /// Moves the link to the display that now has the menu bar, e.g. after plugging in a monitor.
  func restart() {
    guard isRunning else { return }
    stop()
    start()
  }

  @objc private func step(_ link: CADisplayLink) {
    onFrame()
  }
}
