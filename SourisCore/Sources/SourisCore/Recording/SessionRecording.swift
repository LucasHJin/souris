import Foundation

/// One line of a recorded sensor session.
public enum RecordedEvent: Equatable, Codable, Sendable {
  /// The settings in force from this point on. The first line of every recording.
  case settings(PipelineSettings)
  case ar(ARSample)
  case imu(IMUSample)
  case touch(TouchEvent)

  /// A volume-button press (`MotionPipeline.handle(_:)` with a `ScrollButtonPress`).
  case scrollPress(ScrollButtonPress)

  /// A scroll wheel event (`MotionPipeline.handle(_:)` with a `ScrollWheelEvent`).
  case wheel(ScrollWheelEvent)

  case paused(Bool)

  /// `MotionPipeline.recenter()` was called (the Recenter button, or after an ARKit
  /// interruption).
  case recenter
}

/// Writes recorded events as JSON Lines (one `RecordedEvent` per line).
///
/// Not thread-safe: confine each writer to one serial queue (hence `@unchecked Sendable`).
/// Buffered: call `flush()` now and then and `close()` when done.
public final class RecordingWriter: @unchecked Sendable {
  /// Buffered bytes past which `append` writes to the file.
  static let bufferLimit = 64 * 1024

  public let url: URL

  private let handle: FileHandle
  private let encoder = JSONEncoder()
  private var buffer = Data()
  private var isClosed = false

  /// Creates (or truncates) the file at `url`.
  public init(url: URL) throws {
    self.url = url
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    handle = try FileHandle(forWritingTo: url)
    buffer.reserveCapacity(Self.bufferLimit * 2)
  }

  deinit {
    try? close()
  }

  /// Adds one event. It reaches the file when the buffer fills, or on `flush()` or `close()`.
  ///
  /// - Returns: The event's JSON line, without the newline, for sending on to the Mac.
  @discardableResult
  public func append(_ event: RecordedEvent) throws -> Data {
    guard !isClosed else { throw CocoaError(.fileWriteUnknown) }
    let line = try encoder.encode(event)
    buffer.append(line)
    buffer.append(0x0A)
    if buffer.count >= Self.bufferLimit {
      try flush()
    }
    return line
  }

  /// Writes out everything buffered so far.
  public func flush() throws {
    guard !isClosed, !buffer.isEmpty else { return }
    try handle.write(contentsOf: buffer)
    buffer.removeAll(keepingCapacity: true)
  }

  /// Flushes and closes the file. Later calls do nothing.
  public func close() throws {
    guard !isClosed else { return }
    try flush()
    isClosed = true
    try handle.close()
  }
}

/// Reads a recording written by `RecordingWriter`.
public enum RecordingReader {
  /// Every event in the file, in order. Lines that fail to decode (a torn last line) are skipped.
  public static func events(at url: URL) throws -> [RecordedEvent] {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    var events: [RecordedEvent] = []
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
      if let event = try? decoder.decode(RecordedEvent.self, from: Data(line)) {
        events.append(event)
      }
    }
    return events
  }
}

/// Runs a recording through a fresh `MotionPipeline` and collects its outputs, for tuning on the
/// Mac (see `souris-replay`).
public enum RecordingReplay {
  /// One pipeline output, stamped with the arrival time of the input that produced it.
  public struct Step: Equatable, Sendable {
    public var time: TimeInterval
    public var state: MouseState
    public var diagnostics: PipelineDiagnostics

    /// The pipeline events this input caused.
    public var events: [PipelineEvent]

    public init(
      time: TimeInterval,
      state: MouseState,
      diagnostics: PipelineDiagnostics,
      events: [PipelineEvent] = []
    ) {
      self.time = time
      self.state = state
      self.diagnostics = diagnostics
      self.events = events
    }
  }

  /// Replays `events`. If `settings` is given it overrides every recorded settings line.
  ///
  /// Each input yields one step. Samples are stamped with their arrival time, touches,
  /// scroll-button presses and wheel events with their own time, and settings, pause and recenter
  /// lines with the previous step's time.
  public static func run(
    _ events: [RecordedEvent],
    settings: PipelineSettings? = nil
  ) -> [Step] {
    var pipeline = MotionPipeline(settings: settings ?? PipelineSettings())
    var steps: [Step] = []
    steps.reserveCapacity(events.count)
    var time: TimeInterval = 0
    for event in events {
      switch event {
      case .settings(let recorded):
        if settings == nil {
          pipeline.settings = recorded
        }
      case .ar(let sample):
        pipeline.process(sample)
        time = sample.arrival
      case .imu(let sample):
        pipeline.process(sample)
        time = sample.arrival
      case .touch(let touch):
        pipeline.handle(touch)
        time = touch.time
      case .scrollPress(let press):
        pipeline.handle(press)
        time = press.time
      case .wheel(let wheel):
        pipeline.handle(wheel)
        time = wheel.time
      case .paused(let isPaused):
        pipeline.setPaused(isPaused)
      case .recenter:
        pipeline.recenter()
      }
      steps.append(
        Step(
          time: time,
          state: pipeline.state,
          diagnostics: pipeline.diagnostics,
          events: pipeline.drainEvents()))
    }
    return steps
  }
}
