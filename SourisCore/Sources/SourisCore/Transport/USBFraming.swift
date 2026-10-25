import Foundation
import Network

// Over a USB cable the phone and the Mac talk through a TCP stream (usbmuxd, the channel Xcode
// uses), not UDP. The stream carries the same packets as the Wi-Fi link, each one prefixed with
// its length.

extension WireProtocol {
  /// The TCP port the phone listens on, on its loopback interface only, for the Mac's USB link.
  public static let usbPort: UInt16 = 47812

  /// The TCP port the phone listens on, on its loopback interface only, for its own Bluetooth
  /// bridge. Same framing as the USB link.
  public static let bluetoothPort: UInt16 = 47813
}

/// The framing on the USB stream: every packet is preceded by its length as a big-endian
/// `UInt32`.
public enum StreamFraming {
  public static let headerSize = 4

  /// The longest frame either end accepts. Packets are far smaller (a log packet stays under
  /// 9216 bytes), so anything longer means the stream is out of step.
  public static let maxFrameBytes = 64 * 1024

  /// `packet` with its length prefix.
  public static func frame(_ packet: Data) -> Data {
    var framed = Data(capacity: headerSize + packet.count)
    let length = UInt32(packet.count)
    framed.append(UInt8(truncatingIfNeeded: length >> 24))
    framed.append(UInt8(truncatingIfNeeded: length >> 16))
    framed.append(UInt8(truncatingIfNeeded: length >> 8))
    framed.append(UInt8(truncatingIfNeeded: length))
    framed.append(packet)
    return framed
  }

  static func length(of header: UnsafeRawBufferPointer) -> Int {
    Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
  }
}

/// Splits a byte stream back into the packets `StreamFraming.frame(_:)` wrote.
public struct FrameDecoder: Sendable {
  public struct OversizedFrame: Error, Equatable {
    public var length: Int
  }

  private var buffer = Data()

  public init() {}

  /// Bytes received but not yet part of a whole frame.
  public var pendingBytes: Int { buffer.count }

  /// Adds `bytes` from the stream and returns every frame they complete, in order.
  ///
  /// - Throws: `OversizedFrame` when a header announces more than `StreamFraming.maxFrameBytes`.
  ///   The stream can't be resynchronized after that; close it.
  public mutating func append(_ bytes: Data) throws -> [Data] {
    buffer.append(bytes)
    var frames: [Data] = []
    var offset = buffer.startIndex
    while buffer.endIndex - offset >= StreamFraming.headerSize {
      let length = buffer[offset..<(offset + StreamFraming.headerSize)].withUnsafeBytes {
        StreamFraming.length(of: $0)
      }
      guard length <= StreamFraming.maxFrameBytes else { throw OversizedFrame(length: length) }
      let start = offset + StreamFraming.headerSize
      guard buffer.endIndex - start >= length else { break }
      frames.append(Data(buffer[start..<(start + length)]))
      offset = start + length
    }
    if offset > buffer.startIndex {
      buffer = Data(buffer[offset...])
    }
    return frames
  }
}

/// `StreamFraming` as a Network.framework protocol, so a TCP `NWConnection` sends and receives
/// whole packets with `send(content:)` and `receiveMessage`, exactly like the UDP one.
final class LengthPrefixFramer: NWProtocolFramerImplementation {
  nonisolated(unsafe) static let definition = NWProtocolFramer.Definition(
    implementation: LengthPrefixFramer.self)

  static var label: String { "SourisLengthPrefix" }

  /// Options to put first in a TCP connection's application protocols.
  static var options: NWProtocolFramer.Options {
    NWProtocolFramer.Options(definition: definition)
  }

  required init(framer: NWProtocolFramer.Instance) {}

  func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }

  func wakeup(framer: NWProtocolFramer.Instance) {}

  func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

  func cleanup(framer: NWProtocolFramer.Instance) {}

  func handleOutput(
    framer: NWProtocolFramer.Instance,
    message: NWProtocolFramer.Message,
    messageLength: Int,
    isComplete: Bool
  ) {
    let length = UInt32(messageLength)
    framer.writeOutput(data: [
      UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
    ])
    do {
      try framer.writeOutputNoCopy(length: messageLength)
    } catch {
      framer.markFailed(error: .posix(.EIO))
    }
  }

  func handleInput(framer: NWProtocolFramer.Instance) -> Int {
    while true {
      var length: Int?
      let parsed = framer.parseInput(
        minimumIncompleteLength: StreamFraming.headerSize,
        maximumLength: StreamFraming.headerSize
      ) { buffer, _ in
        guard let buffer, buffer.count >= StreamFraming.headerSize else { return 0 }
        length = StreamFraming.length(of: UnsafeRawBufferPointer(buffer))
        return StreamFraming.headerSize
      }
      guard parsed, let length else { return StreamFraming.headerSize }
      guard length <= StreamFraming.maxFrameBytes else {
        framer.markFailed(error: .posix(.EBADMSG))
        return 0
      }
      let message = NWProtocolFramer.Message(definition: Self.definition)
      guard framer.deliverInputNoCopy(length: length, message: message, isComplete: true) else {
        return 0
      }
    }
  }
}
