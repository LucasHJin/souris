import Foundation
import Testing

@testable import SourisCore

@Suite struct BluetoothFramingTests {
  static func state(seq: UInt32) -> Data {
    Packet.state(
      StatePacket(epoch: 1, seq: seq, phoneTimeMicros: 0, state: MouseState(cursor: SIMD2(1, 2))))
      .encoded()
  }

  static let ping = Packet.ping(PingPacket(id: 7, phoneTimeMicros: 5)).encoded()

  @Test func aSmallPacketIsOneFragment() throws {
    let packet = Self.state(seq: 1)
    let fragments = BluetoothFraming.fragments(of: packet, maximumLength: 182)
    #expect(fragments.count == 1)
    var reassembler = BluetoothReassembler()
    #expect(try reassembler.append(fragments[0]) == packet)
  }

  @Test func aLargePacketSplitsAndJoins() throws {
    let packet = Data((0..<1200).map { UInt8($0 % 251) })
    let fragments = BluetoothFraming.fragments(of: packet, maximumLength: 182)
    #expect(fragments.count == 7)
    #expect(fragments.allSatisfy { $0.count <= 182 })
    var reassembler = BluetoothReassembler()
    for fragment in fragments.dropLast() {
      #expect(try reassembler.append(fragment) == nil)
    }
    #expect(try reassembler.append(fragments.last!) == packet)
  }

  @Test func smallPacketsPassBetweenTheFragmentsOfALargeOne() throws {
    let large = Data(repeating: 9, count: 500)
    let small = Self.state(seq: 3)
    let fragments = BluetoothFraming.fragments(of: large, maximumLength: 100)
    var reassembler = BluetoothReassembler()
    var delivered: [Data] = []
    for (index, fragment) in fragments.enumerated() {
      if let packet = try reassembler.append(fragment) { delivered.append(packet) }
      if index == 1, let packet = try reassembler.append(
        BluetoothFraming.fragments(of: small, maximumLength: 100)[0])
      {
        delivered.append(packet)
      }
    }
    #expect(delivered == [small, large])
  }

  @Test func aPacketExactlyTheRoomLeftIsOneFragment() {
    let packet = Data(repeating: 1, count: 181)
    #expect(BluetoothFraming.fragments(of: packet, maximumLength: 182).count == 1)
    #expect(BluetoothFraming.fragments(of: packet + Data([2]), maximumLength: 182).count == 2)
  }

  @Test func theQueueKeepsOnlyTheNewestStateAndPutsItFirst() {
    var queue = BluetoothSendQueue()
    queue.enqueue(Data(repeating: 4, count: 400), maximumLength: 182)
    queue.enqueue(Self.ping, maximumLength: 182)
    queue.enqueue(Self.state(seq: 1), maximumLength: 182)
    queue.enqueue(Self.state(seq: 2), maximumLength: 182)
    var sent: [Data] = []
    while let next = queue.next {
      sent.append(next)
      queue.removeNext()
    }
    // The newest state, then the ping, then the three fragments of the large packet.
    #expect(sent.count == 5)
    #expect(sent[0] == BluetoothFraming.fragments(of: Self.state(seq: 2), maximumLength: 182)[0])
    #expect(sent[1].dropFirst() == Self.ping)
    #expect(sent[2...].allSatisfy { $0.first! & BluetoothFraming.bulk != 0 })
    #expect(queue.isEmpty)
  }

  @Test func packetTypeReadsTheHeader() {
    #expect(BluetoothFraming.packetType(of: Self.state(seq: 1)) == .state)
    #expect(BluetoothFraming.packetType(of: Self.ping) == .ping)
    #expect(BluetoothFraming.packetType(of: Data([1, 2])) == nil)
  }

  @Test func anEmptyFragmentIsAnError() {
    var reassembler = BluetoothReassembler()
    #expect(throws: BluetoothReassembler.Error.self) { try reassembler.append(Data()) }
  }
}
