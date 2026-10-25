import Foundation
import Network
import Synchronization

/// A phone that has said hello to the Mac.
public struct PeerInfo: Hashable, Sendable {
  public var deviceID: UUID
  public var name: String

  public init(deviceID: UUID, name: String) {
    self.deviceID = deviceID
    self.name = name
  }
}

/// The Mac listener's lifecycle.
public enum ServerState: Equatable, Sendable {
  case stopped
  case starting
  case listening(port: UInt16)
  case failed(String)
}

/// New records from one phone's log stream, in id order, each delivered exactly once.
public struct PhoneLogBatch: Equatable, Sendable {
  public var peer: PeerInfo

  /// The phone's stream id, new on every launch of the phone app.
  public var streamID: UInt32

  public var records: [UplinkRecord]

  /// Records the phone dropped before it could send them (its queue was full). They come right
  /// before `records` in the stream and will never arrive. `records` may be empty when this isn't
  /// zero.
  public var missingBefore: Int

  public init(peer: PeerInfo, streamID: UInt32, records: [UplinkRecord], missingBefore: Int) {
    self.peer = peer
    self.streamID = streamID
    self.records = records
    self.missingBefore = missingBefore
  }
}

/// What the server reports to the Mac app. Always delivered on the server's queue.
public enum ServerEvent: Equatable, Sendable {
  case stateChanged(ServerState)

  /// A phone that isn't approved or denied said hello. Reported once per device until resolved.
  case approvalRequested(PeerInfo)

  /// The phone allowed to move the pointer changed, or `nil` when none is.
  case controllerChanged(PeerInfo?)

  /// A state packet from the controlling phone. Packets from other phones are never reported.
  case state(StatePacket)

  /// The controlling phone sent nothing for `silenceTimeout`, or said bye. Release every held
  /// button. It stays the controller and resumes when packets return.
  case controllerSilent

  /// Log records from an approved phone, to write to the phone's log files.
  case phoneLog(PhoneLogBatch)

  /// An entry for the Mac's own diagnostic log, category `"server"`.
  case log(LogEntry)
}

/// The Mac end of the link: a UDP listener, advertised over Bonjour.
///
/// - A hello from an approved device gets `welcome(accepted)`; from a denied device,
///   `welcome(denied)`; from an unknown device, `welcome(pending)` plus `approvalRequested`.
/// - The first approved device to send a state packet becomes the controller. Another approved
///   device takes over only when the controller has been silent for `silenceTimeout`; until then
///   it gets `welcome(busy)` and its state packets are ignored.
/// - Every ping from an approved device gets an immediate pong on the same connection.
/// - `disconnectController()` kicks the controller's current session: that device and epoch get
///   `welcome(disconnected)` and are ignored until the phone starts a new session.
/// - Connections silent for `idleConnectionTimeout` are cancelled.
/// - Log packets are accepted only on flows whose hello came from an approved device, kicked or
///   not. Each one gets a `logAck` and its new records are reported as `phoneLog`, following
///   `LogInbox`'s rules. Receive state per device survives `stop()` and `start()`.
/// - The server's own diagnostics arrive as `log` events. Events that can repeat per packet are
///   logged once and then counted per second.
///
/// Thread safety: every method may be called from any thread. Events arrive on `queue`, which is
/// also where packets are received and replied to.
public final class SourisServer: @unchecked Sendable {
  public struct Configuration: Sendable {
    /// The port to listen on. If it's taken the server falls back to any free port. 0 = any.
    public var port: UInt16 = WireProtocol.defaultPort

    /// Advertise `_souris._udp` over Bonjour. Off in tests.
    public var advertisesBonjour = true

    /// The advertised Bonjour name; `nil` uses the computer name.
    public var serviceName: String?

    /// Sent to phones in welcome packets.
    public var macName: String

    /// Also accept peer-to-peer Wi-Fi (AWDL). Off by default: AWDL makes the Mac's radio hop
    /// channels, which causes the stalls this app works to avoid.
    public var includesPeerToPeer = false

    public var silenceTimeout: Duration = .milliseconds(750)

    public var idleConnectionTimeout: Duration = .seconds(10)

    public init(macName: String) {
      self.macName = macName
    }
  }

  public let configuration: Configuration

  /// The values other threads read. Everything else is touched only on `queue`.
  private struct Shared {
    var port: UInt16?
    var approvedDevices: Set<UUID> = []
  }

  /// One UDP flow from a phone. A phone that restarts shows up as a new flow.
  private struct Connection {
    var nwConnection: NWConnection
    var peer: PeerInfo?

    /// The epoch of the last hello on this flow.
    var epoch: UInt16?
    var lastHeard: ContinuousClock.Instant

    /// The status of the last welcome sent on this flow.
    var lastWelcome: WelcomeStatus?
  }

  /// The phone currently allowed to move the pointer.
  private struct Controller {
    var peer: PeerInfo
    var epoch: UInt16
    var lastState: ContinuousClock.Instant
    var hasReportedSilence = false
  }

  private static let timerInterval = DispatchTimeInterval.milliseconds(100)
  private static let logCategory = "server"

  private let queue: DispatchQueue
  private let onEvent: @Sendable (ServerEvent) -> Void
  private let shared = Mutex(Shared())

  /// Sends log acks best effort, out of the Wi-Fi voice queue.
  private let logAckContext: NWConnection.ContentContext

  private var listener: NWListener?
  private var listenerGeneration = 0
  private var hasFallenBackToAnyPort = false
  private var timer: (any DispatchSourceTimer)?
  private var connections: [Int: Connection] = [:]
  private var lastConnectionID = 0
  private var deniedDevices: Set<UUID> = []
  private var pendingApprovals: Set<UUID> = []

  /// The epoch of each device's session that `disconnectController()` ended.
  private var kickedEpochs: [UUID: UInt16] = [:]
  private var controller: Controller?

  private var logInboxes: [UUID: LogInbox] = [:]
  private var logLimiter = LogRateLimiter()

  public init(
    configuration: Configuration,
    queue: DispatchQueue,
    onEvent: @escaping @Sendable (ServerEvent) -> Void
  ) {
    self.configuration = configuration
    self.queue = queue
    self.onEvent = onEvent
    let ip = NWProtocolIP.Metadata()
    ip.serviceClass = .bestEffort
    logAckContext = NWConnection.ContentContext(identifier: "logAck", metadata: [ip])
  }

  deinit {
    timer?.cancel()
    listener?.cancel()
    for connection in connections.values {
      connection.nwConnection.cancel()
    }
  }

  /// The port actually listened on, once listening.
  public var port: UInt16? {
    shared.withLock { $0.port }
  }

  /// Devices allowed to control the pointer. Set the persisted list before `start()`.
  public var approvedDevices: Set<UUID> {
    get { shared.withLock { $0.approvedDevices } }
    set { shared.withLock { $0.approvedDevices = newValue } }
  }

  // MARK: - Lifecycle

  /// Starts listening. Does nothing if the server is already running.
  public func start() {
    queue.async { [self] in
      guard listener == nil else { return }
      hasFallenBackToAnyPort = false
      emit(.stateChanged(.starting))
      startTimer()
      startListener(port: configuration.port)
    }
  }

  /// Stops listening and cancels every connection.
  public func stop() {
    queue.async { [self] in
      teardown(reason: "stop() called")
      emit(.stateChanged(.stopped))
    }
  }

  /// Answers an `approvalRequested`. Approving adds the device to `approvedDevices`; denying
  /// refuses it until the server restarts. The phone learns the answer from its next welcome,
  /// which is also sent right away.
  ///
  /// Denying the phone that is controlling the pointer drops it as the controller.
  public func resolveApproval(for deviceID: UUID, approved: Bool) {
    shared.withLock { shared in
      if approved {
        shared.approvedDevices.insert(deviceID)
      } else {
        shared.approvedDevices.remove(deviceID)
      }
    }
    queue.async { [self] in
      log(
        .info, "approvalResolved",
        fields: ["device": .string(deviceID.uuidString), "approved": .bool(approved)])
      pendingApprovals.remove(deviceID)
      if approved {
        deniedDevices.remove(deviceID)
      } else {
        deniedDevices.insert(deviceID)
        if controller?.peer.deviceID == deviceID {
          dropController(reason: "denied")
        }
      }
      for (id, connection) in connections where connection.peer?.deviceID == deviceID {
        sendWelcome(welcomeStatus(for: deviceID, epoch: connection.epoch), on: id)
      }
    }
  }

  /// Kicks the phone that is controlling the pointer. Reports `controllerSilent` then
  /// `controllerChanged(nil)`, and sends `welcome(disconnected)` to the phone at once.
  ///
  /// The kick covers the phone's current session, identified by its device ID and epoch. Every
  /// hello from that session gets `welcome(disconnected)` and its state and pings are ignored. A
  /// hello with a different epoch, which the phone sends after starting a new session, clears the
  /// kick and is handled normally. Restarting the server also clears it.
  public func disconnectController() {
    queue.async { [self] in
      guard let current = controller else { return }
      let deviceID = current.peer.deviceID
      kickedEpochs[deviceID] = current.epoch
      dropController(reason: "kicked from the Mac")
      for (id, connection) in connections where connection.peer?.deviceID == deviceID {
        sendWelcome(welcomeStatus(for: deviceID, epoch: connection.epoch), on: id)
      }
    }
  }

  // MARK: - Listener

  private func startListener(port: UInt16) {
    listenerGeneration += 1
    let generation = listenerGeneration

    let parameters = NWParameters.udp
    parameters.serviceClass = .interactiveVoice
    parameters.includePeerToPeer = configuration.includesPeerToPeer

    let listener: NWListener
    do {
      if let endpointPort = NWEndpoint.Port(rawValue: port), endpointPort != .any {
        listener = try NWListener(using: parameters, on: endpointPort)
      } else {
        listener = try NWListener(using: parameters)
      }
    } catch {
      var fields = (error as? NWError)?.logFields ?? ["error": .string(error.networkDescription)]
      fields["requestedPort"] = .int(Int(port))
      log(.error, "listenerCreateFailed", fields: fields)
      listenerFailed(error.networkDescription, requestedPort: port)
      return
    }

    if configuration.advertisesBonjour {
      listener.service = NWListener.Service(
        name: configuration.serviceName, type: WireProtocol.bonjourServiceType)
      listener.serviceRegistrationUpdateHandler = { [weak self] change in
        self?.serviceRegistrationChanged(change, generation: generation)
      }
    }
    listener.stateUpdateHandler = { [weak self] state in
      self?.listenerStateChanged(state, generation: generation, requestedPort: port)
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection, generation: generation)
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  private func listenerStateChanged(
    _ state: NWListener.State, generation: Int, requestedPort: UInt16
  ) {
    guard generation == listenerGeneration, let listener else { return }
    var fields = state.logFields
    fields["requestedPort"] = .int(Int(requestedPort))
    switch state {
    case .ready:
      guard let port = listener.port?.rawValue else { return }
      fields["port"] = .int(Int(port))
      log(.info, "listener", fields: fields)
      shared.withLock { $0.port = port }
      emit(.stateChanged(.listening(port: port)))
    case .waiting:
      log(.warning, "listener", fields: fields)
    case .failed(let error):
      log(.error, "listener", fields: fields)
      listenerFailed(error.networkDescription, requestedPort: requestedPort)
    default:
      log(.debug, "listener", fields: fields)
    }
  }

  private func serviceRegistrationChanged(
    _ change: NWListener.ServiceRegistrationChange, generation: Int
  ) {
    guard generation == listenerGeneration else { return }
    switch change {
    case .add(let endpoint):
      log(
        .info, "bonjour",
        fields: ["change": "add", "service": .string(endpoint.debugDescription)])
    case .remove(let endpoint):
      log(
        .info, "bonjour",
        fields: ["change": "remove", "service": .string(endpoint.debugDescription)])
    @unknown default:
      log(.info, "bonjour", fields: ["change": "unknown"])
    }
  }

  /// Retries once on any free port when a specific port fails (usually because it's taken), then
  /// gives up.
  private func listenerFailed(_ message: String, requestedPort: UInt16) {
    if requestedPort != 0 && !hasFallenBackToAnyPort {
      hasFallenBackToAnyPort = true
      log(
        .warning, "portFallback", "Port \(requestedPort) failed, trying any free port",
        fields: ["requestedPort": .int(Int(requestedPort)), "error": .string(message)])
      listener?.cancel()
      listener = nil
      startListener(port: 0)
      return
    }
    teardown(reason: "listener failed: \(message)")
    emit(.stateChanged(.failed(message)))
  }

  /// Cancels the listener, connections and timer, and drops the controller.
  private func teardown(reason: String) {
    if listener != nil || !connections.isEmpty {
      log(.info, "teardown", reason, fields: ["flows": .int(connections.count)])
    }
    flushLimitedLogs(.now + logLimiter.interval)
    listenerGeneration += 1
    timer?.cancel()
    timer = nil
    listener?.cancel()
    listener = nil
    shared.withLock { $0.port = nil }
    for connection in connections.values {
      connection.nwConnection.cancel()
    }
    connections.removeAll()
    pendingApprovals.removeAll()
    kickedEpochs.removeAll()
    if controller != nil {
      dropController(reason: "server stopped")
    }
  }

  // MARK: - Connections

  private func accept(_ nwConnection: NWConnection, generation: Int) {
    guard generation == listenerGeneration else {
      nwConnection.cancel()
      return
    }
    lastConnectionID += 1
    let id = lastConnectionID
    connections[id] = Connection(nwConnection: nwConnection, lastHeard: .now)
    nwConnection.stateUpdateHandler = { [weak self] state in
      self?.connectionStateChanged(state, on: id)
    }
    nwConnection.start(queue: queue)
    receive(on: id)
  }

  private func connectionStateChanged(_ state: NWConnection.State, on id: Int) {
    switch state {
    case .ready:
      guard let connection = connections[id] else { return }
      var fields = connection.nwConnection.currentPath?.logFields ?? [:]
      fields["flow"] = .int(id)
      fields["remote"] = .string(connection.nwConnection.endpoint.debugDescription)
      log(.info, "flowOpened", fields: fields)
    case .failed(let error):
      closeConnection(id, reason: "failed: \(error.networkDescription)")
    case .cancelled:
      closeConnection(id, reason: "cancelled")
    default:
      break
    }
  }

  private func receive(on id: Int) {
    guard let nwConnection = connections[id]?.nwConnection else { return }
    nwConnection.receiveMessage { [weak self] data, _, _, error in
      self?.received(data, error: error, on: id)
    }
  }

  private func received(_ data: Data?, error: NWError?, on id: Int) {
    guard connections[id] != nil else { return }
    if let error {
      closeConnection(id, reason: "receive failed: \(error.networkDescription)")
      return
    }
    // An empty datagram arrives as no data and no error; it must not end the flow.
    if let data {
      do {
        let packet = try Packet.decode(data)
        connections[id]?.lastHeard = .now
        handle(packet, on: id)
      } catch {
        logLimited(
          .warning, "decodeError", "\(error)",
          fields: ["flow": .int(id), "bytes": .int(data.count)])
      }
    }
    receive(on: id)
  }

  private func closeConnection(_ id: Int, reason: String) {
    guard let connection = connections.removeValue(forKey: id) else { return }
    connection.nwConnection.cancel()
    var fields: [String: LogValue] = [
      "flow": .int(id),
      "reason": .string(reason),
      "remote": .string(connection.nwConnection.endpoint.debugDescription),
    ]
    if let peer = connection.peer {
      fields["device"] = .string(peer.deviceID.uuidString)
      fields["name"] = .string(peer.name)
    }
    log(.info, "flowClosed", fields: fields)
  }

  private func send(_ packet: Packet, on id: Int) {
    connections[id]?.nwConnection.send(content: packet.encoded(), completion: .idempotent)
  }

  private func sendWelcome(_ status: WelcomeStatus, on id: Int) {
    if let connection = connections[id], connection.lastWelcome != status {
      connections[id]?.lastWelcome = status
      log(
        .info, "welcome",
        fields: [
          "flow": .int(id),
          "status": .string(String(describing: status)),
          "previous": .string(connection.lastWelcome.map { String(describing: $0) } ?? "none"),
          "name": .string(connection.peer?.name ?? "unknown"),
        ])
    }
    send(.welcome(WelcomePacket(status: status, macName: configuration.macName)), on: id)
  }

  // MARK: - Packets

  private func handle(_ packet: Packet, on id: Int) {
    switch packet {
    case .hello(let hello):
      handleHello(hello, on: id)
    case .state(let state):
      handleState(state, on: id)
    case .ping(let ping):
      handlePing(ping, on: id)
    case .bye(let bye):
      handleBye(bye, on: id)
    case .log(let log):
      handleLog(log, on: id)
    case .pong, .welcome, .logAck:
      logLimited(
        .warning, "unexpectedPacket", "A packet only the Mac sends arrived from a phone",
        fields: ["flow": .int(id)])
    }
  }

  private func handleHello(_ hello: HelloPacket, on id: Int) {
    let peer = PeerInfo(deviceID: hello.deviceID, name: hello.deviceName)
    let previous = connections[id]
    if previous?.peer != peer || previous?.epoch != hello.epoch {
      var fields: [String: LogValue] = [
        "flow": .int(id),
        "device": .string(peer.deviceID.uuidString),
        "name": .string(peer.name),
        "epoch": .int(Int(hello.epoch)),
        "approved": .bool(isApproved(peer.deviceID)),
      ]
      if let previousEpoch = previous?.epoch {
        fields["previousEpoch"] = .int(Int(previousEpoch))
      }
      log(.info, "hello", fields: fields)
    }
    connections[id]?.peer = peer
    connections[id]?.epoch = hello.epoch
    if let kickedEpoch = kickedEpochs[peer.deviceID], kickedEpoch != hello.epoch {
      kickedEpochs[peer.deviceID] = nil
    }
    let status = welcomeStatus(for: peer.deviceID, epoch: hello.epoch)
    sendWelcome(status, on: id)
    if status == .pending && pendingApprovals.insert(peer.deviceID).inserted {
      log(
        .info, "approvalRequested",
        fields: ["device": .string(peer.deviceID.uuidString), "name": .string(peer.name)])
      emit(.approvalRequested(peer))
    }
  }

  private func handleState(_ state: StatePacket, on id: Int) {
    guard let peer = connections[id]?.peer, isApproved(peer.deviceID) else {
      logLimited(
        .warning, "ignoredState", "State from a flow without an approved hello",
        fields: ["flow": .int(id)])
      return
    }
    guard !isKicked(peer.deviceID, epoch: state.epoch) else {
      logLimited(
        .info, "ignoredKickedState", fields: ["flow": .int(id), "name": .string(peer.name)])
      return
    }
    let now = ContinuousClock.now

    if controller?.peer.deviceID != peer.deviceID {
      if let current = controller, !isSilent(current, at: now) {
        logLimited(
          .info, "ignoredBusyState",
          fields: ["name": .string(peer.name), "controller": .string(current.peer.name)])
        return
      }
      var fields: [String: LogValue] = [
        "device": .string(peer.deviceID.uuidString),
        "name": .string(peer.name),
        "epoch": .int(Int(state.epoch)),
      ]
      if let current = controller {
        fields["reason"] = "takeover after silence"
        fields["previous"] = .string(current.peer.name)
        fields["silenceMs"] = .double((now - current.lastState).milliseconds)
        if !current.hasReportedSilence {
          emit(.controllerSilent)
        }
      } else {
        fields["reason"] = "first state"
      }
      log(.info, "controller", fields: fields)
      controller = Controller(peer: peer, epoch: state.epoch, lastState: now)
      emit(.controllerChanged(peer))
    } else if let current = controller, current.hasReportedSilence {
      log(
        .info, "resumed",
        fields: [
          "name": .string(peer.name), "gapMs": .double((now - current.lastState).milliseconds),
        ])
    }

    controller?.epoch = state.epoch
    controller?.lastState = now
    controller?.hasReportedSilence = false
    emit(.state(state))
  }

  private func handlePing(_ ping: PingPacket, on id: Int) {
    guard let connection = connections[id], let peer = connection.peer,
          isApproved(peer.deviceID), !isKicked(peer.deviceID, epoch: connection.epoch)
    else {
      logLimited(.info, "ignoredPing", fields: ["flow": .int(id)])
      return
    }
    let pong = PongPacket(
      id: ping.id, phoneTimeMicros: ping.phoneTimeMicros, macTimeMicros: Uptime.micros())
    send(.pong(pong), on: id)
  }

  private func handleBye(_ bye: ByePacket, on id: Int) {
    guard let peer = connections[id]?.peer,
          let current = controller,
          current.peer.deviceID == peer.deviceID,
          current.epoch == bye.epoch
    else { return }
    dropController(reason: "bye")
  }

  private func handleLog(_ packet: LogPacket, on id: Int) {
    guard let connection = connections[id], let peer = connection.peer,
          isApproved(peer.deviceID)
    else {
      logLimited(
        .warning, "ignoredLog", "Log packet from a flow without an approved hello",
        fields: ["flow": .int(id), "records": .int(packet.records.count)])
      return
    }
    let delivery = logInboxes[peer.deviceID, default: LogInbox()].receive(packet)
    let ack = Packet.logAck(LogAckPacket(stream: packet.stream, throughID: delivery.ackThrough))
    connection.nwConnection.send(
      content: ack.encoded(), contentContext: logAckContext, isComplete: true,
      completion: .idempotent)

    if delivery.missingBefore > 0 {
      log(
        .warning, "phoneLogGap", "The phone dropped log records before sending them",
        fields: [
          "name": .string(peer.name),
          "stream": .int(Int(packet.stream)),
          "missing": .int(delivery.missingBefore),
        ])
    }
    guard !delivery.records.isEmpty || delivery.missingBefore > 0 else { return }
    emit(
      .phoneLog(
        PhoneLogBatch(
          peer: peer,
          streamID: packet.stream,
          records: delivery.records,
          missingBefore: delivery.missingBefore)))
  }

  // MARK: - Approval and control

  private func isApproved(_ deviceID: UUID) -> Bool {
    shared.withLock { $0.approvedDevices.contains(deviceID) }
  }

  private func isSilent(_ controller: Controller, at now: ContinuousClock.Instant) -> Bool {
    now - controller.lastState >= configuration.silenceTimeout
  }

  private func isKicked(_ deviceID: UUID, epoch: UInt16?) -> Bool {
    guard let epoch else { return false }
    return kickedEpochs[deviceID] == epoch
  }

  /// The status to welcome `deviceID` with, for a session that began with `epoch`.
  private func welcomeStatus(for deviceID: UUID, epoch: UInt16?) -> WelcomeStatus {
    if isApproved(deviceID) {
      if isKicked(deviceID, epoch: epoch) {
        return .disconnected
      }
      if let current = controller, current.peer.deviceID != deviceID,
         !isSilent(current, at: .now)
      {
        return .busy
      }
      return .accepted
    }
    return deniedDevices.contains(deviceID) ? .denied : .pending
  }

  private func dropController(reason: String) {
    if let current = controller {
      log(
        .info, "controller",
        fields: [
          "device": "none",
          "reason": .string(reason),
          "previous": .string(current.peer.name),
        ])
    }
    controller = nil
    emit(.controllerSilent)
    emit(.controllerChanged(nil))
  }

  // MARK: - Timer

  private func startTimer() {
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + Self.timerInterval, repeating: Self.timerInterval,
      leeway: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    self.timer = timer
    timer.resume()
  }

  private func tick() {
    let now = ContinuousClock.now
    if let current = controller, !current.hasReportedSilence, isSilent(current, at: now) {
      controller?.hasReportedSilence = true
      log(
        .warning, "silent",
        fields: [
          "name": .string(current.peer.name),
          "gapMs": .double((now - current.lastState).milliseconds),
        ])
      emit(.controllerSilent)
    }
    let idleTimeout = configuration.idleConnectionTimeout
    for (id, connection) in connections where now - connection.lastHeard >= idleTimeout {
      closeConnection(id, reason: "idle for \(Int(idleTimeout.seconds)) s")
    }
    flushLimitedLogs(now)
  }

  // MARK: - Events and logging

  private func emit(_ event: ServerEvent) {
    onEvent(event)
  }

  private func log(
    _ level: LogLevel, _ event: String, _ message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    emit(
      .log(
        LogEntry(
          level: level, category: Self.logCategory, event: event, message: message,
          fields: fields)))
  }

  /// Logs the first `event` and counts repeats for a second, for events that can happen on every
  /// packet.
  private func logLimited(
    _ level: LogLevel, _ event: String, _ message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    guard logLimiter.admit(event, level: level, now: .now) else { return }
    log(level, event, message, fields: fields)
  }

  private func flushLimitedLogs(_ now: ContinuousClock.Instant) {
    for summary in logLimiter.drainSummaries(now: now) {
      emit(.log(summary.entry(category: Self.logCategory)))
    }
  }
}
