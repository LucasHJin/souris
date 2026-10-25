import Foundation

import SourisCore

/// The Mac's diagnostic log, which also receives everything the phone sends.
///
/// - One file per launch, `~/Library/Logs/Souris/souris-<date>.jsonl`. Each line is a
///   `LogEntry` with a `source` key in front: `mac` (the app), `server` (the listener) or `phone`.
///   Phone lines also carry `device`, `stream` (one per phone app launch) and `received` (the
///   Mac's wall clock on arrival, which shows how late a backlog came in).
/// - Sensor recordings the phone streams are written as they arrive to
///   `~/Library/Logs/Souris/Recordings/<device>-<name>.jsonl`, ready for `souris-replay`.
/// - Files older than `retentionDays` are deleted at launch.
///
/// Every method may be called from any thread; writes happen in order on a utility queue and are
/// flushed about once a second.
final class MacLog: @unchecked Sendable {
  static let retentionDays = 14

  static let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Souris", isDirectory: true)

  static let recordingsDirectory = directory.appendingPathComponent(
    "Recordings", isDirectory: true)

  /// This launch's log file.
  let fileURL: URL

  /// A recording being received, keyed by stream and recording id.
  private struct Recording {
    var url: URL
    var handle: FileHandle?
    var buffer = Data()
    var lines = 0
  }

  private struct RecordingKey: Hashable {
    var stream: UInt32
    var id: UInt32
  }

  private let queue = DispatchQueue(label: "souris.log", qos: .utility)
  private let handle: FileHandle?
  private var buffer = Data()
  private var recordings: [RecordingKey: Recording] = [:]
  private var flushTimer: (any DispatchSourceTimer)?

  init() {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
    Self.deleteOldFiles(in: Self.directory)
    Self.deleteOldFiles(in: Self.recordingsDirectory)
    fileURL = Self.directory.appendingPathComponent("souris-\(Self.timestamp()).jsonl")
    fileManager.createFile(atPath: fileURL.path, contents: nil)
    handle = try? FileHandle(forWritingTo: fileURL)

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(200))
    timer.setEventHandler { [weak self] in self?.writeBuffers() }
    timer.resume()
    flushTimer = timer
  }

  deinit {
    flushTimer?.cancel()
  }

  /// Logs one of the Mac's own entries. `source` is `mac` or `server`.
  func write(_ entry: LogEntry, source: String = "mac") {
    let prefix = "{\"source\":\(Self.jsonString(source)),"
    queue.async { [self] in
      append(prefix, entry)
    }
  }

  /// Convenience for the app's own entries, stamped now.
  func log(
    _ level: LogLevel,
    _ category: String,
    _ event: String,
    _ message: String? = nil,
    _ fields: [String: LogValue] = [:]
  ) {
    write(LogEntry(level: level, category: category, event: event, message: message, fields: fields))
  }

  /// Writes what one log packet from a phone delivered.
  func write(_ batch: PhoneLogBatch) {
    let received = Date()
    queue.async { [self] in
      let device = batch.peer.name
      if batch.missingBefore > 0 {
        append(
          "{\"source\":\"mac\",",
          LogEntry(
            level: .warning, category: "log", event: "phoneLogGap",
            message: "The phone dropped log records before sending them",
            fields: [
              "device": .string(device), "stream": .int(Int(batch.streamID)),
              "missing": .int(batch.missingBefore),
            ]))
      }
      let prefix = "{\"source\":\"phone\",\"device\":\(Self.jsonString(device)),"
        + "\"stream\":\(batch.streamID),\"received\":\(Self.jsonString(Self.iso(received))),"
      for record in batch.records {
        deliver(record, stream: batch.streamID, device: device, phonePrefix: prefix)
      }
    }
  }

  /// Writes everything buffered and waits for it, e.g. when quitting.
  func flushAndWait() {
    queue.sync { writeBuffers() }
  }

  // MARK: - On the queue

  private func deliver(
    _ record: UplinkRecord, stream: UInt32, device: String, phonePrefix: String
  ) {
    switch record {
    case .log(let entry):
      append(phonePrefix, entry)
    case .recordingStarted(let id, let name):
      let key = RecordingKey(stream: stream, id: id)
      closeRecording(key)
      let url = Self.recordingsDirectory.appendingPathComponent(
        "\(Self.fileSafe(device))-\(name.hasSuffix(".jsonl") ? name : name + ".jsonl")")
      recordings[key] = openRecording(at: url)
      append(
        "{\"source\":\"mac\",",
        LogEntry(
          level: .info, category: "recording", event: "receiving",
          fields: ["device": .string(device), "path": .string(url.path)]))
    case .recordingLine(let id, let line):
      let key = RecordingKey(stream: stream, id: id)
      if recordings[key] == nil {
        // The start marker was lost (the Mac app restarted mid-recording, or the phone dropped
        // it), so name the file after the stream instead.
        let url = Self.recordingsDirectory.appendingPathComponent(
          "\(Self.fileSafe(device))-stream\(stream)-recording\(id)-partial.jsonl")
        recordings[key] = openRecording(at: url)
      }
      recordings[key]?.buffer.append(line)
      recordings[key]?.buffer.append(0x0A)
      recordings[key]?.lines += 1
    case .recordingEnded(let id):
      let key = RecordingKey(stream: stream, id: id)
      guard let recording = recordings[key] else { return }
      closeRecording(key)
      append(
        "{\"source\":\"mac\",",
        LogEntry(
          level: .info, category: "recording", event: "saved",
          fields: [
            "device": .string(device), "path": .string(recording.url.path),
            "lines": .int(recording.lines),
          ]))
    }
  }

  private func append(_ prefix: String, _ entry: LogEntry) {
    // `jsonLine()` starts with `{`; the prefix replaces it and adds the extra keys first.
    buffer.append(Data(prefix.utf8))
    buffer.append(entry.jsonLine().dropFirst())
    buffer.append(0x0A)
    if buffer.count >= 256 * 1024 {
      writeBuffers()
    }
  }

  private func openRecording(at url: URL) -> Recording {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return Recording(url: url, handle: try? FileHandle(forWritingTo: url))
  }

  private func closeRecording(_ key: RecordingKey) {
    guard var recording = recordings.removeValue(forKey: key) else { return }
    write(&recording)
    try? recording.handle?.close()
  }

  private func writeBuffers() {
    if !buffer.isEmpty {
      try? handle?.write(contentsOf: buffer)
      buffer.removeAll(keepingCapacity: true)
    }
    for key in Array(recordings.keys) {
      write(&recordings[key]!)
    }
  }

  private func write(_ recording: inout Recording) {
    guard !recording.buffer.isEmpty else { return }
    try? recording.handle?.write(contentsOf: recording.buffer)
    recording.buffer.removeAll(keepingCapacity: true)
  }

  // MARK: - Helpers

  private static func deleteOldFiles(in directory: URL) {
    let fileManager = FileManager.default
    let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
    let files = (try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files where file.pathExtension == "jsonl" {
      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      if let modified, modified < cutoff {
        try? fileManager.removeItem(at: file)
      }
    }
  }

  private static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: Date())
  }

  private static func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }

  /// `name` as a JSON string literal, quotes included.
  private static func jsonString(_ name: String) -> String {
    guard let data = try? JSONEncoder().encode(name) else { return "\"\"" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Letters, digits, `-` and `_` only, for file names built from a phone's name.
  private static func fileSafe(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return result.isEmpty ? "iPhone" : result
  }
}
