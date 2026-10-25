import Foundation

/// One unit of diagnostics the phone ships to the Mac in log packets: a log entry, or a piece of
/// a sensor recording.
///
/// Binary layout: `kind u8`, then the payload. A log's payload is the entry's `jsonLine()`. The
/// recording kinds start with `recordingID u32`, followed by the name's UTF-8 bytes
/// (`recordingStarted`), the line's bytes (`recordingLine`) or nothing (`recordingEnded`). The
/// payload runs to the end of the record, whose length the enclosing packet gives.
public enum UplinkRecord: Equatable, Sendable {
  case log(LogEntry)

  /// A sensor recording started. `name` is what the Mac should call its file.
  case recordingStarted(recordingID: UInt32, name: String)

  /// One JSON Lines line of a sensor recording, without the newline.
  case recordingLine(recordingID: UInt32, line: Data)

  case recordingEnded(recordingID: UInt32)

  /// The kind byte that starts each encoded record.
  enum Kind: UInt8 {
    case log = 1
    case recordingStarted = 2
    case recordingLine = 3
    case recordingEnded = 4
  }

  /// The record's bytes: the kind byte and the payload.
  public func encoded() -> Data {
    switch self {
    case .log(let entry):
      let json = entry.jsonLine()
      var writer = ByteWriter(capacity: 1 + json.count)
      writer.write(Kind.log.rawValue)
      writer.write(json)
      return writer.data
    case .recordingStarted(let recordingID, let name):
      var writer = ByteWriter(capacity: 5 + name.utf8.count)
      writer.write(Kind.recordingStarted.rawValue)
      writer.write(recordingID)
      writer.write(Data(name.utf8))
      return writer.data
    case .recordingLine(let recordingID, let line):
      var writer = ByteWriter(capacity: 5 + line.count)
      writer.write(Kind.recordingLine.rawValue)
      writer.write(recordingID)
      writer.write(line)
      return writer.data
    case .recordingEnded(let recordingID):
      var writer = ByteWriter(capacity: 5)
      writer.write(Kind.recordingEnded.rawValue)
      writer.write(recordingID)
      return writer.data
    }
  }

  /// Parses one record, exactly as long as `data`. Works on slices.
  public static func decode(_ data: Data) throws(PacketDecodeError) -> UplinkRecord {
    var reader = ByteReader(data)
    let rawKind = try reader.read(UInt8.self)
    switch Kind(rawValue: rawKind) {
    case .log:
      let json = reader.readRemaining()
      guard let entry = try? JSONDecoder().decode(LogEntry.self, from: json) else {
        throw .invalidLogEntry
      }
      return .log(entry)
    case .recordingStarted:
      let recordingID = try reader.read(UInt32.self)
      guard let name = String(validating: reader.readRemaining(), as: UTF8.self) else {
        throw .invalidString
      }
      return .recordingStarted(recordingID: recordingID, name: name)
    case .recordingLine:
      let recordingID = try reader.read(UInt32.self)
      return .recordingLine(recordingID: recordingID, line: reader.readRemaining())
    case .recordingEnded:
      return .recordingEnded(recordingID: try reader.read(UInt32.self))
    case nil:
      throw .invalidRecordKind(rawKind)
    }
  }
}
