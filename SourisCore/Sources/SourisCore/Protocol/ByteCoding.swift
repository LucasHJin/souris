import Foundation

/// Byte sizes that follow from the wire layout.
enum WireLayout {
  /// `magic u16`, `version u8`, `type u8`.
  static let headerSize = 4

  /// Payload sizes. Hello and welcome have a fixed part plus a name of up to
  /// `WireProtocol.maxNameBytes`: hello is `epoch u16`, `deviceID` 16 bytes and `nameLength u8`;
  /// welcome is `status u8` and `nameLength u8`. The state payload ends with a count byte and
  /// one byte per `MacShortcut`.
  static let statePayloadSize = 49 + MacShortcut.allCases.count
  static let pingPayloadSize = 12
  static let pongPayloadSize = 20
  static let helloFixedSize = 19
  static let welcomeFixedSize = 2
  static let byePayloadSize = 2

  /// A log packet is `stream u32`, `oldestID u32`, `firstID u32` and `count u16`, then each
  /// record behind a `u16` length.
  static let logFixedSize = 14
  static let logRecordLengthSize = 2
  static let logAckPayloadSize = 8

  /// A complete state packet, header included.
  static let stateSize = headerSize + statePayloadSize
}

/// Appends little-endian values to a buffer sized up front.
struct ByteWriter {
  private(set) var data: Data

  /// Starts a packet of `type` whose payload is about `payloadCapacity` bytes.
  init(type: PacketType, payloadCapacity: Int) {
    data = Data()
    data.reserveCapacity(WireLayout.headerSize + payloadCapacity)
    write(WireProtocol.magic)
    write(WireProtocol.version)
    write(type.rawValue)
  }

  /// Starts a buffer with no packet header, for a part of a packet such as a log record.
  init(capacity: Int) {
    data = Data()
    data.reserveCapacity(capacity)
  }

  mutating func write<Value: FixedWidthInteger>(_ value: Value) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func write(_ value: Double) {
    write(value.bitPattern)
  }

  /// Writes the 16 UUID bytes in `uuid_t` order.
  mutating func write(_ value: UUID) {
    withUnsafeBytes(of: value.uuid) { data.append(contentsOf: $0) }
  }

  mutating func write(_ bytes: Data) {
    data.append(bytes)
  }

  /// Writes a `u8` length and the UTF-8 bytes of `name`, cut back to the last whole character that
  /// fits in `WireProtocol.maxNameBytes`.
  mutating func writeName(_ name: String) {
    let fitting = name.prefix(utf8Bytes: WireProtocol.maxNameBytes)
    write(UInt8(fitting.utf8.count))
    data.append(contentsOf: fitting.utf8)
  }
}

/// Reads little-endian values from a datagram without ever trapping on short input.
///
/// Works on slices: positions are offsets from `data.startIndex`, not from zero.
struct ByteReader {
  private let data: Data
  private var position: Data.Index

  init(_ data: Data) {
    self.data = data
    position = data.startIndex
  }

  var remaining: Int {
    data.endIndex - position
  }

  mutating func read<Value: FixedWidthInteger>(
    _ type: Value.Type = Value.self
  ) throws(PacketDecodeError) -> Value {
    let size = MemoryLayout<Value>.size
    guard remaining >= size else { throw .truncated }
    var value: Value = 0
    for offset in 0..<size {
      value |= Value(truncatingIfNeeded: data[position + offset]) << (offset * 8)
    }
    position += size
    return value
  }

  mutating func readDouble() throws(PacketDecodeError) -> Double {
    Double(bitPattern: try read(UInt64.self))
  }

  mutating func readUUID() throws(PacketDecodeError) -> UUID {
    let size = MemoryLayout<uuid_t>.size
    guard remaining >= size else { throw .truncated }
    var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &raw) { buffer in
      buffer.copyBytes(from: data[position..<position + size])
    }
    position += size
    return UUID(uuid: raw)
  }

  /// Reads the next `count` bytes as they are.
  mutating func readBytes(count: Int) throws(PacketDecodeError) -> Data {
    guard count >= 0, remaining >= count else { throw .truncated }
    let bytes = Data(data[position..<position + count])
    position += count
    return bytes
  }

  /// Reads everything left.
  mutating func readRemaining() -> Data {
    let bytes = Data(data[position...])
    position = data.endIndex
    return bytes
  }

  /// Reads a `u8` length followed by that many UTF-8 bytes.
  mutating func readName() throws(PacketDecodeError) -> String {
    let length = Int(try read(UInt8.self))
    guard remaining >= length else { throw .truncated }
    let bytes = data[position..<position + length]
    guard let name = String(validating: bytes, as: UTF8.self) else { throw .invalidString }
    position += length
    return name
  }
}

extension String {
  /// The longest prefix made of whole characters that takes at most `limit` UTF-8 bytes.
  ///
  /// Cutting on character boundaries keeps multi-byte scalars and grapheme clusters (emoji with
  /// modifiers, accents) intact.
  func prefix(utf8Bytes limit: Int) -> Substring {
    guard utf8.count > limit else { return self[...] }
    var end = startIndex
    var used = 0
    for index in indices {
      let next = self.index(after: index)
      used += utf8.distance(from: index, to: next)
      guard used <= limit else { break }
      end = next
    }
    return self[..<end]
  }
}
