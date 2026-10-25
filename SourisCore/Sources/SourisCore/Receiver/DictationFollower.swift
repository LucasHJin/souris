import Foundation

/// Keeps macOS's Dictation on while the phone asks for it, judging by whether Dictation is
/// recording rather than by counting presses of the key that toggles it.
///
/// Dictation drops a press that arrives while it is still starting (it takes it for a second
/// start), so counting presses drifts: after one lost press Dictation is on whenever the wheel
/// isn't held. The rules:
/// - When the phone starts asking and Dictation isn't recording, press the first of `keys`. If
///   nothing records within `fallbackDelay` and the phone still asks, press each other key once.
///   Recording that starts within `startTimeout` of the first press is Dictation starting, and
///   the key pressed last moves to the front of `keys`.
/// - Dictation is listening once it has recorded for `listeningDelay`: the microphone opens that
///   long before Dictation takes speech.
/// - When the phone stops asking and Dictation is listening, press the key that started it. While
///   it is still starting, wait until it listens. If it still records `stopTimeout` after a press,
///   press again, up to `maxStopPresses` in all.
/// - Recording counts as stopped only after `stopDebounce` without it, since the microphone can
///   drop out briefly while Dictation starts.
/// - Dictation that stops by itself while the phone asks isn't restarted until the phone asks
///   again. Dictation the phone didn't ask for (started from the keyboard) is left alone, unless
///   the phone asks while it runs: then the phone's release stops it.
public struct DictationFollower: Sendable {
  /// A key that toggles Dictation.
  public enum Key: String, CaseIterable, Sendable {
    /// The keyboard's 🎤 key.
    case microphone

    /// Dictation's custom shortcut, ⌃⌥D, which Lucas sets in System Settings.
    case shortcut
  }

  /// Why a key was pressed.
  public enum Purpose: String, Sendable {
    case start

    /// Another key, after the first one started nothing.
    case fallback

    case stop
  }

  public enum Action: Equatable, Sendable {
    case press(Key, Purpose)

    /// Dictation started or stopped recording, `sincePress` after the press that asked for it
    /// (the first press for a start, the latest for a stop), if one did.
    case recording(Bool, sincePress: TimeInterval?)

    /// Whether Dictation is listening for the phone changed.
    case listening(Bool)

    /// Dictation didn't respond to the presses for a start or a stop, so the follower stopped
    /// trying until the phone asks again.
    case gaveUp(Purpose)
  }

  public struct Settings: Equatable, Sendable {
    /// How long Dictation records before it takes speech, seconds. Measured on the M1 Pro as
    /// 0.24–0.26 s from the microphone opening to Dictation's listening state (2026-10-25).
    public var listeningDelay: TimeInterval = 0.25

    /// How long to wait for a key to start Dictation before trying the next, seconds. A cold
    /// start, when Dictation's input method has to launch, took 0.8 s to take the press.
    public var fallbackDelay: TimeInterval = 1.5

    /// How long after the first press recording still counts as the start, seconds.
    public var startTimeout: TimeInterval = 3

    /// How long a stop may take before the key is pressed again, seconds. Dictation stopped
    /// within 0.11 s of the press, then the debounce adds `stopDebounce`.
    public var stopTimeout: TimeInterval = 0.6

    public var maxStopPresses = 3

    /// How long recording must be off before it counts as stopped, seconds.
    public var stopDebounce: TimeInterval = 0.2

    public init() {}
  }

  /// A start or stop that was pressed for and hasn't shown in the recording yet.
  private struct Pending {
    var purpose: Purpose
    var key: Key
    var firstPressAt: TimeInterval
    var lastPressAt: TimeInterval
    var presses = 1
    var triedKeys: [Key]

    init(purpose: Purpose, key: Key, at time: TimeInterval) {
      self.purpose = purpose
      self.key = key
      firstPressAt = time
      lastPressAt = time
      triedKeys = [key]
    }

    var isStart: Bool {
      purpose != .stop
    }
  }

  public var settings: Settings

  /// The keys to try, in order.
  public private(set) var keys: [Key]

  /// Whether Dictation is listening for the phone.
  public private(set) var isListening = false

  private var isWanted = false

  /// The phone's current request has been acted on: it started Dictation or found it running.
  private var hasHandledRequest = false

  /// Dictation is running, or starting, for the phone, so the phone's release stops it.
  private var ownsSession = false

  /// Recording, debounced, and since when.
  private var isRecording = false
  private var recordingSince: TimeInterval?
  private var silentSince: TimeInterval?

  /// The key that started the current session.
  private var activeKey: Key?
  private var pending: Pending?

  public init(keys: [Key] = Key.allCases, settings: Settings = Settings()) {
    precondition(!keys.isEmpty, "DictationFollower needs a key to press")
    self.keys = keys
    self.settings = settings
  }

  /// Whether `update(isRecording:at:)` should be called every few tens of milliseconds. When
  /// false, nothing the recording does changes anything.
  public var needsUpdates: Bool {
    isWanted || ownsSession || pending != nil
  }

  /// The phone started (`wanted`) or stopped asking for Dictation.
  public mutating func setWanted(_ wanted: Bool, at time: TimeInterval) -> [Action] {
    guard wanted != isWanted else { return [] }
    isWanted = wanted
    if wanted {
      hasHandledRequest = false
    }
    return reconcile(at: time)
  }

  /// Takes whether Dictation records now, and presses whatever is due.
  public mutating func update(isRecording recording: Bool, at time: TimeInterval) -> [Action] {
    var actions: [Action] = []
    if recording {
      silentSince = nil
      if !isRecording {
        isRecording = true
        recordingSince = time
        let sincePress = pending.flatMap { $0.isStart ? time - $0.firstPressAt : nil }
        actions.append(.recording(true, sincePress: sincePress))
      }
    } else if isRecording {
      let since = silentSince ?? time
      silentSince = since
      if time - since >= settings.stopDebounce {
        isRecording = false
        recordingSince = nil
        silentSince = nil
        let sincePress = pending.flatMap { $0.isStart ? nil : since - $0.lastPressAt }
        actions.append(.recording(false, sincePress: sincePress))
      }
    }
    return actions + reconcile(at: time)
  }

  // MARK: - Private

  private func isListeningNow(at time: TimeInterval) -> Bool {
    guard isRecording, let recordingSince else { return false }
    return time - recordingSince >= settings.listeningDelay
  }

  private mutating func reconcile(at time: TimeInterval) -> [Action] {
    var actions: [Action] = []
    if let pending {
      actions += resolve(pending, at: time)
    }
    if pending == nil {
      if isWanted {
        if !hasHandledRequest {
          hasHandledRequest = true
          ownsSession = true
          if !isRecording {
            let key = keys[0]
            pending = Pending(purpose: .start, key: key, at: time)
            actions.append(.press(key, .start))
          }
        }
      } else if ownsSession {
        if !isRecording {
          ownsSession = false
        } else if isListeningNow(at: time) {
          let key = activeKey ?? keys[0]
          pending = Pending(purpose: .stop, key: key, at: time)
          actions.append(.press(key, .stop))
        }
      }
    }
    let listening = ownsSession && pending?.purpose != .stop && isListeningNow(at: time)
    if listening != isListening {
      isListening = listening
      actions.append(.listening(listening))
    }
    return actions
  }

  /// Clears `pending` once the recording shows it took effect, and presses again when it is
  /// overdue.
  private mutating func resolve(_ pending: Pending, at time: TimeInterval) -> [Action] {
    var pending = pending
    if pending.isStart {
      if isRecording {
        self.pending = nil
        activeKey = pending.key
        keys.removeAll { $0 == pending.key }
        keys.insert(pending.key, at: 0)
      } else if time - pending.firstPressAt >= settings.startTimeout {
        self.pending = nil
        ownsSession = false
        return [.gaveUp(.start)]
      } else if isWanted, time - pending.lastPressAt >= settings.fallbackDelay,
        let next = keys.first(where: { !pending.triedKeys.contains($0) })
      {
        pending.purpose = .fallback
        pending.key = next
        pending.lastPressAt = time
        pending.presses += 1
        pending.triedKeys.append(next)
        self.pending = pending
        return [.press(next, .fallback)]
      }
      return []
    }
    if !isRecording {
      self.pending = nil
      ownsSession = false
    } else if time - pending.lastPressAt >= settings.stopTimeout {
      if isWanted {
        // The phone asks again and Dictation is still on: leave it on.
        self.pending = nil
      } else if pending.presses < settings.maxStopPresses {
        pending.lastPressAt = time
        pending.presses += 1
        self.pending = pending
        return [.press(pending.key, .stop)]
      } else {
        self.pending = nil
        ownsSession = false
        return [.gaveUp(.stop)]
      }
    }
    return []
  }
}
