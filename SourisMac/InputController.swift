import Dispatch
import Foundation
import Synchronization

import SourisCore

/// What the input queue tells the model, for the menu. Everything else stays on the queue.
enum InputReport: Sendable {
  case serverStateChanged(ServerState)
  case approvalRequested(PeerInfo)
  case controllerChanged(PeerInfo?)

  /// The controlling phone went quiet. It stays the controller and may resume.
  case controllerSilent

  /// Packets from a silent controller are arriving again.
  case controllerResumed
}

/// A copy of the packet counters that the menu can read from the main thread.
struct InputSnapshot: Sendable {
  var packetsPerSecond = 0.0
  var stats = PacketStats()

  /// `ProcessInfo.systemUptime` when this was taken, so a stalled feed shows as stale.
  var updatedAt: TimeInterval = 0
}

/// Turns server events into posted input, and writes the server's and the phone's log entries.
///
/// All state is confined to `queue`, which is also the server's queue. `handle(_:report:)` must
/// be called there. Nothing here waits on the main thread.
final class InputController: @unchecked Sendable {
  let queue = DispatchQueue(label: "souris.input", qos: .userInteractive)

  /// Packets closer together than this count as one burst, as when Wi-Fi delivers a backlog.
  private static let burstGap: TimeInterval = 0.002

  /// One second of arrivals, summarized in the `input` log entry.
  private struct ReceiveWindow {
    var packets = 0
    var maxGap: TimeInterval = 0
    var longestBurst = 0
    var currentBurst = 0

    /// One-way delays relative to the session's fastest packet, milliseconds.
    var delays: [Double] = []
  }

  private let poster: EventPoster
  private let shortcutPoster = ShortcutPoster()
  private let log: MacLog
  private var tracker = RemoteStateTracker()
  private var isSilent = false
  private var windowStart: TimeInterval?
  private var windowPackets = 0
  private let snapshotStorage = Mutex(InputSnapshot())

  private var receive = ReceiveWindow()
  private var lastArrival: TimeInterval?

  /// The smallest Mac-arrival − phone-send time seen this session. The two uptime clocks differ
  /// by a constant, so each packet's excess over this is how long it was held up on the way.
  private var fastestDelay: Double?
  private var windowStats = PacketStats()
  private var windowCounters = PostCounters()

  /// Paces cursor motion and scrolling onto the display's refreshes (see `MotionPlayout`).
  private var playout: MotionPlayout

  /// The pacing chosen in the menu; `playout.pacing` is it resolved for `transport`.
  private var preferredPacing: PointerPacing
  private var transport = LinkTransport.wifi

  /// Cumulative cursor motion received from the phone and posted, points. Their difference is
  /// what the playout still holds.
  private var receivedTotal = SIMD2<Double>.zero
  private var postedTotal = SIMD2<Double>.zero
  private var pacedScroll = PacedScroll()

  init(
    clickInterval: TimeInterval,
    displayLayout: DisplayLayout,
    pacing: PointerPacing,
    log: MacLog
  ) {
    poster = EventPoster(clickInterval: clickInterval, displayLayout: displayLayout)
    preferredPacing = pacing
    playout = MotionPlayout(pacing: pacing.resolved(for: .wifi), limits: .forLink(.wifi))
    self.log = log
  }

  /// The latest packet counters. Safe to call from any thread.
  var snapshot: InputSnapshot {
    snapshotStorage.withLock { $0 }
  }

  /// Handles one server event on the input queue.
  ///
  /// - Parameters:
  ///   - event: The event from the server.
  ///   - report: Called for events the menu needs; it must not block.
  func handle(_ event: ServerEvent, report: (InputReport) -> Void) {
    switch event {
    case .state(let packet):
      if isSilent {
        isSilent = false
        windowStart = nil
        report(.controllerResumed)
      }
      recordArrival(of: packet)
      if let update = tracker.apply(packet) {
        if !update.buttonChanges.isEmpty {
          logButtons(update.buttonChanges)
        }
        post(update, phoneTime: Double(packet.phoneTimeMicros) / 1_000_000)
        press(update.shortcuts)
        if let isOn = update.dictation {
          toggleDictation(isOn)
        }
      }
      countPacket()

    case .controllerSilent:
      releaseEverything()
      isSilent = true
      report(.controllerSilent)

    case .controllerChanged(let peer):
      endSession()
      report(.controllerChanged(peer))

    case .stateChanged(let state):
      switch state {
      case .stopped, .failed:
        endSession()
      case .starting, .listening:
        break
      }
      report(.serverStateChanged(state))

    case .approvalRequested(let peer):
      report(.approvalRequested(peer))

    case .phoneLog(let batch):
      log.write(batch)

    case .log(let entry):
      log.write(entry, source: "server")
    }
  }

  /// Shows one display refresh's worth of cursor motion and scrolling. Call from the display
  /// link; it hops onto the queue.
  func displayFrame() {
    queue.async { [self] in
      guard playout.pacing != .immediate else { return }
      show(playout.frame(at: ProcessInfo.processInfo.systemUptime))
    }
  }

  /// Changes how motion is paced. Whatever the playout still holds is posted first.
  func setPacing(_ pacing: PointerPacing) {
    queue.async { [self] in
      preferredPacing = pacing
      applyPacing()
    }
  }

  /// Tells the playout what carries the packets now, which `.auto` pacing and the playout's
  /// limits depend on. The new link's trip times are measured afresh.
  func setTransport(_ transport: LinkTransport) {
    queue.async { [self] in
      guard transport != self.transport else { return }
      self.transport = transport
      playout.limits = .forLink(transport)
      playout.relink()
      fastestDelay = nil
      applyPacing()
    }
  }

  /// Releases every held button and ends any scroll, without waiting.
  func reset() {
    queue.async { self.endSession() }
  }

  /// Like `reset()`, but returns once the releases are posted. For quitting.
  func resetAndWait() {
    queue.sync { endSession() }
  }

  // MARK: - Private

  /// Resolves the preferred pacing for the current link and switches the playout to it, posting
  /// whatever it still holds first.
  private func applyPacing() {
    let pacing = preferredPacing.resolved(for: transport)
    guard pacing != playout.pacing else { return }
    show(playout.flush())
    playout.pacing = pacing
  }

  /// Posts the releases for anything held and forgets the cursor position. The next packet from
  /// the phone starts a fresh baseline.
  private func releaseEverything() {
    let releases = tracker.releaseAll()
    if !releases.buttonChanges.isEmpty || !releases.scrollEvents.isEmpty {
      log.log(
        .info, "input", "releaseAll", "Released what the phone held",
        ["buttons": .int(releases.buttonChanges.count), "scrolls": .int(releases.scrollEvents.count)])
    }
    if let isOn = releases.dictation {
      toggleDictation(isOn)
    }
    let scrollEnd = pacedScroll.cancel()
    if playout.pacing == .immediate {
      poster.post(releases)
    } else {
      // What the playout still holds is dropped, so only the gesture's end is posted.
      poster.post(InputUpdate(buttonChanges: releases.buttonChanges, scrollEvents: scrollEnd))
    }
    poster.reset()
    playout.reset()
    receivedTotal = .zero
    postedTotal = .zero
  }

  /// Posts an update: buttons at once, and the motion and scrolling either at once or through
  /// the playout.
  private func post(_ update: InputUpdate, phoneTime: TimeInterval) {
    guard playout.pacing != .immediate else {
      poster.post(update)
      return
    }
    receivedTotal += update.cursorDelta
    pacedScroll.receive(update.scrollEvents)
    playout.add(
      total: receivedTotal, scroll: pacedScroll.received, phoneTime: phoneTime,
      arrival: ProcessInfo.processInfo.systemUptime, missedPackets: update.missedPackets)
    if !update.buttonChanges.isEmpty {
      // A press or release lands where the phone says the cursor is, so the held motion goes
      // first. The click freeze keeps the hand still around taps, so this is rarely more than a
      // few points.
      show(playout.flush())
      poster.post(InputUpdate(buttonChanges: update.buttonChanges))
    }
  }

  /// Presses the Mac shortcuts the phone asked for, logging each.
  private func press(_ shortcuts: [MacShortcut]) {
    for shortcut in shortcuts {
      var fields: [String: LogValue] = ["shortcut": .string(shortcut.logName)]
      var level = LogLevel.info
      switch shortcutPoster.press(shortcut) {
      case .pressed(let combo):
        fields["keyCode"] = .int(Int(combo.keyCode))
        fields["flags"] = .string(String(combo.flags.rawValue, radix: 16))
      case .openedMissionControl:
        fields["opened"] = .string("Mission Control")
      case .disabled:
        fields["disabled"] = .bool(true)
        level = .warning
      }
      log.log(level, "input", "shortcut", nil, fields)
    }
  }

  /// Presses the dictation shortcut, which macOS's Dictation toggles on, so the same press
  /// starts and stops it.
  private func toggleDictation(_ isOn: Bool) {
    shortcutPoster.post(ShortcutPoster.dictation)
    log.log(.info, "input", "dictation", isOn ? "Started dictation" : "Stopped dictation", [:])
  }

  /// Posts the motion and scrolling from what has been posted so far to `frame`.
  private func show(_ frame: MotionPlayout.Frame?) {
    guard let frame else { return }
    let delta = frame.cursor - postedTotal
    postedTotal = frame.cursor
    let scrollEvents = pacedScroll.show(frame.scroll)
    if delta != .zero || !scrollEvents.isEmpty {
      poster.post(InputUpdate(cursorDelta: delta, scrollEvents: scrollEvents))
    }
  }

  /// Ends the current phone's session: releases everything and starts counting from zero.
  private func endSession() {
    releaseEverything()
    tracker = RemoteStateTracker()
    isSilent = false
    windowStart = nil
    windowPackets = 0
    receive = ReceiveWindow()
    lastArrival = nil
    fastestDelay = nil
    windowStats = PacketStats()
    windowCounters = poster.counters
    snapshotStorage.withLock { $0 = InputSnapshot() }
  }

  private func recordArrival(of packet: StatePacket) {
    let now = ProcessInfo.processInfo.systemUptime
    if let lastArrival {
      let gap = now - lastArrival
      receive.maxGap = max(receive.maxGap, gap)
      if gap < Self.burstGap {
        receive.currentBurst += 1
      } else {
        receive.currentBurst = 1
      }
    } else {
      receive.currentBurst = 1
    }
    receive.longestBurst = max(receive.longestBurst, receive.currentBurst)
    lastArrival = now
    receive.packets += 1

    let delay = now - Double(packet.phoneTimeMicros) / 1_000_000
    let fastest = min(fastestDelay ?? delay, delay)
    fastestDelay = fastest
    receive.delays.append((delay - fastest) * 1000)
  }

  private func logButtons(_ changes: [ButtonChange]) {
    for change in changes {
      log.log(
        .debug, "input", change.isDown ? "buttonDown" : "buttonUp", nil,
        ["button": .string(String(describing: change.button))])
    }
  }

  /// Counts one applied packet and publishes the rate once a second, with an `input` log entry.
  private func countPacket() {
    let now = ProcessInfo.processInfo.systemUptime
    guard let start = windowStart else {
      windowStart = now
      windowPackets = 1
      return
    }
    windowPackets += 1
    let elapsed = now - start
    guard elapsed >= 1 else { return }

    let published = InputSnapshot(
      packetsPerSecond: Double(windowPackets) / elapsed,
      stats: tracker.stats,
      updatedAt: now)
    snapshotStorage.withLock { $0 = published }
    logWindow(seconds: elapsed)
    windowStart = now
    windowPackets = 0
  }

  /// The `input` entry: what arrived and what was posted over the last window.
  private func logWindow(seconds: TimeInterval) {
    let stats = tracker.stats
    let counters = poster.counters
    let delays = receive.delays.sorted()
    func quantile(_ fraction: Double) -> Double {
      guard !delays.isEmpty else { return 0 }
      return delays[min(delays.count - 1, Int(fraction * Double(delays.count - 1)))]
    }
    var fields: [String: LogValue] = [
      "windowS": .double((seconds * 1000).rounded() / 1000),
      "packets": .int(receive.packets),
      "lost": .int(stats.lost - windowStats.lost),
      "stale": .int(stats.stale - windowStats.stale),
      "maxGapMs": .double((receive.maxGap * 10_000).rounded() / 10),
      "longestBurst": .int(receive.longestBurst),
      "delayP50Ms": .double((quantile(0.5) * 10).rounded() / 10),
      "delayP95Ms": .double((quantile(0.95) * 10).rounded() / 10),
      "delayMaxMs": .double(((delays.last ?? 0) * 10).rounded() / 10),
      "moves": .int(counters.moves - windowCounters.moves),
      "travelPt": .double(((counters.travel - windowCounters.travel) * 10).rounded() / 10),
      "buttonEvents": .int(counters.buttonEvents - windowCounters.buttonEvents),
      "scrollEvents": .int(counters.scrollEvents - windowCounters.scrollEvents),
    ]
    let resyncs = counters.resyncs - windowCounters.resyncs
    if resyncs > 0 {
      fields["resyncs"] = .int(resyncs)
    }
    fields["pacing"] = .string(playout.pacing.rawValue)
    fields["transport"] = .string(transport.rawValue)
    if playout.pacing != .immediate {
      let paced = playout.takeStats()
      fields["paceDelayMs"] = .double((playout.targetDelay * 10_000).rounded() / 10)
      fields["paceMaxBehindMs"] = .double((paced.maxBehind * 10_000).rounded() / 10)
      if paced.catchUpFrames > 0 {
        fields["catchUpFrames"] = .int(paced.catchUpFrames)
      }
      if paced.skipped > 0 {
        fields["skippedMs"] = .double((paced.skipped * 10_000).rounded() / 10)
      }
      if paced.coastFrames > 0 {
        fields["coastFrames"] = .int(paced.coastFrames)
        fields["coastMaxPt"] = .double((paced.maxCoastOffset * 10).rounded() / 10)
      }
    }
    let level: LogLevel = receive.maxGap > 0.15 || resyncs > 0 ? .warning : .debug
    log.log(level, "input", "input", nil, fields)
    windowStats = stats
    windowCounters = counters
    receive = ReceiveWindow(currentBurst: receive.currentBurst)
  }
}
