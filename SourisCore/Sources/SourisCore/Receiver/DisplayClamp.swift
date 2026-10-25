import CoreGraphics

/// Keeps a cursor position on a real display.
///
/// Displays are rectangles in global Core Graphics coordinates (origin at the top-left of the main
/// display, +y down), as `CGDisplayBounds` returns them. Their union can have gaps and notches
/// that aren't valid positions, so clamping is per display, never to the union's bounding box.
public enum DisplayClamp {
  /// Returns `point` if it lies on any display. Otherwise clamps it into the display that contains
  /// `previous`, or, if `previous` is on no display, into the display nearest to `point`.
  ///
  /// A point is on a display when `minX <= x <= maxX - 1` and `minY <= y <= maxY - 1`; clamping
  /// uses those same limits. With no displays, returns `point` unchanged.
  public static func clamp(_ point: CGPoint, previous: CGPoint, displays: [CGRect]) -> CGPoint {
    // A display narrower or shorter than one point holds no positions, so it can't be a target.
    let usable = displays.filter { $0.width >= 1 && $0.height >= 1 }
    if usable.contains(where: { holds(point, on: $0) }) {
      return point
    }
    let containing = usable.first { holds(previous, on: $0) }
    guard let display = containing ?? nearestDisplay(to: point, in: usable) else {
      return point
    }
    return CGPoint(
      x: min(max(point.x, display.minX), display.maxX - 1),
      y: min(max(point.y, display.minY), display.maxY - 1)
    )
  }

  private static func holds(_ point: CGPoint, on display: CGRect) -> Bool {
    point.x >= display.minX
      && point.x <= display.maxX - 1
      && point.y >= display.minY
      && point.y <= display.maxY - 1
  }

  /// The display whose limits are closest to `point`. Distance is measured to those limits, so
  /// the chosen display is the one clamping moves the point least.
  private static func nearestDisplay(to point: CGPoint, in displays: [CGRect]) -> CGRect? {
    displays.min { squaredDistance(from: point, to: $0) < squaredDistance(from: point, to: $1) }
  }

  private static func squaredDistance(from point: CGPoint, to display: CGRect) -> CGFloat {
    let dx = max(display.minX - point.x, point.x - (display.maxX - 1), 0)
    let dy = max(display.minY - point.y, point.y - (display.maxY - 1), 0)
    return dx * dx + dy * dy
  }
}
