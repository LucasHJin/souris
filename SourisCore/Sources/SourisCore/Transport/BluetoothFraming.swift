import CoreBluetooth
import Foundation

// Over Bluetooth LE the phone is a peripheral with one service and two characteristics: the
// phone notifies its packets on the outbox, and the Mac writes its replies, without response, to
// the inbox. Each notification or write carries one fragment: a header byte, then up to one
// attribute value's worth of a packet.

/// The Bluetooth service's identifiers.
public enum BluetoothService {
  public static let service = "38B11BFF-7222-4CFF-A421-3118D7318A36"

  /// Phone → Mac, notify.
  public static let outbox = "7720D5CC-75D8-46F0-A5BC-3895C30C2733"

  /// Mac → phone, write without response.
  public static let inbox = "FD367EC2-2F88-4AF5-9EC5-849D6D12B6F7"

  /// The name the phone advertises.
  public static let localName = "Souris"
}

/// Splits packets into fragments that fit one attribute value, and joins them back.
///
/// The header byte has two flags. `bulk` marks a fragment of a packet too large for one value;
/// `continues` marks every bulk fragment but the packet's last. A packet that fits goes as one
/// fragment without `bulk`, so it can be sent between the fragments of a large one (a log packet
/// takes seven at the usual 182-byte size) and a state packet never waits behind a log packet.
/// Bluetooth delivers notifications and writes in order and without loss, so no sequence numbers
/// are needed.
public enum BluetoothFraming {
  public static let headerSize = 1
  static let bulk: UInt8 = 0x40
  static let continues: UInt8 = 0x80

  /// The fragments for `packet`, each at most `maximumLength` bytes, header included.
  public static func fragments(of packet: Data, maximumLength: Int) -> [Data] {
    let room = max(1, maximumLength - headerSize)
    guard packet.count > room else {
      var fragment = Data([0])
      fragment.append(packet)
      return [fragment]
    }
    var fragments: [Data] = []
    var offset = packet.startIndex
    while offset < packet.endIndex {
      let end = min(packet.endIndex, offset + room)
      let flags = end < packet.endIndex ? bulk | continues : bulk
      var fragment = Data([flags])
      fragment.append(packet[offset..<end])
      fragments.append(fragment)
      offset = end
    }
    return fragments
  }

  /// The packet type byte of `packet` (after the magic and version), if it has one.
  public static func packetType(of packet: Data) -> PacketType? {
    guard packet.count > 3 else { return nil }
    return PacketType(rawValue: packet[packet.startIndex + 3])
  }
}

/// Joins fragments from one direction of the link back into packets.
public struct BluetoothReassembler: Sendable {
  public struct Error: Swift.Error, CustomStringConvertible {
    public var description: String
  }

  /// The largest packet accepted, bytes. Log packets stay under 9216.
  public static let maxPacketBytes = 64 * 1024

  private var bulk = Data()

  public init() {}

  /// Adds one fragment and returns the packet it completes, if any.
  public mutating func append(_ fragment: Data) throws(Error) -> Data? {
    guard let flags = fragment.first else { throw Error(description: "empty fragment") }
    let payload = fragment.dropFirst(BluetoothFraming.headerSize)
    guard flags & BluetoothFraming.bulk != 0 else {
      return Data(payload)
    }
    bulk.append(payload)
    guard bulk.count <= Self.maxPacketBytes else {
      bulk.removeAll()
      throw Error(description: "packet over \(Self.maxPacketBytes) bytes")
    }
    guard flags & BluetoothFraming.continues == 0 else { return nil }
    defer { bulk.removeAll(keepingCapacity: true) }
    return bulk
  }

  /// Drops a partly received packet, e.g. when the link drops.
  public mutating func reset() {
    bulk.removeAll()
  }
}

/// The phone's outgoing packets while Bluetooth can't take them all.
///
/// The newest state packet replaces any older one still waiting, as state is absolute and the Mac
/// only wants the latest. Other small packets wait their turn in order, ahead of the fragments of
/// large ones, so pings and hellos aren't held up by a log packet.
public struct BluetoothSendQueue: Sendable {
  private var state: Data?
  private var small: [Data] = []
  private var large: [Data] = []

  public init() {}

  public var isEmpty: Bool {
    state == nil && small.isEmpty && large.isEmpty
  }

  /// Fragments of large packets waiting.
  public var largeFragmentCount: Int {
    large.count
  }

  /// Queues `packet` as fragments of at most `maximumLength` bytes.
  public mutating func enqueue(_ packet: Data, maximumLength: Int) {
    let fragments = BluetoothFraming.fragments(of: packet, maximumLength: maximumLength)
    if fragments.count > 1 {
      large += fragments
    } else if BluetoothFraming.packetType(of: packet) == .state {
      state = fragments[0]
    } else {
      small.append(fragments[0])
    }
  }

  /// The next fragment to send, without removing it.
  public var next: Data? {
    state ?? small.first ?? large.first
  }

  /// Removes the fragment `next` returned, once it was sent.
  public mutating func removeNext() {
    if state != nil {
      state = nil
    } else if !small.isEmpty {
      small.removeFirst()
    } else if !large.isEmpty {
      large.removeFirst()
    }
  }

  public mutating func removeAll() {
    state = nil
    small.removeAll()
    large.removeAll()
  }
}

extension CBManagerState {
  /// A short name for the log and the status line.
  var logName: String {
    switch self {
    case .unknown: "unknown"
    case .resetting: "resetting"
    case .unsupported: "unsupported"
    case .unauthorized: "not allowed"
    case .poweredOff: "off"
    case .poweredOn: "on"
    @unknown default: "unknown"
    }
  }
}
