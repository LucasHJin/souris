import Foundation
import Synchronization
import Testing

@testable import SourisCore

@Suite struct QueueWatchdogTests {
  @Test func aBlockedQueueIsReportedWithTheWorkThatBlockedIt() async throws {
    let queue = DispatchQueue(label: "test.watched")
    let stalls = Mutex<[QueueWatchdog.Stall]>([])
    let watchdog = QueueWatchdog(queue: queue, interval: 0.02, threshold: 0.1) { stall in
      stalls.withLock { $0.append(stall) }
    }
    try await Task.sleep(for: .milliseconds(100))
    queue.async {
      watchdog.note("blocker")
      Thread.sleep(forTimeInterval: 0.4)
    }
    queue.async {
      watchdog.note("after")
    }
    try await Task.sleep(for: .milliseconds(700))
    let reported = stalls.withLock { $0 }
    #expect(reported.count == 1)
    #expect(reported.first?.lastWork == "blocker")
    #expect((reported.first?.duration ?? 0) > 0.25)
    // Read once the heartbeat was overdue, so about the threshold after the blocker began.
    #expect((reported.first?.lastWorkAge ?? 0) > 0.05)
  }

  @Test func aBusyButFlowingQueueIsNotReported() async throws {
    let queue = DispatchQueue(label: "test.flowing")
    let stalls = Mutex(0)
    let watchdog = QueueWatchdog(queue: queue, interval: 0.02, threshold: 0.1) { _ in
      stalls.withLock { $0 += 1 }
    }
    for _ in 0..<40 {
      queue.async {
        watchdog.note("work")
        Thread.sleep(forTimeInterval: 0.005)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(stalls.withLock { $0 } == 0)
  }
}
