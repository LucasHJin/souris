import Foundation
import Network
import Synchronization

/// Where the phone sends packets.
public enum ClientTarget: Equatable, Codable, Sendable {
  /// Browse Bonjour for `_souris._udp`. `name` picks a specific Mac; `nil` takes the first found.
  case bonjour(name: String?)

  /// A fixed address, for networks that block Bonjour. `host` is an IP address or host name.
  case host(String, port: UInt16)
}

/// The phone's view of the link, for the status line.
public enum ClientStatus: Equatable, Sendable {
  case stopped
  /// Browsing Bonjour with no Mac found yet.
  case searching
  /// A Mac was found or a host was given; waiting for the first welcome.
  case connecting
  case waitingForApproval(macName: String)
  case connected(macName: String)
  case denied(macName: String)
  case busy(macName: String)
  /// The Mac disconnected this phone. Nothing is sent but the hello, until `start()` begins a new
  /// session.
  case disconnected(macName: String)
  /// The connection had a welcome but nothing has come back for a while.
  case notResponding(macName: String)
  /// The user turned off Local Network access for the app.
  case localNetworkDenied
  case failed(String)
}

/// Round-trip and send statistics for the debug overlay.
public struct LinkStats: Equatable, Sendable {
  /// Median round-trip time over the recent pings, in milliseconds.
  public var rttMedianMs: Double?

  /// Largest round-trip time over the recent pings, in milliseconds. Wi-Fi stalls show up here.
  public var rttMaxMs: Double?

  /// State packets sent per second, smoothed.
  public var packetsPerSecond: Double = 0

  /// Pings that got no pong within a second, over the recent pings, as a fraction.
  public var pingLoss: Double = 0

  /// Log records waiting for the Mac's ack, from the client's `LogOutbox`.
  public var logRecordsQueued = 0

  /// Log records the outbox dropped unsent because it was full.
  public var logRecordsDropped = 0

  /// What carries the link.
  public var transport = LinkTransport.wifi

  public init() {}
}

/// What carries the link to the Mac.
public enum LinkTransport: String, Sendable {
  case wifi
  case usb
  case bluetooth
}

/// The phone end of the link.
///
/// - Finds the Mac (Bonjour or a fixed host), opens a UDP flow with the `.interactiveVoice`
///   service class (unless `usesVoiceServiceClass` is off), and sends a hello on ready and every
///   second after that.
/// - `send(_:)` is latest-wins: if a send is still in flight the new state replaces any queued one,
///   and only the newest is sent when the previous send completes. Each sent packet gets the next
///   `seq`. Nothing is sent until the Mac has accepted the phone.
/// - While connected, the latest state is re-sent at least every `keepaliveInterval`, and a ping
///   goes out every `pingInterval`.
/// - Each `start()` uses a new random epoch. `stop()` sends a bye and cancels everything.
/// - When the Mac disconnects the phone (`welcome(disconnected)`), the status becomes
///   `.disconnected`, state, pings and keepalives stop, and the hello continues at its usual
///   interval. The Mac holds the disconnect for the session's epoch, and the epoch only changes on
///   the next `start()`, so reconnecting means `stop()` then `start()`.
/// - If nothing comes back for 3 s (`notRespondingTimeout`) the status becomes `.notResponding`;
///   after 6 s (`reconnectTimeout`) the client reconnects, re-browsing when the target is Bonjour.
/// - With `listensForUSB`, the client also listens on its loopback interface for the Mac's USB
///   link (`WireProtocol.usbPort`, TCP framed by `StreamFraming`). When the Mac connects over the
///   cable, that connection replaces the Wi-Fi one. Bonjour browsing carries on in the background,
///   so when the cable link closes or goes silent the client reconnects over Wi-Fi at once rather
///   than waiting seconds for peer-to-peer discovery. Log packets aren't rate limited over USB.
/// - With `listensForBluetooth`, it listens the same way on `WireProtocol.bluetoothPort` for the
///   phone's own `BluetoothPeripheralBridge`, which relays to the Mac over Bluetooth LE. That link
///   replaces Wi-Fi but never the cable: while the cable carries the link, a Bluetooth connection
///   is turned away (the bridge tries again), and so it is for 30 s after Bluetooth went silent.
///   Log packets over Bluetooth are held to `bluetoothLogBytesPerSecond`.
/// - Wi-Fi connections never use a wired interface: the only one a phone has is the cable's
///   network link, which the USB link already covers and which vanishes the moment the cable is
///   pulled.
/// - Until the first welcome on a connection, the hello repeats every `firstHelloInterval`
///   instead of `helloInterval`, so a hello lost on a link that is just waking up costs a quarter
///   second rather than a second.
/// - With a `LogOutbox`, the client logs its network events into it (category `"net"`) and, while
///   the latest welcome is `accepted` or `busy` and the Mac is responding, sends log packets one at
///   a time: a log packet goes only when no state packet is waiting or in flight, the previous log
///   packet has completed, and `logBytesPerSecond` allows it. Log packets carry the best-effort
///   service class per message, so they stay out of the Wi-Fi voice queue the state packets use.
///   Without an outbox nothing is logged or sent.
///
/// Thread safety: every method may be called from any thread. `onStatus` and `onBrowseResults`
/// are called on `queue`. The log outbox must be confined to `queue` as well.
public final class SourisClient: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var target: ClientTarget = .bonjour(name: nil)

    /// Also use peer-to-peer Wi-Fi (AWDL). Off by default for latency.
    public var includesPeerToPeer = false

    /// Mark packets `.interactiveVoice` (Wi-Fi voice queue). Off sends best effort, for A/B tests.
    public var usesVoiceServiceClass = true

    public var keepaliveInterval: Duration = .milliseconds(50)

    public var pingInterval: Duration = .milliseconds(200)

    /// How often the hello is repeated. The Mac answers each one, so this is also how soon a
    /// changed approval or a freed controller seat shows up.
    public var helloInterval: Duration = .seconds(1)

    /// How often the hello is repeated before the first welcome on a connection.
    public var firstHelloInterval: Duration = .milliseconds(250)

    /// Silence from the Mac after which the status becomes `.notResponding`.
    public var notRespondingTimeout: Duration = .seconds(3)

    /// Silence from the Mac after which the client reconnects. Keep it above
    /// `notRespondingTimeout`.
    public var reconnectTimeout: Duration = .seconds(6)

    /// The average rate log packets may use, bytes per second. `nil` sends them as fast as the
    /// state packets leave room for. Wi-Fi stalls queue everything sent into them, so the log
    /// stream is kept small next to the state packets.
    public var logBytesPerSecond: Double? = 20_000

    /// Listen on the loopback interface for the Mac's USB link, and prefer it while it's up.
    public var listensForUSB = false

    /// The loopback TCP port the USB link listens on.
    public var usbPort: UInt16 = WireProtocol.usbPort

    /// Listen on the loopback interface for the phone's Bluetooth bridge, and prefer it to Wi-Fi
    /// while it's up.
    public var listensForBluetooth = false

    /// The loopback TCP port the Bluetooth bridge connects to.
    public var bluetoothPort: UInt16 = WireProtocol.bluetoothPort

    /// The average rate log packets may use over Bluetooth, bytes per second. The state packets
    /// alone take about 10 KB/s of a link that manages a few tens.
    public var bluetoothLogBytesPerSecond: Double = 4_000

    public init(deviceID: UUID, deviceName: String) {
      self.deviceID = deviceID
      self.deviceName = deviceName
    }
  }

  public let configuration: Configuration

  /// The outbox this client logs into and sends from, if any. It outlives the client: the app
  /// hands the same outbox to each new client so the backlog carries over.
  public let logOutbox: LogOutbox?

  /// The values other threads read. Everything else is touched only on `queue`.
  private struct Shared {
    var status = ClientStatus.stopped
    var stats = LinkStats()
    var onBrowseResults: (@Sendable ([String]) -> Void)?
  }

  private static let retryDelay = Duration.seconds(1)
  private static let sendStallTimeout = Duration.seconds(1)
  private static let rateSampleInterval = Duration.milliseconds(500)
  private static let byeGracePeriod = DispatchTimeInterval.milliseconds(100)
  /// Credit the log rate limit can bank, bytes: about two full log packets.
  private static let logBurstBytes = 2.0 * Double(LogOutbox.datagramTarget)
  private static let logCategory = "net"
  private static let slowRoundTripMs = 150.0
  private static let linkSummaryInterval = Duration.seconds(1)

  /// How long Bluetooth is turned away after it went silent, so a link too weak to carry the
  /// packets doesn't flap between Bluetooth and Wi-Fi every few seconds.
  private static let bluetoothHoldoff = Duration.seconds(30)

  private let queue: DispatchQueue
  private let onStatus: @Sendable (ClientStatus) -> Void
  private let shared = Mutex(Shared())

  /// How often `tick()` runs: fast enough to hold the keepalive and ping intervals.
  private let tickInterval: Duration

  /// Sends log packets best effort, whatever service class the connection uses.
  private let logContext: NWConnection.ContentContext

  private var isStarted = false
  private var epoch: UInt16 = 0
  private var seq: UInt32 = 0
  private var helloData = Data()
  private var tickTimer: (any DispatchSourceTimer)?
  private var retryAt: ContinuousClock.Instant?

  private var browser: NWBrowser?
  private var browserToken = 0
  private var endpoints: [String: NWEndpoint] = [:]
  private var browsedNames: [String] = []

  private var connection: NWConnection?

  /// A link that reaches this client over loopback rather than one it opened over Wi-Fi.
  private enum SideLink: String, Sendable {
    case usb
    case bluetooth

    var transport: LinkTransport {
      switch self {
      case .usb: .usb
      case .bluetooth: .bluetooth
      }
    }

    var displayName: String {
      switch self {
      case .usb: "USB"
      case .bluetooth: "Bluetooth"
      }
    }
  }

  /// A loopback listener for one kind of side link.
  private struct SideListener {
    var listener: NWListener?
    var generation = 0
    var retryAt: ContinuousClock.Instant?
  }

  /// The side link the current connection is, or nil for Wi-Fi.
  private var sideLink: SideLink?
  private var sideListeners: [SideLink: SideListener] = [:]
  private var bluetoothHoldoffUntil: ContinuousClock.Instant?

  /// Bumped for every connection so late callbacks from an old one can be told apart.
  private var connectionToken = 0
  private var isConnectionReady = false
  private var isReceiving = false

  /// The latest welcome on this connection, `nil` until the first one.
  private var welcome: WelcomePacket?
  private var isNotResponding = false
  private var lastHeard = ContinuousClock.now
  private var nextHelloAt = ContinuousClock.now

  private var latestState: MouseState?
  private var hasUnsentState = false
  private var isSendInFlight = false
  private var lastSentAt = ContinuousClock.now

  private var nextPingID: UInt32 = 0
  private var nextPingAt = ContinuousClock.now
  private var monitor = LinkMonitor()
  private var sentSincePreviousSample = 0
  private var rateSampleStart = ContinuousClock.now

  private var logLimiter = LogRateLimiter()
  private var logBudget: ByteRateLimiter?
  private var bluetoothLogBudget: ByteRateLimiter
  private var isLogSendInFlight = false
  private var lastLogSentAt = ContinuousClock.now
  private var summary = LinkSummary()
  private var nextSummaryAt = ContinuousClock.now

  /// Counts for the 1 Hz `link` log entry, reset after each one.
  private struct LinkSummary {
    var roundTripsMs: [Double] = []
    var pingsSent = 0
    var pongs = 0
    var statesSent = 0
    var sendErrors = 0
  }

  /// - Parameters:
  ///   - configuration: What to connect to and how.
  ///   - queue: The serial queue the client works on. `logOutbox` must be confined to it.
  ///   - logOutbox: Where to log network events and what log records to send. `nil` turns both
  ///     off.
  ///   - onStatus: Called on `queue` whenever the status changes.
  public init(
    configuration: Configuration,
    queue: DispatchQueue,
    logOutbox: LogOutbox? = nil,
    onStatus: @escaping @Sendable (ClientStatus) -> Void
  ) {
    self.configuration = configuration
    self.queue = queue
    self.logOutbox = logOutbox
    self.onStatus = onStatus
    tickInterval = max(
      .milliseconds(5),
      min(configuration.keepaliveInterval / 4, configuration.pingInterval / 2, .milliseconds(100)))
    let ip = NWProtocolIP.Metadata()
    ip.serviceClass = .bestEffort
    logContext = NWConnection.ContentContext(identifier: "log", metadata: [ip])
    logBudget = configuration.logBytesPerSecond.map {
      ByteRateLimiter(bytesPerSecond: $0, burst: Self.logBurstBytes)
    }
    bluetoothLogBudget = ByteRateLimiter(
      bytesPerSecond: configuration.bluetoothLogBytesPerSecond, burst: Self.logBurstBytes)
  }

  deinit {
    tickTimer?.cancel()
    browser?.cancel()
    for side in sideListeners.values {
      side.listener?.cancel()
    }
    connection?.cancel()
  }

  /// Names of the Macs Bonjour currently sees, sorted. Called on `queue` when the list changes.
  public var onBrowseResults: (@Sendable ([String]) -> Void)? {
    get { shared.withLock { $0.onBrowseResults } }
    set { shared.withLock { $0.onBrowseResults = newValue } }
  }

  /// The link's current status.
  public var status: ClientStatus {
    shared.withLock { $0.status }
  }

  /// Round-trip and send statistics, refreshed twice a second and on every pong.
  public var stats: LinkStats {
    shared.withLock { $0.stats }
  }

  // MARK: - Public control

  /// Starts looking for the Mac and connecting. Does nothing if already started.
  public func start() {
    queue.async { [self] in
      guard !isStarted else { return }
      isStarted = true
      epoch = Self.randomEpoch(differentFrom: epoch)
      seq = 0
      nextPingID = 0
      latestState = nil
      hasUnsentState = false
      retryAt = nil
      monitor = LinkMonitor()
      sentSincePreviousSample = 0
      rateSampleStart = .now
      publishStats()
      helloData = Packet.hello(
        HelloPacket(
          epoch: epoch, deviceID: configuration.deviceID, deviceName: configuration.deviceName)
      ).encoded()
      startTimer()
      log(
        .info, "start",
        fields: [
          "epoch": .int(Int(epoch)),
          "target": .string(configuration.target.logDescription),
          "deviceName": .string(configuration.deviceName),
          "peerToPeer": .bool(configuration.includesPeerToPeer),
          "voiceServiceClass": .bool(configuration.usesVoiceServiceClass),
          "listensForUSB": .bool(configuration.listensForUSB),
          "listensForBluetooth": .bool(configuration.listensForBluetooth),
        ])
      if configuration.listensForUSB {
        startListener(for: .usb)
      }
      if configuration.listensForBluetooth {
        startListener(for: .bluetooth)
      }

      switch configuration.target {
      case .bonjour:
        setStatus(.searching, reason: "started, browsing Bonjour")
        startBrowser()
      case .host:
        setStatus(.connecting, reason: "started with a fixed host")
        connectIfPossible()
      }
    }
  }

  /// Sends a bye so the Mac releases everything at once, then closes the connection and stops
  /// browsing.
  public func stop() {
    queue.async { [self] in
      guard isStarted else { return }
      isStarted = false
      tickTimer?.cancel()
      tickTimer = nil
      browserToken += 1
      browser?.cancel()
      browser = nil
      endpoints.removeAll()
      browsedNames.removeAll()
      retryAt = nil
      stopListener(for: .usb)
      stopListener(for: .bluetooth)

      let wasReady = isConnectionReady
      if let old = detachConnection() {
        if wasReady {
          sayGoodbye(on: old)
        } else {
          old.cancel()
        }
      }
      log(.info, "stop", fields: ["epoch": .int(Int(epoch)), "byeSent": .bool(wasReady)])
      flushLimitedLogs(.now)
      setStatus(.stopped, reason: "stop() called")
      shared.withLock { $0.stats = LinkStats() }
    }
  }

  /// Queues `state` to send, replacing any state not yet sent.
  public func send(_ state: MouseState) {
    queue.async { [self] in
      guard isStarted else { return }
      latestState = state
      hasUnsentState = true
      pumpState()
    }
  }

  // MARK: - Target and connection

  private func makeParameters() -> NWParameters {
    let parameters = NWParameters.udp
    parameters.serviceClass =
      configuration.usesVoiceServiceClass ? .interactiveVoice : .bestEffort
    parameters.includePeerToPeer = configuration.includesPeerToPeer
    parameters.prohibitedInterfaceTypes = [.cellular, .wiredEthernet]
    return parameters
  }

  private func startBrowser() {
    browserToken += 1
    let token = browserToken
    let browser = NWBrowser(
      for: .bonjour(type: WireProtocol.bonjourServiceType, domain: nil), using: makeParameters())
    browser.stateUpdateHandler = { [weak self] state in
      self?.browserStateChanged(state, token: token)
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      self?.browseResultsChanged(results, token: token)
    }
    self.browser = browser
    browser.start(queue: queue)
  }

  private func browserStateChanged(_ state: NWBrowser.State, token: Int) {
    guard token == browserToken, isStarted else { return }
    switch state {
    case .ready:
      log(.info, "browser", fields: state.logFields)
      if connection == nil { clearError(to: .searching, reason: "browser ready") }
    case .waiting(let error):
      log(.warning, "browser", fields: state.logFields)
      if error.isLocalNetworkDenied {
        setStatus(.localNetworkDenied, reason: "browser waiting: \(error.networkDescription)")
      }
    case .failed(let error):
      log(.error, "browser", fields: state.logFields)
      browser?.cancel()
      browser = nil
      setStatus(
        Self.failureStatus(for: error), reason: "browser failed: \(error.networkDescription)")
      retryAt = .now + Self.retryDelay
    default:
      log(.debug, "browser", fields: state.logFields)
    }
  }

  private func browseResultsChanged(_ results: Set<NWBrowser.Result>, token: Int) {
    guard token == browserToken, isStarted else { return }
    var found: [String: NWEndpoint] = [:]
    let ordered = results.sorted { $0.endpoint.debugDescription < $1.endpoint.debugDescription }
    for result in ordered {
      if case .service(let name, _, _, _) = result.endpoint, found[name] == nil {
        found[name] = result.endpoint
      }
    }
    endpoints = found
    let services = ordered.map { result in
      let interfaces = result.interfaces.map(\.logName).joined(separator: ",")
      return "\(result.endpoint.debugDescription) [\(interfaces)]"
    }
    log(
      .info, "browseResults",
      fields: ["count": .int(results.count), "services": .string(services.joined(separator: "; "))])

    let names = found.keys.sorted()
    if names != browsedNames {
      browsedNames = names
      let callback = shared.withLock { $0.onBrowseResults }
      callback?(names)
    }
    connectIfPossible()
  }

  /// Opens a connection to the target if there isn't one and nothing is waiting to be retried.
  private func connectIfPossible() {
    guard isStarted, connection == nil, retryAt == nil, sideLink == nil else { return }
    switch configuration.target {
    case .host(let host, let port):
      guard let port = NWEndpoint.Port(rawValue: port), port != .any else {
        log(.error, "target", "Invalid port", fields: ["port": .int(Int(port))])
        setStatus(.failed("Invalid port"), reason: "invalid port \(port)")
        return
      }
      let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
      log(
        .info, "target",
        fields: ["kind": "host", "endpoint": .string(endpoint.debugDescription)])
      open(endpoint)
    case .bonjour(let name):
      guard let chosen = name ?? endpoints.keys.min(), let endpoint = endpoints[chosen] else {
        return
      }
      log(
        .info, "target",
        fields: [
          "kind": "bonjour",
          "service": .string(chosen),
          "requested": .string(name ?? "first found"),
          "endpoint": .string(endpoint.debugDescription),
        ])
      open(endpoint)
    }
  }

  private func open(_ endpoint: NWEndpoint) {
    let connection = NWConnection(to: endpoint, using: makeParameters())
    begin(connection, description: endpoint.debugDescription)
  }

  /// Makes `connection` the current one and starts it.
  private func begin(_ connection: NWConnection, description: String) {
    connectionToken += 1
    let token = connectionToken
    connection.stateUpdateHandler = { [weak self] state in
      self?.connectionStateChanged(state, token: token)
    }
    connection.pathUpdateHandler = { [weak self] path in
      self?.pathChanged(path, token: token)
    }
    connection.viabilityUpdateHandler = { [weak self] isViable in
      self?.logConnectionChange("viability", ["viable": .bool(isViable)], token: token)
    }
    connection.betterPathUpdateHandler = { [weak self] isAvailable in
      self?.logConnectionChange("betterPath", ["available": .bool(isAvailable)], token: token)
    }
    self.connection = connection
    isConnectionReady = false
    isReceiving = false
    welcome = nil
    isNotResponding = false
    isSendInFlight = false
    isLogSendInFlight = false
    lastHeard = .now
    monitor = LinkMonitor()
    publishStats()
    if status == .searching {
      setStatus(.connecting, reason: "found \(description)")
    }
    connection.start(queue: queue)
  }

  private func connectionStateChanged(_ state: NWConnection.State, token: Int) {
    guard token == connectionToken, isStarted else { return }
    var fields = state.logFields
    fields["connection"] = .int(token)
    switch state {
    case .ready:
      log(.info, "connection", fields: fields)
      if let path = connection?.currentPath {
        logPath(path, token: token)
      }
      isConnectionReady = true
      lastHeard = .now
      nextSummaryAt = .now + Self.linkSummaryInterval
      summary = LinkSummary()
      logOutbox?.rewind()
      clearError(to: .connecting, reason: "connection ready")
      sendHello()
      if !isReceiving {
        isReceiving = true
        receive(token: token)
      }
    case .waiting(let error):
      log(.warning, "connection", fields: fields)
      if error.isLocalNetworkDenied {
        setStatus(.localNetworkDenied, reason: "connection waiting: \(error.networkDescription)")
      }
    case .failed(let error):
      log(.error, "connection", fields: fields)
      connectionFailed(
        Self.failureStatus(for: error), reason: "connection failed: \(error.networkDescription)")
    default:
      log(.debug, "connection", fields: fields)
    }
  }

  private func pathChanged(_ path: NWPath, token: Int) {
    guard token == connectionToken, isStarted else { return }
    logPath(path, token: token)
  }

  private func logPath(_ path: NWPath, token: Int) {
    var fields = path.logFields
    fields["connection"] = .int(token)
    log(path.status == .satisfied ? .info : .warning, "path", fields: fields)
  }

  private func logConnectionChange(_ event: String, _ fields: [String: LogValue], token: Int) {
    guard token == connectionToken, isStarted else { return }
    log(.info, event, fields: fields.merging(["connection": .int(token)]) { $1 })
  }

  private func connectionFailed(_ status: ClientStatus, reason: String) {
    if let sideLink {
      fallBack(from: sideLink, reason: reason)
      return
    }
    detachConnection()?.cancel()
    setStatus(status, reason: reason)
    retryAt = .now + Self.retryDelay
  }

  /// Forgets the connection without cancelling it, and resets everything tied to it.
  private func detachConnection() -> NWConnection? {
    let old = connection
    connection = nil
    connectionToken += 1
    isConnectionReady = false
    isReceiving = false
    welcome = nil
    isNotResponding = false
    isSendInFlight = false
    isLogSendInFlight = false
    sideLink = nil
    return old
  }

  /// Drops the connection and starts over: re-browses for a Bonjour target, reconnects to a host.
  private func reconnect(silence: Duration) {
    if let sideLink {
      let reason = "no reply over \(sideLink.displayName) for \(Int(silence.milliseconds)) ms"
      if sideLink == .bluetooth {
        bluetoothHoldoffUntil = .now + Self.bluetoothHoldoff
      }
      fallBack(from: sideLink, reason: reason)
      return
    }
    log(
      .warning, "reconnect",
      fields: [
        "silenceMs": .double(silence.milliseconds),
        "target": .string(configuration.target.logDescription),
      ])
    detachConnection()?.cancel()
    let reason = "no reply for \(Int(silence.milliseconds)) ms, reconnecting"
    switch configuration.target {
    case .bonjour:
      browserToken += 1
      browser?.cancel()
      browser = nil
      endpoints.removeAll()
      setStatus(.searching, reason: reason)
      startBrowser()
    case .host:
      setStatus(.connecting, reason: reason)
      connectIfPossible()
    }
  }

  private func sayGoodbye(on old: NWConnection) {
    let bye = Packet.bye(ByePacket(epoch: epoch)).encoded()
    old.send(content: bye, completion: .contentProcessed { _ in old.cancel() })
    queue.asyncAfter(deadline: .now() + Self.byeGracePeriod) { old.cancel() }
  }

  // MARK: - Side links (USB, Bluetooth)

  private func port(for side: SideLink) -> UInt16 {
    switch side {
    case .usb: configuration.usbPort
    case .bluetooth: configuration.bluetoothPort
    }
  }

  private func startListener(for side: SideLink) {
    var state = sideListeners[side] ?? SideListener()
    state.generation += 1
    state.retryAt = nil
    let generation = state.generation
    let event = "\(side.rawValue)Listener"
    let portNumber = port(for: side)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.defaultProtocolStack.applicationProtocols.insert(LengthPrefixFramer.options, at: 0)
    // usbmuxd and the Bluetooth bridge both reach the app over loopback, so nothing on Wi-Fi can
    // reach these.
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true
    guard let port = NWEndpoint.Port(rawValue: portNumber), port != .any else {
      log(.error, event, "Invalid port", fields: ["port": .int(Int(portNumber))])
      sideListeners[side] = state
      return
    }
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters, on: port)
    } catch {
      var fields = (error as? NWError)?.logFields ?? ["error": .string(error.networkDescription)]
      fields["port"] = .int(Int(portNumber))
      log(.error, event, "Couldn’t listen", fields: fields)
      state.retryAt = .now + Self.retryDelay
      sideListeners[side] = state
      return
    }
    listener.stateUpdateHandler = { [weak self] listenerState in
      self?.listenerStateChanged(listenerState, side: side, generation: generation)
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection, side: side, generation: generation)
    }
    state.listener = listener
    sideListeners[side] = state
    listener.start(queue: queue)
  }

  private func stopListener(for side: SideLink) {
    guard var state = sideListeners[side] else { return }
    state.generation += 1
    state.listener?.cancel()
    state.listener = nil
    state.retryAt = nil
    sideListeners[side] = state
  }

  private func listenerStateChanged(
    _ state: NWListener.State, side: SideLink, generation: Int
  ) {
    guard generation == sideListeners[side]?.generation, isStarted else { return }
    var fields = state.logFields
    fields["port"] = .int(Int(port(for: side)))
    let event = "\(side.rawValue)Listener"
    switch state {
    case .ready:
      log(.info, event, fields: fields)
    case .waiting:
      log(.warning, event, fields: fields)
    case .failed:
      // Usually the port is still held by the previous client's listener; try again shortly.
      log(.warning, event, fields: fields)
      sideListeners[side]?.listener?.cancel()
      sideListeners[side]?.listener = nil
      sideListeners[side]?.retryAt = .now + Self.retryDelay
    default:
      log(.debug, event, fields: fields)
    }
  }

  /// Switches to a side link, dropping the Wi-Fi connection (or an older side link). The cable
  /// outranks Bluetooth, so a Bluetooth link that arrives while the cable is up is turned away.
  private func accept(_ incoming: NWConnection, side: SideLink, generation: Int) {
    guard generation == sideListeners[side]?.generation, isStarted else {
      incoming.cancel()
      return
    }
    if side == .bluetooth && sideLink == .usb {
      logLimited(.info, "bluetoothDeclined", "The cable carries the link; Bluetooth waits")
      incoming.cancel()
      return
    }
    if side == .bluetooth, let until = bluetoothHoldoffUntil, ContinuousClock.now < until {
      logLimited(.info, "bluetoothDeclined", "Bluetooth went silent recently; staying on Wi-Fi")
      incoming.cancel()
      return
    }
    log(
      .info, "\(side.rawValue)Connected", "The Mac connected over \(side.displayName)",
      fields: [
        "remote": .string(incoming.endpoint.debugDescription),
        "replaced": .string(sideLink?.rawValue ?? (connection == nil ? "none" : "wifi")),
      ])
    // No bye: the Mac keeps this phone as the controller and carries on over the new flow. The
    // browser keeps running so the Wi-Fi endpoint is ready for a fallback.
    detachConnection()?.cancel()
    retryAt = nil
    sideLink = side
    setStatus(.connecting, reason: "the Mac connected over \(side.displayName)")
    begin(incoming, description: side.displayName)
  }

  /// Drops the side link and goes back to Wi-Fi straight away.
  private func fallBack(from side: SideLink, reason: String) {
    log(
      .warning, "\(side.rawValue)Disconnected", "Falling back to Wi-Fi",
      fields: ["reason": .string(reason)])
    detachConnection()?.cancel()
    publishStats()
    let closed = "\(side.displayName) link closed: \(reason)"
    switch configuration.target {
    case .bonjour:
      setStatus(.searching, reason: closed)
      if browser == nil {
        startBrowser()
      }
    case .host:
      setStatus(.connecting, reason: closed)
    }
    connectIfPossible()
  }

  // MARK: - Receiving

  private func receive(token: Int) {
    guard token == connectionToken, let connection else { return }
    connection.receiveMessage { [weak self] data, _, _, error in
      self?.received(data, error: error, token: token)
    }
  }

  private func received(_ data: Data?, error: NWError?, token: Int) {
    guard token == connectionToken, isStarted else { return }
    if let error {
      log(.error, "receiveError", fields: error.logFields)
      connectionFailed(
        Self.failureStatus(for: error), reason: "receive failed: \(error.networkDescription)")
      return
    }
    // A stream has no empty packets: nothing received means the other end closed the link.
    if let sideLink, data?.isEmpty ?? true {
      connectionFailed(.connecting, reason: "the \(sideLink.displayName) link closed")
      return
    }
    if let data {
      do {
        handle(try Packet.decode(data))
      } catch {
        logLimited(
          .warning, "decodeError", "\(error)", fields: ["bytes": .int(data.count)])
      }
    }
    receive(token: token)
  }

  private func handle(_ packet: Packet) {
    lastHeard = .now
    if isNotResponding {
      isNotResponding = false
      setStatus(statusFromWelcome, reason: "the Mac answered again")
    }
    switch packet {
    case .welcome(let welcome):
      handleWelcome(welcome)
    case .pong(let pong):
      handlePong(pong)
    case .logAck(let ack):
      logOutbox?.acknowledge(stream: ack.stream, through: ack.throughID, now: .now)
    case .state, .ping, .hello, .bye, .log:
      break
    }
  }

  private func handleWelcome(_ packet: WelcomePacket) {
    let previous = welcome
    welcome = packet
    if previous?.status != packet.status {
      log(
        .info, "welcome",
        fields: [
          "status": .string(String(describing: packet.status)),
          "previous": .string(previous.map { String(describing: $0.status) } ?? "none"),
          "mac": .string(packet.macName),
        ])
    }
    setStatus(statusFromWelcome, reason: "welcome \(packet.status)")
    if packet.status == .accepted && previous?.status != .accepted {
      hasUnsentState = latestState != nil
      nextPingAt = .now
      pumpState()
    }
  }

  private func handlePong(_ pong: PongPacket) {
    let roundTripMs = monitor.recordPong(
      id: pong.id, echoedMicros: pong.phoneTimeMicros, arrivalMicros: Uptime.micros())
    publishStats()
    logOutbox?.roundTrip = stats.rttMedianMs.map { .milliseconds($0) }
    guard let roundTripMs else { return }
    summary.pongs += 1
    summary.roundTripsMs.append(roundTripMs)
    if roundTripMs > Self.slowRoundTripMs {
      logLimited(
        .warning, "slowPing",
        fields: ["rttMs": .double(roundTripMs), "pingID": .int(Int(pong.id))])
    }
  }

  private var statusFromWelcome: ClientStatus {
    guard let welcome else { return .connecting }
    switch welcome.status {
    case .pending: return .waitingForApproval(macName: welcome.macName)
    case .accepted: return .connected(macName: welcome.macName)
    case .denied: return .denied(macName: welcome.macName)
    case .busy: return .busy(macName: welcome.macName)
    case .disconnected: return .disconnected(macName: welcome.macName)
    }
  }

  // MARK: - Sending

  private func sendHello() {
    sendTracked(helloData, kind: "hello")
    let interval = welcome == nil ? configuration.firstHelloInterval : configuration.helloInterval
    nextHelloAt = .now + interval
  }

  private func sendPing() {
    nextPingID &+= 1
    let sentMicros = Uptime.micros()
    monitor.recordPing(id: nextPingID, sentMicros: sentMicros)
    sendTracked(.ping(PingPacket(id: nextPingID, phoneTimeMicros: sentMicros)), kind: "ping")
    summary.pingsSent += 1
    nextPingAt = .now + configuration.pingInterval
  }

  private func sendTracked(_ packet: Packet, kind: String) {
    sendTracked(packet.encoded(), kind: kind)
  }

  /// Sends a datagram whose only follow-up is logging a failed send.
  private func sendTracked(
    _ datagram: Data, kind: String, context: NWConnection.ContentContext = .defaultMessage
  ) {
    guard let connection else { return }
    let token = connectionToken
    connection.send(
      content: datagram, contentContext: context, isComplete: true,
      completion: .contentProcessed { [weak self] error in
        guard let error else { return }
        self?.sendFailed(error, kind: kind, token: token)
      })
  }

  /// Sends the latest state if one is waiting and the previous send has completed.
  private func pumpState() {
    guard hasUnsentState, !isSendInFlight, isConnectionReady, welcome?.status == .accepted,
          let connection, let state = latestState
    else { return }
    hasUnsentState = false
    isSendInFlight = true
    lastSentAt = .now
    sentSincePreviousSample += 1
    summary.statesSent += 1
    seq &+= 1
    let packet = StatePacket(
      epoch: epoch, seq: seq, phoneTimeMicros: Uptime.micros(), state: state)
    let token = connectionToken
    connection.send(
      content: Packet.state(packet).encoded(),
      completion: .contentProcessed { [weak self] error in
        self?.sendCompleted(error: error, token: token)
      })
  }

  private func sendCompleted(error: NWError?, token: Int) {
    guard token == connectionToken else { return }
    if let error {
      sendFailed(error, kind: "state", token: token)
    }
    isSendInFlight = false
    pumpState()
    // The gap behind a state packet is the log stream's chance to go.
    if isConnectionReady && welcome?.status == .accepted {
      sendLogs(.now)
    }
  }

  private func sendFailed(_ error: NWError, kind: String, token: Int) {
    guard token == connectionToken, isStarted else { return }
    summary.sendErrors += 1
    var fields = error.logFields
    fields["packet"] = .string(kind)
    logLimited(.warning, "sendError", fields: fields)
  }

  /// A state packet is waiting to go or still being sent. Log packets wait for it, so they never
  /// queue in front of one.
  private var isStatePending: Bool {
    welcome?.status == .accepted && (isSendInFlight || (hasUnsentState && latestState != nil))
  }

  /// Sends the next log packet from the outbox, if nothing else is in the way.
  private func sendLogs(_ now: ContinuousClock.Instant) {
    guard let logOutbox, let connection, !isNotResponding else { return }
    // A send that never completed would hold up the log stream for good.
    if isLogSendInFlight && now - lastLogSentAt > Self.sendStallTimeout {
      isLogSendInFlight = false
    }
    guard !isLogSendInFlight, !isStatePending else { return }
    // The cable has room to spare; Wi-Fi and Bluetooth need the log stream held back.
    switch sideLink {
    case .usb:
      break
    case .bluetooth:
      guard bluetoothLogBudget.canSend(now: now) else { return }
    case nil:
      if logBudget?.canSend(now: now) == false { return }
    }
    guard let datagram = logOutbox.nextDatagram(now: now) else { return }
    switch sideLink {
    case .usb: break
    case .bluetooth: bluetoothLogBudget.charge(datagram.count)
    case nil: logBudget?.charge(datagram.count)
    }
    isLogSendInFlight = true
    lastLogSentAt = now
    let token = connectionToken
    connection.send(
      content: datagram, contentContext: logContext, isComplete: true,
      completion: .contentProcessed { [weak self] error in
        self?.logSendCompleted(error: error, token: token)
      })
  }

  private func logSendCompleted(error: NWError?, token: Int) {
    guard token == connectionToken else { return }
    isLogSendInFlight = false
    if let error {
      sendFailed(error, kind: "log", token: token)
    }
  }

  // MARK: - Timer

  private func startTimer() {
    tickTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + tickInterval.dispatchInterval, repeating: tickInterval.dispatchInterval,
      leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    tickTimer = timer
    timer.resume()
  }

  private func tick() {
    guard isStarted else { return }
    let now = ContinuousClock.now

    for (side, state) in sideListeners {
      if let due = state.retryAt, now >= due {
        startListener(for: side)
      }
    }
    if let due = retryAt, now >= due {
      retryAt = nil
      if case .bonjour = configuration.target, browser == nil {
        startBrowser()
      }
      connectIfPossible()
    }
    if isConnectionReady {
      tickConnection(now)
    }
    sampleSendRate(now)
    if isConnectionReady && now >= nextSummaryAt {
      logLinkSummary()
      nextSummaryAt = now + Self.linkSummaryInterval
    }
    flushLimitedLogs(now)
  }

  private func tickConnection(_ now: ContinuousClock.Instant) {
    let silence = now - lastHeard
    if silence >= configuration.reconnectTimeout {
      reconnect(silence: silence)
      return
    }
    if silence >= configuration.notRespondingTimeout, let welcome, !isNotResponding {
      isNotResponding = true
      log(.warning, "notResponding", fields: ["silenceMs": .double(silence.milliseconds)])
      setStatus(
        .notResponding(macName: welcome.macName),
        reason: "no reply for \(Int(silence.milliseconds)) ms")
    }
    if now >= nextHelloAt {
      sendHello()
    }
    guard welcome?.status == .accepted else {
      if welcome?.status == .busy {
        sendLogs(now)
      }
      return
    }

    // A send that never completed would block every later one.
    if isSendInFlight && now - lastSentAt > Self.sendStallTimeout {
      isSendInFlight = false
      logLimited(
        .warning, "sendStall", "A state send never completed",
        fields: ["stalledMs": .double((now - lastSentAt).milliseconds)])
    }
    // Resend when the next tick would pass the keepalive deadline. Ticks are a quarter interval
    // apart, so keepalives come 3/4 to 1 interval after the previous send.
    if now - lastSentAt + tickInterval > configuration.keepaliveInterval && latestState != nil {
      hasUnsentState = true
    }
    pumpState()
    if now >= nextPingAt {
      sendPing()
    }
    sendLogs(now)
  }

  private func sampleSendRate(_ now: ContinuousClock.Instant) {
    let elapsed = now - rateSampleStart
    guard elapsed >= Self.rateSampleInterval else { return }
    monitor.recordSends(sentSincePreviousSample, over: elapsed.seconds)
    sentSincePreviousSample = 0
    rateSampleStart = now
    publishStats()
  }

  // MARK: - Status

  private func setStatus(_ newStatus: ClientStatus, reason: String) {
    let previous = shared.withLock { shared in
      let previous = shared.status
      shared.status = newStatus
      return previous
    }
    guard previous != newStatus else { return }
    var fields: [String: LogValue] = [
      "from": .string(previous.logName),
      "to": .string(newStatus.logName),
      "reason": .string(reason),
    ]
    if let detail = newStatus.logDetail {
      fields["detail"] = .string(detail)
    }
    log(newStatus.isProblem ? .warning : .info, "status", fields: fields)
    onStatus(newStatus)
  }

  /// Replaces a "denied" or "failed" status with `recovered`, once the thing that failed works.
  private func clearError(to recovered: ClientStatus, reason: String) {
    switch status {
    case .localNetworkDenied, .failed:
      setStatus(recovered, reason: reason)
    default:
      break
    }
  }

  private func publishStats() {
    var snapshot = monitor.snapshot(nowMicros: Uptime.micros())
    snapshot.transport = sideLink?.transport ?? .wifi
    if let outboxStats = logOutbox?.stats {
      snapshot.logRecordsQueued = outboxStats.queuedRecords
      snapshot.logRecordsDropped = outboxStats.dropped
    }
    shared.withLock { $0.stats = snapshot }
  }

  // MARK: - Logging

  private func log(
    _ level: LogLevel, _ event: String, _ message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    logOutbox?.log(
      level: level, category: Self.logCategory, event: event, message: message, fields: fields)
  }

  /// Logs the first `event` and counts repeats for a second, for events that can happen on every
  /// packet.
  private func logLimited(
    _ level: LogLevel, _ event: String, _ message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    guard logOutbox != nil, logLimiter.admit(event, level: level, now: .now) else { return }
    log(level, event, message, fields: fields)
  }

  private func flushLimitedLogs(_ now: ContinuousClock.Instant) {
    guard let logOutbox else { return }
    for summary in logLimiter.drainSummaries(now: now) {
      logOutbox.enqueue(.log(summary.entry(category: Self.logCategory)))
    }
  }

  /// Logs the last second of the link: round trips, pings, state sends, send errors and the
  /// outbox.
  private func logLinkSummary() {
    guard let logOutbox else { return }
    let stats = monitor.snapshot(nowMicros: Uptime.micros())
    let outbox = logOutbox.stats
    var fields: [String: LogValue] = [
      "pingsSent": .int(summary.pingsSent),
      "pongs": .int(summary.pongs),
      "pingLossRecent": .double(stats.pingLoss),
      "statesSent": .int(summary.statesSent),
      "sendErrors": .int(summary.sendErrors),
      "welcome": .string(welcome.map { String(describing: $0.status) } ?? "none"),
      "transport": .string((sideLink?.transport ?? .wifi).rawValue),
      "logQueued": .int(outbox.queuedRecords),
      "logQueuedBytes": .int(outbox.queuedBytes),
      "logAckedThrough": .int(Int(outbox.ackedThrough)),
      "logDropped": .int(outbox.dropped),
      "logPacketsSent": .int(outbox.packetsSent),
      "logRetransmits": .int(outbox.retransmits),
      "logRetransmitTimeoutMs": .double(outbox.retransmitTimeout.milliseconds),
    ]
    let sorted = summary.roundTripsMs.sorted()
    if !sorted.isEmpty {
      fields["rttP50Ms"] = .double(sorted[sorted.count / 2])
      fields["rttMaxMs"] = .double(sorted[sorted.count - 1])
    }
    summary = LinkSummary()
    log(.info, "link", fields: fields)
  }

  // MARK: - Helpers

  private static func failureStatus(for error: NWError) -> ClientStatus {
    error.isLocalNetworkDenied ? .localNetworkDenied : .failed(error.networkDescription)
  }

  private static func randomEpoch(differentFrom previous: UInt16) -> UInt16 {
    var epoch = UInt16.random(in: .min ... .max)
    while epoch == previous {
      epoch = UInt16.random(in: .min ... .max)
    }
    return epoch
  }
}

extension ClientStatus {
  /// The case name, such as `connected`.
  fileprivate var logName: String {
    switch self {
    case .stopped: "stopped"
    case .searching: "searching"
    case .connecting: "connecting"
    case .waitingForApproval: "waitingForApproval"
    case .connected: "connected"
    case .denied: "denied"
    case .busy: "busy"
    case .disconnected: "disconnected"
    case .notResponding: "notResponding"
    case .localNetworkDenied: "localNetworkDenied"
    case .failed: "failed"
    }
  }

  /// The Mac's name or the failure message, if the case carries one.
  fileprivate var logDetail: String? {
    switch self {
    case .waitingForApproval(let macName), .connected(let macName), .denied(let macName),
      .busy(let macName), .disconnected(let macName), .notResponding(let macName):
      macName
    case .failed(let message):
      message
    case .stopped, .searching, .connecting, .localNetworkDenied:
      nil
    }
  }

  fileprivate var isProblem: Bool {
    switch self {
    case .denied, .disconnected, .notResponding, .localNetworkDenied, .failed: true
    default: false
    }
  }
}

extension ClientTarget {
  fileprivate var logDescription: String {
    switch self {
    case .bonjour(let name): "bonjour:\(name ?? "first found")"
    case .host(let host, let port): "host:\(host):\(port)"
    }
  }
}
