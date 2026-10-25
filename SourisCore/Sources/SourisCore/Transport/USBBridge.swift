#if os(macOS)
import Darwin
import Foundation
import Network
import Synchronization

/// The Mac's USB link, for the menu.
public enum USBBridgeState: Equatable, Sendable {
  case stopped

  /// usbmuxd, the system service Xcode uses to reach iPhones over USB, can't be reached.
  case unavailable(String)

  /// No iPhone is plugged in.
  case noDevice

  /// An iPhone is plugged in but Souris on it isn't listening: the app is closed, in the
  /// background, or a build without USB support.
  case waitingForApp

  /// Linked to Souris on the iPhone and relaying its packets.
  case connected
}

/// What the bridge reports. Always delivered on the bridge's queue.
public enum USBBridgeEvent: Sendable {
  case stateChanged(USBBridgeState)

  /// An entry for the Mac's diagnostic log, category `"usb"`.
  case log(LogEntry)
}

/// Links an iPhone on the USB cable to the Mac's `SourisServer`.
///
/// - It asks usbmuxd (`/var/run/usbmuxd`) to report iPhones as they are plugged in and out, and
///   only uses ones attached by USB, not over Wi-Fi sync.
/// - For a plugged-in iPhone it asks usbmuxd to connect to `WireProtocol.usbPort` on the phone,
///   where `SourisClient` listens on loopback. A refused connect (the app isn't open) is retried
///   every second while the phone stays plugged in.
/// - Once linked, each `StreamFraming` frame from the phone goes to the server as a UDP datagram
///   on loopback, and every datagram the server sends back goes down the cable as a frame. The
///   server sees an ordinary UDP flow from 127.0.0.1 and needs no USB knowledge.
/// - When the stream closes (unplugged, the app quit), the relay is torn down and the phone falls
///   back to Wi-Fi on its own.
///
/// Thread safety: every method may be called from any thread. Events arrive on `queue`.
public final class USBBridge: @unchecked Sendable {
  private static let usbmuxdPath = "/var/run/usbmuxd"
  private static let retryDelay = DispatchTimeInterval.seconds(1)
  private static let usbmuxdRetryDelay = DispatchTimeInterval.seconds(5)
  private static let relayingWindow = Duration.milliseconds(1500)
  private static let logCategory = "usb"

  /// A device the cable link is (or is being) set up to.
  private struct Link {
    /// Tells this link's callbacks apart from an earlier one's.
    var id: Int
    var deviceID: Int
    var socket: StreamSocket

    /// Nil until usbmuxd has answered the connect; then the relay to the server.
    var relay: NWConnection?
    var handshake = UsbmuxDecoder()
    var frames = FrameDecoder()
  }

  private let queue: DispatchQueue
  private let onEvent: @Sendable (USBBridgeEvent) -> Void
  private let lastUplink = Mutex<ContinuousClock.Instant?>(nil)

  private var serverPort: UInt16?
  private var generation = 0
  private var state = USBBridgeState.stopped
  private var listenSocket: StreamSocket?
  private var listenDecoder = UsbmuxDecoder()

  /// USB-attached iPhones, by usbmuxd device id, with their serial numbers.
  private var devices: [Int: String] = [:]
  private var link: Link?
  private var lastLinkID = 0
  private var nextTag: UInt32 = 1

  public init(
    queue: DispatchQueue = DispatchQueue(label: "souris.usb", qos: .userInteractive),
    onEvent: @escaping @Sendable (USBBridgeEvent) -> Void
  ) {
    self.queue = queue
    self.onEvent = onEvent
  }

  deinit {
    link?.relay?.cancel()
    link?.socket.close()
    listenSocket?.close()
  }

  /// True while packets from a phone came up the cable within the last 1.5 s.
  public var isRelaying: Bool {
    guard let last = lastUplink.withLock({ $0 }) else { return false }
    return ContinuousClock.now - last < Self.relayingWindow
  }

  /// Starts watching for iPhones and relaying to the server on `serverPort`. Calling it again
  /// with another port starts over with that one.
  public func start(serverPort: UInt16) {
    queue.async { [self] in
      guard serverPort != self.serverPort else { return }
      teardown()
      self.serverPort = serverPort
      log(.info, "start", fields: ["serverPort": .int(Int(serverPort))])
      openListenSocket()
    }
  }

  public func stop() {
    queue.async { [self] in
      guard serverPort != nil else { return }
      teardown()
      serverPort = nil
      log(.info, "stop")
      setState(.stopped)
    }
  }

  // MARK: - Watching for devices

  private func openListenSocket() {
    let current = generation
    do {
      let socket = try StreamSocket.connect(toUnixPath: Self.usbmuxdPath)
      listenSocket = socket
      listenDecoder = UsbmuxDecoder()
      socket.startReading(
        on: queue,
        onData: { [weak self] data in self?.listenSocketReceived(data, generation: current) },
        onClose: { [weak self] reason in self?.listenSocketClosed(reason, generation: current) })
      guard socket.write(Usbmux.message(["MessageType": "Listen"], tag: takeTag())) else {
        listenSocketClosed("couldn’t send Listen", generation: current)
        return
      }
      if devices.isEmpty {
        setState(.noDevice)
      }
    } catch {
      log(.warning, "usbmuxdUnavailable", "\(error)")
      setState(.unavailable("\(error)"))
      retry(after: Self.usbmuxdRetryDelay, generation: current) { $0.openListenSocket() }
    }
  }

  private func listenSocketReceived(_ data: Data, generation current: Int) {
    guard current == generation else { return }
    listenDecoder.append(data)
    do {
      while let message = try listenDecoder.next() {
        handleListenMessage(message)
      }
    } catch {
      listenSocketClosed("unreadable usbmuxd message: \(error)", generation: current)
    }
  }

  private func handleListenMessage(_ message: [String: Any]) {
    let type = message["MessageType"] as? String
    switch type {
    case "Result":
      let number = message["Number"] as? Int ?? -1
      if number != 0 {
        log(.warning, "listenRefused", fields: ["number": .int(number)])
      }
    case "Attached":
      let properties = message["Properties"] as? [String: Any] ?? [:]
      guard let deviceID = message["DeviceID"] as? Int ?? properties["DeviceID"] as? Int else {
        return
      }
      let connectionType = properties["ConnectionType"] as? String ?? "unknown"
      let serial = properties["SerialNumber"] as? String ?? "unknown"
      log(
        .info, "attached",
        fields: [
          "device": .int(deviceID), "connectionType": .string(connectionType),
          "serial": .string(serial),
        ])
      // Wi-Fi sync devices show up too; the point is to get off Wi-Fi.
      guard connectionType == "USB" else { return }
      devices[deviceID] = serial
      if link == nil {
        connectLink(to: deviceID)
      }
    case "Detached":
      guard let deviceID = message["DeviceID"] as? Int,
        devices.removeValue(forKey: deviceID) != nil
      else { return }
      log(.info, "detached", fields: ["device": .int(deviceID)])
      if link?.deviceID == deviceID {
        closeLink(reason: "unplugged")
      }
      if link == nil, let next = devices.keys.min() {
        connectLink(to: next)
      } else if devices.isEmpty {
        setState(.noDevice)
      }
    default:
      break
    }
  }

  private func listenSocketClosed(_ reason: String, generation current: Int) {
    guard current == generation else { return }
    log(.warning, "usbmuxdClosed", reason)
    teardown()
    setState(.unavailable(reason))
    let next = generation
    retry(after: Self.usbmuxdRetryDelay, generation: next) { $0.openListenSocket() }
  }

  // MARK: - The cable link

  private func connectLink(to deviceID: Int) {
    let current = generation
    let socket: StreamSocket
    do {
      socket = try StreamSocket.connect(toUnixPath: Self.usbmuxdPath)
    } catch {
      log(.warning, "linkSocketFailed", "\(error)")
      retryLink(to: deviceID, generation: current)
      return
    }
    lastLinkID += 1
    let id = lastLinkID
    link = Link(id: id, deviceID: deviceID, socket: socket)
    socket.startReading(
      on: queue,
      onData: { [weak self] data in self?.linkReceived(data, link: id) },
      onClose: { [weak self] reason in self?.linkClosed(reason, link: id) })
    let connect = Usbmux.message(
      [
        "MessageType": "Connect",
        "DeviceID": deviceID,
        // usbmuxd wants the port in network byte order.
        "PortNumber": Int(WireProtocol.usbPort.bigEndian),
      ],
      tag: takeTag())
    if !socket.write(connect) {
      linkClosed("couldn’t send Connect", link: id)
    }
  }

  private func linkReceived(_ data: Data, link id: Int) {
    guard link?.id == id else { return }
    guard link?.relay == nil else {
      forwardUp(data, link: id)
      return
    }
    link?.handshake.append(data)
    let message: [String: Any]?
    do {
      message = try link?.handshake.next()
    } catch {
      linkClosed("unreadable usbmuxd reply: \(error)", link: id)
      return
    }
    guard let message else { return }
    let number = message["Number"] as? Int ?? -1
    guard message["MessageType"] as? String == "Result", number == 0 else {
      // 3 is "connection refused": nothing is listening on the phone.
      linkClosed("connect refused (\(number))", link: id)
      return
    }
    // From here the socket is a raw stream to the phone.
    let leftover = link?.handshake.remainder ?? Data()
    startRelay(link: id)
    if !leftover.isEmpty {
      forwardUp(leftover, link: id)
    }
  }

  private func startRelay(link id: Int) {
    guard let serverPort, let port = NWEndpoint.Port(rawValue: serverPort),
      let deviceID = link?.deviceID
    else { return }
    let relay = NWConnection(host: .ipv4(.loopback), port: port, using: .udp)
    relay.stateUpdateHandler = { [weak self] state in
      self?.relayStateChanged(state, link: id)
    }
    link?.relay = relay
    relay.start(queue: queue)
    receiveFromServer(link: id)
    log(
      .info, "linked", "Linked to Souris on the iPhone over USB",
      fields: ["device": .int(deviceID), "serial": .string(devices[deviceID] ?? "unknown")])
    setState(.connected)
  }

  /// Frames from the phone, to the server.
  private func forwardUp(_ data: Data, link id: Int) {
    guard link?.id == id, let relay = link?.relay else { return }
    let frames: [Data]
    do {
      frames = try link?.frames.append(data) ?? []
    } catch {
      linkClosed("stream out of step: \(error)", link: id)
      return
    }
    guard !frames.isEmpty else { return }
    lastUplink.withLock { $0 = .now }
    for frame in frames {
      relay.send(content: frame, completion: .idempotent)
    }
  }

  /// Datagrams from the server, down the cable.
  private func receiveFromServer(link id: Int) {
    guard link?.id == id, let relay = link?.relay else { return }
    relay.receiveMessage { [weak self] data, _, _, error in
      guard let self, link?.id == id else { return }
      if let error {
        linkClosed("relay receive failed: \(error.networkDescription)", link: id)
        return
      }
      if let data, !data.isEmpty, let socket = link?.socket,
        !socket.write(StreamFraming.frame(data))
      {
        linkClosed("write to the phone failed", link: id)
        return
      }
      receiveFromServer(link: id)
    }
  }

  private func relayStateChanged(_ state: NWConnection.State, link id: Int) {
    if case .failed(let error) = state {
      linkClosed("relay failed: \(error.networkDescription)", link: id)
    }
  }

  private func linkClosed(_ reason: String, link id: Int) {
    guard let closing = link, closing.id == id else { return }
    closeLink(reason: reason)
    guard devices[closing.deviceID] != nil else { return }
    setState(.waitingForApp)
    retryLink(to: closing.deviceID, generation: generation)
  }

  private func retryLink(to deviceID: Int, generation current: Int) {
    retry(after: Self.retryDelay, generation: current) { bridge in
      guard bridge.link == nil, bridge.devices[deviceID] != nil else { return }
      bridge.connectLink(to: deviceID)
    }
  }

  private func closeLink(reason: String) {
    guard let link else { return }
    // Refused connects repeat every second while the app is closed, so only real links are
    // logged as closed.
    if link.relay != nil {
      log(.info, "unlinked", reason, fields: ["device": .int(link.deviceID)])
      lastUplink.withLock { $0 = nil }
    }
    link.relay?.cancel()
    link.socket.close()
    self.link = nil
  }

  // MARK: - Helpers

  /// Closes every socket and forgets every device, and ignores callbacks from before.
  private func teardown() {
    generation += 1
    closeLink(reason: "stopped")
    listenSocket?.close()
    listenSocket = nil
    devices.removeAll()
  }

  private func retry(
    after delay: DispatchTimeInterval, generation current: Int,
    _ action: @escaping @Sendable (USBBridge) -> Void
  ) {
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, current == generation else { return }
      action(self)
    }
  }

  private func takeTag() -> UInt32 {
    defer { nextTag &+= 1 }
    return nextTag
  }

  private func setState(_ newState: USBBridgeState) {
    guard newState != state else { return }
    state = newState
    onEvent(.stateChanged(newState))
  }

  private func log(
    _ level: LogLevel, _ event: String, _ message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    onEvent(
      .log(
        LogEntry(
          level: level, category: Self.logCategory, event: event, message: message,
          fields: fields)))
  }
}

// MARK: - usbmuxd protocol

/// usbmuxd's plist protocol: a 16-byte little-endian header (total length, version 1, message
/// type 8 for plist, tag) and an XML property list.
enum Usbmux {
  static let headerSize = 16
  static let version: UInt32 = 1
  static let plistMessageType: UInt32 = 8

  static func message(_ fields: [String: Any], tag: UInt32) -> Data {
    var dictionary = fields
    dictionary["ClientVersionString"] = "souris"
    dictionary["ProgName"] = "Souris"
    dictionary["kLibUSBMuxVersion"] = 3
    let payload =
      (try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
      ?? Data()
    var data = Data(capacity: headerSize + payload.count)
    for value in [UInt32(headerSize + payload.count), version, plistMessageType, tag] {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(payload)
    return data
  }
}

/// Splits usbmuxd's replies into property lists.
struct UsbmuxDecoder {
  struct BadMessage: Error, CustomStringConvertible {
    var description: String
  }

  private var buffer = Data()

  /// Bytes after the last message taken. After a successful Connect these are the first bytes of
  /// the raw stream.
  var remainder: Data { buffer }

  mutating func append(_ data: Data) {
    buffer.append(data)
  }

  /// The next whole message, or nil until more bytes arrive.
  mutating func next() throws -> [String: Any]? {
    guard buffer.count >= Usbmux.headerSize else { return nil }
    let header = [UInt8](buffer.prefix(Usbmux.headerSize))
    func word(_ index: Int) -> Int {
      (0..<4).reduce(0) { $0 | Int(header[index * 4 + $1]) << (8 * $1) }
    }
    let length = word(0)
    guard length >= Usbmux.headerSize, length <= 1 << 20 else {
      throw BadMessage(description: "length \(length)")
    }
    guard buffer.count >= length else { return nil }
    let start = buffer.startIndex
    let payload = buffer.subdata(in: (start + Usbmux.headerSize)..<(start + length))
    buffer = Data(buffer.dropFirst(length))
    guard word(2) == Int(Usbmux.plistMessageType) else {
      throw BadMessage(description: "message type \(word(2))")
    }
    let plist = try PropertyListSerialization.propertyList(from: payload, format: nil)
    guard let dictionary = plist as? [String: Any] else {
      throw BadMessage(description: "not a dictionary")
    }
    return dictionary
  }
}

// MARK: - Socket

/// A Unix stream socket: non-blocking, read through a dispatch source, written with a short
/// wait for room.
final class StreamSocket: @unchecked Sendable {
  struct SocketError: Error, CustomStringConvertible {
    var description: String

    init(_ call: String, _ code: Int32) {
      description = "\(call): \(String(cString: strerror(code)))"
    }
  }

  /// How long a write waits for room in the socket before giving up, milliseconds.
  private static let writeTimeoutMs: Int32 = 1000

  private let fd: Int32
  private var source: (any DispatchSourceRead)?
  private var isClosed = false

  private init(fd: Int32) {
    self.fd = fd
  }

  deinit {
    close()
  }

  static func connect(toUnixPath path: String) throws -> StreamSocket {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError("socket", errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(fd)
      throw SocketError("connect", ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(fd)
      throw SocketError("connect", code)
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    return StreamSocket(fd: fd)
  }

  /// Calls `onData` with every read and `onClose` once when the other end closes or a read
  /// fails, both on `queue`.
  func startReading(
    on queue: DispatchQueue,
    onData: @escaping @Sendable (Data) -> Void,
    onClose: @escaping @Sendable (String) -> Void
  ) {
    guard !isClosed, source == nil else { return }
    let fd = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in
      guard let self, !isClosed else { return }
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count > 0 {
        onData(Data(buffer[0..<count]))
        return
      }
      let code = errno
      if count < 0 && (code == EAGAIN || code == EINTR) { return }
      close()
      onClose(count == 0 ? "closed" : String(cString: strerror(code)))
    }
    source.setCancelHandler {
      Darwin.close(fd)
    }
    self.source = source
    source.resume()
  }

  /// Writes all of `data`. False if the socket is closed, failed, or stayed full for a second.
  func write(_ data: Data) -> Bool {
    guard !isClosed else { return false }
    let fd = fd
    return data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return true }
      var offset = 0
      while offset < raw.count {
        let written = Darwin.write(fd, base + offset, raw.count - offset)
        if written > 0 {
          offset += written
          continue
        }
        let code = errno
        if written < 0 && code == EINTR { continue }
        if written < 0 && code == EAGAIN {
          var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
          if poll(&descriptor, 1, Self.writeTimeoutMs) > 0 { continue }
        }
        return false
      }
      return true
    }
  }

  /// Stops reading and closes the socket. Safe to call more than once.
  func close() {
    guard !isClosed else { return }
    isClosed = true
    if let source {
      source.cancel()
    } else {
      Darwin.close(fd)
    }
  }
}
#endif
