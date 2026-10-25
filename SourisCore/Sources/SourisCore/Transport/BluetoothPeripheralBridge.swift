#if os(iOS)
import CoreBluetooth
import Foundation
import Network

/// The phone's Bluetooth link, for the status line and the log.
public enum BluetoothPeripheralState: Equatable, Sendable {
  case stopped

  /// Bluetooth is off, not allowed for the app, or unsupported.
  case unavailable(String)

  /// Advertising, waiting for the Mac to connect.
  case advertising

  /// The Mac is connected and subscribed; packets are relayed.
  case connected
}

/// What the bridge reports. Always delivered on the bridge's queue.
public enum BluetoothPeripheralEvent: Sendable {
  case stateChanged(BluetoothPeripheralState)

  /// An entry for the phone's log, category `"bluetooth"`.
  case log(LogEntry)
}

/// Carries the phone's link to the Mac over Bluetooth LE, as the cable's USB bridge does on the
/// Mac side.
///
/// - The phone advertises `BluetoothService.service`. The Mac's `BluetoothCentralBridge` connects,
///   subscribes to the outbox and writes to the inbox.
/// - Once the Mac subscribes, the bridge connects over loopback TCP to the `SourisClient`'s
///   Bluetooth listener (`WireProtocol.bluetoothPort`, `StreamFraming`), which makes Bluetooth the
///   client's link unless the cable is up. A refused connection is retried every 2 s.
/// - Packets from the client go out as outbox notifications through a `BluetoothSendQueue`, so the
///   newest state replaces an older one that hasn't gone yet. A `BluetoothPacer` spaces the
///   notifications so iOS's transmit queue never fills, measuring the link from the round trips
///   of the client's pings, timed from when each ping is handed to Bluetooth so the pacer's own
///   wait isn't counted. While states keep coming, a log fragment goes ahead of the state at
///   most every `largeFragmentSpacing`. Fragments the Mac writes are reassembled and handed to
///   the client.
/// - It asks for the shortest connection interval the Mac allows.
///
/// Thread safety: every method may be called from any thread. Events arrive on `queue`.
public final class BluetoothPeripheralBridge: NSObject, @unchecked Sendable {
  private static let retryDelay = DispatchTimeInterval.seconds(2)
  private static let logCategory = "bluetooth"
  private static let summaryInterval = Duration.seconds(1)

  /// Fragments of large packets allowed to wait; more is a backlog the log outbox will resend.
  private static let maxQueuedLargeFragments = 256

  /// While the cursor moves, a log fragment may take a state's turn this often, seconds. At one
  /// every 250 ms the phone's 5 Hz stats alone outran it and its log fell behind.
  private static let largeFragmentSpacing: TimeInterval = 0.1

  /// Pings handed over this long ago without a pong are forgotten, seconds.
  private static let pingTimeout: TimeInterval = 5

  private let queue: DispatchQueue
  private let clientPort: UInt16
  private let onEvent: @Sendable (BluetoothPeripheralEvent) -> Void

  private var isStarted = false
  private var manager: CBPeripheralManager?
  private var outbox: CBMutableCharacteristic?
  private var inbox: CBMutableCharacteristic?
  private var central: CBCentral?
  private var state = BluetoothPeripheralState.stopped

  private var client: NWConnection?
  private var clientGeneration = 0
  private var sendQueue = BluetoothSendQueue()
  private var pacer = BluetoothPacer()
  private var isSendScheduled = false
  private var lastLargeSentAt: TimeInterval = 0
  private var reassembler = BluetoothReassembler()

  /// When each ping still waiting for its pong was handed to Bluetooth, by ping id.
  private var pingsHandedOver: [UInt32: TimeInterval] = [:]

  // Counts for the 1 Hz `link` entry.
  private var notificationsSent = 0
  private var notificationsRefused = 0
  private var packetsFromMac = 0
  private var droppedLargePackets = 0
  private var roundTripsMs: [Double] = []
  private var nextSummaryAt = ContinuousClock.now

  public init(
    clientPort: UInt16 = WireProtocol.bluetoothPort,
    queue: DispatchQueue = DispatchQueue(label: "souris.bluetooth", qos: .userInteractive),
    onEvent: @escaping @Sendable (BluetoothPeripheralEvent) -> Void
  ) {
    self.clientPort = clientPort
    self.queue = queue
    self.onEvent = onEvent
  }

  /// Starts advertising. The first start asks for Bluetooth permission.
  public func start() {
    queue.async { [self] in
      guard !isStarted else { return }
      isStarted = true
      log(.info, "start")
      manager = CBPeripheralManager(delegate: self, queue: queue)
    }
  }

  public func stop() {
    queue.async { [self] in
      guard isStarted else { return }
      isStarted = false
      log(.info, "stop")
      closeClient(reason: "stopped")
      manager?.stopAdvertising()
      manager?.removeAllServices()
      manager?.delegate = nil
      manager = nil
      central = nil
      outbox = nil
      inbox = nil
      setState(.stopped)
    }
  }

  // MARK: - Service

  private func publishService() {
    guard let manager else { return }
    let outbox = CBMutableCharacteristic(
      type: CBUUID(string: BluetoothService.outbox), properties: [.notify], value: nil,
      permissions: [.readable])
    let inbox = CBMutableCharacteristic(
      type: CBUUID(string: BluetoothService.inbox), properties: [.writeWithoutResponse],
      value: nil, permissions: [.writeable])
    let service = CBMutableService(type: CBUUID(string: BluetoothService.service), primary: true)
    service.characteristics = [outbox, inbox]
    self.outbox = outbox
    self.inbox = inbox
    manager.removeAllServices()
    manager.add(service)
  }

  // MARK: - Loopback link to the client

  private func openClient() {
    guard isStarted, central != nil, client == nil,
      let port = NWEndpoint.Port(rawValue: clientPort)
    else { return }
    clientGeneration += 1
    let generation = clientGeneration
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.defaultProtocolStack.applicationProtocols.insert(LengthPrefixFramer.options, at: 0)
    parameters.requiredInterfaceType = .loopback
    let connection = NWConnection(host: .ipv4(.loopback), port: port, using: parameters)
    connection.stateUpdateHandler = { [weak self] state in
      self?.clientStateChanged(state, generation: generation)
    }
    client = connection
    connection.start(queue: queue)
  }

  private func clientStateChanged(_ state: NWConnection.State, generation: Int) {
    guard generation == clientGeneration else { return }
    switch state {
    case .ready:
      log(.info, "clientLinked")
      receiveFromClient(generation: generation)
    case .failed(let error):
      clientClosed("failed: \(error.networkDescription)", generation: generation)
    case .waiting(let error):
      // Loopback refuses at once when nothing listens; waiting means the same thing here.
      clientClosed("waiting: \(error.networkDescription)", generation: generation)
    case .cancelled:
      clientClosed("cancelled", generation: generation)
    default:
      break
    }
  }

  private func receiveFromClient(generation: Int) {
    guard generation == clientGeneration, let client else { return }
    client.receiveMessage { [weak self] data, _, isComplete, error in
      guard let self, generation == clientGeneration else { return }
      if let error {
        clientClosed("receive failed: \(error.networkDescription)", generation: generation)
        return
      }
      if let data, !data.isEmpty {
        enqueue(data)
      } else if isComplete {
        clientClosed("the client closed the link", generation: generation)
        return
      }
      receiveFromClient(generation: generation)
    }
  }

  private func clientClosed(_ reason: String, generation: Int) {
    guard generation == clientGeneration, client != nil else { return }
    closeClient(reason: reason)
    guard isStarted, central != nil else { return }
    queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
      self?.openClient()
    }
  }

  private func closeClient(reason: String) {
    guard let client else { return }
    clientGeneration += 1
    client.cancel()
    self.client = nil
    sendQueue.removeAll()
    log(.debug, "clientClosed", reason)
  }

  // MARK: - Sending to the Mac

  private func enqueue(_ packet: Data) {
    guard let central else { return }
    let length = central.maximumUpdateValueLength
    let fragmentCount = (packet.count + length - 2) / max(1, length - 1)
    let queued = sendQueue.largeFragmentCount
    if fragmentCount > 1 && queued + fragmentCount > Self.maxQueuedLargeFragments {
      droppedLargePackets += 1
      return
    }
    sendQueue.enqueue(packet, maximumLength: length)
    pump()
  }

  /// Sends the next fragment if the pacer allows it, and otherwise schedules a try for when it
  /// will.
  private func pump() {
    defer { logSummaryIfDue() }
    guard let manager, let outbox, let central else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard pacer.canSend(at: now) else {
      if !sendQueue.isEmpty {
        schedulePump(at: pacer.nextSendTime)
      }
      return
    }
    let largeFirst = now - lastLargeSentAt >= Self.largeFragmentSpacing
    guard let (fragment, kind) = sendQueue.next(largeFirst: largeFirst) else { return }
    guard manager.updateValue(fragment, for: outbox, onSubscribedCentrals: [central]) else {
      // Bluetooth's queue is full; `peripheralManagerIsReady` calls back when there is room.
      notificationsRefused += 1
      pacer.didRefuse(at: now)
      return
    }
    sendQueue.removeNext(kind)
    pacer.didSend(at: now)
    notificationsSent += 1
    switch kind {
    case .small:
      notePingHandedOver(fragment, at: now)
    case .large:
      lastLargeSentAt = now
    case .state:
      break
    }
    if !sendQueue.isEmpty {
      schedulePump(at: pacer.nextSendTime)
    }
  }

  private func schedulePump(at time: TimeInterval) {
    guard !isSendScheduled else { return }
    isSendScheduled = true
    let delay = max(0, time - ProcessInfo.processInfo.systemUptime)
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      isSendScheduled = false
      pump()
    }
  }

  /// Remembers when a ping went to Bluetooth, if `fragment` holds one.
  private func notePingHandedOver(_ fragment: Data, at time: TimeInterval) {
    let packet = Data(fragment.dropFirst(BluetoothFraming.headerSize))
    guard BluetoothFraming.packetType(of: packet) == .ping,
      case .ping(let ping) = try? Packet.decode(packet)
    else { return }
    pingsHandedOver = pingsHandedOver.filter { time - $0.value < Self.pingTimeout }
    pingsHandedOver[ping.id] = time
  }

  /// Feeds the round trip of a pong from the Mac to the pacer.
  private func measureRoundTrip(of packet: Data) {
    guard BluetoothFraming.packetType(of: packet) == .pong,
      case .pong(let pong) = try? Packet.decode(packet),
      let handedOver = pingsHandedOver.removeValue(forKey: pong.id)
    else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let roundTrip = now - handedOver
    pacer.didMeasure(roundTrip: roundTrip, at: now)
    roundTripsMs.append(roundTrip * 1000)
  }

  // MARK: - Helpers

  private func logSummaryIfDue() {
    let now = ContinuousClock.now
    guard state == .connected, now >= nextSummaryAt else { return }
    nextSummaryAt = now + Self.summaryInterval
    var fields: [String: LogValue] = [
      "notifications": .int(notificationsSent),
      "queueFull": .int(notificationsRefused),
      "fromMac": .int(packetsFromMac),
      "intervalMs": .double((pacer.interval * 10_000).rounded() / 10),
      "waitingLarge": .int(sendQueue.largeFragmentCount),
    ]
    if droppedLargePackets > 0 {
      fields["droppedLarge"] = .int(droppedLargePackets)
    }
    if !roundTripsMs.isEmpty {
      let sorted = roundTripsMs.sorted()
      fields["rttP50Ms"] = .double((sorted[sorted.count / 2] * 10).rounded() / 10)
      fields["rttMaxMs"] = .double(((sorted.last ?? 0) * 10).rounded() / 10)
    }
    if let baseline = pacer.baselineRoundTrip {
      fields["rttBaselineMs"] = .double((baseline * 10_000).rounded() / 10)
    }
    if let central {
      fields["maxValue"] = .int(central.maximumUpdateValueLength)
    }
    log(.debug, "link", fields: fields)
    notificationsSent = 0
    notificationsRefused = 0
    packetsFromMac = 0
    droppedLargePackets = 0
    roundTripsMs.removeAll()
  }

  private func setState(_ newState: BluetoothPeripheralState) {
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

extension BluetoothPeripheralBridge: CBPeripheralManagerDelegate {
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard isStarted, peripheral === manager else { return }
    log(.info, "radio", fields: ["state": .string(peripheral.state.logName)])
    switch peripheral.state {
    case .poweredOn:
      publishService()
    default:
      closeClient(reason: "Bluetooth \(peripheral.state.logName)")
      central = nil
      setState(.unavailable(peripheral.state.logName))
    }
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?
  ) {
    guard isStarted, peripheral === manager else { return }
    if let error {
      log(.error, "serviceFailed", error.localizedDescription)
      setState(.unavailable(error.localizedDescription))
      return
    }
    peripheral.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BluetoothService.service)],
      CBAdvertisementDataLocalNameKey: BluetoothService.localName,
    ])
  }

  public func peripheralManagerDidStartAdvertising(
    _ peripheral: CBPeripheralManager, error: (any Error)?
  ) {
    guard isStarted, peripheral === manager else { return }
    if let error {
      log(.error, "advertisingFailed", error.localizedDescription)
      setState(.unavailable(error.localizedDescription))
      return
    }
    log(.info, "advertising")
    if central == nil {
      setState(.advertising)
    }
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    guard isStarted, peripheral === manager,
      characteristic.uuid == CBUUID(string: BluetoothService.outbox)
    else { return }
    if let current = self.central, current.identifier != central.identifier {
      log(.warning, "secondMacIgnored", fields: ["central": .string(central.identifier.uuidString)])
      return
    }
    self.central = central
    reassembler.reset()
    pacer.reset()
    pingsHandedOver.removeAll()
    peripheral.setDesiredConnectionLatency(.low, for: central)
    log(
      .info, "macSubscribed",
      fields: [
        "central": .string(central.identifier.uuidString),
        "maxValue": .int(central.maximumUpdateValueLength),
      ])
    setState(.connected)
    openClient()
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard isStarted, peripheral === manager, central.identifier == self.central?.identifier
    else { return }
    log(.info, "macUnsubscribed")
    self.central = nil
    closeClient(reason: "the Mac unsubscribed")
    setState(.advertising)
  }

  public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard peripheral === manager else { return }
    pump()
  }

  public func peripheralManager(
    _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
  ) {
    guard isStarted, peripheral === manager else { return }
    for request in requests where request.characteristic.uuid == inbox?.uuid {
      guard let value = request.value else { continue }
      do {
        if let packet = try reassembler.append(value) {
          packetsFromMac += 1
          measureRoundTrip(of: packet)
          client?.send(content: packet, completion: .idempotent)
        }
      } catch {
        log(.warning, "badFragment", error.description)
        reassembler.reset()
      }
    }
  }
}
#endif
