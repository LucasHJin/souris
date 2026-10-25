import AppKit
import CoreGraphics
import Foundation
import Observation

import SourisCore

extension PeerInfo {
  /// The phone's name for display, or "iPhone" if it sent none.
  var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "iPhone" : trimmed
  }
}

/// Everything the menu shows, and the owner of the server's lifecycle.
///
/// Input never passes through here. The server delivers events on the input queue to
/// `InputController`, which posts them and forwards only what the menu needs.
@MainActor
@Observable
final class MacModel {
  // MARK: - Menu state

  private(set) var serverState = ServerState.stopped
  private(set) var controller: PeerInfo?
  private(set) var isControllerSilent = false
  private(set) var isAccessibilityGranted = CGPreflightPostEventAccess()
  private(set) var localAddress: String?
  private(set) var packetsPerSecond = 0
  private(set) var lossFraction = 0.0
  private(set) var approvedDeviceIDs: Set<UUID>
  private(set) var acceptsConnections: Bool
  private(set) var allowsPeerToPeer: Bool
  private(set) var pointerPacing: PointerPacing
  private(set) var usesBluetooth: Bool
  private(set) var usbState = USBBridgeState.stopped
  private(set) var bluetoothState = BluetoothCentralState.stopped

  /// The controlling phone's packets are coming over the USB cable.
  private(set) var isControllerOnUSB = false

  /// The controlling phone's packets are coming over Bluetooth.
  private(set) var isControllerOnBluetooth = false

  /// Phones waiting for an answer. The first one is the one the alert is about.
  private var approvalQueue: [PeerInfo] = []

  // MARK: - Private state

  @ObservationIgnored private let preferences = Preferences()
  @ObservationIgnored private let log: MacLog
  @ObservationIgnored private let macName: String
  @ObservationIgnored private let displayLayout: DisplayLayout
  @ObservationIgnored private let inputController: InputController
  @ObservationIgnored private let frameClock: FrameClock
  @ObservationIgnored private var server: SourisServer?
  @ObservationIgnored private var usbBridge: USBBridge?
  @ObservationIgnored private var bluetoothBridge: BluetoothCentralBridge?

  /// Bumped whenever a server is started or stopped, so late reports from an old one are ignored.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var approvalAlert: ApprovalAlert?
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  @ObservationIgnored private var tickCount = 0
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []

  init() {
    let preferences = Preferences()
    let displayLayout = DisplayLayout()
    let log = MacLog()
    self.log = log
    self.displayLayout = displayLayout
    macName = SystemInfo.computerName()
    let inputController = InputController(
      clickInterval: NSEvent.doubleClickInterval, displayLayout: displayLayout,
      pacing: preferences.pointerPacing, log: log)
    self.inputController = inputController
    frameClock = FrameClock { inputController.displayFrame() }
    approvedDeviceIDs = preferences.approvedDeviceIDs
    acceptsConnections = preferences.acceptsConnections
    allowsPeerToPeer = preferences.allowsPeerToPeer
    pointerPacing = preferences.pointerPacing
    usesBluetooth = preferences.usesBluetooth
  }

  // MARK: - Derived menu content

  /// True while a phone is controlling the pointer.
  var isConnected: Bool {
    controller != nil && !isControllerSilent
  }

  /// The first line of the menu.
  var statusTitle: String {
    guard acceptsConnections else { return "Off" }
    switch serverState {
    case .stopped: return "Off"
    case .starting: return "Starting…"
    case .failed(let reason): return "Can’t listen: \(reason)"
    case .listening:
      guard isConnected else { return "Waiting for iPhone…" }
      if isControllerOnUSB { return "Connected over USB" }
      if isControllerOnBluetooth { return "Connected over Bluetooth" }
      return "Connected to iPhone"
    }
  }

  /// The Bluetooth link's state, when it isn't carrying the connection but is worth knowing.
  var bluetoothDetail: String? {
    guard acceptsConnections, usesBluetooth, !isControllerOnBluetooth else { return nil }
    switch bluetoothState {
    case .unavailable(let reason): return "Bluetooth: \(reason)"
    case .connecting: return "Bluetooth: connecting…"
    case .connected: return isControllerOnUSB ? nil : "Bluetooth: linked"
    case .stopped, .searching: return nil
    }
  }

  /// The USB cable's state, when an iPhone is plugged in and it isn't carrying the connection.
  var usbDetail: String? {
    guard acceptsConnections, !isControllerOnUSB else { return nil }
    switch usbState {
    case .waitingForApp: return "USB: open Souris on the iPhone"
    case .connected: return "USB: linked"
    case .stopped, .unavailable, .noDevice: return nil
    }
  }

  /// The packet readout, shown only while a phone controls the pointer.
  var statusDetail: String? {
    guard isConnected else { return nil }
    let loss = lossFraction.formatted(.percent.precision(.fractionLength(1)))
    return "\(packetsPerSecond) packets/s · \(loss) lost"
  }

  /// The address to type into the phone when Bonjour is blocked.
  var addressText: String? {
    guard case .listening(let port) = serverState, let localAddress else { return nil }
    return "Address: \(localAddress):\(port)"
  }

  /// The phone waiting for an answer, if any.
  var pendingApproval: PeerInfo? {
    approvalQueue.first
  }

  var hasApprovedDevices: Bool {
    !approvedDeviceIDs.isEmpty
  }

  /// The menu bar icon's SF Symbol.
  var menuBarSymbol: String {
    if !isAccessibilityGranted { return "exclamationmark.triangle" }
    if case .failed = serverState, acceptsConnections { return "exclamationmark.triangle" }
    return isConnected ? "computermouse.fill" : "computermouse"
  }

  // MARK: - Lifecycle

  /// Starts everything. Call once, after the app has finished launching.
  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    logLaunch()

    observeSystemNotifications()
    refreshAccessibility()
    if !isAccessibilityGranted {
      _ = CGRequestPostEventAccess()
    }
    refreshLocalAddress()
    startUSBBridge()
    if acceptsConnections {
      startServer()
    }
    startTicking()
  }

  /// Stops the server and releases anything held. Safe to call more than once.
  func shutDown() {
    log.log(.info, "app", "quit")
    stopServer()
    inputController.resetAndWait()
    log.flushAndWait()
  }

  // MARK: - Menu actions

  func setAcceptsConnections(_ isOn: Bool) {
    guard isOn != acceptsConnections else { return }
    log.log(.info, "menu", "acceptConnections", nil, ["on": .bool(isOn)])
    acceptsConnections = isOn
    preferences.acceptsConnections = isOn
    if isOn {
      startServer()
    } else {
      stopServer()
    }
  }

  func setAllowsPeerToPeer(_ isOn: Bool) {
    guard isOn != allowsPeerToPeer else { return }
    log.log(.info, "menu", "peerToPeer", nil, ["on": .bool(isOn)])
    allowsPeerToPeer = isOn
    preferences.allowsPeerToPeer = isOn
    if acceptsConnections {
      startServer()
    }
  }

  func setUsesBluetooth(_ isOn: Bool) {
    guard isOn != usesBluetooth else { return }
    log.log(.info, "menu", "bluetooth", nil, ["on": .bool(isOn)])
    usesBluetooth = isOn
    preferences.usesBluetooth = isOn
    if case .listening(let port) = serverState, isOn {
      startBluetoothBridge(serverPort: port)
    } else {
      stopBluetoothBridge()
    }
  }

  func setPointerPacing(_ pacing: PointerPacing) {
    guard pacing != pointerPacing else { return }
    log.log(.info, "menu", "pointerPacing", nil, ["pacing": .string(pacing.rawValue)])
    pointerPacing = pacing
    preferences.pointerPacing = pacing
    inputController.setPacing(pacing)
    updateFrameClock()
  }

  func disconnectController() {
    log.log(.info, "menu", "disconnect", "Disconnect iPhone chosen")
    server?.disconnectController()
  }

  func forgetApprovedDevices() {
    log.log(.info, "menu", "forgetApproved", nil, ["count": .int(approvedDeviceIDs.count)])
    approvedDeviceIDs = []
    preferences.approvedDeviceIDs = []
    server?.disconnectController()
    server?.approvedDevices = []
  }

  /// Brings the approval alert back to the front.
  func showApproval() {
    presentApproval()
  }

  /// Opens the log folder with this launch's file selected.
  func showLogs() {
    log.flushAndWait()
    NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
  }

  func openAccessibilitySettings() {
    let address = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    guard let url = URL(string: address) else { return }
    NSWorkspace.shared.open(url)
  }

  // MARK: - Server

  private func startServer() {
    stopServer()
    generation += 1
    let current = generation

    var configuration = SourisServer.Configuration(macName: macName)
    configuration.includesPeerToPeer = allowsPeerToPeer

    let input = inputController
    let report: @Sendable (InputReport) -> Void = { [weak self] item in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.handle(item, generation: current)
        }
      }
    }
    let server = SourisServer(configuration: configuration, queue: input.queue) { event in
      input.handle(event, report: report)
    }
    server.approvedDevices = approvedDeviceIDs
    self.server = server
    serverState = .starting
    server.start()
  }

  /// A listener can fail when the network changes under it, so try again shortly, unless the
  /// server has been restarted or turned off since.
  private func scheduleRestart() {
    log.log(.warning, "app", "serverRestartScheduled", "The listener failed; retrying in 3 s")
    let failedGeneration = generation
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard let self, generation == failedGeneration, acceptsConnections else { return }
      startServer()
    }
  }

  private func stopServer() {
    generation += 1
    server?.stop()
    server = nil
    usbBridge?.stop()
    stopBluetoothBridge()
    isControllerOnUSB = false
    isControllerOnBluetooth = false
    inputController.reset()
    serverState = .stopped
    controller = nil
    isControllerSilent = false
    packetsPerSecond = 0
    lossFraction = 0
    dismissApprovals()
    updateFrameClock()
  }

  /// The display link runs only while a phone is moving the pointer through the playout.
  private func updateFrameClock() {
    if isConnected && pointerPacing != .immediate {
      frameClock.start()
    } else {
      frameClock.stop()
    }
  }

  private func handle(_ report: InputReport, generation reportGeneration: Int) {
    guard reportGeneration == generation else { return }
    switch report {
    case .serverStateChanged(let state):
      serverState = state
      switch state {
      case .stopped:
        controller = nil
        isControllerSilent = false
        dismissApprovals()
      case .failed:
        controller = nil
        isControllerSilent = false
        dismissApprovals()
        scheduleRestart()
      case .listening(let port):
        refreshLocalAddress()
        usbBridge?.start(serverPort: port)
        if usesBluetooth {
          startBluetoothBridge(serverPort: port)
        }
      case .starting:
        break
      }
    case .approvalRequested(let peer):
      guard !approvalQueue.contains(where: { $0.deviceID == peer.deviceID }) else { return }
      approvalQueue.append(peer)
      presentApproval()
    case .controllerChanged(let peer):
      controller = peer
      isControllerSilent = false
      packetsPerSecond = 0
      lossFraction = 0
    case .controllerSilent:
      isControllerSilent = true
    case .controllerResumed:
      isControllerSilent = false
    }
    updateFrameClock()
  }

  // MARK: - USB

  /// The bridge lives as long as the app; it runs while the server listens.
  private func startUSBBridge() {
    let log = log
    usbBridge = USBBridge { [weak self] event in
      switch event {
      case .log(let entry):
        log.write(entry)
      case .stateChanged(let state):
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            self?.usbState = state
          }
        }
      }
    }
  }

  // MARK: - Bluetooth

  /// Created on first use, so the Bluetooth permission prompt only appears with the setting on.
  private func startBluetoothBridge(serverPort: UInt16) {
    if bluetoothBridge == nil {
      let log = log
      bluetoothBridge = BluetoothCentralBridge { [weak self] event in
        switch event {
        case .log(let entry):
          log.write(entry)
        case .stateChanged(let state):
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              self?.bluetoothState = state
            }
          }
        }
      }
    }
    bluetoothBridge?.start(serverPort: serverPort)
  }

  private func stopBluetoothBridge() {
    bluetoothBridge?.stop()
    isControllerOnBluetooth = false
  }

  // MARK: - Approval

  private func presentApproval() {
    guard let peer = approvalQueue.first else { return }
    if let approvalAlert {
      approvalAlert.bringToFront()
      return
    }
    let alert = ApprovalAlert(deviceName: peer.displayName) { [weak self] approved in
      self?.resolveApproval(for: peer, approved: approved)
    }
    approvalAlert = alert
    alert.show()
  }

  private func resolveApproval(for peer: PeerInfo, approved: Bool) {
    log.log(
      .info, "approval", approved ? "allowed" : "denied", nil,
      ["device": .string(peer.displayName), "deviceID": .string(peer.deviceID.uuidString)])
    approvalAlert = nil
    approvalQueue.removeAll { $0.deviceID == peer.deviceID }
    if approved {
      approvedDeviceIDs.insert(peer.deviceID)
      preferences.approvedDeviceIDs = approvedDeviceIDs
    }
    server?.resolveApproval(for: peer.deviceID, approved: approved)
    presentApproval()
  }

  /// Drops every pending request, e.g. when the server stops. A phone that is still trying asks
  /// again after the server restarts.
  private func dismissApprovals() {
    approvalAlert?.dismiss()
    approvalAlert = nil
    approvalQueue = []
  }

  // MARK: - System state

  private func observeSystemNotifications() {
    let center = NotificationCenter.default
    let screens = center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [displayLayout, weak self] _ in
      displayLayout.refresh()
      MainActor.assumeIsolated {
        self?.frameClock.restart()
      }
    }
    let terminating = center.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.shutDown()
      }
    }
    observers = [screens, terminating]
  }

  private func refreshAccessibility() {
    let granted = CGPreflightPostEventAccess()
    if granted != isAccessibilityGranted {
      isAccessibilityGranted = granted
      log.log(granted ? .info : .warning, "app", "accessibility", nil, ["granted": .bool(granted)])
    }
  }

  private func refreshLocalAddress() {
    let address = SystemInfo.localIPv4Address()
    if address != localAddress {
      localAddress = address
      log.log(.info, "app", "address", nil, ["address": .string(address ?? "none")])
    }
  }

  private func logLaunch() {
    let info = Bundle.main.infoDictionary ?? [:]
    let displays = displayLayout.bounds.map {
      "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))"
    }
    log.log(
      .info, "app", "launch", "Souris for Mac started",
      [
        "version": .string(info["CFBundleShortVersionString"] as? String ?? "?"),
        "build": .string(info["CFBundleVersion"] as? String ?? "?"),
        "system": .string(ProcessInfo.processInfo.operatingSystemVersionString),
        "macName": .string(macName),
        "displays": .string(displays.joined(separator: " ")),
        "accessibility": .bool(isAccessibilityGranted),
        "acceptsConnections": .bool(acceptsConnections),
        "peerToPeer": .bool(allowsPeerToPeer),
        "pointerPacing": .string(pointerPacing.rawValue),
        "bluetooth": .bool(usesBluetooth),
        "approvedDevices": .int(approvedDeviceIDs.count),
        "doubleClickInterval": .double(NSEvent.doubleClickInterval),
      ])
  }

  /// Runs once a second: packet readout, and the slower checks on every few ticks.
  private func startTicking() {
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        self?.tick()
      }
    }
  }

  private func tick() {
    tickCount += 1

    let onUSB = isConnected && (usbBridge?.isRelaying ?? false)
    let onBluetooth = isConnected && !onUSB && (bluetoothBridge?.isRelaying ?? false)
    if onUSB != isControllerOnUSB || onBluetooth != isControllerOnBluetooth {
      isControllerOnUSB = onUSB
      isControllerOnBluetooth = onBluetooth
      log.log(
        .info, "app", "transport", nil, ["usb": .bool(onUSB), "bluetooth": .bool(onBluetooth)])
    }

    if isConnected {
      let snapshot = inputController.snapshot
      let isFresh = ProcessInfo.processInfo.systemUptime - snapshot.updatedAt < 1.5
      let rate = isFresh ? Int(snapshot.packetsPerSecond.rounded()) : 0
      if rate != packetsPerSecond {
        packetsPerSecond = rate
      }
      if snapshot.stats.lossFraction != lossFraction {
        lossFraction = snapshot.stats.lossFraction
      }
    }

    // Check every 2 s until the permission is granted, then only occasionally in case it is
    // revoked.
    let accessibilityInterval = isAccessibilityGranted ? 10 : 2
    if tickCount % accessibilityInterval == 0 {
      refreshAccessibility()
    }
    if tickCount % 5 == 0 {
      refreshLocalAddress()
    }
  }
}
