import Foundation
import Testing
import simd

@testable import SourisCore

@Suite struct RecordingRoundTripTests {
  /// A session with a bit of everything: slides, a swivel, a click, tilt and button scrolls, a
  /// lift, a pause and a recenter.
  static func richSession() -> [RecordedEvent] {
    var session = SyntheticSession(duration: 8)
    session.path.position = { time in
      let right = 0.02 * Synthetic.ramp(time, 0.5, 1) + 0.01 * Synthetic.ramp(time, 4, 4.15)
      let forward = 0.015 * Synthetic.ramp(time, 1.2, 1.6)
      let up = 0.04 * Synthetic.ramp(time, 4, 4.15) - 0.03 * Synthetic.ramp(time, 4.6, 4.8)
      return Synthetic.rest + SIMD3(right, up, -forward)
    }
    session.path.yaw = { time in -0.2 * Synthetic.ramp(time, 1.8, 2.2) }
    session.path.pitch = { time in
      22 * .pi / 180 * (Synthetic.ramp(time, 3, 3.2) - Synthetic.ramp(time, 3.6, 3.8))
    }
    session.touch(.contact(time: 2.5))
    session.touch(.button(.left, isDown: true, time: 2.55))
    session.touch(.contact(time: 2.7))
    session.touch(.button(.left, isDown: false, time: 2.7))
    session.scrollPress(.up, at: 0.8)
    session.scrollPress(.down, at: 2)
    session.scrollPress(.down, at: 2.125)
    session.scrollPress(.up, at: 5)
    session.pause(true, at: 5.5)
    session.scrollPress(.up, at: 5.7)
    session.pause(false, at: 6)
    session.inserts.append((6.5, .recenter))
    return [.settings(Synthetic.tiltSettings)] + session.events()
  }

  static func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("souris-\(UUID().uuidString)-\(name).jsonl")
  }

  static func write(_ events: [RecordedEvent], to url: URL) throws {
    let writer = try RecordingWriter(url: url)
    for event in events {
      try writer.append(event)
    }
    try writer.close()
  }

  @Test func eventsSurviveARoundTrip() throws {
    let events = Self.richSession()
    let url = Self.temporaryURL("round-trip")
    defer { try? FileManager.default.removeItem(at: url) }
    try Self.write(events, to: url)
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    // Big enough to have gone through several buffer flushes.
    #expect(size > 3 * RecordingWriter.bufferLimit)
    #expect(try RecordingReader.events(at: url) == events)
  }

  @Test func aTornLastLineIsSkipped() throws {
    let events = Array(Self.richSession().prefix(50))
    let url = Self.temporaryURL("torn")
    defer { try? FileManager.default.removeItem(at: url) }
    try Self.write(events, to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"ar\":{\"_0\":{\"timest".utf8))
    try handle.close()
    #expect(try RecordingReader.events(at: url) == events)
  }

  @Test func replayIsDeterministic() throws {
    let events = Self.richSession()
    let first = RecordingReplay.run(events)
    let second = RecordingReplay.run(events)
    #expect(first == second)
    #expect(first.count == events.count)

    let url = Self.temporaryURL("determinism")
    defer { try? FileManager.default.removeItem(at: url) }
    try Self.write(events, to: url)
    #expect(RecordingReplay.run(try RecordingReader.events(at: url)) == first)
    // The session exercised the whole pipeline.
    let final = try #require(first.last)
    #expect(simd_length(final.state.cursor) > 10)
    #expect(final.state.scroll.y > 10)
    #expect(first.contains { $0.state.flags.contains(.scrollActive) })
    #expect(first.contains { $0.state.flags.contains(.lifted) })
    #expect(first.contains { $0.state.buttons == [.left] })
    #expect(first.contains { $0.state.flags.contains(.paused) })
    // Four of the five presses count; the one during the pause is ignored.
    #expect(final.diagnostics.scrollPresses == 4)
  }

  @Test func scrollPressesSurviveARoundTripAndReplayWithTheirEvents() throws {
    let events = Self.richSession()
    let presses = events.compactMap { event -> ScrollButtonPress? in
      if case .scrollPress(let press) = event { return press }
      return nil
    }
    #expect(presses.count == 5)
    let url = Self.temporaryURL("presses")
    defer { try? FileManager.default.removeItem(at: url) }
    try Self.write(events, to: url)
    let read = try RecordingReader.events(at: url)
    #expect(read == events)
    #expect(read.contains(.scrollPress(ScrollButtonPress(direction: .down, time: 2.125))))

    let steps = RecordingReplay.run(read)
    // Each press shows up in its own step, with the press's own time.
    let pressSteps = steps.filter {
      $0.events.contains { if case .scrollPress = $0.kind { true } else { false } }
    }
    #expect(pressSteps.map(\.time) == [0.8, 2, 2.125, 5])
    #expect(steps.last?.diagnostics.scrollPresses == 4)
  }

  @Test func recordingsWithoutScrollPressesStillDecode() throws {
    // A line written before button scroll existed.
    let line = Data(#"{"paused":{"_0":true}}"#.utf8)
    #expect(try JSONDecoder().decode(RecordedEvent.self, from: line) == .paused(true))
  }

  @Test func settingsLinesApplyUnlessOverridden() {
    var session = SyntheticSession(duration: 2)
    session.path.position = { time in
      Synthetic.rest + SIMD3(0.02 * Synthetic.ramp(time, 0.5, 1), 0, 0)
    }
    var doubled = Synthetic.flatGainSettings
    doubled.pointer.slowGain = 5
    let events = [RecordedEvent.settings(doubled)] + session.events()
    let recorded = RecordingReplay.run(events).last?.state.cursor.x ?? 0
    let overridden = RecordingReplay.run(events, settings: Synthetic.flatGainSettings)
      .last?.state.cursor.x ?? 0
    #expect(abs(recorded - 100) < 0.5, "recorded \(recorded)")
    #expect(abs(overridden - 50) < 0.5, "overridden \(overridden)")
  }

  @Test func nonSampleLinesKeepThePreviousTime() {
    let sample = SyntheticSession(duration: 0.1).arSample(at: 0.05)
    let events: [RecordedEvent] = [
      .settings(PipelineSettings()), .ar(sample), .paused(true), .recenter,
      .touch(.contact(time: 0.2)), .scrollPress(ScrollButtonPress(direction: .up, time: 0.3)),
      .paused(false),
    ]
    let times = RecordingReplay.run(events).map(\.time)
    #expect(times == [0, sample.arrival, sample.arrival, sample.arrival, 0.2, 0.3, 0.3])
  }

  @Test func recenterReplaysLikeACall() {
    let events = Self.richSession()
    var pipeline = MotionPipeline()
    for event in events {
      pipeline.feed(event)
    }
    #expect(RecordingReplay.run(events).last?.state == pipeline.state)
    #expect(events.contains(.recenter))
  }

  /// Writes the rich session where `SOURIS_SAMPLE_RECORDING` points, for trying `souris-replay`.
  @Test func writesASampleRecordingWhenAsked() throws {
    guard let path = ProcessInfo.processInfo.environment["SOURIS_SAMPLE_RECORDING"] else { return }
    try Self.write(Self.richSession(), to: URL(fileURLWithPath: path))
  }
}
