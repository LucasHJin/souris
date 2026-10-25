import Dispatch
import Foundation
import Synchronization

/// Notices when a serial queue stops running its work, and says what work it last started.
///
/// A timer on the watchdog's own queue sends the watched queue a heartbeat every `interval`. A
/// heartbeat that waits longer than `threshold` to run means the queue was blocked. While it
/// waits, the watchdog reads the label the queue's work last set with `note(_:)`, which names the
/// work that was running when the queue stopped. Once the heartbeat runs, the stall is reported on
/// the watched queue.
///
/// Thread safety: `note(_:)` is meant for the watched queue; everything else may be called from
/// any thread.
public final class QueueWatchdog: @unchecked Sendable {
  /// One stall, as reported once the queue runs again.
  public struct Stall: Sendable {
    /// How long the heartbeat waited, seconds.
    public var duration: TimeInterval

    /// The label the queue's work last set before the stall.
    public var lastWork: String

    /// How long before the stall was noticed that label was set, seconds. About the stall's
    /// length when the labelled work is what blocked; much longer when unlabelled work did.
    public var lastWorkAge: TimeInterval
  }

  private struct State {
    var label: StaticString = "none"
    var labelTime: TimeInterval = 0
    var heartbeatSentAt: TimeInterval?

    /// The label and its age, read while a heartbeat was overdue.
    var stalledWork: (label: StaticString, age: TimeInterval)?
  }

  private let watched: DispatchQueue
  private let threshold: TimeInterval
  private let onStall: @Sendable (Stall) -> Void
  private let state = Mutex(State())
  private let timer: any DispatchSourceTimer

  /// Starts watching `queue`.
  ///
  /// - Parameters:
  ///   - queue: The serial queue to watch.
  ///   - interval: How often a heartbeat is sent, seconds.
  ///   - threshold: How long a heartbeat may wait before it counts as a stall, seconds.
  ///   - onStall: Called on `queue` after each stall.
  public init(
    queue: DispatchQueue,
    interval: TimeInterval = 0.05,
    threshold: TimeInterval = 0.25,
    onStall: @escaping @Sendable (Stall) -> Void
  ) {
    watched = queue
    self.threshold = threshold
    self.onStall = onStall
    timer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "souris.watchdog", qos: .userInitiated))
    timer.schedule(
      deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in
      self?.check()
    }
    timer.resume()
  }

  deinit {
    timer.cancel()
  }

  /// Names the work the watched queue is starting. Call from the watched queue.
  public func note(_ label: StaticString) {
    let now = ProcessInfo.processInfo.systemUptime
    state.withLock { state in
      state.label = label
      state.labelTime = now
    }
  }

  private func check() {
    let now = ProcessInfo.processInfo.systemUptime
    let shouldSend = state.withLock { state in
      guard let sent = state.heartbeatSentAt else {
        state.heartbeatSentAt = now
        return true
      }
      if now - sent > threshold && state.stalledWork == nil {
        state.stalledWork = (state.label, now - state.labelTime)
      }
      return false
    }
    guard shouldSend else { return }
    watched.async { [weak self] in
      self?.beat()
    }
  }

  private func beat() {
    let now = ProcessInfo.processInfo.systemUptime
    let (sent, stalledWork, label, labelTime) = state.withLock { state in
      defer {
        state.heartbeatSentAt = nil
        state.stalledWork = nil
      }
      return (state.heartbeatSentAt, state.stalledWork, state.label, state.labelTime)
    }
    guard let sent, now - sent > threshold else { return }
    let work = stalledWork ?? (label, now - labelTime)
    onStall(Stall(duration: now - sent, lastWork: "\(work.label)", lastWorkAge: work.age))
  }
}
