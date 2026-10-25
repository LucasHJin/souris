import Foundation
import Synchronization
import Testing

@testable import SourisCore

@Suite("Log outbox")
struct LogOutboxTests {
  private let start = ContinuousClock.now

  private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    start + .milliseconds(milliseconds)
  }

  /// A recording line of exactly `bytes` encoded bytes (kind, id and line).
  private func line(_ index: Int, bytes: Int = 100) -> UplinkRecord {
    var text = Array("\(index):".utf8)
    text += Array(repeating: UInt8(ascii: "x"), count: max(0, bytes - 5 - text.count))
    return .recordingLine(recordingID: 1, line: Data(text))
  }

  private func decode(_ datagram: Data?) throws -> LogPacket {
    let data = try #require(datagram)
    guard case .log(let packet) = try Packet.decode(data) else {
      Issue.record("Expected a log packet")
      throw CancellationError()
    }
    return packet
  }

  /// Sends until the window or the queue stops it, returning the packets.
  private func drain(_ outbox: LogOutbox, at now: ContinuousClock.Instant) throws -> [LogPacket] {
    var packets: [LogPacket] = []
    while let datagram = outbox.nextDatagram(now: now) {
      packets.append(try decode(datagram))
    }
    return packets
  }

  // MARK: - Packing

  @Test func packsConsecutiveRecordsIntoDatagramsOfAbout1200Bytes() throws {
    let outbox = LogOutbox(streamID: 42)
    for index in 0..<30 {
      outbox.enqueue(line(index))
    }
    let datagram = try #require(outbox.nextDatagram(now: at(0)))
    #expect(datagram.count <= LogOutbox.datagramTarget)
    let packet = try decode(datagram)
    #expect(packet.stream == 42)
    #expect(packet.oldestID == 1)
    #expect(packet.firstID == 1)
    // 18 header bytes, then 102 per record: 11 records fill 1140 bytes, a 12th would pass 1200.
    #expect(packet.records.count == 11)
    #expect(packet.records.first == line(0))

    let rest = try drain(outbox, at: at(0))
    #expect(rest.map(\.firstID) == [12, 23])
    #expect(rest.map(\.records.count) == [11, 8])
    #expect(outbox.nextDatagram(now: at(0)) == nil)
    #expect(outbox.stats.packetsSent == 3)
  }

  @Test func recordLargerThanADatagramGoesAlone() throws {
    let outbox = LogOutbox(streamID: 1)
    outbox.enqueue(line(0))
    outbox.enqueue(line(1, bytes: 5000))
    outbox.enqueue(line(2))
    let packets = try drain(outbox, at: at(0))
    #expect(packets.map(\.records.count) == [1, 1, 1])
    #expect(packets[1].records == [line(1, bytes: 5000)])
  }

  @Test func recordAtTheLimitIsKeptAndOneOverIsRejected() throws {
    let outbox = LogOutbox(streamID: 1)
    #expect(outbox.enqueue(line(0, bytes: LogOutbox.maxRecordBytes)))
    #expect(!outbox.enqueue(line(1, bytes: LogOutbox.maxRecordBytes + 1)))
    #expect(outbox.stats.rejected == 1)
    #expect(outbox.stats.queuedRecords == 1)
    let packets = try drain(outbox, at: at(0))
    #expect(packets.count == 1)
    #expect(packets[0].records == [line(0, bytes: LogOutbox.maxRecordBytes)])
  }

  @Test func oversizedLogEntryIsCutDownToFit() throws {
    let outbox = LogOutbox(streamID: 1)
    let message = String(repeating: "é\n", count: 20_000)
    outbox.log(level: .info, category: "net", event: "big", message: message, fields: ["k": 1])
    #expect(outbox.stats.rejected == 0)
    #expect(outbox.stats.queuedBytes <= LogOutbox.maxRecordBytes)
    let packet = try #require(try drain(outbox, at: at(0)).first)
    guard case .log(let entry) = try #require(packet.records.first) else {
      Issue.record("Expected a log entry")
      return
    }
    #expect(entry.event == "big")
    #expect(entry.fields["k"] == 1)
    #expect(entry.fields["truncatedFromBytes"] != nil)
    #expect(message.hasPrefix(try #require(entry.message)))
    #expect(try #require(entry.message).utf8.count > 1000)
  }

  @Test func onEnqueueSeesEveryRecordAsGiven() {
    let seen = Mutex<[UplinkRecord]>([])
    let outbox = LogOutbox(streamID: 1) { record in seen.withLock { $0.append(record) } }
    let big = line(1, bytes: LogOutbox.maxRecordBytes + 1)
    outbox.enqueue(line(0))
    outbox.enqueue(big)
    #expect(seen.withLock { $0 } == [line(0), big])
  }

  @Test func defaultStreamIsRandomAndNonZero() {
    let streams = (0..<20).map { _ in LogOutbox().streamID }
    #expect(!streams.contains(0))
    #expect(Set(streams).count > 1)
  }

  // MARK: - Window and acks

  @Test func windowStopsAt256RecordsInFlight() throws {
    let outbox = LogOutbox(streamID: 1)
    for index in 0..<400 {
      outbox.enqueue(line(index, bytes: 10))
    }
    let packets = try drain(outbox, at: at(0))
    #expect(packets.reduce(0) { $0 + $1.records.count } == LogOutbox.windowRecords)
    #expect(outbox.nextDatagram(now: at(0)) == nil)

    outbox.acknowledge(stream: 1, through: 100, now: at(10))
    #expect(outbox.stats.ackedThrough == 100)
    #expect(outbox.stats.queuedRecords == 300)
    let more = try drain(outbox, at: at(10))
    #expect(more.first?.firstID == 257)
    #expect(more.first?.oldestID == 101)
    #expect(more.reduce(0) { $0 + $1.records.count } == 100)
  }

  @Test func windowStopsAt256KilobytesInFlight() throws {
    let outbox = LogOutbox(streamID: 1)
    for index in 0..<40 {
      outbox.enqueue(line(index, bytes: LogOutbox.maxRecordBytes))
    }
    let packets = try drain(outbox, at: at(0))
    // The window closes once 256 KiB is in flight: 29 records are 261 000 bytes, the 30th passes.
    #expect(packets.count == 30)
  }

  @Test func ackFreesRecordsAndStaleOrForeignAcksAreIgnored() throws {
    let outbox = LogOutbox(streamID: 5)
    for index in 0..<10 {
      outbox.enqueue(line(index))
    }
    _ = try drain(outbox, at: at(0))
    outbox.acknowledge(stream: 5, through: 6, now: at(5))
    #expect(outbox.stats.queuedRecords == 4)

    outbox.acknowledge(stream: 5, through: 3, now: at(6))
    outbox.acknowledge(stream: 5, through: 6, now: at(6))
    outbox.acknowledge(stream: 99, through: 10, now: at(6))
    outbox.acknowledge(stream: 5, through: 11, now: at(6))
    #expect(outbox.stats.ackedThrough == 6)
    #expect(outbox.stats.queuedRecords == 4)

    outbox.acknowledge(stream: 5, through: 10, now: at(7))
    #expect(outbox.stats.queuedRecords == 0)
    #expect(outbox.stats.queuedBytes == 0)
    #expect(outbox.nextDatagram(now: at(1000)) == nil)
  }

  @Test func noAckProgressFor300msGoesBackToTheOldestUnacked() throws {
    let outbox = LogOutbox(streamID: 1)
    for index in 0..<30 {
      outbox.enqueue(line(index))
    }
    let first = try drain(outbox, at: at(0))
    #expect(first.count == 3)
    outbox.acknowledge(stream: 1, through: 11, now: at(100))

    #expect(outbox.nextDatagram(now: at(399)) == nil)
    let resent = try decode(outbox.nextDatagram(now: at(400)))
    #expect(resent.firstID == 12)
    #expect(resent.oldestID == 12)
    #expect(outbox.stats.retransmits == 1)

    // The timer restarts at the rewind.
    _ = try drain(outbox, at: at(400))
    #expect(outbox.nextDatagram(now: at(699)) == nil)
    #expect(try decode(outbox.nextDatagram(now: at(700))).firstID == 12)
  }

  @Test func ackPastTheCursorAfterARewindSkipsAhead() throws {
    let outbox = LogOutbox(streamID: 1)
    for index in 0..<30 {
      outbox.enqueue(line(index))
    }
    _ = try drain(outbox, at: at(0))
    #expect(try decode(outbox.nextDatagram(now: at(300))).firstID == 1)
    outbox.acknowledge(stream: 1, through: 22, now: at(310))
    #expect(try decode(outbox.nextDatagram(now: at(310))).firstID == 23)
  }

  @Test func rewindResendsAtOnce() throws {
    let outbox = LogOutbox(streamID: 1)
    for index in 0..<5 {
      outbox.enqueue(line(index))
    }
    _ = try drain(outbox, at: at(0))
    outbox.rewind()
    #expect(try decode(outbox.nextDatagram(now: at(1))).firstID == 1)
  }

  @Test func recordsQueuedAfterTheWindowDrainedAreSentAtOnce() throws {
    let outbox = LogOutbox(streamID: 1)
    outbox.enqueue(line(0))
    _ = try drain(outbox, at: at(0))
    outbox.acknowledge(stream: 1, through: 1, now: at(5))
    outbox.enqueue(line(1))
    #expect(try decode(outbox.nextDatagram(now: at(6))).firstID == 2)
  }

  // MARK: - Byte limit

  @Test func overTheByteLimitTheOldestAreDroppedAndOldestIDAdvances() throws {
    let outbox = LogOutbox(streamID: 1, byteLimit: 1000)
    for index in 0..<25 {
      outbox.enqueue(line(index))
    }
    #expect(outbox.stats.queuedRecords == 10)
    #expect(outbox.stats.queuedBytes == 1000)
    #expect(outbox.stats.dropped == 15)
    let packet = try decode(outbox.nextDatagram(now: at(0)))
    #expect(packet.oldestID == 16)
    #expect(packet.firstID == 16)
    #expect(packet.records.first == line(15))
  }

  @Test func droppingInFlightRecordsMovesTheCursorUp() throws {
    let outbox = LogOutbox(streamID: 1, byteLimit: 1000)
    for index in 0..<10 {
      outbox.enqueue(line(index))
    }
    _ = try drain(outbox, at: at(0))
    for index in 10..<15 {
      outbox.enqueue(line(index))
    }
    let packet = try decode(outbox.nextDatagram(now: at(1)))
    #expect(packet.oldestID == 6)
    #expect(packet.firstID == 11)
    outbox.acknowledge(stream: 1, through: 3, now: at(2))
    #expect(outbox.stats.ackedThrough == 3)
    #expect(outbox.stats.queuedRecords == 10)
  }
}
