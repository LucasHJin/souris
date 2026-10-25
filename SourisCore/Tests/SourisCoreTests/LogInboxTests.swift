import Foundation
import Testing

@testable import SourisCore

@Suite("Log inbox")
struct LogInboxTests {
  private func record(_ id: UInt32) -> UplinkRecord {
    .recordingEnded(recordingID: id)
  }

  /// A packet whose records carry their own ids, so accepted records can be checked by id.
  private func packet(
    stream: UInt32 = 1, oldest: UInt32 = 1, first: UInt32, count: Int
  ) -> LogPacket {
    let ids = (0..<UInt32(count)).map { first + $0 }
    return LogPacket(stream: stream, oldestID: oldest, firstID: first, records: ids.map(record))
  }

  private func ids(_ delivery: LogInbox.Delivery) -> [UInt32] {
    delivery.records.map { record in
      if case .recordingEnded(let id) = record { id } else { 0 }
    }
  }

  @Test func inOrderPacketsAreAcceptedAndAcked() {
    var inbox = LogInbox()
    let first = inbox.receive(packet(first: 1, count: 3))
    #expect(ids(first) == [1, 2, 3])
    #expect(first.ackThrough == 3)
    #expect(first.missingBefore == 0)
    let second = inbox.receive(packet(first: 4, count: 2))
    #expect(ids(second) == [4, 5])
    #expect(second.ackThrough == 5)
  }

  @Test func duplicatesAreSkippedAndStillAcked() {
    var inbox = LogInbox()
    _ = inbox.receive(packet(first: 1, count: 5))
    let repeated = inbox.receive(packet(first: 1, count: 5))
    #expect(repeated.records.isEmpty)
    #expect(repeated.ackThrough == 5)

    let overlapping = inbox.receive(packet(first: 3, count: 5))
    #expect(ids(overlapping) == [6, 7])
    #expect(overlapping.ackThrough == 7)
  }

  @Test func transientGapAcceptsNothingUntilTheMissingRecordsArrive() {
    var inbox = LogInbox()
    _ = inbox.receive(packet(first: 1, count: 3))
    let ahead = inbox.receive(packet(first: 6, count: 2))
    #expect(ahead.records.isEmpty)
    #expect(ahead.ackThrough == 3)
    #expect(ahead.missingBefore == 0)

    let resent = inbox.receive(packet(first: 4, count: 4))
    #expect(ids(resent) == [4, 5, 6, 7])
    #expect(resent.ackThrough == 7)
  }

  @Test func permanentGapIsCountedAndSkipped() {
    var inbox = LogInbox()
    _ = inbox.receive(packet(first: 1, count: 3))
    let afterDrop = inbox.receive(packet(oldest: 10, first: 10, count: 2))
    #expect(ids(afterDrop) == [10, 11])
    #expect(afterDrop.missingBefore == 6)
    #expect(afterDrop.ackThrough == 11)
  }

  @Test func permanentGapFollowedByLossSkipsOnlyTheDroppedRecords() {
    var inbox = LogInbox()
    _ = inbox.receive(packet(first: 1, count: 3))
    let delivery = inbox.receive(packet(oldest: 8, first: 12, count: 1))
    #expect(delivery.records.isEmpty)
    #expect(delivery.missingBefore == 4)
    #expect(delivery.ackThrough == 7)

    let resent = inbox.receive(packet(oldest: 8, first: 8, count: 5))
    #expect(ids(resent) == [8, 9, 10, 11, 12])
    #expect(resent.missingBefore == 0)
  }

  @Test func unknownStreamStartsAtTheOldestHeldRecord() {
    var inbox = LogInbox()
    let fresh = inbox.receive(packet(stream: 9, oldest: 50, first: 50, count: 2))
    #expect(ids(fresh) == [50, 51])
    #expect(fresh.missingBefore == 0)

    // A Mac that restarted mid-stream waits for the phone to go back to its oldest record.
    var restarted = LogInbox()
    let ahead = restarted.receive(packet(stream: 9, oldest: 40, first: 52, count: 1))
    #expect(ahead.records.isEmpty)
    #expect(ahead.ackThrough == 39)
  }

  @Test func newStreamMidwayStartsOverAndTheOldOneKeepsItsPlace() {
    var inbox = LogInbox()
    _ = inbox.receive(packet(stream: 1, first: 1, count: 100))
    let relaunched = inbox.receive(packet(stream: 2, first: 1, count: 2))
    #expect(ids(relaunched) == [1, 2])
    #expect(relaunched.ackThrough == 2)

    let straggler = inbox.receive(packet(stream: 1, first: 99, count: 3))
    #expect(ids(straggler) == [101])
    #expect(straggler.ackThrough == 101)
  }

  @Test func idsPastUInt32MaxAreNotAccepted() {
    var inbox = LogInbox()
    let overflowing = LogPacket(
      stream: 1, oldestID: .max, firstID: .max, records: [record(1), record(2)])
    let delivery = inbox.receive(overflowing)
    #expect(delivery.records.isEmpty)
  }
}
