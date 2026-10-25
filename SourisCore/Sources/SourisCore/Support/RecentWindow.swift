/// The most recent `capacity` elements, oldest first. Appending to a full window overwrites the
/// oldest element without reallocating.
struct RecentWindow<Element>: RandomAccessCollection, MutableCollection {
  let capacity: Int

  private var storage: [Element] = []

  /// Index in `storage` of the oldest element once the window is full, else 0.
  private var oldest = 0

  init(capacity: Int) {
    precondition(capacity > 0, "A window needs room for at least one element")
    self.capacity = capacity
    storage.reserveCapacity(capacity)
  }

  var startIndex: Int { 0 }

  var endIndex: Int { storage.count }

  subscript(position: Int) -> Element {
    get { storage[physicalIndex(of: position)] }
    set { storage[physicalIndex(of: position)] = newValue }
  }

  mutating func append(_ element: Element) {
    if storage.count < capacity {
      storage.append(element)
    } else {
      storage[oldest] = element
      oldest = (oldest + 1) % capacity
    }
  }

  mutating func removeAll() {
    storage.removeAll(keepingCapacity: true)
    oldest = 0
  }

  private func physicalIndex(of position: Int) -> Int {
    precondition(position >= 0 && position < storage.count, "Index out of range")
    return (oldest + position) % storage.count
  }
}
