import Foundation
import Testing

@testable import SourisCore

@Suite("USB framing")
struct USBFramingTests {
  @Test func framesCarryABigEndianLength() {
    let framed = StreamFraming.frame(Data([0xAA, 0xBB, 0xCC]))
    #expect([UInt8](framed) == [0, 0, 0, 3, 0xAA, 0xBB, 0xCC])
  }

  @Test func decoderSplitsFramesWhateverTheChunking() throws {
    let packets = [Data("hello".utf8), Data(), Data(repeating: 7, count: 9000), Data([1])]
    let stream = packets.map(StreamFraming.frame).reduce(Data(), +)
    for chunkSize in [1, 3, 4, 5, 1000, stream.count] {
      var decoder = FrameDecoder()
      var decoded: [Data] = []
      var offset = 0
      while offset < stream.count {
        let end = min(offset + chunkSize, stream.count)
        decoded += try decoder.append(stream.subdata(in: offset..<end))
        offset = end
      }
      #expect(decoded == packets, "chunk size \(chunkSize)")
      #expect(decoder.pendingBytes == 0)
    }
  }

  @Test func decoderRejectsAnOversizedFrame() {
    var decoder = FrameDecoder()
    let length = UInt32(StreamFraming.maxFrameBytes + 1)
    let header = Data([
      UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF),
      UInt8(length & 0xFF),
    ])
    #expect(throws: FrameDecoder.OversizedFrame.self) { try decoder.append(header) }
  }

  @Test func decodedPacketsRoundTrip() throws {
    let hello = Packet.hello(HelloPacket(epoch: 9, deviceID: UUID(), deviceName: "Phone"))
    var decoder = FrameDecoder()
    let frames = try decoder.append(StreamFraming.frame(hello.encoded()))
    #expect(try frames.map(Packet.decode) == [hello])
  }

  #if os(macOS)
  @Test func usbmuxMessagesRoundTripAndLeaveTheRawStreamBehind() throws {
    let message = Usbmux.message(["MessageType": "Connect", "DeviceID": 4], tag: 7)
    let header = [UInt8](message.prefix(Usbmux.headerSize))
    #expect(header[0..<4] == [UInt8(message.count & 0xFF), UInt8(message.count >> 8), 0, 0])
    #expect(header[4..<8] == [1, 0, 0, 0])
    #expect(header[8..<12] == [8, 0, 0, 0])
    #expect(header[12..<16] == [7, 0, 0, 0])

    var decoder = UsbmuxDecoder()
    decoder.append(message.prefix(10))
    #expect(try decoder.next() == nil)
    decoder.append(message.dropFirst(10) + Data([0xAB, 0xCD]))
    let decoded = try #require(try decoder.next())
    #expect(decoded["MessageType"] as? String == "Connect")
    #expect(decoded["DeviceID"] as? Int == 4)
    #expect(decoded["ProgName"] as? String == "Souris")
    #expect(try decoder.next() == nil)
    #expect([UInt8](decoder.remainder) == [0xAB, 0xCD])
  }

  @Test func theUSBPortGoesToUsbmuxdInNetworkByteOrder() {
    // 47812 is 0xBAC4; usbmuxd reads the number's little-endian bytes as the port's.
    #expect(Int(WireProtocol.usbPort.bigEndian) == 0xC4BA)
  }
  #endif
}
