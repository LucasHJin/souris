import Foundation
import Network
import Synchronization
import Testing

@testable import SourisCore

// MARK: - Helpers

/// An ordered, thread-safe log for values that arrive on network queues.
private final class Recorder<Value: Sendable>: Sendable {
  private let storage = Mutex<[Value]>([])

  var values: [Value] {
    storage.withLock { $0 }
  }

  func append(_ value: Value) {
    storage.withLock { $0.append(value) }
  }
}

extension Recorder where Value == ServerEvent {
  fileprivate var states: [StatePacket] {
    values.compactMap { event in
      if case .state(let packet) = event { packet } else { nil }
    }
  }

  fileprivate func contains(_ event: ServerEvent) -> Bool {
    values.contains(event)
  }

  fileprivate func index(of event: ServerEvent) -> Int? {
    values.firstIndex(of: event)
  }

  fileprivate func count(of event: ServerEvent) -> Int {
    values.filter { $0 == event }.count
  }

  fileprivate var phoneLogBatches: [PhoneLogBatch] {
    values.compactMap { event in
      if case .phoneLog(let batch) = event { batch } else { nil }
    }
  }

  /// Every record delivered from phones, in delivery order.
  fileprivate var phoneRecords: [UplinkRecord] {
    phoneLogBatches.flatMap(\.records)
  }

  /// The delivered phone log entries in `category`.
  fileprivate func phoneEntries(category: String) -> [LogEntry] {
    phoneRecords.compactMap { record in
      if case .log(let entry) = record, entry.category == category { entry } else { nil }
    }
  }

  /// The server's own log entries.
  fileprivate var serverEntries: [LogEntry] {
    values.compactMap { event in
      if case .log(let entry) = event { entry } else { nil }
    }
  }
}

/// A log outbox with the serial queue it's confined to, which its client also runs on.
private final class TestOutbox: Sendable {
  let queue = DispatchQueue(label: "test.client")
  let outbox: LogOutbox

  init(byteLimit: Int = 16 * 1024 * 1024) {
    outbox = LogOutbox(byteLimit: byteLimit)
  }

  func enqueue(_ records: [UplinkRecord]) {
    queue.sync {
      for record in records {
        outbox.enqueue(record)
      }
    }
  }

  var stats: LogOutbox.Stats {
    queue.sync { outbox.stats }
  }
}

/// Records the test enqueues, told apart from the client's own `net` entries by their category.
private func testRecords(_ range: Range<Int>, nearLimitAt: Int? = nil) -> [UplinkRecord] {
  range.map { index in
    if index == nearLimitAt {
      // Kind byte and id, then the line: exactly `LogOutbox.maxRecordBytes` encoded.
      let line = Data(repeating: UInt8(ascii: "z"), count: LogOutbox.maxRecordBytes - 5)
      return .recordingLine(recordingID: 1, line: line)
    }
    switch index % 4 {
    case 0:
      return .log(
        LogEntry(level: .info, category: "test", event: "tick", fields: ["i": .int(index)]))
    case 1:
      return .recordingLine(recordingID: 1, line: Data(#"{"i":\#(index)}"#.utf8))
    case 2:
      return .log(
        LogEntry(
          level: .warning, category: "test", event: "note", message: "record \(index) “quoted”"))
    default:
      return .recordingLine(recordingID: 1, line: Data(repeating: UInt8(index % 256), count: 40))
    }
  }
}

extension UplinkRecord {
  /// False for the client's own entries, which share the stream with the test's records.
  fileprivate var isFromTest: Bool {
    if case .log(let entry) = self { entry.category != "net" } else { true }
  }
}

private struct WaitTimeout: Error, CustomStringConvertible {
  var description: String
}

/// Polls `condition` every 10 ms until it holds, failing the test with `description` on timeout.
private func waitUntil(
  _ description: @autoclosure () -> String,
  timeout: Duration = .seconds(5),
  condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  guard condition() else {
    throw WaitTimeout(description: "Timed out waiting for \(description())")
  }
}

/// Fails the test if `condition` becomes true within `duration`.
private func expectNever(
  _ description: String,
  for duration: Duration,
  condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + duration
  while ContinuousClock.now < deadline {
    if condition() {
      Issue.record("Unexpected: \(description)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private let macName = "Test Mac"

/// A client talking to the test server over loopback, with its status changes recorded.
private final class TestClient: Sendable {
  let client: SourisClient
  let deviceID: UUID
  let statuses = Recorder<ClientStatus>()

  init(
    port: UInt16,
    deviceID: UUID = UUID(),
    name: String = "Test Phone",
    outbox: TestOutbox? = nil,
    configure: (inout SourisClient.Configuration) -> Void = { _ in }
  ) {
    var configuration = SourisClient.Configuration(deviceID: deviceID, deviceName: name)
    configuration.target = .host("127.0.0.1", port: port)
    configuration.pingInterval = .milliseconds(40)
    configuration.helloInterval = .milliseconds(250)
    // Loopback has no Wi-Fi queue to protect, and the log tests push a lot of records.
    configuration.logBytesPerSecond = nil
    configure(&configuration)
    self.deviceID = deviceID
    let statuses = statuses
    client = SourisClient(
      configuration: configuration,
      queue: outbox?.queue ?? DispatchQueue(label: "test.client"),
      logOutbox: outbox?.outbox
    ) { statuses.append($0) }
  }

  var peer: PeerInfo {
    PeerInfo(deviceID: deviceID, name: client.configuration.deviceName)
  }

  func waitForStatus(_ expected: ClientStatus, timeout: Duration = .seconds(5)) async throws {
    try await waitUntil("client status \(expected) (now \(client.status))", timeout: timeout) {
      client.status == expected
    }
  }

  func send(cursorX: Double) {
    client.send(MouseState(cursor: SIMD2(cursorX, 0)))
  }
}

/// A bare UDP socket that speaks the protocol by hand, for cases a real client wouldn't produce.
private final class RawPeer: Sendable {
  let connection: NWConnection
  let received = Recorder<Packet>()

  init(port: UInt16) {
    connection = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: .udp)
    connection.start(queue: DispatchQueue(label: "test.raw-peer"))
    receiveNext()
  }

  private func receiveNext() {
    connection.receiveMessage { [self] data, _, _, error in
      if let data, let packet = try? Packet.decode(data) {
        received.append(packet)
      }
      if error == nil { receiveNext() }
    }
  }

  func send(_ packet: Packet) {
    sendRaw(packet.encoded())
  }

  func sendRaw(_ data: Data) {
    connection.send(content: data, completion: .idempotent)
  }

  func hello(deviceID: UUID, epoch: UInt16 = 1, name: String = "Raw Phone") {
    send(.hello(HelloPacket(epoch: epoch, deviceID: deviceID, deviceName: name)))
  }

  func state(epoch: UInt16 = 1, seq: UInt32, buttons: MouseButtons = []) {
    let state = MouseState(buttons: buttons)
    send(.state(StatePacket(epoch: epoch, seq: seq, phoneTimeMicros: 0, state: state)))
  }

  func welcomeCount(_ status: WelcomeStatus) -> Int {
    let welcome = Packet.welcome(WelcomePacket(status: status, macName: macName))
    return received.values.filter { $0 == welcome }.count
  }

  func hasWelcome(_ status: WelcomeStatus) -> Bool {
    welcomeCount(status) > 0
  }

  func cancel() {
    connection.cancel()
  }
}

/// A stand-in Mac that welcomes the first hello on each flow and then goes quiet.
private final class FakeMac: Sendable {
  private let listener: NWListener?
  private let queue = DispatchQueue(label: "test.fake-mac")
  private let connections = Recorder<NWConnection>()

  init() {
    listener = try? NWListener(using: .udp)
    listener?.newConnectionHandler = { [queue, connections] connection in
      connections.append(connection)
      connection.start(queue: queue)
      connection.receiveMessage { data, _, _, _ in
        guard let data, case .hello = try? Packet.decode(data) else { return }
        let welcome = WelcomePacket(status: .accepted, macName: macName)
        connection.send(content: Packet.welcome(welcome).encoded(), completion: .idempotent)
      }
    }
  }

  func start() async throws -> UInt16 {
    let listener = try #require(listener)
    listener.start(queue: queue)
    try await waitUntil("the fake Mac to listen") { (listener.port?.rawValue ?? 0) != 0 }
    return try #require(listener.port?.rawValue)
  }

  func stop() {
    listener?.cancel()
    for connection in connections.values {
      connection.cancel()
    }
  }
}

/// Forwards UDP between phones and a server, dropping some log packets and acks on the way.
private final class LossyProxy: Sendable {
  private let listener: NWListener?
  private let queue = DispatchQueue(label: "test.proxy")
  private let connections = Recorder<NWConnection>()
  private let counts = Mutex<(up: Int, down: Int)>((0, 0))
  let droppedUp = Recorder<Int>()
  let droppedDown = Recorder<Int>()

  /// Drops every `dropEveryUp`th log packet to the server and every `dropEveryDown`th log ack
  /// back.
  init(serverPort: UInt16, dropEveryUp: Int, dropEveryDown: Int) {
    listener = try? NWListener(using: .udp)
    listener?.newConnectionHandler = { [self] inbound in
      let outbound = NWConnection(
        host: "127.0.0.1", port: NWEndpoint.Port(rawValue: serverPort) ?? .any, using: .udp)
      connections.append(inbound)
      connections.append(outbound)
      inbound.start(queue: queue)
      outbound.start(queue: queue)
      forward(from: inbound, to: outbound, every: dropEveryUp, isUp: true)
      forward(from: outbound, to: inbound, every: dropEveryDown, isUp: false)
    }
  }

  private func forward(
    from source: NWConnection, to target: NWConnection, every: Int, isUp: Bool
  ) {
    source.receiveMessage { [self] data, _, _, error in
      if let data {
        if shouldDrop(data, every: every, isUp: isUp) {
          (isUp ? droppedUp : droppedDown).append(data.count)
        } else {
          target.send(content: data, completion: .idempotent)
        }
      }
      if error == nil { forward(from: source, to: target, every: every, isUp: isUp) }
    }
  }

  private func shouldDrop(_ data: Data, every: Int, isUp: Bool) -> Bool {
    switch try? Packet.decode(data) {
    case .log where isUp, .logAck where !isUp:
      return counts.withLock { counts in
        if isUp {
          counts.up += 1
          return counts.up.isMultiple(of: every)
        }
        counts.down += 1
        return counts.down.isMultiple(of: every)
      }
    default:
      return false
    }
  }

  func start() async throws -> UInt16 {
    let listener = try #require(listener)
    listener.start(queue: queue)
    try await waitUntil("the proxy to listen") { (listener.port?.rawValue ?? 0) != 0 }
    return try #require(listener.port?.rawValue)
  }

  func stop() {
    listener?.cancel()
    for connection in connections.values {
      connection.cancel()
    }
  }
}

/// A stand-in for the Mac's USB bridge: connects to the client's USB port over loopback TCP,
/// with the same framing, and welcomes every hello as `usbMacName`.
private final class FakeUSBMac: Sendable {
  static let macName = "USB Mac"

  let connection: NWConnection
  let received = Recorder<Packet>()

  init(port: UInt16) {
    let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
    parameters.defaultProtocolStack.applicationProtocols.insert(LengthPrefixFramer.options, at: 0)
    connection = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: parameters)
    connection.start(queue: DispatchQueue(label: "test.usb-mac"))
    receiveNext()
  }

  private func receiveNext() {
    connection.receiveMessage { [self] data, _, _, error in
      if let data, let packet = try? Packet.decode(data) {
        received.append(packet)
        if case .hello = packet {
          let welcome = WelcomePacket(status: .accepted, macName: Self.macName)
          connection.send(content: Packet.welcome(welcome).encoded(), completion: .idempotent)
        }
      }
      if error == nil, !(data?.isEmpty ?? true) { receiveNext() }
    }
  }

  var states: [StatePacket] {
    received.values.compactMap { if case .state(let state) = $0 { state } else { nil } }
  }

  func cancel() {
    connection.cancel()
  }
}

/// A server on a free loopback port, with its events recorded.
private final class TestServer: Sendable {
  let server: SourisServer
  let events = Recorder<ServerEvent>()

  init(
    approved: Set<UUID> = [],
    port: UInt16 = 0,
    configure: (inout SourisServer.Configuration) -> Void = { _ in }
  ) {
    var configuration = SourisServer.Configuration(macName: macName)
    configuration.port = port
    configuration.advertisesBonjour = false
    configure(&configuration)
    let events = events
    server = SourisServer(
      configuration: configuration, queue: DispatchQueue(label: "test.server")
    ) { events.append($0) }
    server.approvedDevices = approved
  }

  /// Starts the server and returns the port it listens on.
  func start() async throws -> UInt16 {
    server.start()
    try await waitUntil("the server to listen") { server.port != nil }
    return try #require(server.port)
  }
}

// MARK: - Tests

@Suite("Transport", .serialized)
struct TransportTests {
  // MARK: Approval

  @Test func unknownDeviceRequestsApprovalAndTheClientWaits() async throws {
    let server = TestServer()
    let port = try await server.start()
    let client = TestClient(port: port)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await waitUntil("approvalRequested") {
      server.events.contains(.approvalRequested(client.peer))
    }
    try await client.waitForStatus(.waitingForApproval(macName: macName))
    #expect(server.server.approvedDevices.isEmpty)
  }

  @Test func approvingConnectsTheClient() async throws {
    let server = TestServer()
    let port = try await server.start()
    let client = TestClient(port: port)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await waitUntil("approvalRequested") {
      server.events.contains(.approvalRequested(client.peer))
    }
    server.server.resolveApproval(for: client.deviceID, approved: true)
    try await client.waitForStatus(.connected(macName: macName))
    #expect(server.server.approvedDevices == [client.deviceID])
  }

  @Test func denyingRefusesTheClient() async throws {
    let server = TestServer()
    let port = try await server.start()
    let client = TestClient(port: port)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await waitUntil("approvalRequested") {
      server.events.contains(.approvalRequested(client.peer))
    }
    server.server.resolveApproval(for: client.deviceID, approved: false)
    try await client.waitForStatus(.denied(macName: macName))
    #expect(server.server.approvedDevices.isEmpty)

    // A later hello must keep getting denied, and not ask again.
    try await Task.sleep(for: .milliseconds(600))
    #expect(client.client.status == .denied(macName: macName))
    #expect(server.events.count(of: .approvalRequested(client.peer)) == 1)
  }

  @Test func approvalIsRequestedOncePerDeviceUntilResolved() async throws {
    let server = TestServer()
    let port = try await server.start()
    let peer = RawPeer(port: port)
    let deviceID = UUID()
    defer {
      peer.cancel()
      server.server.stop()
    }

    for _ in 0..<3 {
      peer.hello(deviceID: deviceID, name: "Raw Phone")
    }
    try await waitUntil("three pending welcomes") {
      let pending = WelcomePacket(status: .pending, macName: macName)
      return peer.received.values.filter { $0 == .welcome(pending) }.count == 3
    }
    let request = ServerEvent.approvalRequested(PeerInfo(deviceID: deviceID, name: "Raw Phone"))
    #expect(server.events.count(of: request) == 1)
  }

  @Test func resolvingApprovalAnswersWithoutWaitingForTheNextHello() async throws {
    let server = TestServer()
    let port = try await server.start()
    let peer = RawPeer(port: port)
    let deviceID = UUID()
    defer {
      peer.cancel()
      server.server.stop()
    }

    peer.hello(deviceID: deviceID)
    try await waitUntil("the pending welcome") { peer.hasWelcome(.pending) }
    server.server.resolveApproval(for: deviceID, approved: true)
    try await waitUntil("the accepted welcome") { peer.hasWelcome(.accepted) }
  }

  @Test func deniedControllerIsDropped() async throws {
    let device = UUID()
    let server = TestServer(approved: [device])
    let port = try await server.start()
    let peer = RawPeer(port: port)
    defer {
      peer.cancel()
      server.server.stop()
    }

    peer.hello(deviceID: device)
    peer.state(seq: 1)
    let info = PeerInfo(deviceID: device, name: "Raw Phone")
    try await waitUntil("the controller") { server.events.contains(.controllerChanged(info)) }
    server.server.resolveApproval(for: device, approved: false)
    try await waitUntil("the controller to be dropped") {
      server.events.contains(.controllerChanged(nil))
    }
    try await waitUntil("a denied welcome") { peer.hasWelcome(.denied) }
    #expect(server.server.approvedDevices.isEmpty)
  }

  // MARK: Control and state

  @Test func statesArriveInOrderWithTheirValues() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))

    for i in 1...20 {
      let state = MouseState(
        buttons: i.isMultiple(of: 2) ? [.left] : [.right],
        flags: [.scrollActive],
        cursor: SIMD2(Double(i), -Double(i)),
        scroll: SIMD2(0.5, Double(i) * 2))
      client.client.send(state)
      try await Task.sleep(for: .milliseconds(8))
    }
    try await waitUntil("the last state") { server.events.states.last?.state.cursor.x == 20 }

    let states = server.events.states
    let epoch = try #require(states.first?.epoch)
    var previousSeq: UInt32 = 0
    for packet in states {
      #expect(packet.epoch == epoch)
      #expect(packet.seq > previousSeq)
      previousSeq = packet.seq

      let i = Int(packet.state.cursor.x)
      #expect((1...20).contains(i))
      #expect(packet.state.cursor.y == -Double(i))
      #expect(packet.state.scroll == SIMD2(0.5, Double(i) * 2))
      #expect(packet.state.flags == [.scrollActive])
      #expect(packet.state.buttons == (i.isMultiple(of: 2) ? [.left] : [.right]))
    }

    let events = server.events.values
    let changed = try #require(events.firstIndex(of: .controllerChanged(client.peer)))
    let firstState = try #require(events.firstIndex { if case .state = $0 { true } else { false } })
    #expect(changed < firstState)
  }

  @Test func burstOfSendsEndsWithTheLastStateAndIncreasingSequenceNumbers() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))

    for i in 1...1000 {
      client.send(cursorX: Double(i))
    }
    try await waitUntil("the last state of the burst") {
      server.events.states.last?.state.cursor.x == 1000
    }

    let states = server.events.states
    #expect(states.count <= 1000)
    var previousSeq: UInt32 = 0
    var previousX = 0.0
    for packet in states {
      #expect(packet.seq > previousSeq)
      #expect(packet.state.cursor.x >= previousX)
      previousSeq = packet.seq
      previousX = packet.state.cursor.x
    }
  }

  @Test func idleClientKeepsResendingTheLatestState() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    client.send(cursorX: 42)

    try await waitUntil("ten keepalives") { server.events.states.count >= 10 }
    let states = server.events.states
    #expect(states.allSatisfy { $0.state.cursor.x == 42 })
    #expect(zip(states, states.dropFirst()).allSatisfy { $0.seq < $1.seq })

    try await waitUntil("a send rate") { client.client.stats.packetsPerSecond > 5 }
    #expect(client.client.stats.packetsPerSecond < 100)
  }

  @Test func nothingIsSentBeforeApproval() async throws {
    let server = TestServer()
    let port = try await server.start()
    let client = TestClient(port: port)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    client.send(cursorX: 1)
    try await client.waitForStatus(.waitingForApproval(macName: macName))
    client.send(cursorX: 2)
    try await Task.sleep(for: .milliseconds(300))
    #expect(server.events.states.isEmpty)

    server.server.resolveApproval(for: client.deviceID, approved: true)
    try await client.waitForStatus(.connected(macName: macName))
    try await waitUntil("the held state to be sent") {
      server.events.states.last?.state.cursor.x == 2
    }
  }

  @Test func statesFromAnUnapprovedOrUnintroducedPeerAreIgnored() async throws {
    let approved = UUID()
    let server = TestServer(approved: [approved])
    let port = try await server.start()
    let stranger = RawPeer(port: port)
    let anonymous = RawPeer(port: port)
    defer {
      stranger.cancel()
      anonymous.cancel()
      server.server.stop()
    }

    stranger.hello(deviceID: UUID())
    stranger.state(seq: 1, buttons: .left)
    anonymous.state(seq: 1, buttons: .left)
    try await expectNever("a state or controller from an ignored peer", for: .milliseconds(300)) {
      server.events.values.contains { event in
        switch event {
        case .state, .controllerChanged: true
        default: false
        }
      }
    }
  }

  @Test func garbageDatagramsAreIgnored() async throws {
    let device = UUID()
    let server = TestServer(approved: [device])
    let port = try await server.start()
    let peer = RawPeer(port: port)
    defer {
      peer.cancel()
      server.server.stop()
    }

    peer.sendRaw(Data())
    peer.sendRaw(Data([1, 2, 3]))
    peer.sendRaw(Data(repeating: 0xFF, count: 200))
    peer.sendRaw(Data([0x52, 0x53, 0x01, 0x06, 0x09]))
    peer.hello(deviceID: device)
    try await waitUntil("the accepted welcome after the garbage") { peer.hasWelcome(.accepted) }
  }

  // MARK: Ping and pong

  @Test func pingAndPongMeasureRoundTripTime() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    try await waitUntil("round-trip statistics") {
      let stats = client.client.stats
      return stats.rttMedianMs != nil && stats.rttMaxMs != nil
    }

    let stats = client.client.stats
    let median = try #require(stats.rttMedianMs)
    let maximum = try #require(stats.rttMaxMs)
    #expect(median >= 0 && median < 500)
    #expect(maximum >= median)
    #expect(stats.pingLoss == 0)
  }

  @Test func unapprovedPeersGetNoPongUntilApproved() async throws {
    let server = TestServer()
    let port = try await server.start()
    let peer = RawPeer(port: port)
    let deviceID = UUID()
    defer {
      peer.cancel()
      server.server.stop()
    }

    func hasPong() -> Bool {
      peer.received.values.contains { if case .pong = $0 { true } else { false } }
    }

    peer.hello(deviceID: deviceID)
    peer.send(.ping(PingPacket(id: 1, phoneTimeMicros: 111)))
    try await expectNever("a pong for an unapproved peer", for: .milliseconds(300)) {
      hasPong()
    }

    server.server.resolveApproval(for: deviceID, approved: true)
    peer.send(.ping(PingPacket(id: 2, phoneTimeMicros: 222)))
    try await waitUntil("a pong") {
      peer.received.values.contains { packet in
        guard case .pong(let pong) = packet else { return false }
        return pong.id == 2 && pong.phoneTimeMicros == 222
      }
    }
  }

  // MARK: Leaving and silence

  @Test func stoppingTheClientReleasesTheController() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone)
    defer { server.server.stop() }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    client.send(cursorX: 1)
    try await waitUntil("the controller") {
      server.events.contains(.controllerChanged(client.peer))
    }

    client.client.stop()
    try await waitUntil("the controller to be dropped") {
      server.events.contains(.controllerChanged(nil))
    }
    let silent = try #require(server.events.index(of: .controllerSilent))
    let dropped = try #require(server.events.index(of: .controllerChanged(nil)))
    #expect(silent < dropped)
    #expect(client.client.status == .stopped)
    #expect(client.statuses.values.last == .stopped)
  }

  @Test func silentPhoneIsReportedOnceAndStaysTheController() async throws {
    let device = UUID()
    let server = TestServer(approved: [device])
    let port = try await server.start()
    let peer = RawPeer(port: port)
    defer {
      peer.cancel()
      server.server.stop()
    }

    peer.hello(deviceID: device)
    peer.state(seq: 1)
    let info = PeerInfo(deviceID: device, name: "Raw Phone")
    try await waitUntil("the controller") { server.events.contains(.controllerChanged(info)) }

    let silentSince = ContinuousClock.now
    try await waitUntil("controllerSilent", timeout: .seconds(3)) {
      server.events.contains(.controllerSilent)
    }
    let elapsed = ContinuousClock.now - silentSince
    #expect(elapsed >= .milliseconds(500))
    #expect(elapsed <= .seconds(2))

    try await Task.sleep(for: .milliseconds(500))
    #expect(server.events.count(of: .controllerSilent) == 1)
    #expect(!server.events.contains(.controllerChanged(nil)))

    peer.state(seq: 2)
    try await waitUntil("state after the silence") { server.events.states.count == 2 }
    try await Task.sleep(for: .milliseconds(1000))
    #expect(server.events.count(of: .controllerSilent) == 2)
  }

  @Test func byeFromAnOldEpochDoesNotDropTheController() async throws {
    let device = UUID()
    let server = TestServer(approved: [device])
    let port = try await server.start()
    let peer = RawPeer(port: port)
    defer {
      peer.cancel()
      server.server.stop()
    }

    peer.hello(deviceID: device, epoch: 5)
    peer.state(epoch: 5, seq: 1)
    let info = PeerInfo(deviceID: device, name: "Raw Phone")
    try await waitUntil("the controller") { server.events.contains(.controllerChanged(info)) }

    peer.send(.bye(ByePacket(epoch: 4)))
    try await expectNever("a drop from a stale bye", for: .milliseconds(300)) {
      server.events.contains(.controllerChanged(nil))
    }
    peer.send(.bye(ByePacket(epoch: 5)))
    try await waitUntil("the drop from a matching bye") {
      server.events.contains(.controllerChanged(nil))
    }
  }

  // MARK: Several phones

  @Test func secondApprovedPhoneIsBusyUntilTheFirstLeaves() async throws {
    let first = UUID()
    let second = UUID()
    let server = TestServer(approved: [first, second])
    let port = try await server.start()
    let firstClient = TestClient(port: port, deviceID: first, name: "First")
    let secondClient = TestClient(port: port, deviceID: second, name: "Second")
    defer {
      firstClient.client.stop()
      secondClient.client.stop()
      server.server.stop()
    }

    firstClient.client.start()
    try await firstClient.waitForStatus(.connected(macName: macName))
    firstClient.send(cursorX: 1)
    try await waitUntil("the first controller") {
      server.events.contains(.controllerChanged(firstClient.peer))
    }

    secondClient.client.start()
    secondClient.send(cursorX: 99)
    try await secondClient.waitForStatus(.busy(macName: macName))
    try await Task.sleep(for: .milliseconds(300))
    #expect(secondClient.client.status == .busy(macName: macName))
    #expect(!server.events.states.contains { $0.state.cursor.x == 99 })
    #expect(!server.events.contains(.controllerChanged(secondClient.peer)))

    firstClient.client.stop()
    try await secondClient.waitForStatus(.connected(macName: macName))
    secondClient.send(cursorX: 100)
    try await waitUntil("the second controller") {
      server.events.contains(.controllerChanged(secondClient.peer))
    }
  }

  @Test func silentControllerIsReplacedByAnotherApprovedPhone() async throws {
    let first = UUID()
    let second = UUID()
    let server = TestServer(approved: [first, second]) { $0.silenceTimeout = .milliseconds(400) }
    let port = try await server.start()
    let ghost = RawPeer(port: port)
    let client = TestClient(port: port, deviceID: second, name: "Second")
    defer {
      ghost.cancel()
      client.client.stop()
      server.server.stop()
    }

    ghost.hello(deviceID: first)
    ghost.state(seq: 1)
    let ghostInfo = PeerInfo(deviceID: first, name: "Raw Phone")
    try await waitUntil("the first controller") {
      server.events.contains(.controllerChanged(ghostInfo))
    }

    client.client.start()
    client.send(cursorX: 7)
    try await client.waitForStatus(.connected(macName: macName), timeout: .seconds(3))
    try await waitUntil("the takeover") { server.events.contains(.controllerChanged(client.peer)) }

    let silent = try #require(server.events.index(of: .controllerSilent))
    let takeover = try #require(server.events.index(of: .controllerChanged(client.peer)))
    #expect(silent < takeover)
    try await waitUntil("the new controller's state") {
      server.events.states.last?.state.cursor.x == 7
    }
  }

  @Test func disconnectingKicksTheSessionUntilTheClientStartsOver() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    client.send(cursorX: 1)
    try await waitUntil("the controller") {
      server.events.contains(.controllerChanged(client.peer))
    }
    let firstEpoch = try #require(server.events.states.last?.epoch)

    server.server.disconnectController()
    try await waitUntil("the controller to be dropped") {
      server.events.contains(.controllerChanged(nil))
    }
    let silent = try #require(server.events.index(of: .controllerSilent))
    let dropped = try #require(server.events.index(of: .controllerChanged(nil)))
    #expect(silent < dropped)
    try await client.waitForStatus(.disconnected(macName: macName))

    // Hellos keep flowing, so the status holds, but the session stays off.
    let statesAtKick = server.events.states.count
    client.send(cursorX: 5)
    try await Task.sleep(for: .milliseconds(800))
    #expect(client.client.status == .disconnected(macName: macName))
    #expect(server.events.states.count == statesAtKick)
    #expect(server.events.count(of: .controllerChanged(client.peer)) == 1)

    // A new session has a new epoch, which clears the kick.
    client.client.stop()
    try await client.waitForStatus(.stopped)
    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    client.send(cursorX: 6)
    try await waitUntil("a state from the new session") {
      server.events.states.last?.state.cursor.x == 6
    }
    #expect(server.events.states.last?.epoch != firstEpoch)
    #expect(server.events.count(of: .controllerChanged(client.peer)) == 2)
  }

  @Test func kickedSessionIsIgnoredUntilTheEpochChanges() async throws {
    let device = UUID()
    let server = TestServer(approved: [device])
    let port = try await server.start()
    let peer = RawPeer(port: port)
    defer {
      peer.cancel()
      server.server.stop()
    }

    peer.hello(deviceID: device, epoch: 5)
    peer.state(epoch: 5, seq: 1)
    let info = PeerInfo(deviceID: device, name: "Raw Phone")
    try await waitUntil("the controller") { server.events.contains(.controllerChanged(info)) }
    #expect(peer.welcomeCount(.accepted) == 1)

    // The kick is announced without waiting for the next hello.
    server.server.disconnectController()
    try await waitUntil("the disconnected welcome") { peer.welcomeCount(.disconnected) == 1 }

    peer.hello(deviceID: device, epoch: 5)
    try await waitUntil("another disconnected welcome") { peer.welcomeCount(.disconnected) == 2 }

    peer.state(epoch: 5, seq: 2)
    peer.send(.ping(PingPacket(id: 1, phoneTimeMicros: 1)))
    try await expectNever("input from the kicked session", for: .milliseconds(300)) {
      let pong = peer.received.values.contains { if case .pong = $0 { true } else { false } }
      return pong || server.events.states.count > 1
        || server.events.count(of: .controllerChanged(info)) > 1
    }
    #expect(peer.welcomeCount(.accepted) == 1)

    // A hello from a new epoch is a new session and is welcomed as usual.
    peer.hello(deviceID: device, epoch: 6)
    try await waitUntil("an accepted welcome") { peer.welcomeCount(.accepted) == 2 }
    peer.state(epoch: 6, seq: 1)
    try await waitUntil("control to return") {
      server.events.count(of: .controllerChanged(info)) == 2
    }
    #expect(server.events.states.last?.epoch == 6)
  }

  @Test func kickDoesNotAffectOtherPhones() async throws {
    let first = UUID()
    let second = UUID()
    let server = TestServer(approved: [first, second])
    let port = try await server.start()
    let firstPeer = RawPeer(port: port)
    let secondClient = TestClient(port: port, deviceID: second, name: "Second")
    defer {
      firstPeer.cancel()
      secondClient.client.stop()
      server.server.stop()
    }

    firstPeer.hello(deviceID: first, epoch: 3)
    firstPeer.state(epoch: 3, seq: 1)
    let firstInfo = PeerInfo(deviceID: first, name: "Raw Phone")
    try await waitUntil("the first controller") {
      server.events.contains(.controllerChanged(firstInfo))
    }
    server.server.disconnectController()
    try await waitUntil("the kick") { firstPeer.welcomeCount(.disconnected) == 1 }

    secondClient.client.start()
    try await secondClient.waitForStatus(.connected(macName: macName))
    secondClient.send(cursorX: 9)
    try await waitUntil("the second controller") {
      server.events.contains(.controllerChanged(secondClient.peer))
    }
  }

  // MARK: Client lifecycle

  @Test func eachStartUsesANewEpoch() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone)
    defer {
      client.client.stop()
      server.server.stop()
    }

    var epochs: [UInt16] = []
    for round in 1...3 {
      client.client.start()
      try await client.waitForStatus(.connected(macName: macName))
      client.send(cursorX: Double(round))
      try await waitUntil("a state in round \(round)") {
        server.events.states.last?.state.cursor.x == Double(round)
      }
      epochs.append(try #require(server.events.states.last?.epoch))
      client.client.stop()
      try await client.waitForStatus(.stopped)
      try await waitUntil("the controller to be released") {
        server.events.count(of: .controllerChanged(nil)) == round
      }
    }
    #expect(epochs[0] != epochs[1])
    #expect(epochs[1] != epochs[2])
    #expect(Set(epochs).count >= 2)
  }

  @Test func silentMacMakesTheClientNotRespondingThenReconnect() async throws {
    let mac = FakeMac()
    let port = try await mac.start()
    let client = TestClient(port: port) {
      $0.notRespondingTimeout = .milliseconds(400)
      $0.reconnectTimeout = .milliseconds(900)
    }
    defer {
      client.client.stop()
      mac.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    try await client.waitForStatus(.notResponding(macName: macName), timeout: .seconds(3))
    // The reconnect opens a fresh flow, which the fake Mac welcomes again.
    try await waitUntil("a second connected status", timeout: .seconds(3)) {
      client.statuses.values.filter { $0 == .connected(macName: macName) }.count == 2
    }
    let expected: [ClientStatus] = [
      .connecting,
      .connected(macName: macName),
      .notResponding(macName: macName),
      .connecting,
    ]
    #expect(Array(client.statuses.values.prefix(4)) == expected)
  }

  @Test func clientRecoversWhenTheMacRestartsOnTheSamePort() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let client = TestClient(port: port, deviceID: phone) {
      $0.notRespondingTimeout = .milliseconds(300)
      $0.reconnectTimeout = .milliseconds(900)
    }
    defer { client.client.stop() }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    client.send(cursorX: 1)
    try await waitUntil("a state") { !server.events.states.isEmpty }

    server.server.stop()
    try await waitUntil("the server to stop") { server.events.contains(.stateChanged(.stopped)) }
    try await Task.sleep(for: .milliseconds(200))

    let restarted = TestServer(approved: [phone], port: port)
    defer { restarted.server.stop() }
    let newPort = try await restarted.start()
    #expect(newPort == port)

    try await waitUntil("the client to reach the new server", timeout: .seconds(6)) {
      client.client.status == .connected(macName: macName)
        && restarted.events.contains(.approvalRequested(client.peer)) == false
    }
    client.send(cursorX: 2)
    try await waitUntil("a state at the new server", timeout: .seconds(3)) {
      restarted.events.states.last?.state.cursor.x == 2
    }
  }

  // MARK: Server lifecycle

  @Test func serverReportsItsLifecycle() async throws {
    let server = TestServer()
    let port = try await server.start()
    #expect(server.events.values.first == .stateChanged(.starting))
    #expect(server.events.contains(.stateChanged(.listening(port: port))))

    server.server.stop()
    try await waitUntil("stopped") { server.events.contains(.stateChanged(.stopped)) }
    #expect(server.server.port == nil)

    let again = try await server.start()
    #expect(again != 0)
    server.server.stop()
  }

  @Test func busyPortFallsBackToAnotherPort() async throws {
    let first = TestServer()
    let taken = try await first.start()
    let second = TestServer(port: taken)
    defer {
      second.server.stop()
      first.server.stop()
    }

    let fallback = try await second.start()
    #expect(fallback != taken)
    #expect(second.events.contains(.stateChanged(.listening(port: fallback))))
    let failures = second.events.values.filter { event in
      if case .stateChanged(.failed) = event { true } else { false }
    }
    #expect(failures.isEmpty)
  }

  // MARK: Logs

  @Test func approvedPhoneDeliversEveryLogRecordInOrderExactlyOnce() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let outbox = TestOutbox()
    let client = TestClient(port: port, deviceID: phone, outbox: outbox)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    let started = UplinkRecord.recordingStarted(recordingID: 1, name: "loopback")
    let records =
      [started] + testRecords(0..<2000, nearLimitAt: 1000) + [.recordingEnded(recordingID: 1)]
    for chunk in stride(from: 0, to: records.count, by: 250) {
      outbox.enqueue(Array(records[chunk..<min(chunk + 250, records.count)]))
      try await Task.sleep(for: .milliseconds(20))
    }

    try await waitUntil("every record", timeout: .seconds(15)) {
      server.events.phoneRecords.filter(\.isFromTest).count >= records.count
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(server.events.phoneRecords.filter(\.isFromTest) == records)
    #expect(server.events.phoneLogBatches.allSatisfy { $0.missingBefore == 0 })
    #expect(server.events.phoneLogBatches.allSatisfy { $0.peer == client.peer })
    #expect(Set(server.events.phoneLogBatches.map(\.streamID)) == [outbox.outbox.streamID])
    try await waitUntil("the outbox to empty") { outbox.stats.queuedRecords == 0 }
  }

  @Test func logRecordsSurviveLostPacketsAndAcks() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let serverPort = try await server.start()
    let proxy = LossyProxy(serverPort: serverPort, dropEveryUp: 10, dropEveryDown: 7)
    let port = try await proxy.start()
    let outbox = TestOutbox()
    let client = TestClient(port: port, deviceID: phone, outbox: outbox)
    defer {
      client.client.stop()
      proxy.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    let records = testRecords(0..<120)
    outbox.enqueue(records)
    try await waitUntil("every record despite the loss", timeout: .seconds(15)) {
      server.events.phoneRecords.filter(\.isFromTest).count >= records.count
    }
    #expect(server.events.phoneRecords.filter(\.isFromTest) == records)
    #expect(!proxy.droppedUp.values.isEmpty)
    #expect(!proxy.droppedDown.values.isEmpty)
    #expect(outbox.stats.retransmits > 0)
  }

  @Test func recordsQueuedBeforeConnectingAreDeliveredAfterAndCarryAcrossClients()
    async throws
  {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let outbox = TestOutbox()
    defer { server.server.stop() }

    let early = testRecords(0..<50)
    outbox.enqueue(early)
    let first = TestClient(port: port, deviceID: phone, outbox: outbox)
    first.client.start()
    try await waitUntil("the early records") {
      server.events.phoneRecords.filter(\.isFromTest) == early
    }
    first.client.stop()
    try await first.waitForStatus(.stopped)

    // Logged while no client exists, then sent by the next client from the same outbox.
    let between = testRecords(50..<80)
    outbox.enqueue(between)
    let second = TestClient(port: port, deviceID: phone, outbox: outbox)
    defer { second.client.stop() }
    second.client.start()
    try await waitUntil("the records logged between clients") {
      server.events.phoneRecords.filter(\.isFromTest) == early + between
    }
    #expect(server.events.phoneLogBatches.allSatisfy { $0.missingBefore == 0 })
  }

  @Test func pendingPhoneLogsWaitForApproval() async throws {
    let server = TestServer()
    let port = try await server.start()
    let outbox = TestOutbox()
    let client = TestClient(port: port, outbox: outbox)
    defer {
      client.client.stop()
      server.server.stop()
    }

    let records = testRecords(0..<20)
    outbox.enqueue(records)
    client.client.start()
    try await client.waitForStatus(.waitingForApproval(macName: macName))
    try await expectNever("logs from a pending phone", for: .milliseconds(300)) {
      !server.events.phoneLogBatches.isEmpty
    }

    server.server.resolveApproval(for: client.deviceID, approved: true)
    try await waitUntil("the held records after approval") {
      server.events.phoneRecords.filter(\.isFromTest) == records
    }
  }

  @Test func logsOnAFlowWithoutAnApprovedHelloAreIgnoredAndLogged() async throws {
    let server = TestServer()
    let port = try await server.start()
    let peer = RawPeer(port: port)
    defer {
      peer.cancel()
      server.server.stop()
    }

    let packet = LogPacket(stream: 1, oldestID: 1, firstID: 1, records: testRecords(0..<3))
    peer.send(.log(packet))
    peer.hello(deviceID: UUID())
    peer.send(.log(packet))
    try await waitUntil("a server entry about the ignored log") {
      server.events.serverEntries.contains { $0.event == "ignoredLog" }
    }
    #expect(server.events.phoneLogBatches.isEmpty)
    #expect(!peer.received.values.contains { if case .logAck = $0 { true } else { false } })
  }

  @Test func statusChangeIsLoggedOnBothEnds() async throws {
    let server = TestServer()
    let port = try await server.start()
    let outbox = TestOutbox()
    let client = TestClient(port: port, outbox: outbox)
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await waitUntil("approvalRequested") {
      server.events.contains(.approvalRequested(client.peer))
    }
    server.server.resolveApproval(for: client.deviceID, approved: true)
    try await client.waitForStatus(.connected(macName: macName))

    try await waitUntil("the client's status entry for connecting") {
      server.events.phoneEntries(category: "net").contains { entry in
        entry.event == "status" && entry.fields["from"] == "waitingForApproval"
          && entry.fields["to"] == "connected" && entry.fields["detail"] == .string(macName)
      }
    }
    let netEvents = Set(server.events.phoneEntries(category: "net").map(\.event))
    #expect(netEvents.isSuperset(of: ["start", "target", "connection", "path", "welcome"]))

    let serverEntries = server.events.serverEntries
    #expect(serverEntries.allSatisfy { $0.category == "server" })
    let serverEvents = Set(serverEntries.map(\.event))
    #expect(
      serverEvents.isSuperset(of: ["listener", "flowOpened", "hello", "approvalRequested"]))
    #expect(
      serverEntries.contains { entry in
        entry.event == "approvalResolved" && entry.fields["approved"] == true
      })
    #expect(
      serverEntries.contains { entry in
        entry.event == "welcome" && entry.fields["status"] == "accepted"
          && entry.fields["previous"] == "pending"
      })

    try await waitUntil("a link summary", timeout: .seconds(3)) {
      server.events.phoneEntries(category: "net").contains { $0.event == "link" }
    }
    let link = try #require(
      server.events.phoneEntries(category: "net").first { $0.event == "link" })
    #expect(link.fields["pingsSent"] != nil)
    #expect(link.fields["logQueued"] != nil)
  }

  // MARK: USB

  @Test func aMacOnTheUSBPortTakesOverAndClosingItFallsBackToWiFi() async throws {
    let phone = UUID()
    let server = TestServer(approved: [phone])
    let port = try await server.start()
    let usbPort = UInt16.random(in: 50_000...59_000)
    let client = TestClient(port: port, deviceID: phone) { configuration in
      configuration.listensForUSB = true
      configuration.usbPort = usbPort
    }
    defer {
      client.client.stop()
      server.server.stop()
    }

    client.client.start()
    try await client.waitForStatus(.connected(macName: macName))
    #expect(!client.client.stats.isUSB)

    // The USB listener started with the client, so it is up by the time Wi-Fi has connected.
    let usbMac = FakeUSBMac(port: usbPort)
    try await client.waitForStatus(.connected(macName: FakeUSBMac.macName))
    #expect(client.client.stats.isUSB)

    client.send(cursorX: 42)
    try await waitUntil("a state over USB") {
      usbMac.states.contains { $0.state.cursor.x == 42 }
    }

    usbMac.cancel()
    try await client.waitForStatus(.connected(macName: macName))
    #expect(!client.client.stats.isUSB)
  }

  @Test func withoutListensForUSBNothingListens() async throws {
    let server = TestServer(approved: [])
    let port = try await server.start()
    let usbPort = UInt16.random(in: 50_000...59_000)
    let client = TestClient(port: port) { $0.usbPort = usbPort }
    defer {
      client.client.stop()
      server.server.stop()
    }
    client.client.start()
    let usbMac = FakeUSBMac(port: usbPort)
    defer { usbMac.cancel() }
    try await expectNever("a hello on the USB port", for: .milliseconds(500)) {
      !usbMac.received.values.isEmpty
    }
  }
}
