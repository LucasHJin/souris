import Foundation
import Testing

@testable import SourisCore

/// macOS's Dictation as the logs of 2026-10-25 show it: a press starts it if it's off, opening
/// the microphone `takesPressAfter + opensMicAfter` later and listening `listensAfter` after that;
/// a press while it is still starting is dropped; a press while it listens stops it.
private struct FakeDictation {
  var acceptedKeys: Set<DictationFollower.Key> = Set(DictationFollower.Key.allCases)
  var takesPressAfter: TimeInterval = 0.02

  /// How long the first press takes instead, as when Dictation's input method has to launch.
  var takesFirstPressAfter: TimeInterval?
  var opensMicAfter: TimeInterval = 0.1
  var listensAfter: TimeInterval = 0.25
  var closesMicAfter: TimeInterval = 0.05

  /// Stop presses to drop, as if they never arrived.
  var dropsStopPresses = 0

  /// When the microphone opens and closes, in order.
  private(set) var micOpenAt: TimeInterval?
  private(set) var micClosesAt: TimeInterval?

  private(set) var presses: [(key: DictationFollower.Key, time: TimeInterval)] = []

  mutating func press(_ key: DictationFollower.Key, at time: TimeInterval) {
    presses.append((key, time))
    guard acceptedKeys.contains(key) else { return }
    let isFirst = micOpenAt == nil
    let handledAt = time + (isFirst ? takesFirstPressAfter ?? takesPressAfter : takesPressAfter)
    if let micOpenAt, micClosesAt == nil {
      guard handledAt >= micOpenAt + listensAfter else { return }  // Still starting: dropped.
      if dropsStopPresses > 0 {
        dropsStopPresses -= 1
        return
      }
      micClosesAt = handledAt + closesMicAfter
    } else if micOpenAt == nil || (micClosesAt.map { handledAt >= $0 } ?? false) {
      micOpenAt = handledAt + opensMicAfter
      micClosesAt = nil
    }
  }

  /// Dictation stopping by itself, as when focus moves to another app.
  mutating func stopByItself(at time: TimeInterval) {
    micClosesAt = time
  }

  func isRecording(at time: TimeInterval) -> Bool {
    guard let micOpenAt, time >= micOpenAt else { return false }
    return micClosesAt.map { time < $0 } ?? true
  }

  func isListening(at time: TimeInterval) -> Bool {
    guard let micOpenAt else { return false }
    return isRecording(at: time) && time >= micOpenAt + listensAfter
  }
}

/// Runs the follower against a fake Dictation every 20 ms, with the phone asking from `holdFrom`
/// until `holdUntil`.
private struct Run {
  var follower = DictationFollower(keys: [.microphone, .shortcut])
  var dictation = FakeDictation()
  var actions: [(action: DictationFollower.Action, time: TimeInterval)] = []
  var events: [(time: TimeInterval, apply: (inout FakeDictation) -> Void)] = []

  mutating func hold(from start: TimeInterval, until end: TimeInterval, runUntil: TimeInterval) {
    let step = 0.02
    var time = start
    record(follower.setWanted(true, at: time), at: time)
    var released = false
    while time < runUntil {
      time += step
      for event in events where event.time > time - step && event.time <= time {
        event.apply(&dictation)
      }
      if !released && time >= end {
        released = true
        record(follower.setWanted(false, at: time), at: time)
      }
      record(follower.update(isRecording: dictation.isRecording(at: time), at: time), at: time)
    }
  }

  private mutating func record(_ new: [DictationFollower.Action], at time: TimeInterval) {
    for action in new {
      actions.append((action, time))
      if case .press(let key, _) = action {
        dictation.press(key, at: time)
      }
    }
  }

  var presses: [DictationFollower.Action] {
    actions.map(\.action).filter { if case .press = $0 { true } else { false } }
  }

  func firstTime(of action: DictationFollower.Action) -> TimeInterval? {
    actions.first { $0.action == action }?.time
  }

  /// When Dictation first counted as recording.
  var recordingStartTime: TimeInterval? {
    actions.first { if case .recording(true, _) = $0.action { true } else { false } }?.time
  }
}

struct DictationFollowerTests {
  @Test func aHoldStartsDictationAndTheReleaseStopsIt() {
    var run = Run()
    run.hold(from: 0, until: 2, runUntil: 3)
    #expect(run.presses == [.press(.microphone, .start), .press(.microphone, .stop)])
    #expect(run.dictation.isListening(at: 1))
    #expect(!run.dictation.isRecording(at: 3))
    #expect(!run.follower.needsUpdates)
  }

  @Test func listeningIsReportedOnceDictationTakesSpeech() throws {
    var run = Run()
    run.hold(from: 0, until: 2, runUntil: 3)
    let listening = try #require(run.firstTime(of: .listening(true)))
    let micOpen = try #require(run.recordingStartTime)
    #expect(listening >= micOpen + 0.25 && listening < micOpen + 0.3, "\(listening)")
    // It stops counting as listening the moment the stop is pressed.
    #expect(run.firstTime(of: .listening(false)) == run.firstTime(of: .press(.microphone, .stop)))
  }

  /// The first test session: Dictation's input method launched on the first press and took it
  /// 0.82 s later, the finger lifted 1 s in, and the stop press arrived while it was starting.
  @Test func aReleaseWhileDictationStartsWaitsUntilItListens() throws {
    var run = Run()
    run.dictation.takesFirstPressAfter = 0.82
    run.hold(from: 0, until: 1, runUntil: 4)
    #expect(run.presses == [.press(.microphone, .start), .press(.microphone, .stop)])
    let stop = try #require(run.firstTime(of: .press(.microphone, .stop)))
    #expect(stop >= 0.82 + 0.1 + 0.25, "\(stop)")
    #expect(!run.dictation.isRecording(at: 4))
  }

  @Test func dictationThatStopsByItselfIsNotStartedAgain() {
    var run = Run()
    run.events = [(1, { $0.stopByItself(at: 1) })]
    run.hold(from: 0, until: 2, runUntil: 3)
    #expect(run.presses == [.press(.microphone, .start)])
    #expect(!run.dictation.isRecording(at: 3))
    #expect(run.firstTime(of: .listening(false)).map { $0 > 1 && $0 < 1.3 } == true)
  }

  @Test func aKeyThatStartsNothingFallsBackToTheNext() throws {
    var run = Run()
    run.dictation.acceptedKeys = [.shortcut]
    run.hold(from: 0, until: 3, runUntil: 4)
    #expect(
      run.presses == [
        .press(.microphone, .start), .press(.shortcut, .fallback), .press(.shortcut, .stop),
      ])
    let fallback = try #require(run.firstTime(of: .press(.shortcut, .fallback)))
    #expect(fallback >= 1.5 && fallback < 1.55, "\(fallback)")
    // The key that worked goes first from now on.
    #expect(run.follower.keys == [.shortcut, .microphone])
  }

  @Test func noFallbackOnceThePhoneStopsAsking() {
    var run = Run()
    run.dictation.acceptedKeys = []
    run.hold(from: 0, until: 0.5, runUntil: 4)
    #expect(run.presses == [.press(.microphone, .start)])
    #expect(run.actions.map(\.action).contains(.gaveUp(.start)))
    #expect(!run.follower.needsUpdates)
  }

  @Test func whenNoKeyStartsDictationItGivesUpUntilAsked() {
    var run = Run()
    run.dictation.acceptedKeys = []
    run.hold(from: 0, until: 5, runUntil: 6)
    #expect(run.presses == [.press(.microphone, .start), .press(.shortcut, .fallback)])
    #expect(run.firstTime(of: .gaveUp(.start)).map { $0 >= 3 && $0 < 3.05 } == true)
    #expect(!run.actions.map(\.action).contains(.listening(true)))
  }

  @Test func aLostStopPressIsPressedAgain() throws {
    var run = Run()
    run.dictation.dropsStopPresses = 1
    run.hold(from: 0, until: 2, runUntil: 4)
    #expect(
      run.presses == [
        .press(.microphone, .start), .press(.microphone, .stop), .press(.microphone, .stop),
      ])
    #expect(!run.dictation.isRecording(at: 4))
  }

  @Test func stopsArePressedAtMostThreeTimes() {
    var run = Run()
    run.dictation.dropsStopPresses = 10
    run.hold(from: 0, until: 2, runUntil: 6)
    #expect(run.presses.count == 4)
    #expect(run.actions.map(\.action).contains(.gaveUp(.stop)))
    #expect(!run.follower.needsUpdates)
  }

  @Test func aBriefMicrophoneDropoutIsNotAStop() {
    var follower = DictationFollower(keys: [.shortcut])
    _ = follower.setWanted(true, at: 0)
    _ = follower.update(isRecording: true, at: 0.1)
    _ = follower.setWanted(false, at: 0.15)
    // The microphone drops out for 80 ms while Dictation starts.
    var actions = follower.update(isRecording: false, at: 0.2)
    actions += follower.update(isRecording: true, at: 0.28)
    #expect(!actions.contains(.recording(false, sincePress: nil)))
    // It still counts as the phone's, so it is stopped once listening.
    actions += follower.update(isRecording: true, at: 0.36)
    #expect(actions.contains(.press(.shortcut, .stop)))
  }

  @Test func dictationStartedFromTheKeyboardIsLeftAlone() {
    var follower = DictationFollower()
    #expect(follower.update(isRecording: true, at: 0) == [.recording(true, sincePress: nil)])
    #expect(follower.update(isRecording: true, at: 1).isEmpty)
    #expect(!follower.needsUpdates)
  }

  @Test func holdingWhileDictationRunsTakesItOver() {
    var follower = DictationFollower(keys: [.shortcut])
    _ = follower.update(isRecording: true, at: 0)
    // Already listening, so no press, and the phone hears about it at once.
    #expect(follower.setWanted(true, at: 1) == [.listening(true)])
    let release = follower.setWanted(false, at: 2)
    #expect(release == [.press(.shortcut, .stop), .listening(false)])
  }

  @Test func holdingAgainDuringAStopStartsDictationOnceItStops() {
    var run = Run()
    run.hold(from: 0, until: 1, runUntil: 1.04)
    run.hold(from: 1.04, until: 3, runUntil: 4)
    #expect(
      run.presses == [
        .press(.microphone, .start), .press(.microphone, .stop),
        .press(.microphone, .start), .press(.microphone, .stop),
      ])
    #expect(run.dictation.isListening(at: 2))
  }
}
