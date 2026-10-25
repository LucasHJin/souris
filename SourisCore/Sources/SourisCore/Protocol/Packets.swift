import Foundation

/// Constants shared by both ends of the link.
public enum WireProtocol {
  /// The first two bytes of every packet, written as a little-endian `UInt16`. On the wire that is
  /// the byte sequence `0x52 0x53`.
  public static let magic: UInt16 = 0x5352

  /// The protocol version carried in every header. Packets with another version are rejected.
  public static let version: UInt8 = 1

  /// The UDP port the Mac listens on when it's free. Bonjour advertises whatever port is used.
  public static let defaultPort: UInt16 = 47811

  /// The Bonjour service type. It must match `NSBonjourServices` in both Info.plists.
  public static let bonjourServiceType = "_souris._udp"

  /// The longest device or Mac name sent, in UTF-8 bytes. Longer names are truncated on a
  /// character boundary when encoded.
  public static let maxNameBytes = 63
}

/// The packet type byte that follows the magic and version.
public enum PacketType: UInt8, Sendable {
  case state = 1
  case ping = 2
  case pong = 3
  /// Reserved. Mac shortcuts ride in the state packet as counts instead (`ShortcutPresses`), so
  /// a lost packet can't drop one.
  case action = 4
  case hello = 5
  case welcome = 6
  case bye = 7
  case log = 8
  case logAck = 9
}

/// Phone → Mac, on every pipeline tick and as a keepalive.
public struct StatePacket: Equatable, Sendable {
  /// Changes whenever the phone starts a new session. A new epoch resets the Mac's baseline.
  public var epoch: UInt16

  /// Increments with every state packet in an epoch. The Mac drops packets that aren't newer.
  public var seq: UInt32

  /// The phone's uptime clock when the packet was built, in microseconds.
  public var phoneTimeMicros: UInt64

  public var state: MouseState

  public init(epoch: UInt16, seq: UInt32, phoneTimeMicros: UInt64, state: MouseState) {
    self.epoch = epoch
    self.seq = seq
    self.phoneTimeMicros = phoneTimeMicros
    self.state = state
  }
}

/// Phone → Mac, to measure round-trip time.
public struct PingPacket: Equatable, Sendable {
  public var id: UInt32
  public var phoneTimeMicros: UInt64

  public init(id: UInt32, phoneTimeMicros: UInt64) {
    self.id = id
    self.phoneTimeMicros = phoneTimeMicros
  }
}

/// Mac → phone, the immediate reply to a ping.
public struct PongPacket: Equatable, Sendable {
  public var id: UInt32

  /// Echoed from the ping.
  public var phoneTimeMicros: UInt64

  /// The Mac's uptime clock when it replied, in microseconds.
  public var macTimeMicros: UInt64

  public init(id: UInt32, phoneTimeMicros: UInt64, macTimeMicros: UInt64) {
    self.id = id
    self.phoneTimeMicros = phoneTimeMicros
    self.macTimeMicros = macTimeMicros
  }
}

/// Phone → Mac, introducing the phone. Sent on connect and about once a second after that.
public struct HelloPacket: Equatable, Sendable {
  public var epoch: UInt16

  /// A stable per-install identifier the Mac uses to remember approval.
  public var deviceID: UUID

  public var deviceName: String

  public init(epoch: UInt16, deviceID: UUID, deviceName: String) {
    self.epoch = epoch
    self.deviceID = deviceID
    self.deviceName = deviceName
  }
}

/// The Mac's answer to a hello.
public enum WelcomeStatus: UInt8, Sendable {
  /// Waiting for the user to allow this phone on the Mac.
  case pending = 0
  /// This phone controls the pointer.
  case accepted = 1
  /// The user refused this phone.
  case denied = 2
  /// Another phone is controlling the pointer right now.
  case busy = 3
  /// The Mac disconnected this phone. It stays off until the phone starts a new session, which is
  /// a new epoch.
  case disconnected = 4
}

/// Mac → phone, the reply to every hello.
public struct WelcomePacket: Equatable, Sendable {
  public var status: WelcomeStatus
  public var macName: String

  public init(status: WelcomeStatus, macName: String) {
    self.status = status
    self.macName = macName
  }
}

/// Phone → Mac, sent when the phone stops (app backgrounded). The Mac releases everything held.
public struct ByePacket: Equatable, Sendable {
  public var epoch: UInt16

  public init(epoch: UInt16) {
    self.epoch = epoch
  }
}

/// Phone → Mac, a run of diagnostic records with consecutive ids.
///
/// The phone resends records until the Mac acknowledges them (go-back-N), so a record can arrive
/// more than once. See `LogOutbox` for the sending rules and `LogInbox` for the receiving ones.
public struct LogPacket: Equatable, Sendable {
  /// Random per phone app launch. Record ids count from 1 within a stream.
  public var stream: UInt32

  /// The oldest record id the phone still holds. Ids below it that the Mac hasn't received were
  /// dropped by the phone and will never come.
  public var oldestID: UInt32

  /// The id of `records[0]`. The rest follow consecutively.
  public var firstID: UInt32

  public var records: [UplinkRecord]

  public init(stream: UInt32, oldestID: UInt32, firstID: UInt32, records: [UplinkRecord]) {
    self.stream = stream
    self.oldestID = oldestID
    self.firstID = firstID
    self.records = records
  }

  /// The datagram for records already encoded with `UplinkRecord.encoded()`, so the phone encodes
  /// each record once however often it is resent.
  static func datagram(
    stream: UInt32, oldestID: UInt32, firstID: UInt32, encodedRecords: [Data]
  ) -> Data {
    let recordBytes = encodedRecords.reduce(0) { $0 + WireLayout.logRecordLengthSize + $1.count }
    var writer = ByteWriter(type: .log, payloadCapacity: WireLayout.logFixedSize + recordBytes)
    writer.write(stream)
    writer.write(oldestID)
    writer.write(firstID)
    writer.write(UInt16(encodedRecords.count))
    for record in encodedRecords {
      writer.write(UInt16(record.count))
      writer.write(record)
    }
    return writer.data
  }
}

/// Mac → phone, the reply to every log packet the Mac accepts, including duplicates.
public struct LogAckPacket: Equatable, Sendable {
  public var stream: UInt32

  /// Every record of `stream` up to and including this id has been accepted. 0 means none.
  public var throughID: UInt32

  public init(stream: UInt32, throughID: UInt32) {
    self.stream = stream
    self.throughID = throughID
  }
}

/// Any packet on the wire.
///
/// Layout (little-endian): `magic u16`, `version u8`, `type u8`, then the payload. See
/// `docs/architecture.md` for the byte layout of each payload.
public enum Packet: Equatable, Sendable {
  case state(StatePacket)
  case ping(PingPacket)
  case pong(PongPacket)
  case hello(HelloPacket)
  case welcome(WelcomePacket)
  case bye(ByePacket)
  case log(LogPacket)
  case logAck(LogAckPacket)

  /// The packet's bytes, header included.
  ///
  /// Names in hello and welcome packets longer than `WireProtocol.maxNameBytes` are cut back to the
  /// last whole character that fits. A log packet must hold at most `UInt16.max` records of at
  /// most `UInt16.max` bytes each; `LogOutbox` keeps far below both.
  public func encoded() -> Data {
    switch self {
    case .state(let packet):
      var writer = ByteWriter(type: .state, payloadCapacity: WireLayout.statePayloadSize)
      writer.write(packet.epoch)
      writer.write(packet.seq)
      writer.write(packet.phoneTimeMicros)
      writer.write(packet.state.buttons.rawValue)
      writer.write(packet.state.flags.rawValue)
      writer.write(packet.state.cursor.x)
      writer.write(packet.state.cursor.y)
      writer.write(packet.state.scroll.y)
      writer.write(packet.state.scroll.x)
      let shortcutCounts = packet.state.shortcuts.counts
      writer.write(UInt8(shortcutCounts.count))
      for count in shortcutCounts {
        writer.write(count)
      }
      return writer.data
    case .ping(let packet):
      var writer = ByteWriter(type: .ping, payloadCapacity: WireLayout.pingPayloadSize)
      writer.write(packet.id)
      writer.write(packet.phoneTimeMicros)
      return writer.data
    case .pong(let packet):
      var writer = ByteWriter(type: .pong, payloadCapacity: WireLayout.pongPayloadSize)
      writer.write(packet.id)
      writer.write(packet.phoneTimeMicros)
      writer.write(packet.macTimeMicros)
      return writer.data
    case .hello(let packet):
      var writer = ByteWriter(
        type: .hello, payloadCapacity: WireLayout.helloFixedSize + WireProtocol.maxNameBytes)
      writer.write(packet.epoch)
      writer.write(packet.deviceID)
      writer.writeName(packet.deviceName)
      return writer.data
    case .welcome(let packet):
      var writer = ByteWriter(
        type: .welcome, payloadCapacity: WireLayout.welcomeFixedSize + WireProtocol.maxNameBytes)
      writer.write(packet.status.rawValue)
      writer.writeName(packet.macName)
      return writer.data
    case .bye(let packet):
      var writer = ByteWriter(type: .bye, payloadCapacity: WireLayout.byePayloadSize)
      writer.write(packet.epoch)
      return writer.data
    case .log(let packet):
      return LogPacket.datagram(
        stream: packet.stream,
        oldestID: packet.oldestID,
        firstID: packet.firstID,
        encodedRecords: packet.records.map { $0.encoded() })
    case .logAck(let packet):
      var writer = ByteWriter(type: .logAck, payloadCapacity: WireLayout.logAckPayloadSize)
      writer.write(packet.stream)
      writer.write(packet.throughID)
      return writer.data
    }
  }

  /// Parses one datagram.
  ///
  /// Works on slices with a non-zero `startIndex`. Bytes after the end of the payload are ignored
  /// so a newer sender can append fields. Unknown button and flag bits are kept as they are.
  ///
  /// In a log packet, a record that is framed correctly but can't be parsed becomes an error-level
  /// `.log` entry with the event `"undecodableRecord"`, so its id still counts and one bad record
  /// can't stall the stream. A record whose length runs past the datagram fails the whole packet.
  public static func decode(_ data: Data) throws(PacketDecodeError) -> Packet {
    guard data.count >= WireLayout.headerSize else { throw .tooShort }
    var reader = ByteReader(data)
    let magic = try reader.read(UInt16.self)
    guard magic == WireProtocol.magic else { throw .badMagic(magic) }
    let version = try reader.read(UInt8.self)
    guard version == WireProtocol.version else { throw .unsupportedVersion(version) }
    let rawType = try reader.read(UInt8.self)

    switch PacketType(rawValue: rawType) {
    case .state:
      let epoch = try reader.read(UInt16.self)
      let seq = try reader.read(UInt32.self)
      let phoneTimeMicros = try reader.read(UInt64.self)
      let buttons = MouseButtons(rawValue: try reader.read(UInt8.self))
      let flags = StateFlags(rawValue: try reader.read(UInt8.self))
      let cursorX = try reader.readDouble()
      let cursorY = try reader.readDouble()
      let scrollY = try reader.readDouble()
      let scrollX = try reader.readDouble()
      // Phones built before shortcuts end the packet here.
      var shortcutCounts: [UInt8] = []
      if reader.remaining > 0 {
        let count = try reader.read(UInt8.self)
        for _ in 0..<count {
          shortcutCounts.append(try reader.read(UInt8.self))
        }
      }
      let state = MouseState(
        buttons: buttons,
        flags: flags,
        cursor: SIMD2(cursorX, cursorY),
        scroll: SIMD2(scrollX, scrollY),
        shortcuts: ShortcutPresses(counts: shortcutCounts))
      return .state(
        StatePacket(epoch: epoch, seq: seq, phoneTimeMicros: phoneTimeMicros, state: state))
    case .ping:
      let id = try reader.read(UInt32.self)
      let phoneTimeMicros = try reader.read(UInt64.self)
      return .ping(PingPacket(id: id, phoneTimeMicros: phoneTimeMicros))
    case .pong:
      let id = try reader.read(UInt32.self)
      let phoneTimeMicros = try reader.read(UInt64.self)
      let macTimeMicros = try reader.read(UInt64.self)
      return .pong(
        PongPacket(id: id, phoneTimeMicros: phoneTimeMicros, macTimeMicros: macTimeMicros))
    case .hello:
      let epoch = try reader.read(UInt16.self)
      let deviceID = try reader.readUUID()
      let deviceName = try reader.readName()
      return .hello(HelloPacket(epoch: epoch, deviceID: deviceID, deviceName: deviceName))
    case .welcome:
      let rawStatus = try reader.read(UInt8.self)
      guard let status = WelcomeStatus(rawValue: rawStatus) else {
        throw .invalidWelcomeStatus(rawStatus)
      }
      let macName = try reader.readName()
      return .welcome(WelcomePacket(status: status, macName: macName))
    case .bye:
      return .bye(ByePacket(epoch: try reader.read(UInt16.self)))
    case .log:
      let stream = try reader.read(UInt32.self)
      let oldestID = try reader.read(UInt32.self)
      let firstID = try reader.read(UInt32.self)
      let count = Int(try reader.read(UInt16.self))
      var records: [UplinkRecord] = []
      records.reserveCapacity(count)
      for _ in 0..<count {
        let length = Int(try reader.read(UInt16.self))
        records.append(decodeRecordOrPlaceholder(try reader.readBytes(count: length)))
      }
      return .log(
        LogPacket(stream: stream, oldestID: oldestID, firstID: firstID, records: records))
    case .logAck:
      let stream = try reader.read(UInt32.self)
      let throughID = try reader.read(UInt32.self)
      return .logAck(LogAckPacket(stream: stream, throughID: throughID))
    case .action, nil:
      throw .unknownType(rawType)
    }
  }

  private static func decodeRecordOrPlaceholder(_ bytes: Data) -> UplinkRecord {
    do {
      return try UplinkRecord.decode(bytes)
    } catch {
      return .log(
        LogEntry(
          level: .error,
          category: "log",
          event: "undecodableRecord",
          message: "A phone log record couldn't be decoded: \(error)",
          fields: ["bytes": .int(bytes.count), "kind": .int(Int(bytes.first ?? 0))]))
    }
  }
}

/// Why a datagram couldn't be parsed.
public enum PacketDecodeError: Error, Equatable, Sendable {
  /// Shorter than the 4-byte header.
  case tooShort
  case badMagic(UInt16)
  case unsupportedVersion(UInt8)
  /// A type byte with no packet behind it, including the reserved `PacketType.action`.
  case unknownType(UInt8)
  /// The payload is shorter than its type requires.
  case truncated
  /// A device, Mac or recording name wasn't valid UTF-8.
  case invalidString
  /// A welcome carried a status byte that isn't a `WelcomeStatus`.
  case invalidWelcomeStatus(UInt8)
  /// An uplink record started with a kind byte that isn't a known kind.
  case invalidRecordKind(UInt8)
  /// An uplink log record's payload wasn't a valid `LogEntry` in JSON.
  case invalidLogEntry
}
