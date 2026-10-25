import Foundation
import os

import SourisCore

/// The phone's copy of its log: `Documents/Logs/phone-<date>.jsonl`, one `LogEntry` per line,
/// plus the unified log. Everything sent to the Mac lands here too, so a session that never
/// reached the Mac can still be read (Files → On My iPhone → Souris → Logs).
///
/// Writes happen on a utility queue and are flushed about once a second.
final class PhoneLogFile: @unchecked Sendable {
  /// Log files kept; older ones are deleted at launch.
  static let keptFiles = 20

  let url: URL?

  private let queue = DispatchQueue(label: "souris.log-file", qos: .utility)
  private let handle: FileHandle?
  private let logger = Logger(subsystem: "com.lucasjin.souris", category: "souris")
  private var buffer = Data()
  private var lastFlush = ProcessInfo.processInfo.systemUptime

  init() {
    let directory = try? Self.logsDirectory()
    if let directory {
      Self.deleteOldFiles(in: directory)
      let url = directory.appendingPathComponent("phone-\(Self.timestamp()).jsonl")
      FileManager.default.createFile(atPath: url.path, contents: nil)
      self.url = url
      handle = try? FileHandle(forWritingTo: url)
    } else {
      url = nil
      handle = nil
    }
  }

  deinit {
    try? handle?.close()
  }

  /// Queues `entry` for the file and mirrors it to the unified log.
  func append(_ entry: LogEntry) {
    let line = entry.jsonLine()
    mirror(entry, line: line)
    queue.async { [self] in
      buffer.append(line)
      buffer.append(0x0A)
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastFlush >= 1 || buffer.count >= 64 * 1024 {
        writeBuffer(at: now)
      }
    }
  }

  /// Writes everything queued so far, e.g. when the app leaves the foreground.
  func flush() {
    queue.async { [self] in
      writeBuffer(at: ProcessInfo.processInfo.systemUptime)
    }
  }

  private func writeBuffer(at now: TimeInterval) {
    lastFlush = now
    guard !buffer.isEmpty else { return }
    try? handle?.write(contentsOf: buffer)
    buffer.removeAll(keepingCapacity: true)
  }

  private func mirror(_ entry: LogEntry, line: Data) {
    // The 5 Hz stats would drown everything else in Console; they're in the file and on the Mac.
    guard entry.category != "stats" else { return }
    let text = String(decoding: line, as: UTF8.self)
    switch entry.level {
    case .debug: logger.debug("\(text, privacy: .public)")
    case .info: logger.info("\(text, privacy: .public)")
    case .warning: logger.notice("\(text, privacy: .public)")
    case .error: logger.error("\(text, privacy: .public)")
    }
  }

  private static func logsDirectory() throws -> URL {
    let documents = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = documents.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Keeps the newest `keptFiles − 1`, making room for the one about to be created. File names
  /// start with a sortable timestamp.
  private static func deleteOldFiles(in directory: URL) {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    let logs = files.filter { $0.pathExtension == "jsonl" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in logs.dropLast(keptFiles - 1) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: Date())
  }
}

// MARK: - Turning things into log entries

extension PipelineEvent {
  /// The event as a "pipeline" log entry, dated by its own uptime.
  func logEntry(now: TimeInterval, date: Date) -> LogEntry {
    let (level, name, fields) = describe()
    return LogEntry(
      time: time,
      date: date.addingTimeInterval(time - now),
      level: level,
      category: "pipeline",
      event: name,
      fields: fields)
  }

  private func describe() -> (LogLevel, String, [String: LogValue]) {
    switch kind {
    case .engaged(let pitch, let isLevelCaptured):
      var fields: [String: LogValue] = ["levelCaptured": .bool(isLevelCaptured)]
      if let pitch {
        fields["pitchDeg"] = .double(pitch.rounded(places: 1))
      }
      return (.info, "engaged", fields)
    case .levelRejected(let pitch):
      return (.info, "levelRejected", ["pitchDeg": .double(pitch.rounded(places: 1))])
    case .reanchored(let reason):
      return (.info, "reanchored", ["reason": .string(reason.rawValue)])
    case .lifted(let rise, let rolledBack):
      return (
        .info, "lifted",
        ["riseCm": .double(rise.rounded(places: 2)),
         "rolledBackPt": .double(rolledBack.rounded(places: 1))]
      )
    case .setDown(let drop):
      return (.info, "setDown", ["dropCm": .double(drop.rounded(places: 2))])
    case .jumpRejected(let speed):
      return (.warning, "jumpRejected", ["speedMS": .double(speed.rounded(places: 2))])
    case .trackingChanged(let status):
      let level: LogLevel = status == .normal ? .info : .warning
      return (level, "tracking", ["status": .string(status.rawValue)])
    case .gateChanged(let from, let to):
      // A click freeze opens and closes on every tap; the rest explain a stopped cursor.
      let level: LogLevel = from == .clickFreeze || to == .clickFreeze ? .debug : .info
      return (level, "gate", ["from": .string(from.rawValue), "to": .string(to.rawValue)])
    case .scrollStarted(let source):
      return (.debug, "scrollStarted", ["source": .string(source.rawValue)])
    case .scrollEnded(let source, let pixels):
      return (
        .debug, "scrollEnded",
        ["source": .string(source.rawValue), "px": .double(pixels.rounded(places: 1))]
      )
    case .scrollPress(let direction, let pixels):
      return (
        .debug, "scrollPress",
        ["direction": .string(direction.rawValue), "px": .double(pixels.rounded(places: 1))]
      )
    case .shortcutPressed(let shortcut):
      return (.info, "shortcut", ["shortcut": .string(shortcut.logName)])
    case .paused(let isPaused):
      return (.info, "paused", ["paused": .bool(isPaused)])
    case .recentered:
      return (.info, "recentered", [:])
    case .predictionChecked(let sign, let correlation):
      var fields: [String: LogValue] = ["correlation": .double(correlation.rounded(places: 3))]
      if let sign {
        fields["sign"] = .double(sign)
      }
      return (sign == nil ? .warning : .info, "predictionChecked", fields)
    }
  }
}

enum SettingsDiff {
  /// Every leaf of `value`'s JSON form, keyed by its dotted path, e.g. `pointer.slowGain`.
  static func leaves(of value: some Encodable) -> [String: LogValue] {
    guard let data = try? JSONEncoder().encode(value),
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return [:] }
    var leaves: [String: LogValue] = [:]
    collect(object, path: "", into: &leaves)
    return leaves
  }

  /// The leaves of `new` that differ from `old`, with their new values.
  static func changes(from old: some Encodable, to new: some Encodable) -> [String: LogValue] {
    let before = leaves(of: old)
    return leaves(of: new).filter { before[$0.key] != $0.value }
  }

  private static func collect(_ object: Any, path: String, into leaves: inout [String: LogValue]) {
    if let dictionary = object as? [String: Any] {
      for (key, child) in dictionary {
        collect(child, path: path.isEmpty ? key : "\(path).\(key)", into: &leaves)
      }
    } else if let number = object as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        leaves[path] = .bool(number.boolValue)
      } else if CFNumberIsFloatType(number) {
        leaves[path] = .double(number.doubleValue)
      } else {
        leaves[path] = .int(number.intValue)
      }
    } else if let string = object as? String {
      leaves[path] = .string(string)
    }
  }
}

extension Double {
  /// Rounded to `places` decimal places, to keep log lines short.
  func rounded(places: Int) -> Double {
    let scale = pow(10, Double(places))
    return (self * scale).rounded() / scale
  }
}
