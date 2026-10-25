/// A fixed-capacity FIFO that overwrites its oldest element when full. Storage is allocated once,
/// so the pipeline's per-sample histories don't allocate in steady state.
struct RingBuffer<Element> {
  private var storage: [Element?]
  private var head = 0

  /// The number of stored elements.
  private(set) var count = 0

  init(capacity: Int) {
    precondition(capacity > 0, "A ring buffer needs room for at least one element")
    storage = Array(repeating: nil, count: capacity)
  }

  var capacity: Int { storage.count }

  var isEmpty: Bool { count == 0 }

  /// The oldest element.
  var first: Element? { isEmpty ? nil : self[0] }

  /// The newest element.
  var last: Element? { isEmpty ? nil : self[count - 1] }

  /// The element at `index`, where 0 is the oldest.
  subscript(index: Int) -> Element {
    precondition(index >= 0 && index < count, "Ring buffer index out of range")
    // Every slot below `count` has been written, so the stored optional is never nil.
    return storage[(head + index) % storage.count]!
  }

  /// Appends `element`, dropping the oldest one if the buffer is full.
  mutating func append(_ element: Element) {
    if count == storage.count {
      storage[head] = element
      head = (head + 1) % storage.count
    } else {
      storage[(head + count) % storage.count] = element
      count += 1
    }
  }

  mutating func removeFirst() {
    guard !isEmpty else { return }
    storage[head] = nil
    head = (head + 1) % storage.count
    count -= 1
  }

  mutating func removeAll() {
    while !isEmpty {
      removeFirst()
    }
    head = 0
  }
}

extension RingBuffer: Sendable where Element: Sendable {}
