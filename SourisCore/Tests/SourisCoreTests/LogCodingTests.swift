import Foundation
import Testing

@testable import SourisCore

@Suite("Log coding")
struct LogCodingTests {
  /// 2026-10-26T07:33:20.789Z.
  static let date = Date(timeIntervalSince1970: 1_793_000_000.789)

  static let entry = LogEntry(
    time: 812.25,
    date: date,
    level: .info,
    category: "net",
    event: "status",
    message: "to \"connected\"\n\ttab \u{1}",
    fields: ["b": 2, "a": "x", "c": 0.5, "d": true])

  // MARK: - LogEntry JSON

  @Test func jsonLineHasReadableKeysInOrder() {
    let line = String(decoding: Self.entry.jsonLine(), as: UTF8.self)
    let expected =
      #"{"time":812.25,"date":"2026-10-26T07:33:20.789Z","level":"info","category":"net","#
      + #""event":"status","message":"to \"connected\"\n\ttab \u0001","#
      + #""fields":{"a":"x","b":2,"c":0.5,"d":true}}"#
    #expect(line == expected)
    #expect(!line.contains("\n"))
  }

  @Test func jsonLineLeavesOutAMissingMessageAndEmptyFields() {
    let entry = LogEntry(time: 1, date: Self.date, level: .debug, category: "c", event: "e")
    let expected =
      #"{"time":1.0,"date":"2026-10-26T07:33:20.789Z","#
      + #""level":"debug","category":"c","event":"e"}"#
    #expect(String(decoding: entry.jsonLine(), as: UTF8.self) == expected)
  }

  @Test func jsonLineDecodesBackToTheSameEntry() throws {
    let decoded = try JSONDecoder().decode(LogEntry.self, from: Self.entry.jsonLine())
    #expect(decoded == Self.entry)
  }

  @Test func codableEncodesTheDateAsAStringWhateverTheStrategy() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(Self.entry)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["date"] as? String == "2026-10-26T07:33:20.789Z")
    #expect(Set(object.keys) == ["time", "date", "level", "category", "event", "message", "fields"])
    #expect(try JSONDecoder().decode(LogEntry.self, from: data) == Self.entry)
  }

  @Test func dateIsKeptToWholeMilliseconds() {
    var entry = LogEntry(
      time: 0, date: Date(timeIntervalSince1970: 10.123_456), level: .info, category: "c",
      event: "e")
    #expect(entry.date == Date(timeIntervalSince1970: 10.123))
    entry.date = Date(timeIntervalSince1970: 20.000_6)
    #expect(entry.date == Date(timeIntervalSince1970: 20.001))
    #expect(String(decoding: entry.jsonLine(), as: UTF8.self).contains("1970-01-01T00:00:20.001Z"))
  }

  @Test func convenienceInitStampsTheCurrentClocks() {
    let before = ProcessInfo.processInfo.systemUptime
    let entry = LogEntry(level: .warning, category: "net", event: "x")
    #expect(entry.time >= before)
    #expect(abs(entry.date.timeIntervalSinceNow) < 5)
  }

  @Test func badDateIsADecodingError() {
    let json = #"{"time":1,"date":"yesterday","level":"info","category":"c","event":"e"}"#
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(LogEntry.self, from: Data(json.utf8))
    }
  }

  // MARK: - LogValue and LogLevel

  @Test func valuesEncodeAsBareScalars() throws {
    let values: [String: LogValue] = [
      "s": "text", "i": -3, "d": 2.5, "b": false, "nan": .double(.nan), "inf": .double(-.infinity),
    ]
    let data = try JSONEncoder().encode(values)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["s"] as? String == "text")
    #expect(object["i"] as? Int == -3)
    #expect(object["d"] as? Double == 2.5)
    #expect(object["b"] as? Bool == false)
    #expect(object["nan"] as? String == "nan")
    #expect(object["inf"] as? String == "-inf")

    let decoded = try JSONDecoder().decode([String: LogValue].self, from: data)
    #expect(decoded["s"] == "text")
    #expect(decoded["i"] == -3)
    #expect(decoded["d"] == 2.5)
    #expect(decoded["b"] == false)
    #expect(decoded["nan"] == "nan")
  }

  @Test func wholeNumberDoubleReadsBackAsInt() throws {
    let entry = LogEntry(
      time: 1, date: Self.date, level: .info, category: "c", event: "e", fields: ["v": 4.0])
    let decoded = try JSONDecoder().decode(LogEntry.self, from: entry.jsonLine())
    #expect(decoded.fields["v"] == .int(4))
  }

  @Test func levelsAreOrderedBySeverity() {
    #expect(LogLevel.allCases.sorted() == [.debug, .info, .warning, .error])
    #expect(LogLevel.warning > .info)
    #expect(LogLevel.error.rawValue == "error")
  }

  // MARK: - UplinkRecord

  static let records: [UplinkRecord] = [
    .log(entry),
    .recordingStarted(recordingID: 0xFFFF_FFFF, name: "rec 📱"),
    .recordingStarted(recordingID: 0, name: ""),
    .recordingLine(recordingID: 3, line: Data(#"{"imu":{"t":0.01}}"#.utf8)),
    .recordingLine(recordingID: 3, line: Data()),
    .recordingEnded(recordingID: 3),
  ]

  @Test(arguments: LogCodingTests.records)
  func recordRoundTrips(record: UplinkRecord) throws {
    #expect(try UplinkRecord.decode(record.encoded()) == record)
  }

  @Test(arguments: LogCodingTests.records)
  func recordDecodesFromASlice(record: UplinkRecord) throws {
    let encoded = record.encoded()
    let buffer = Data([1, 2, 3]) + encoded
    #expect(try UplinkRecord.decode(buffer[3...]) == record)
  }

  @Test func recordLayoutMatchesGoldenBytes() {
    #expect(
      Array(UplinkRecord.recordingStarted(recordingID: 0x0102_0304, name: "Ab").encoded())
        == [0x02, 0x04, 0x03, 0x02, 0x01, 0x41, 0x62])
    #expect(
      Array(UplinkRecord.recordingLine(recordingID: 1, line: Data([0x7B, 0x7D])).encoded())
        == [0x03, 0x01, 0x00, 0x00, 0x00, 0x7B, 0x7D])
    #expect(Array(UplinkRecord.recordingEnded(recordingID: 2).encoded()) == [0x04, 2, 0, 0, 0])
    let log = UplinkRecord.log(Self.entry).encoded()
    #expect(log.first == 0x01)
    #expect(log.dropFirst() == Self.entry.jsonLine())
  }

  @Test func emptyRecordIsTruncated() {
    #expect(throws: PacketDecodeError.truncated) { try UplinkRecord.decode(Data()) }
  }

  @Test(arguments: [0, 5, 0x80, 0xFF] as [UInt8])
  func unknownRecordKindIsRejected(kind: UInt8) {
    #expect(throws: PacketDecodeError.invalidRecordKind(kind)) {
      try UplinkRecord.decode(Data([kind, 1, 2, 3, 4]))
    }
  }

  @Test(arguments: [2, 3, 4] as [UInt8])
  func recordingRecordWithoutAFullIDIsTruncated(kind: UInt8) {
    for length in 0..<4 {
      let bytes = Data([kind] + Array(repeating: 0x01, count: length))
      #expect(throws: PacketDecodeError.truncated, "kind \(kind), \(length) id bytes") {
        try UplinkRecord.decode(bytes)
      }
    }
  }

  @Test func recordingNameMustBeUTF8() {
    #expect(throws: PacketDecodeError.invalidString) {
      try UplinkRecord.decode(Data([0x02, 1, 0, 0, 0, 0xC3, 0x28]))
    }
  }

  @Test func logRecordMustHoldAnEntry() {
    let payloads = [
      "",
      "{}",
      "[1,2]",
      #"{"time":1,"date":"2026-10-26T07:33:20.789Z","level":"loud","category":"c","event":"e"}"#,
      #"{"time":1,"level":"info","category":"c","event":"e"}"#,
    ]
    for payload in payloads {
      #expect(throws: PacketDecodeError.invalidLogEntry, "payload \(payload)") {
        try UplinkRecord.decode(Data([0x01]) + Data(payload.utf8))
      }
    }
  }
}
