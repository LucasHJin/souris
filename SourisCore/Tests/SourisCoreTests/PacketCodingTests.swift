import Foundation
import Testing

@testable import SourisCore

@Suite("Packet coding")
struct PacketCodingTests {
  static let deviceID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

  static let sampleState = StatePacket(
    epoch: 0x1234,
    seq: 0x0102_0304,
    phoneTimeMicros: 0x1122_3344_5566_7788,
    state: MouseState(
      buttons: [.left, .middle],
      flags: [.trackingLimited, .paused],
      cursor: SIMD2(1.5, -2.25),
      scroll: SIMD2(-0.5, 3.0),
      shortcuts: ShortcutPresses(counts: [2, 0, 0, 0xFF])))

  static let sampleEntry = LogEntry(
    time: 1234.5678,
    date: Date(timeIntervalSince1970: 1_793_000_000.789),
    level: .warning,
    category: "net",
    event: "status",
    message: "Wi-Fi “dropped” \n again ✈️",
    fields: ["rttMs": 151.25, "count": 3, "ok": false, "reason": "timeout"])

  /// One of each packet type, with names that exercise multi-byte UTF-8.
  static let samples: [Packet] = [
    .state(sampleState),
    .ping(PingPacket(id: 7, phoneTimeMicros: 123_456_789)),
    .pong(PongPacket(id: 7, phoneTimeMicros: 123_456_789, macTimeMicros: 987_654_321)),
    .hello(HelloPacket(epoch: 0xBEEF, deviceID: deviceID, deviceName: "Lucas’s iPhone 📱")),
    .hello(HelloPacket(epoch: 0, deviceID: UUID(), deviceName: "")),
    .welcome(WelcomePacket(status: .pending, macName: "MacBook Pro")),
    .welcome(WelcomePacket(status: .accepted, macName: "Mäc")),
    .welcome(WelcomePacket(status: .denied, macName: "")),
    .welcome(WelcomePacket(status: .busy, macName: "M")),
    .welcome(WelcomePacket(status: .disconnected, macName: "Studio Mac")),
    .bye(ByePacket(epoch: 0xFFFF)),
    .log(LogPacket(stream: 0xDEAD_BEEF, oldestID: 1, firstID: 1, records: [])),
    .log(
      LogPacket(
        stream: 7,
        oldestID: 3,
        firstID: 5,
        records: [
          .log(sampleEntry),
          .recordingStarted(recordingID: 9, name: "session-2026-10-24 café"),
          .recordingLine(recordingID: 9, line: Data(#"{"ar":{"t":1.5}}"#.utf8)),
          .recordingLine(recordingID: 9, line: Data()),
          .recordingEnded(recordingID: 9),
        ])),
    .logAck(LogAckPacket(stream: 0xDEAD_BEEF, throughID: 0x0102_0304)),
  ]

  // MARK: - Round trips

  @Test(arguments: PacketCodingTests.samples)
  func roundTrips(packet: Packet) throws {
    #expect(try Packet.decode(packet.encoded()) == packet)
  }

  @Test func statePacketIs57Bytes() {
    #expect(Packet.state(Self.sampleState).encoded().count == 57)
  }

  @Test func aStatePacketFromBeforeShortcutsDecodesWithNoPresses() throws {
    let encoded = Packet.state(Self.sampleState).encoded()
    let old = encoded.prefix(52)
    guard case .state(let decoded) = try Packet.decode(old) else {
      Issue.record("Expected a state packet")
      return
    }
    #expect(decoded.state.shortcuts == ShortcutPresses())
    #expect(decoded.state.cursor == Self.sampleState.state.cursor)
  }

  @Test func shortcutCountsFromANewerPhoneAreKeptOrDropped() throws {
    var bytes = Array(Packet.state(Self.sampleState).encoded().prefix(52))
    // Six counts, two more than this build knows.
    bytes += [6, 1, 2, 3, 4, 5, 6]
    guard case .state(let decoded) = try Packet.decode(Data(bytes)) else {
      Issue.record("Expected a state packet")
      return
    }
    #expect(decoded.state.shortcuts.counts == [1, 2, 3, 4])
  }

  @Test func shortcutPressesCountTheWrappingDifference() {
    var earlier = ShortcutPresses(counts: [0xFF, 3, 0, 0])
    var later = earlier
    later.press(.missionControl)
    later.press(.missionControl)
    later.press(.spotlight)
    #expect(later[.missionControl] == 1)
    #expect(later.presses(since: earlier) == [.missionControl, .missionControl, .spotlight])
    earlier = later
    #expect(later.presses(since: earlier).isEmpty)
  }

  @Test func unknownButtonAndFlagBitsArePreserved() throws {
    let state = MouseState(
      buttons: MouseButtons(rawValue: 0xFF), flags: StateFlags(rawValue: 0xFF))
    let packet = StatePacket(epoch: 1, seq: 2, phoneTimeMicros: 3, state: state)
    let decoded = try Packet.decode(Packet.state(packet).encoded())
    #expect(decoded == .state(packet))
  }

  @Test func doublesSurviveBitExactly() throws {
    let values: [Double] = [
      .pi, -.pi, .leastNonzeroMagnitude, .greatestFiniteMagnitude, .infinity, -.infinity, 1e-300,
    ]
    for value in values {
      let state = MouseState(cursor: SIMD2(value, -value), scroll: SIMD2(-value, value))
      let packet = StatePacket(epoch: 0, seq: 0, phoneTimeMicros: 0, state: state)
      #expect(try Packet.decode(Packet.state(packet).encoded()) == .state(packet))
    }

    let negativeZero = StatePacket(
      epoch: 0, seq: 0, phoneTimeMicros: 0, state: MouseState(cursor: SIMD2(-0.0, 0)))
    guard case .state(let decodedZero) = try Packet.decode(Packet.state(negativeZero).encoded())
    else {
      Issue.record("Expected a state packet")
      return
    }
    #expect(decodedZero.state.cursor.x.sign == .minus)

    let notANumber = StatePacket(
      epoch: 0, seq: 0, phoneTimeMicros: 0, state: MouseState(cursor: SIMD2(.nan, 0)))
    guard case .state(let decodedNaN) = try Packet.decode(Packet.state(notANumber).encoded())
    else {
      Issue.record("Expected a state packet")
      return
    }
    #expect(decodedNaN.state.cursor.x.isNaN)
  }

  // MARK: - Layout

  @Test func stateLayoutMatchesGoldenBytes() {
    let golden: [UInt8] = [
      0x52, 0x53, 0x01, 0x01,  // magic, version, type
      0x34, 0x12,  // epoch
      0x04, 0x03, 0x02, 0x01,  // seq
      0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,  // phoneTimeMicros
      0x05,  // buttons: left | middle
      0x0A,  // flags: trackingLimited | paused
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F,  // cursorX = 1.5
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xC0,  // cursorY = -2.25
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x40,  // scrollY = 3.0
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE0, 0xBF,  // scrollX = -0.5
      0x04,  // shortcut count
      0x02, 0x00, 0x00, 0xFF,  // Mission Control, App windows, Show desktop, Spotlight presses
    ]
    #expect(Array(Packet.state(Self.sampleState).encoded()) == golden)
  }

  @Test func helloLayoutMatchesGoldenBytes() {
    let packet = HelloPacket(epoch: 0x0102, deviceID: Self.deviceID, deviceName: "Ab")
    let golden: [UInt8] = [
      0x52, 0x53, 0x01, 0x05,  // magic, version, type
      0x02, 0x01,  // epoch
      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,  // deviceID, uuid byte order
      0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
      0x02, 0x41, 0x62,  // nameLength, "Ab"
    ]
    #expect(Array(Packet.hello(packet).encoded()) == golden)
  }

  @Test func welcomeAndByeLayoutMatchGoldenBytes() {
    let welcome = WelcomePacket(status: .busy, macName: "Mac")
    #expect(
      Array(Packet.welcome(welcome).encoded())
        == [0x52, 0x53, 0x01, 0x06, 0x03, 0x03, 0x4D, 0x61, 0x63])
    #expect(
      Array(Packet.bye(ByePacket(epoch: 0xA1B2)).encoded())
        == [0x52, 0x53, 0x01, 0x07, 0xB2, 0xA1])
  }

  @Test func welcomeStatusBytesAreStable() {
    let statuses: [(WelcomeStatus, UInt8)] = [
      (.pending, 0), (.accepted, 1), (.denied, 2), (.busy, 3), (.disconnected, 4),
    ]
    for (status, byte) in statuses {
      let encoded = Packet.welcome(WelcomePacket(status: status, macName: "")).encoded()
      #expect(Array(encoded) == [0x52, 0x53, 0x01, 0x06, byte, 0x00])
    }
  }

  @Test func logLayoutMatchesGoldenBytes() throws {
    let packet = LogPacket(
      stream: 0x0A0B_0C0D,
      oldestID: 2,
      firstID: 0x0102_0304,
      records: [
        .recordingEnded(recordingID: 0x11),
        .recordingLine(recordingID: 1, line: Data([0x7B])),
      ])
    let golden: [UInt8] = [
      0x52, 0x53, 0x01, 0x08,  // magic, version, type
      0x0D, 0x0C, 0x0B, 0x0A,  // stream
      0x02, 0x00, 0x00, 0x00,  // oldestID
      0x04, 0x03, 0x02, 0x01,  // firstID
      0x02, 0x00,  // count
      0x05, 0x00, 0x04, 0x11, 0x00, 0x00, 0x00,  // length 5: recordingEnded, id 0x11
      0x06, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x7B,  // length 6: recordingLine, id 1, "{"
    ]
    #expect(Array(Packet.log(packet).encoded()) == golden)
    #expect(try Packet.decode(Data(golden)) == .log(packet))
  }

  @Test func logAckLayoutMatchesGoldenBytes() {
    let ack = LogAckPacket(stream: 0x0102_0304, throughID: 0x0A0B_0C0D)
    #expect(
      Array(Packet.logAck(ack).encoded())
        == [0x52, 0x53, 0x01, 0x09, 0x04, 0x03, 0x02, 0x01, 0x0D, 0x0C, 0x0B, 0x0A])
  }

  @Test func disconnectedWelcomeMatchesGoldenBytes() throws {
    let golden: [UInt8] = [0x52, 0x53, 0x01, 0x06, 0x04, 0x02, 0x4D, 0x61]
    #expect(
      Array(Packet.welcome(WelcomePacket(status: .disconnected, macName: "Ma")).encoded())
        == golden)
    #expect(
      try Packet.decode(Data(golden))
        == .welcome(WelcomePacket(status: .disconnected, macName: "Ma")))
  }

  // MARK: - Names

  @Test func nameOfExactlyMaxBytesIsKept() throws {
    let name = String(repeating: "a", count: WireProtocol.maxNameBytes)
    let hello = HelloPacket(epoch: 1, deviceID: Self.deviceID, deviceName: name)
    #expect(try Packet.decode(Packet.hello(hello).encoded()) == .hello(hello))
  }

  @Test func longAsciiNameIsTruncatedToMaxBytes() throws {
    let name = String(repeating: "a", count: 200)
    let decoded = try Packet.decode(
      Packet.welcome(WelcomePacket(status: .accepted, macName: name)).encoded())
    #expect(
      decoded
        == .welcome(
          WelcomePacket(
            status: .accepted, macName: String(repeating: "a", count: WireProtocol.maxNameBytes))))
  }

  @Test func emojiStraddlingTheLimitIsDroppedWhole() throws {
    // 62 ASCII bytes, then a 4-byte emoji covering bytes 62...65, so byte 63 falls inside it.
    let prefix = String(repeating: "a", count: 62)
    let hello = HelloPacket(epoch: 1, deviceID: Self.deviceID, deviceName: prefix + "😀tail")
    let decoded = try Packet.decode(Packet.hello(hello).encoded())
    guard case .hello(let result) = decoded else {
      Issue.record("Expected a hello packet")
      return
    }
    #expect(result.deviceName == prefix)
    #expect(Packet.hello(hello).encoded().count == 4 + 19 + 62)
  }

  @Test func graphemeClusterIsNotSplit() throws {
    // "e" plus a combining acute is one character of 3 bytes. 61 + 3 = 64 > 63.
    let prefix = String(repeating: "a", count: 61)
    let name = prefix + "e\u{301}" + "z"
    let decoded = try Packet.decode(
      Packet.welcome(WelcomePacket(status: .pending, macName: name)).encoded())
    guard case .welcome(let result) = decoded else {
      Issue.record("Expected a welcome packet")
      return
    }
    #expect(result.macName == prefix)

    // A ZWJ family emoji is one character of 25 bytes made of several scalars.
    let family = "👨‍👩‍👧‍👦"
    let longName = String(repeating: "b", count: 40) + family
    #expect(longName.utf8.count > WireProtocol.maxNameBytes)
    let decodedFamily = try Packet.decode(
      Packet.welcome(WelcomePacket(status: .pending, macName: longName)).encoded())
    guard case .welcome(let familyResult) = decodedFamily else {
      Issue.record("Expected a welcome packet")
      return
    }
    #expect(familyResult.macName == String(repeating: "b", count: 40))
  }

  @Test func multiByteNameThatFitsIsKept() throws {
    let name = String(repeating: "é", count: 31)  // 62 bytes
    let hello = HelloPacket(epoch: 1, deviceID: Self.deviceID, deviceName: name)
    #expect(try Packet.decode(Packet.hello(hello).encoded()) == .hello(hello))
  }

  // MARK: - Errors

  @Test func shorterThanHeaderIsTooShort() {
    for length in 0..<4 {
      let data = Data(repeating: 0x52, count: length)
      #expect(throws: PacketDecodeError.tooShort) { try Packet.decode(data) }
    }
  }

  @Test func badMagicIsRejected() {
    var bytes = Array(Packet.bye(ByePacket(epoch: 1)).encoded())
    bytes[0] = 0x00
    #expect(throws: PacketDecodeError.badMagic(0x5300)) { try Packet.decode(Data(bytes)) }
  }

  @Test func wrongVersionIsRejected() {
    var bytes = Array(Packet.bye(ByePacket(epoch: 1)).encoded())
    bytes[2] = 2
    #expect(throws: PacketDecodeError.unsupportedVersion(2)) { try Packet.decode(Data(bytes)) }
  }

  @Test(arguments: [0, 4, 10, 255] as [UInt8])
  func unknownTypeIsRejected(type: UInt8) {
    let bytes: [UInt8] = [0x52, 0x53, 0x01, type, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    #expect(throws: PacketDecodeError.unknownType(type)) { try Packet.decode(Data(bytes)) }
  }

  @Test(arguments: PacketCodingTests.samples)
  func everyTruncationIsRejected(packet: Packet) {
    let bytes = packet.encoded()
    for length in 0..<bytes.count {
      // A state packet that ends where phones built before shortcuts end it is whole.
      if case .state = packet, length == 52 { continue }
      let expected: PacketDecodeError = length < 4 ? .tooShort : .truncated
      #expect(throws: expected, "length \(length) of \(bytes.count)") {
        try Packet.decode(bytes.prefix(length))
      }
    }
  }

  @Test func nameLongerThanTheRestOfThePacketIsTruncated() {
    var bytes = Array(Packet.welcome(WelcomePacket(status: .accepted, macName: "Mac")).encoded())
    bytes[5] = 20
    #expect(throws: PacketDecodeError.truncated) { try Packet.decode(Data(bytes)) }
  }

  @Test func invalidUTF8InHelloNameIsRejected() {
    var bytes = Array(
      Packet.hello(HelloPacket(epoch: 1, deviceID: Self.deviceID, deviceName: "abc")).encoded())
    bytes[bytes.count - 1] = 0xFF
    #expect(throws: PacketDecodeError.invalidString) { try Packet.decode(Data(bytes)) }
  }

  @Test func invalidUTF8InWelcomeNameIsRejected() {
    let bytes: [UInt8] = [0x52, 0x53, 0x01, 0x06, 0x01, 0x02, 0xC3, 0x28]
    #expect(throws: PacketDecodeError.invalidString) { try Packet.decode(Data(bytes)) }
  }

  @Test func truncatedScalarAtEndOfNameIsRejected() {
    // 0xE2 0x82 starts a 3-byte scalar that never finishes.
    let bytes: [UInt8] = [0x52, 0x53, 0x01, 0x06, 0x01, 0x02, 0xE2, 0x82]
    #expect(throws: PacketDecodeError.invalidString) { try Packet.decode(Data(bytes)) }
  }

  @Test func unknownWelcomeStatusIsRejected() {
    for status: UInt8 in [5, 9, 255] {
      let bytes: [UInt8] = [0x52, 0x53, 0x01, 0x06, status, 0x00]
      #expect(throws: PacketDecodeError.invalidWelcomeStatus(status)) {
        try Packet.decode(Data(bytes))
      }
    }
  }

  @Test func logRecordLongerThanThePacketIsTruncated() {
    let packet = LogPacket(
      stream: 1, oldestID: 1, firstID: 1, records: [.recordingEnded(recordingID: 1)])
    var bytes = Array(Packet.log(packet).encoded())
    bytes[18] = 6  // the record's length, one more than it has
    #expect(throws: PacketDecodeError.truncated) { try Packet.decode(Data(bytes)) }
  }

  @Test func logPacketCountingMoreRecordsThanItHoldsIsTruncated() {
    let packet = LogPacket(
      stream: 1, oldestID: 1, firstID: 1, records: [.recordingEnded(recordingID: 1)])
    var bytes = Array(Packet.log(packet).encoded())
    bytes[16] = 2
    #expect(throws: PacketDecodeError.truncated) { try Packet.decode(Data(bytes)) }
  }

  @Test func undecodableLogRecordBecomesAnErrorEntryAndKeepsItsPlace() throws {
    let good = UplinkRecord.recordingEnded(recordingID: 4)
    let bad: [Data] = [
      Data([0x09, 0x01]),  // unknown kind
      Data([UplinkRecord.Kind.log.rawValue]) + Data("{not json".utf8),
      Data(),  // no kind byte
    ]
    let datagram = LogPacket.datagram(
      stream: 1, oldestID: 1, firstID: 10,
      encodedRecords: [good.encoded()] + bad + [good.encoded()])
    guard case .log(let decoded) = try Packet.decode(datagram) else {
      Issue.record("Expected a log packet")
      return
    }
    #expect(decoded.firstID == 10)
    #expect(decoded.records.count == 5)
    #expect(decoded.records.first == good)
    #expect(decoded.records.last == good)
    for record in decoded.records[1...3] {
      guard case .log(let entry) = record else {
        Issue.record("Expected a placeholder entry, got \(record)")
        continue
      }
      #expect(entry.level == .error)
      #expect(entry.event == "undecodableRecord")
    }
  }

  // MARK: - Leniency and robustness

  @Test(arguments: PacketCodingTests.samples)
  func trailingBytesAreIgnored(packet: Packet) throws {
    let padded = packet.encoded() + Data([0xDE, 0xAD, 0xBE, 0xEF])
    #expect(try Packet.decode(padded) == packet)
  }

  @Test(arguments: PacketCodingTests.samples)
  func decodesFromASliceWithNonZeroStartIndex(packet: Packet) throws {
    let encoded = packet.encoded()
    let buffer = Data([1, 2, 3, 4, 5, 6, 7]) + encoded + Data([9, 9, 9])
    let slice = buffer[7..<(7 + encoded.count)]
    #expect(slice.startIndex == 7)
    #expect(try Packet.decode(slice) == packet)

    let dropped = (Data([0xFF, 0xFF]) + encoded).dropFirst(2)
    #expect(try Packet.decode(dropped) == packet)
  }

  @Test func randomBytesNeverTrap() {
    var generator = SplitMix64(seed: 0xC0FFEE)
    for _ in 0..<20_000 {
      let length = Int(generator.next() % 80)
      var bytes = (0..<length).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
      if length >= 4 && generator.next() % 2 == 0 {
        // Valid header most of the time so the payload parsers get exercised.
        bytes[0] = 0x52
        bytes[1] = 0x53
        bytes[2] = 0x01
        bytes[3] = UInt8(1 + generator.next() % 9)
      }
      _ = try? Packet.decode(Data(bytes))
    }
  }

  @Test func mutatedValidPacketsNeverTrap() {
    var generator = SplitMix64(seed: 42)
    for packet in Self.samples {
      let original = Array(packet.encoded())
      for _ in 0..<500 {
        var bytes = original
        for _ in 0..<3 {
          let index = Int(generator.next() % UInt64(bytes.count))
          bytes[index] = UInt8(truncatingIfNeeded: generator.next())
        }
        _ = try? Packet.decode(Data(bytes))
      }
    }
  }
}

/// A small seeded generator so the fuzz tests are repeatable.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
