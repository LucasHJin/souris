import Testing

@testable import SourisCore

@Suite("Recent window")
struct RecentWindowTests {
  @Test func keepsTheNewestElementsOldestFirst() {
    var window = RecentWindow<Int>(capacity: 3)
    #expect(window.isEmpty)
    for value in 1...5 {
      window.append(value)
    }
    #expect(Array(window) == [3, 4, 5])
    #expect(window.count == 3)
    #expect(window.first == 3)
    #expect(window.last == 5)
  }

  @Test func partiallyFilledWindowKeepsInsertionOrder() {
    var window = RecentWindow<String>(capacity: 4)
    window.append("a")
    window.append("b")
    #expect(Array(window) == ["a", "b"])
  }

  @Test func elementsCanBeChangedInPlace() {
    var window = RecentWindow<Int>(capacity: 3)
    for value in 1...4 {
      window.append(value)
    }
    window[0] = 20
    window[2] += 100
    #expect(Array(window) == [20, 3, 104])
    window.append(5)
    #expect(Array(window) == [3, 104, 5])
  }

  @Test func removeAllStartsOver() {
    var window = RecentWindow<Int>(capacity: 2)
    for value in 1...3 {
      window.append(value)
    }
    window.removeAll()
    #expect(window.isEmpty)
    window.append(9)
    #expect(Array(window) == [9])
  }
}

@Suite("Link monitor")
struct LinkMonitorTests {
  private let second: UInt64 = 1_000_000

  @Test func emptyMonitorReportsNothing() {
    let stats = LinkMonitor().snapshot(nowMicros: 10 * second)
    #expect(stats.rttMedianMs == nil)
    #expect(stats.rttMaxMs == nil)
    #expect(stats.packetsPerSecond == 0)
    #expect(stats.pingLoss == 0)
  }

  @Test func roundTripsGiveMedianAndMaximum() {
    var monitor = LinkMonitor()
    let roundTrips: [(id: UInt32, micros: UInt64)] = [(1, 2_000), (2, 10_000), (3, 4_000)]
    for (id, micros) in roundTrips {
      let sent = UInt64(id) * second
      monitor.recordPing(id: id, sentMicros: sent)
      monitor.recordPong(id: id, echoedMicros: sent, arrivalMicros: sent + micros)
    }
    let stats = monitor.snapshot(nowMicros: 4 * second)
    #expect(stats.rttMedianMs == 4)
    #expect(stats.rttMaxMs == 10)
    #expect(stats.pingLoss == 0)
  }

  @Test func medianOfAnEvenCountAveragesTheMiddlePair() {
    var monitor = LinkMonitor()
    let roundTrips: [(id: UInt32, micros: UInt64)] = [
      (1, 1_000), (2, 2_000), (3, 6_000), (4, 9_000),
    ]
    for (id, micros) in roundTrips {
      let sent = UInt64(id) * second
      monitor.recordPing(id: id, sentMicros: sent)
      monitor.recordPong(id: id, echoedMicros: sent, arrivalMicros: sent + micros)
    }
    #expect(monitor.snapshot(nowMicros: 5 * second).rttMedianMs == 4)
  }

  @Test func onlyTheRecentWindowCounts() {
    var monitor = LinkMonitor()
    for id in 1...(UInt32(LinkMonitor.windowSize) + 10) {
      let sent = UInt64(id) * 1000
      monitor.recordPing(id: id, sentMicros: sent)
      // The first ten are slow, the rest fast: the slow ones age out of the window.
      let rtt: UInt64 = id <= 10 ? 90_000 : 1_000
      monitor.recordPong(id: id, echoedMicros: sent, arrivalMicros: sent + rtt)
    }
    let stats = monitor.snapshot(nowMicros: 100 * second)
    #expect(stats.rttMaxMs == 1)
    #expect(stats.rttMedianMs == 1)
  }

  @Test func pingsWithoutAPongAfterOneSecondCountAsLost() {
    var monitor = LinkMonitor()
    monitor.recordPing(id: 1, sentMicros: 0)
    monitor.recordPing(id: 2, sentMicros: 100_000)
    monitor.recordPong(id: 2, echoedMicros: 100_000, arrivalMicros: 105_000)
    monitor.recordPing(id: 3, sentMicros: 2 * second)

    // Ping 1 is 3 s old and unanswered, ping 2 was answered, ping 3 is still young.
    let stats = monitor.snapshot(nowMicros: 3 * second)
    #expect(stats.pingLoss == 0.5)

    // Just under the threshold, nothing is lost yet.
    #expect(monitor.snapshot(nowMicros: second).pingLoss == 0)
  }

  @Test func youngUnansweredPingsAreNotCountedAtAll() {
    var monitor = LinkMonitor()
    monitor.recordPing(id: 1, sentMicros: 5 * second)
    #expect(monitor.snapshot(nowMicros: 5 * second + 500_000).pingLoss == 0)
  }

  @Test func aLatePongStillCountsAsAnswered() {
    var monitor = LinkMonitor()
    monitor.recordPing(id: 1, sentMicros: 0)
    #expect(monitor.snapshot(nowMicros: 2 * second).pingLoss == 1)
    monitor.recordPong(id: 1, echoedMicros: 0, arrivalMicros: 2 * second)
    #expect(monitor.snapshot(nowMicros: 2 * second).pingLoss == 0)
  }

  @Test func duplicateUnknownAndForgedPongsAreIgnored() {
    var monitor = LinkMonitor()
    monitor.recordPing(id: 1, sentMicros: 1000)
    monitor.recordPong(id: 1, echoedMicros: 1000, arrivalMicros: 3000)
    monitor.recordPong(id: 1, echoedMicros: 1000, arrivalMicros: 9000)
    monitor.recordPong(id: 99, echoedMicros: 1000, arrivalMicros: 4000)
    monitor.recordPing(id: 2, sentMicros: 5000)
    monitor.recordPong(id: 2, echoedMicros: 4999, arrivalMicros: 6000)
    monitor.recordPong(id: 2, echoedMicros: 5000, arrivalMicros: 4000)

    let stats = monitor.snapshot(nowMicros: 10_000)
    #expect(stats.rttMedianMs == 2)
    #expect(stats.rttMaxMs == 2)
  }

  @Test func sendRateIsSmoothed() {
    var monitor = LinkMonitor()
    monitor.recordSends(100, over: 1)
    #expect(monitor.snapshot(nowMicros: 0).packetsPerSecond == 100)
    monitor.recordSends(0, over: 1)
    let smoothed = monitor.snapshot(nowMicros: 0).packetsPerSecond
    #expect(smoothed > 0 && smoothed < 100)
    #expect(smoothed == 60)
  }

  @Test func zeroLengthSampleIsIgnored() {
    var monitor = LinkMonitor()
    monitor.recordSends(10, over: 0)
    #expect(monitor.snapshot(nowMicros: 0).packetsPerSecond == 0)
  }
}
