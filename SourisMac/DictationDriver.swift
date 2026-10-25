import Dispatch
import Foundation

import SourisCore

/// Starts and stops macOS's Dictation for the phone: `DictationFollower` decides from whether
/// Dictation records (`DictationRecordingProbe`, read every 20 ms while it matters), and this
/// presses its keys and logs what happened.
///
/// Not thread-safe: use it only on `queue`, where its timer runs too.
final class DictationDriver {
  private static let updateInterval = DispatchTimeInterval.milliseconds(20)

  /// Called after each key press with what was pressed, for the modifier check.
  var onPress: ((String) -> Void)?

  /// Called when Dictation starts or stops listening for the phone.
  var onListeningChanged: ((Bool) -> Void)?

  private let queue: DispatchQueue
  private let log: MacLog
  private let shortcutPoster: ShortcutPoster
  private let probe = DictationRecordingProbe()
  /// The 🎤 key first, since it works in Spotlight too; ⌃⌥D if it starts nothing.
  private var follower = DictationFollower(keys: [.microphone, .shortcut])
  private var timer: (any DispatchSourceTimer)?

  init(queue: DispatchQueue, log: MacLog, shortcutPoster: ShortcutPoster) {
    self.queue = queue
    self.log = log
    self.shortcutPoster = shortcutPoster
  }

  deinit {
    timer?.cancel()
  }

  /// Whether Dictation is listening for the phone.
  var isListening: Bool {
    follower.isListening
  }

  /// Reads Dictation's state once, so the first hold doesn't wait the 80 ms the first read takes
  /// while Core Audio connects.
  func prepare() {
    _ = probe.isRecording(at: ProcessInfo.processInfo.systemUptime)
  }

  /// The phone started or stopped asking for Dictation.
  ///
  /// - Parameter linkDelayMs: How much longer than the session's fastest packet the one that
  ///   asked took to arrive, when a packet asked.
  func setWanted(_ wanted: Bool, linkDelayMs: Double? = nil) {
    var fields: [String: LogValue] = [:]
    if let linkDelayMs {
      fields["linkDelayMs"] = .double((linkDelayMs * 10).rounded() / 10)
    }
    log.log(
      .info, "input", "dictation",
      wanted ? "The phone started dictating" : "The phone stopped dictating", fields)
    let now = ProcessInfo.processInfo.systemUptime
    var actions = follower.update(isRecording: probe.isRecording(at: now), at: now)
    actions += follower.setWanted(wanted, at: now)
    perform(actions)
    updateTimer()
  }

  // MARK: - Private

  private func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    perform(follower.update(isRecording: probe.isRecording(at: now), at: now))
    updateTimer()
  }

  /// Runs the timer while the follower needs updates.
  private func updateTimer() {
    if follower.needsUpdates, timer == nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + Self.updateInterval, repeating: Self.updateInterval)
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.resume()
      self.timer = timer
    } else if !follower.needsUpdates, let timer {
      timer.cancel()
      self.timer = nil
    }
  }

  private func perform(_ actions: [DictationFollower.Action]) {
    for action in actions {
      switch action {
      case .press(let key, let purpose):
        switch key {
        case .microphone: shortcutPoster.pressMicrophoneKey()
        case .shortcut: shortcutPoster.post(ShortcutPoster.dictation)
        }
        log.log(
          .info, "input", "dictationKey", nil,
          ["key": .string(key.rawValue), "purpose": .string(purpose.rawValue)])
        onPress?("dictation")
      case .recording(let isRecording, let sincePress):
        var fields: [String: LogValue] = ["recording": .bool(isRecording)]
        if let sincePress {
          fields["sincePressMs"] = .double((sincePress * 10_000).rounded() / 10)
        }
        log.log(.info, "input", "dictationRecording", nil, fields)
      case .listening(let isListening):
        log.log(.info, "input", "dictationListening", nil, ["listening": .bool(isListening)])
        onListeningChanged?(isListening)
      case .gaveUp(let purpose):
        log.log(
          .warning, "input", "dictationGaveUp",
          purpose == .stop
            ? "Dictation kept recording after every stop press"
            : "No key started Dictation", ["purpose": .string(purpose.rawValue)])
      }
    }
  }
}
