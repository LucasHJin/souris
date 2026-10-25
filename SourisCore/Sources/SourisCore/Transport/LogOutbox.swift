import Foundation

/// The phone's queue of diagnostic records waiting for the Mac to acknowledge them.
///
/// - Every record gets the next id, counting from 1. Records stay queued, across disconnects and
///   across `SourisClient` instances, until a `logAck` covers them.
/// - Sending is go-back-N: packets go out from a send cursor while at most `windowRecords` records
///   and `windowBytes` (8 KB) bytes are unacknowledged. When records are in flight and no ack has
///   made progress for `retransmitTimeout`, the cursor goes back to the oldest unacknowledged
///   record. The timeout is the longer of 1 s and 3 × `roundTrip`, and doubles (up to 8 s) with
///   each timeout in a row, so a slow link isn't flooded with resends of the same records.
/// - Packets are packed to about `datagramTarget` bytes. A larger record goes alone. A record over
///   `maxRecordBytes` (9000) encoded is cut down if it's a log entry (message first, then
///   fields), and rejected otherwise.
/// - Past `byteLimit` queued bytes the oldest records are dropped and counted. Every packet tells
///   the Mac the oldest id still held, so it can count the dropped ones as missing.
///
/// Not thread-safe: confine it to one serial queue, the same queue as every `SourisClient` it's
/// given to (hence `@unchecked Sendable`). `onEnqueue` runs on that queue too.
public final class LogOutbox: @unchecked Sendable {
  /// Counters for the debug overlay and the link summary.
  public struct Stats: Equatable, Sendable {
    /// Records waiting for an ack, including those in flight.
    public var queuedRecords = 0

    public var queuedBytes = 0

    /// The highest id the Mac has acknowledged, or 0.
    public var ackedThrough: UInt32 = 0

    /// Records dropped unsent because the queue passed `byteLimit`.
    public var dropped = 0

    /// Records refused by `enqueue(_:)` for being over `maxRecordBytes`.
    public var rejected = 0

    public var packetsSent = 0

    /// Packets that resent records already sent once.
    public var retransmits = 0

    /// How long the outbox currently waits for an ack before resending.
    public var retransmitTimeout = Duration.zero

    public init() {}
  }

  /// The largest encoded record queued. Larger log entries are cut down to fit.
  ///
  /// A packet holding one record this size stays under 9216 bytes, the UDP datagram limit macOS
  /// sets by default (`net.inet.udp.maxdgram`). Larger sends fail with `EMSGSIZE`, so a bigger
  /// record could never be delivered and would hold up every record after it.
  public static let maxRecordBytes = 9_000

  /// Packets are filled with records up to about this size, header included. It stays under a
  /// typical 1500-byte MTU, so a packet is one Wi-Fi frame.
  static let datagramTarget = 1200

  static let windowRecords = 256

  /// Unacknowledged bytes allowed at once. A big window on a stalling link let resends of the
  /// whole backlog pile up in front of the state packets.
  static let windowBytes = 8 * 1024

  static let minimumRetransmitTimeout = Duration.seconds(1)
  static let maximumRetransmitTimeout = Duration.seconds(8)

  /// The retransmit timeout is at least this many round trips.
  static let roundTripsPerTimeout = 3

  /// Identifies this outbox's id sequence to the Mac. Random per app launch by default.
  public let streamID: UInt32

  /// Queued bytes past which the oldest records are dropped.
  public let byteLimit: Int

  private let onEnqueue: (@Sendable (UplinkRecord) -> Void)?

  /// Encoded records; `records[head]` has id `oldestID`. Entries before `head` are spent and
  /// cleared, and are removed in bulk now and then.
  private var records: [Data] = []
  private var head = 0

  /// The oldest id still queued, or `nextID` when the queue is empty. Every queued record is
  /// unacknowledged, so this is also the first id to resend.
  private var oldestID: UInt32 = 1
  private var nextID: UInt32 = 1
  private var queuedBytes = 0
  private var ackedThrough: UInt32 = 0

  /// The next id to send. Ids from `oldestID` up to it are in flight.
  private var sendCursor: UInt32 = 1
  private var highestSentID: UInt32 = 0

  /// When an ack last made progress, or when the in-flight window last became non-empty.
  private var lastProgressAt: ContinuousClock.Instant?

  /// Doubles with each timeout that passes without an ack making progress.
  private var backoff = 1

  private var dropped = 0
  private var rejected = 0
  private var packetsSent = 0
  private var retransmits = 0

  /// - Parameters:
  ///   - streamID: The stream id packets carry. Defaults to a random non-zero value.
  ///   - byteLimit: Queued bytes past which the oldest records are dropped. About 16 MB by default.
  ///   - onEnqueue: Called with every record passed to `enqueue(_:)`, before any cutting down,
  ///     including records that are then rejected. The app uses it to mirror records to a local
  ///     file and to `os_log`.
  public init(
    streamID: UInt32 = .random(in: 1 ... .max),
    byteLimit: Int = 16 * 1024 * 1024,
    onEnqueue: (@Sendable (UplinkRecord) -> Void)? = nil
  ) {
    self.streamID = streamID
    self.byteLimit = byteLimit
    self.onEnqueue = onEnqueue
  }

  /// The link's round-trip time, which the client keeps up to date from its pings. `nil` until
  /// one is known.
  public var roundTrip: Duration?

  /// How long to wait for an ack before resending: the longer of 1 s and 3 round trips, doubled
  /// for each timeout in a row, at most 8 s.
  var retransmitTimeout: Duration {
    let base = max(Self.minimumRetransmitTimeout, (roundTrip ?? .zero) * Self.roundTripsPerTimeout)
    return min(Self.maximumRetransmitTimeout, base * backoff)
  }

  public var stats: Stats {
    var stats = Stats()
    stats.queuedRecords = queuedCount
    stats.queuedBytes = queuedBytes
    stats.ackedThrough = ackedThrough
    stats.dropped = dropped
    stats.rejected = rejected
    stats.packetsSent = packetsSent
    stats.retransmits = retransmits
    stats.retransmitTimeout = retransmitTimeout
    return stats
  }

  // MARK: - Queueing

  /// Queues `record` for the Mac.
  ///
  /// - Returns: False if the record was rejected for being over `maxRecordBytes` and not a log
  ///   entry that could be cut down.
  @discardableResult
  public func enqueue(_ record: UplinkRecord) -> Bool {
    onEnqueue?(record)
    var encoded = record.encoded()
    if encoded.count > Self.maxRecordBytes {
      guard case .log(let entry) = record, let fitted = Self.fitted(entry, size: encoded.count)
      else {
        rejected += 1
        return false
      }
      encoded = fitted
    }
    records.append(encoded)
    nextID += 1
    queuedBytes += encoded.count
    while queuedBytes > byteLimit && queuedCount > 1 {
      removeOldest()
      dropped += 1
    }
    return true
  }

  /// Queues a log entry stamped with the current uptime and wall clock.
  public func log(
    level: LogLevel,
    category: String,
    event: String,
    message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    enqueue(
      .log(
        LogEntry(level: level, category: category, event: event, message: message, fields: fields)
      ))
  }

  // MARK: - Sending

  /// The next datagram to send, or `nil` when everything queued is in flight or the window is
  /// full.
  func nextDatagram(now: ContinuousClock.Instant) -> Data? {
    if sendCursor > oldestID, let lastProgressAt, now - lastProgressAt >= retransmitTimeout {
      sendCursor = oldestID
      self.lastProgressAt = now
      if retransmitTimeout < Self.maximumRetransmitTimeout {
        backoff *= 2
      }
    }
    guard sendCursor < nextID else { return nil }

    var inFlightCount = Int(sendCursor - oldestID)
    var inFlightBytes = 0
    for index in head..<(head + inFlightCount) {
      inFlightBytes += records[index].count
    }
    guard inFlightCount < Self.windowRecords, inFlightBytes < Self.windowBytes else { return nil }
    if inFlightCount == 0 {
      lastProgressAt = now
    }

    let firstID = sendCursor
    var batch: [Data] = []
    var size = WireLayout.headerSize + WireLayout.logFixedSize
    while sendCursor < nextID && inFlightCount < Self.windowRecords
      && inFlightBytes < Self.windowBytes
    {
      let record = records[head + Int(sendCursor - oldestID)]
      let added = WireLayout.logRecordLengthSize + record.count
      guard batch.isEmpty || size + added <= Self.datagramTarget else { break }
      batch.append(record)
      size += added
      sendCursor += 1
      inFlightCount += 1
      inFlightBytes += record.count
    }

    packetsSent += 1
    if firstID <= highestSentID {
      retransmits += 1
    }
    highestSentID = max(highestSentID, sendCursor - 1)
    return LogPacket.datagram(
      stream: streamID, oldestID: oldestID, firstID: firstID, encodedRecords: batch)
  }

  /// Frees every record up to `throughID`. Acks for another stream, and acks that don't move past
  /// the last one, are ignored.
  func acknowledge(stream: UInt32, through throughID: UInt32, now: ContinuousClock.Instant) {
    guard stream == streamID, throughID > ackedThrough, throughID < nextID else { return }
    ackedThrough = throughID
    while queuedCount > 0 && oldestID <= throughID {
      removeOldest()
    }
    lastProgressAt = now
    backoff = 1
  }

  /// Resends from the oldest unacknowledged record on the next `nextDatagram(now:)`, for a new
  /// connection where nothing in flight on the old one will be acknowledged.
  func rewind() {
    sendCursor = oldestID
    lastProgressAt = nil
    backoff = 1
  }

  // MARK: - Storage

  private var queuedCount: Int {
    Int(nextID - oldestID)
  }

  private func removeOldest() {
    queuedBytes -= records[head].count
    records[head] = Data()
    head += 1
    oldestID += 1
    if sendCursor < oldestID {
      sendCursor = oldestID
    }
    if head >= 4096 && head * 2 >= records.count {
      records.removeFirst(head)
      head = 0
    }
  }

  /// `entry` encoded and cut down to `maxRecordBytes`, shortening the message first and then
  /// dropping the fields. `nil` if even that doesn't fit.
  private static func fitted(_ entry: LogEntry, size originalSize: Int) -> Data? {
    var entry = entry
    entry.fields["truncatedFromBytes"] = .int(originalSize)
    var encoded = UplinkRecord.log(entry).encoded()
    if encoded.count > maxRecordBytes, let message = entry.message {
      var bare = entry
      bare.message = ""
      let overhead = UplinkRecord.log(bare).encoded().count
      let budget = maxRecordBytes - overhead
      var kept = message
      // Escaping makes the message longer in JSON than in UTF-8, so cut in proportion to its JSON
      // size, and again if a character boundary left it a little over.
      while encoded.count > maxRecordBytes, !kept.isEmpty {
        let jsonBytes = encoded.count - overhead
        let keep = min(kept.utf8.count * max(0, budget) / jsonBytes, kept.utf8.count - 1)
        kept = String(kept.prefix(utf8Bytes: keep))
        entry.message = kept
        encoded = UplinkRecord.log(entry).encoded()
      }
    }
    if encoded.count > maxRecordBytes {
      entry.fields = ["truncatedFromBytes": .int(originalSize)]
      encoded = UplinkRecord.log(entry).encoded()
    }
    return encoded.count <= maxRecordBytes ? encoded : nil
  }
}
