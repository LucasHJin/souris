import CoreGraphics
import Foundation

/// Counts multi-clicks so posted button events carry the right `kCGMouseEventClickState`.
///
/// A press continues a click sequence (count + 1) when it's the same button as the previous press,
/// comes within `maxInterval` of it (press to press) and lands within `maxDistance` points of it.
/// Otherwise the count restarts at 1. The release reuses its press's count.
public struct ClickCounter: Sendable {
  /// Usually `NSEvent.doubleClickInterval`.
  public var maxInterval: TimeInterval

  /// In screen points. Larger than a real mouse needs, because a midair hand drifts between taps.
  public var maxDistance: Double

  private struct Press {
    var button: MouseButton
    var point: CGPoint
    var time: TimeInterval
    var count: Int64
  }

  private var lastPress: Press?

  public init(maxInterval: TimeInterval, maxDistance: Double = 8) {
    self.maxInterval = maxInterval
    self.maxDistance = maxDistance
  }

  /// Records a press and returns its click state (1 = single, 2 = double, ...).
  public mutating func press(
    _ button: MouseButton,
    at point: CGPoint,
    time: TimeInterval
  ) -> Int64 {
    var count: Int64 = 1
    if let last = lastPress, continues(last, with: button, at: point, time: time) {
      count = last.count + 1
    }
    lastPress = Press(button: button, point: point, time: time, count: count)
    return count
  }

  /// The click state to put on the release of `button`: the count of its latest press, or 1.
  public func releaseClickState(for button: MouseButton) -> Int64 {
    guard let last = lastPress, last.button == button else { return 1 }
    return last.count
  }

  private func continues(
    _ last: Press,
    with button: MouseButton,
    at point: CGPoint,
    time: TimeInterval
  ) -> Bool {
    let dx = Double(point.x - last.point.x)
    let dy = Double(point.y - last.point.y)
    return last.button == button
      && time - last.time <= maxInterval
      && dx * dx + dy * dy <= maxDistance * maxDistance
  }
}
