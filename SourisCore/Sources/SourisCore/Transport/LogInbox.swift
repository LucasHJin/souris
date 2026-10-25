/// The Mac's receive side of one phone's log streams: which records to accept, in order and
/// exactly once, and what to acknowledge.
///
/// - Records up to the stream's accepted-through id are duplicates and are skipped.
/// - A packet that starts past the next expected id is a gap. If the packet's `oldestID` is past
///   the next expected id too, the phone dropped the records in between for good: they are counted
///   as missing and skipped. A gap that remains after that is loss in transit: nothing is
///   accepted and the ack stays put, so the phone goes back and resends.
/// - A stream seen for the first time starts at the packet's `oldestID`, or at `firstID` if
///   `oldestID` isn't in `1...firstID`. Anything before it was acknowledged to an earlier run of
///   the Mac app or dropped by the phone, and isn't counted as missing.
///
/// Each stream is tracked separately, so packets still in flight from a previous app launch are
/// handled correctly after the phone has started a new stream.
public struct LogInbox: Sendable {
  /// What to do with one log packet.
  public struct Delivery: Equatable, Sendable {
    /// The new records, in id order.
    public var records: [UplinkRecord]

    /// Records the phone dropped before sending, which come before `records` in the stream.
    public var missingBefore: Int

    /// The id to acknowledge: every record of the stream up to it has been accepted.
    public var ackThrough: UInt32

    public init(records: [UplinkRecord], missingBefore: Int, ackThrough: UInt32) {
      self.records = records
      self.missingBefore = missingBefore
      self.ackThrough = ackThrough
    }
  }

  /// The highest contiguous id accepted, per stream.
  private var acceptedThrough: [UInt32: UInt32] = [:]

  public init() {}

  /// Accepts what's new in `packet` and returns it with the ack to send.
  public mutating func receive(_ packet: LogPacket) -> Delivery {
    let first = Int64(packet.firstID)
    let oldest = Int64(packet.oldestID)
    let last = first + Int64(packet.records.count) - 1

    var through: Int64
    if let known = acceptedThrough[packet.stream] {
      through = Int64(known)
    } else {
      let start = (1...max(1, first)).contains(oldest) ? oldest : first
      through = max(0, start - 1)
    }
    // Ids past `UInt32.max` can't come from a real phone; acknowledge without accepting.
    guard last <= Int64(UInt32.max) else {
      return Delivery(records: [], missingBefore: 0, ackThrough: UInt32(through))
    }

    var missing: Int64 = 0
    if first > through + 1 && oldest > through + 1 {
      let skippedThrough = min(oldest, first) - 1
      missing = skippedThrough - through
      through = skippedThrough
    }
    guard first <= through + 1 else {
      acceptedThrough[packet.stream] = UInt32(through)
      return Delivery(records: [], missingBefore: Int(missing), ackThrough: UInt32(through))
    }

    let duplicates = Int(through + 1 - first)
    let accepted = Array(packet.records.dropFirst(duplicates))
    through = max(through, last)
    acceptedThrough[packet.stream] = UInt32(through)
    return Delivery(records: accepted, missingBefore: Int(missing), ackThrough: UInt32(through))
  }
}
