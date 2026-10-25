import Foundation
import Synchronization

import SourisCore

/// Writes one sensor session to `Documents/Recordings/<date>.jsonl` on its own utility queue.
///
/// The file is flushed about once a second. A write error stops the recording and shows up in
/// `failure`. Every line written is also handed to `onLine`, which sends it on to the Mac.
final class SessionRecorder: @unchecked Sendable {
  /// `systemUptime` when the recording began.
  let startedAt: TimeInterval

  /// The file name, which the Mac reuses for its copy.
  let name: String

  private let queue = DispatchQueue(label: "souris.recording", qos: .utility)
  private let writer: RecordingWriter
  private let onLine: @Sendable (Data) -> Void
  private var lastFlush: TimeInterval
  private var isFinished = false
  private let failureText = Mutex<String?>(nil)

  var failure: String? {
    failureText.withLock { $0 }
  }

  /// Creates the file and writes `settings` (and the paused state, if paused) as its first lines.
  ///
  /// - Parameter onLine: Called on the recorder's queue with each line written, without the
  ///   newline, in order.
  init(
    settings: PipelineSettings,
    isPaused: Bool,
    onLine: @escaping @Sendable (Data) -> Void
  ) throws {
    let directory = try Self.recordingsDirectory()
    name = Self.newFileName()
    writer = try RecordingWriter(url: directory.appendingPathComponent(name))
    self.onLine = onLine
    startedAt = ProcessInfo.processInfo.systemUptime
    lastFlush = startedAt
    let firstLines = [try writer.append(.settings(settings))]
      + (isPaused ? [try writer.append(.paused(true))] : [])
    queue.async {
      for line in firstLines {
        onLine(line)
      }
    }
  }

  func record(_ event: RecordedEvent) {
    queue.async { [self] in
      guard !isFinished, failure == nil else { return }
      do {
        onLine(try writer.append(event))
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFlush >= 1 {
          lastFlush = now
          try writer.flush()
        }
      } catch {
        fail(error)
      }
    }
  }

  /// Flushes and closes the file, then calls `completion` on the recorder's queue, after the last
  /// `onLine`. Later `record` calls are ignored.
  func finish(completion: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      guard !isFinished else { return }
      isFinished = true
      do {
        try writer.flush()
        try writer.close()
      } catch {
        fail(error)
      }
      completion()
    }
  }

  private func fail(_ error: any Error) {
    failureText.withLock { $0 = "Recording stopped: \(error.localizedDescription)" }
  }

  private static func recordingsDirectory() throws -> URL {
    let documents = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = documents.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func newFileName() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: Date()) + ".jsonl"
  }
}
