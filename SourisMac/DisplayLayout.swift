import CoreGraphics
import Synchronization

/// The active displays' bounds in global Core Graphics coordinates, readable from any thread.
///
/// The input queue reads this for every cursor move; the main thread refreshes it when the
/// display configuration changes.
final class DisplayLayout: Sendable {
  private static let maxDisplays = 16

  private let storage = Mutex<[CGRect]>([])

  init() {
    refresh()
  }

  /// One rectangle per active display, with the origin at the top-left of the main display.
  var bounds: [CGRect] {
    storage.withLock { $0 }
  }

  /// Re-reads the display list. Keeps the previous layout if the system can't provide one.
  func refresh() {
    var ids = [CGDirectDisplayID](repeating: 0, count: Self.maxDisplays)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return }
    let rects = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    storage.withLock { $0 = rects }
  }
}
