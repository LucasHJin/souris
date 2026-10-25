#if os(macOS)
import CoreBluetooth
import Foundation
import Network
import Synchronization

/// The Mac's Bluetooth link, for the menu.
public enum BluetoothCentralState: Equatable, Sendable {
  case stopped

  /// Bluetooth is off, not allowed for the app, or unsupported.
  case unavailable(String)

  /// Scanning for an iPhone running Souris.
  case searching

  /// Found one; connecting and setting up.
  case connecting

  /// Linked to Souris on the iPhone and relaying its packets.
  case connected
}

/// What the bridge reports. Always delivered on the bridge's queue.
public enum BluetoothCentralEvent: Sendable {
  case stateChanged(BluetoothCentralState)

  /// An entry for the Mac's diagnostic log, category `"bluetooth"`.
  case log(LogEntry)
}

/// Links an iPhone over Bluetooth LE to the Mac's `SourisServer`, as `USBBridge` does over the
/// cable.
///
/// - It scans for `BluetoothService.service`, connects to the first iPhone found, subscribes to
///   the outbox and finds the inbox.
/// - Each packet reassembled from the outbox goes to the server as a UDP datagram on loopback, and
///   every datagram the server sends back is written to the inbox in fragments. The server sees
///   an ordinary UDP flow from 127.0.0.1.
/// - On a disconnect it scans again. The phone decides which link it uses; while the cable
///   carries it, this link stays connected but idle.
///
/// Thread safety: every method may be called from any thread. Events arrive on `queue`.
public final class BluetoothCentralBridge: NSObject, @unchecked Sendable {
  private static let rescanDelay = DispatchTimeInterval.seconds(1)
  private static let relayingWindow = Duration.milliseconds(1500)
  private static let logCategory = "bluetooth"
  private static let summaryInterval = Duration.seconds(1)

  /// Fragments allowed to wait for the radio; past it the oldest replies are dropped (the phone
  /// asks again).
  private static let maxQueuedWrites = 256

  private let queue: DispatchQueue
  private let onEvent: @Sendable (BluetoothCentralEvent) -> Void
  private let lastUplink = Mutex<ContinuousClock.Instant?>(nil)

  private var serverPort: UInt16?
  private var manager: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var outbox: CBCharacteristic?
  private var inbox: CBCharacteristic?
  private var relay: NWConnection?
  private var relayGeneration = 0
  private var state = BluetoothCentralState.stopped
  private var reassembler = BluetoothReassembler()
  private var writes: [Data] = []

  /// Notifications closer together than this came in the same connection event.
  private static let sameEventGap = Duration.milliseconds(4)

  // Counts for the 1 Hz `link` entry.
  private var packetsUp = 0
  private var writesSent = 0
  private var notificationGapMax: Duration = .zero
  private var lastNotification: ContinuousClock.Instant?
  private var nextSummaryAt = ContinuousClock.now

  /// Gaps between the connection events notifications arrived in, milliseconds, and how many
  /// notifications came in each.
  private var eventGapsMs: [Double] = []
  private var notificationsInEvents = 0

  public init(
    queue: DispatchQueue = DispatchQueue(label: "souris.bluetooth", qos: .userInteractive),
    onEvent: @escaping @Sendable (BluetoothCentralEvent) -> Void
  ) {
    self.queue = queue
    self.onEvent = onEvent
  }

  /// True while packets from a phone came over Bluetooth within the last 1.5 s.
  public var isRelaying: Bool {
    guard let last = lastUplink.withLock({ $0 }) else { return false }
    return ContinuousClock.now - last < Self.relayingWindow
  }

  /// Starts scanning and relaying to the server on `serverPort`. The first start asks for
  /// Bluetooth permission. Calling it again with another port starts over with that one.
  public func start(serverPort: UInt16) {
    queue.async { [self] in
      guard serverPort != self.serverPort else { return }
      teardown()
      self.serverPort = serverPort
      log(.info, "start", fields: ["serverPort": .int(Int(serverPort))])
      if let manager {
        scanIfReady(manager)
      } else {
        manager = CBCentralManager(delegate: self, queue: queue)
      }
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

  // MARK: - Scanning and connecting

  private func scanIfReady(_ manager: CBCentralManager) {
    guard serverPort != nil, peripheral == nil else { return }
    guard manager.state == .poweredOn else {
      setState(.unavailable(manager.state.logName))
      return
    }
    // A phone that is already connected to this Mac (from a previous launch) doesn't advertise
    // to it again, so look there first.
    let service = CBUUID(string: BluetoothService.service)
    if let known = manager.retrieveConnectedPeripherals(withServices: [service]).first {
      connect(known, via: manager, reason: "already connected")
      return
    }
    manager.scanForPeripherals(withServices: [service])
    setState(.searching)
  }

  private func connect(_ peripheral: CBPeripheral, via manager: CBCentralManager, reason: String) {
    manager.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    log(
      .info, "connecting",
      fields: [
        "peripheral": .string(peripheral.identifier.uuidString),
        "name": .string(peripheral.name ?? "unknown"),
        "reason": .string(reason),
      ])
    setState(.connecting)
    manager.connect(peripheral)
  }

  /// Forgets the phone and scans again shortly.
  private func dropPeripheral(reason: String) {
    guard let dropped = peripheral else { return }
    log(.info, "disconnected", reason)
    closeRelay()
    if dropped.state != .disconnected {
      manager?.cancelPeripheralConnection(dropped)
    }
    peripheral = nil
    outbox = nil
    inbox = nil
    writes.removeAll()
    reassembler.reset()
    lastUplink.withLock { $0 = nil }
    queue.asyncAfter(deadline: .now() + Self.rescanDelay) { [weak self] in
      guard let self, let manager else { return }
      scanIfReady(manager)
    }
  }

  // MARK: - Relay to the server

  private func openRelay() {
    guard relay == nil, let serverPort, let port = NWEndpoint.Port(rawValue: serverPort) else {
      return
    }
    relayGeneration += 1
    let generation = relayGeneration
    let relay = NWConnection(host: .ipv4(.loopback), port: port, using: .udp)
    relay.stateUpdateHandler = { [weak self] state in
      guard case .failed(let error) = state else { return }
      self?.relayFailed(error, generation: generation)
    }
    self.relay = relay
    relay.start(queue: queue)
    receiveFromServer(generation: generation)
  }

  private func closeRelay() {
    relayGeneration += 1
    relay?.cancel()
    relay = nil
  }

  private func relayFailed(_ error: NWError, generation: Int) {
    guard generation == relayGeneration else { return }
    log(.warning, "relayFailed", error.networkDescription)
    closeRelay()
    openRelay()
  }

  /// Datagrams from the server, to the phone.
  private func receiveFromServer(generation: Int) {
    guard generation == relayGeneration, let relay else { return }
    relay.receiveMessage { [weak self] data, _, _, error in
      guard let self, generation == relayGeneration else { return }
      if let error {
        relayFailed(error, generation: generation)
        return
      }
      if let data, !data.isEmpty {
        queueWrite(data)
      }
      receiveFromServer(generation: generation)
    }
  }

  private func queueWrite(_ packet: Data) {
    guard let peripheral, inbox != nil else { return }
    let length = peripheral.maximumWriteValueLength(for: .withoutResponse)
    writes += BluetoothFraming.fragments(of: packet, maximumLength: length)
    if writes.count > Self.maxQueuedWrites {
      writes.removeFirst(writes.count - Self.maxQueuedWrites)
      reassembler.reset()
    }
    pumpWrites()
  }

  private func pumpWrites() {
    guard let peripheral, let inbox else { return }
    while !writes.isEmpty && peripheral.canSendWriteWithoutResponse {
      peripheral.writeValue(writes.removeFirst(), for: inbox, type: .withoutResponse)
      writesSent += 1
    }
  }

  // MARK: - Helpers

  private func teardown() {
    manager?.stopScan()
    if let peripheral {
      manager?.cancelPeripheralConnection(peripheral)
    }
    closeRelay()
    peripheral = nil
    outbox = nil
    inbox = nil
    writes.removeAll()
    reassembler.reset()
    lastUplink.withLock { $0 = nil }
  }

  private func logSummaryIfDue(now: ContinuousClock.Instant) {
    guard now >= nextSummaryAt else { return }
    nextSummaryAt = now + Self.summaryInterval
    var fields: [String: LogValue] = [
      "packetsUp": .int(packetsUp),
      "writes": .int(writesSent),
      "maxGapMs": .double((notificationGapMax.milliseconds * 10).rounded() / 10),
    ]
    if !eventGapsMs.isEmpty {
      // The shortest gaps between events are the connection interval; the median shows how
      // often events go by with nothing in them.
      let sorted = eventGapsMs.sorted()
      fields["eventGapP10Ms"] = .double((sorted[sorted.count / 10] * 10).rounded() / 10)
      fields["eventGapP50Ms"] = .double((sorted[sorted.count / 2] * 10).rounded() / 10)
      let perEvent = Double(notificationsInEvents) / Double(sorted.count + 1)
      fields["perEvent"] = .double((perEvent * 10).rounded() / 10)
    }
    log(.debug, "link", fields: fields)
    packetsUp = 0
    writesSent = 0
    notificationGapMax = .zero
    eventGapsMs.removeAll()
    notificationsInEvents = 0
  }

  private func setState(_ newState: BluetoothCentralState) {
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

extension BluetoothCentralBridge: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === manager else { return }
    log(.info, "radio", fields: ["state": .string(central.state.logName)])
    if central.state == .poweredOn {
      scanIfReady(central)
    } else {
      dropPeripheral(reason: "Bluetooth \(central.state.logName)")
      setState(serverPort == nil ? .stopped : .unavailable(central.state.logName))
    }
  }

  public func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    guard central === manager, self.peripheral == nil, serverPort != nil else { return }
    connect(peripheral, via: central, reason: "found, RSSI \(RSSI)")
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard central === manager, peripheral === self.peripheral else { return }
    log(.info, "connected")
    peripheral.discoverServices([CBUUID(string: BluetoothService.service)])
  }

  public func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
  ) {
    guard central === manager, peripheral === self.peripheral else { return }
    dropPeripheral(reason: "connect failed: \(error?.localizedDescription ?? "unknown")")
  }

  public func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    guard central === manager, peripheral === self.peripheral else { return }
    dropPeripheral(reason: error?.localizedDescription ?? "disconnected")
  }
}

extension BluetoothCentralBridge: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    guard peripheral === self.peripheral else { return }
    let uuid = CBUUID(string: BluetoothService.service)
    guard let service = peripheral.services?.first(where: { $0.uuid == uuid }) else {
      dropPeripheral(reason: "no Souris service: \(error?.localizedDescription ?? "missing")")
      return
    }
    peripheral.discoverCharacteristics(
      [CBUUID(string: BluetoothService.outbox), CBUUID(string: BluetoothService.inbox)],
      for: service)
  }

  public func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
    error: (any Error)?
  ) {
    guard peripheral === self.peripheral else { return }
    let characteristics = service.characteristics ?? []
    outbox = characteristics.first { $0.uuid == CBUUID(string: BluetoothService.outbox) }
    inbox = characteristics.first { $0.uuid == CBUUID(string: BluetoothService.inbox) }
    guard let outbox, inbox != nil else {
      dropPeripheral(reason: "characteristics missing: \(error?.localizedDescription ?? "")")
      return
    }
    peripheral.setNotifyValue(true, for: outbox)
  }

  public func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    guard peripheral === self.peripheral, characteristic.uuid == outbox?.uuid else { return }
    guard characteristic.isNotifying else {
      dropPeripheral(reason: "subscribe failed: \(error?.localizedDescription ?? "not notifying")")
      return
    }
    openRelay()
    log(
      .info, "linked", "Linked to Souris on the iPhone over Bluetooth",
      fields: [
        "peripheral": .string(peripheral.identifier.uuidString),
        "maxWrite": .int(peripheral.maximumWriteValueLength(for: .withoutResponse)),
      ])
    setState(.connected)
  }

  public func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    guard peripheral === self.peripheral, characteristic.uuid == outbox?.uuid,
      let value = characteristic.value
    else { return }
    let now = ContinuousClock.now
    if let lastNotification {
      let gap = now - lastNotification
      notificationGapMax = max(notificationGapMax, gap)
      if gap >= Self.sameEventGap {
        eventGapsMs.append(gap.milliseconds)
      }
    }
    lastNotification = now
    notificationsInEvents += 1
    do {
      if let packet = try reassembler.append(value) {
        packetsUp += 1
        lastUplink.withLock { $0 = now }
        relay?.send(content: packet, completion: .idempotent)
      }
    } catch {
      log(.warning, "badFragment", error.description)
      reassembler.reset()
    }
    logSummaryIfDue(now: now)
  }

  public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard peripheral === self.peripheral else { return }
    pumpWrites()
  }

  public func peripheral(
    _ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]
  ) {
    guard peripheral === self.peripheral else { return }
    // The phone app restarted its service; set everything up again.
    dropPeripheral(reason: "the iPhone's service changed")
  }
}
#endif
