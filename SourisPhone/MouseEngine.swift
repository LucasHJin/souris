import AVFoundation
import Foundation

import SourisCore

/// The phone's sensing-to-network path: ARKit and Core Motion samples, touch events and volume
/// presses go into the `MotionPipeline`, and every change in its state goes out through the
/// `SourisClient`. It also keeps the diagnostic log, which goes to the Mac through the client's
/// `LogOutbox` and to a local file.
///
/// All mutable state lives on `queue`. Every public method may be called from any thread and
/// hops onto it. The UI reads `snapshot()`, which never touches the queue.
final class MouseEngine: @unchecked Sendable {
  /// Every this many snapshot ticks (100 ms each) a `stats` entry is logged.
  private static let statsEveryTicks = 2

  private let queue = DispatchQueue(label: "souris.pipeline", qos: .userInteractive)
  private let snapshotBox = SnapshotBox()
  private let identity: DeviceIdentity
  private let logFile: PhoneLogFile

  /// Outlives every client, so whatever was logged while disconnected reaches the Mac later.
  private let logOutbox: LogOutbox

  private var pipeline: MotionPipeline
  private var network: NetworkSettings
  private var autoFocus: Bool

  private var client: SourisClient?
  private var clientStatus = ClientStatus.stopped
  private var macNames: [String] = []

  /// Relays the client's link over Bluetooth LE while the setting is on and the app runs.
  private var bluetoothBridge: BluetoothPeripheralBridge?
  private var bluetoothState = BluetoothPeripheralState.stopped

  /// Bumped whenever the client is replaced, so a stopped client's late callbacks are ignored.
  private var clientGeneration = 0
  private var lastSent: MouseState?

  private var isRunning = false
  private var isSuspended = true
  private var isSettingsOpen = false
  private var isPipelinePaused = false

  private var cameraProblem: CameraProblem?
  private var isCameraInterrupted = false
  private var videoFormat: VideoFormatInfo?
  private var minimumFocusDistance: Int?

  private var recorder: SessionRecorder?
  private var recordingFailure: String?
  private var recordingID: UInt32 = 0
  private var snapshotTimer: (any DispatchSourceTimer)?

  /// Logs a stall when `queue` stops running, with the work it last started.
  private var watchdog: QueueWatchdog?

  // The previous `stats` entry's readings, for per-window differences.
  private var snapshotTicks = 0
  private var statsBaseline: PipelineDiagnostics?
  private var statsBaselineTime: TimeInterval = 0
  private var thermalState = ProcessInfo.processInfo.thermalState

  // Lazy so the callbacks can capture `self`; first touched from `queue`.
  private lazy var arTracker = ARTracker(
    queue: queue,
    onSample: { [weak self] sample in self?.receive(sample) },
    onEvent: { [weak self] event in self?.receive(event) })

  private lazy var motionTracker = MotionTracker(
    queue: queue,
    onSample: { [weak self] sample in self?.receive(sample) })

  init(
    identity: DeviceIdentity,
    pipelineSettings: PipelineSettings,
    network: NetworkSettings,
    autoFocus: Bool
  ) {
    self.identity = identity
    self.network = network
    self.autoFocus = autoFocus
    pipeline = MotionPipeline(settings: pipelineSettings)
    let logFile = PhoneLogFile()
    self.logFile = logFile
    logOutbox = LogOutbox { record in
      if case .log(let entry) = record {
        logFile.append(entry)
      }
    }
    startSnapshotTimer()
    watchdog = QueueWatchdog(queue: queue) { [weak self] stall in
      self?.logStall(stall)
    }
    queue.async { [self] in
      logLaunch(pipelineSettings: pipelineSettings)
    }
  }

  // MARK: - Public API

  /// The latest published snapshot.
  func snapshot() -> EngineSnapshot {
    snapshotBox.value
  }

  /// Starts the sensors and the client. Call when the scene becomes active.
  func activate() {
    queue.async { [self] in start() }
  }

  /// Pauses the pipeline, says goodbye to the Mac and stops the sensors.
  func deactivate() {
    queue.async { [self] in stop() }
  }

  /// Adds an entry to the log, stamped now. Safe from any thread.
  func log(
    _ level: LogLevel,
    _ category: String,
    _ event: String,
    _ message: String? = nil,
    _ fields: [String: LogValue] = [:]
  ) {
    let entry = LogEntry(
      level: level, category: category, event: event, message: message, fields: fields)
    queue.async { [self] in logOutbox.enqueue(.log(entry)) }
  }

  /// Forwards a batch from the touch classifier, in order.
  func handle(touchEvents: [TouchEvent]) {
    queue.async { [self] in
      watchdog?.note("touch")
      for event in touchEvents {
        recorder?.record(.touch(event))
        pipeline.handle(event)
        if case .button(let button, let isDown, _) = event {
          logNow(
            .debug, "touch", isDown ? "down" : "up",
            fields: ["button": .string(String(describing: button))])
        }
      }
      drainPipelineEvents()
      sendIfChanged()
    }
  }

  /// Forwards one volume-button press.
  func handle(scrollPress press: ScrollButtonPress) {
    queue.async { [self] in
      watchdog?.note("volume")
      recorder?.record(.scrollPress(press))
      pipeline.handle(press)
      if isPipelinePaused {
        logNow(.debug, "volume", "ignoredPress", fields: ["paused": true])
      }
      drainPipelineEvents()
      sendIfChanged()
    }
  }

  /// While the settings sheet is open the pipeline is paused but the client stays connected.
  func setSettingsOpen(_ isOpen: Bool) {
    queue.async { [self] in
      watchdog?.note("settings")
      isSettingsOpen = isOpen
      logNow(.info, "app", isOpen ? "settingsOpened" : "settingsClosed")
      updatePause()
      drainPipelineEvents()
      sendIfChanged()
    }
  }

  func update(pipelineSettings: PipelineSettings) {
    queue.async { [self] in
      let changes = SettingsDiff.changes(from: pipeline.settings, to: pipelineSettings)
      pipeline.settings = pipelineSettings
      recorder?.record(.settings(pipelineSettings))
      if !changes.isEmpty {
        logNow(.info, "settings", "pipeline", fields: changes)
      }
    }
  }

  /// Recreates the client when the network settings differ.
  func update(network newNetwork: NetworkSettings) {
    queue.async { [self] in
      watchdog?.note("network")
      guard newNetwork != network else { return }
      network = newNetwork
      logNow(.info, "settings", "network", fields: Self.fields(for: newNetwork))
      guard isRunning else { return }
      stopClient()
      startClient()
      updateBluetoothBridge()
    }
  }

  /// Starts a fresh session with the Mac (a new epoch), e.g. after the Mac disconnected this
  /// phone.
  func reconnect() {
    queue.async { [self] in
      logNow(.info, "app", "reconnect", "Reconnect tapped")
      guard isRunning else { return }
      stopClient()
      startClient()
    }
  }

  /// Re-runs the AR session with the new focus mode.
  func update(autoFocus enabled: Bool) {
    queue.async { [self] in
      guard enabled != autoFocus else { return }
      autoFocus = enabled
      logNow(.info, "settings", "autoFocus", fields: ["on": .bool(enabled)])
      guard isRunning, ARTracker.isSupported else { return }
      videoFormat = arTracker.run(autoFocus: enabled, resetTracking: false)
    }
  }

  func recenter() {
    queue.async { [self] in
      recorder?.record(.recenter)
      pipeline.recenter()
      drainPipelineEvents()
      sendIfChanged()
    }
  }

  func setRecording(_ isOn: Bool) {
    queue.async { [self] in
      if isOn {
        startRecording()
      } else {
        stopRecording()
      }
    }
  }

  // MARK: - Lifecycle (on queue)

  private func start() {
    guard !isRunning else { return }
    watchdog?.note("activate")
    isRunning = true
    isSuspended = false
    cameraProblem = nil
    isCameraInterrupted = false
    if minimumFocusDistance == nil {
      minimumFocusDistance = Self.readMinimumFocusDistance()
    }

    startClient()
    updateBluetoothBridge()
    if ARTracker.isSupported {
      videoFormat = arTracker.run(autoFocus: autoFocus, resetTracking: true)
    } else {
      cameraProblem = .unavailable("This iPhone can't run ARKit world tracking.")
    }
    motionTracker.start()
    var fields: [String: LogValue] = ["autoFocus": .bool(autoFocus)]
    if let videoFormat {
      fields["video"] = .string(
        "\(videoFormat.width)x\(videoFormat.height)@\(videoFormat.framesPerSecond)")
    }
    if let minimumFocusDistance {
      fields["minFocusMm"] = .int(minimumFocusDistance)
    }
    if let cameraProblem {
      fields["cameraProblem"] = .string(String(describing: cameraProblem))
    }
    logNow(.info, "app", "activate", fields: fields)
    updatePause()
    drainPipelineEvents()
    sendIfChanged()
    publishSnapshot()
  }

  private func stop() {
    guard isRunning else { return }
    watchdog?.note("deactivate")
    isRunning = false
    isSuspended = true
    logNow(.info, "app", "deactivate")
    updatePause()
    drainPipelineEvents()
    sendIfChanged()
    motionTracker.stop()
    arTracker.pause()
    stopClient()
    updateBluetoothBridge()
    logFile.flush()
    publishSnapshot()
  }

  private func startClient() {
    var configuration = SourisClient.Configuration(
      deviceID: identity.id, deviceName: identity.name)
    configuration.target = network.target
    configuration.includesPeerToPeer = network.includesPeerToPeer
    configuration.usesVoiceServiceClass = network.usesVoiceServiceClass
    // A Mac on the cable reaches the app through usbmuxd, and one on Bluetooth through the
    // bridge; Wi-Fi stays the fallback.
    configuration.listensForUSB = true
    configuration.listensForBluetooth = network.usesBluetooth
    configuration.pausesPeerToPeerOnBluetooth = network.pausesPeerToPeerOnBluetooth

    clientGeneration += 1
    let generation = clientGeneration
    let client = SourisClient(configuration: configuration, queue: queue, logOutbox: logOutbox) {
      [weak self] status in
      guard let self, generation == clientGeneration else { return }
      clientStatus = status
    }
    client.onBrowseResults = { [weak self] names in
      guard let self, generation == clientGeneration else { return }
      macNames = names
    }
    self.client = client
    clientStatus = client.status
    lastSent = nil
    client.start()
    sendIfChanged()
  }

  private func stopClient() {
    clientGeneration += 1
    client?.stop()
    client = nil
    clientStatus = .stopped
  }

  /// Runs the Bluetooth bridge while the app is active and the setting is on. It outlives the
  /// clients it relays for: each new client listens on the same loopback port, and the bridge
  /// reconnects to it.
  private func updateBluetoothBridge() {
    let shouldRun = isRunning && network.usesBluetooth
    if shouldRun && bluetoothBridge == nil {
      let bridge = BluetoothPeripheralBridge { [weak self] event in
        guard let self else { return }
        queue.async { [self] in
          watchdog?.note("bluetooth")
          switch event {
          case .log(let entry):
            logOutbox.enqueue(.log(entry))
          case .stateChanged(let state):
            bluetoothState = state
          }
        }
      }
      bluetoothBridge = bridge
      bridge.start()
    } else if !shouldRun, let bridge = bluetoothBridge {
      bridge.stop()
      bluetoothBridge = nil
      bluetoothState = .stopped
    }
  }

  /// The pipeline pauses while the app is inactive or the settings sheet is open.
  private func updatePause() {
    let shouldPause = isSuspended || isSettingsOpen
    guard shouldPause != isPipelinePaused else { return }
    isPipelinePaused = shouldPause
    recorder?.record(.paused(shouldPause))
    pipeline.setPaused(shouldPause)
  }

  // MARK: - Inputs (on queue)

  private func receive(_ sample: ARSample) {
    watchdog?.note("arFrame")
    if cameraProblem != nil {
      cameraProblem = nil
    }
    recorder?.record(.ar(sample))
    pipeline.process(sample)
    drainPipelineEvents()
    sendIfChanged()
  }

  private func receive(_ sample: IMUSample) {
    watchdog?.note("imu")
    recorder?.record(.imu(sample))
    pipeline.process(sample)
    drainPipelineEvents()
    sendIfChanged()
  }

  private func receive(_ event: ARTracker.Event) {
    watchdog?.note("arEvent")
    switch event {
    case .interrupted:
      isCameraInterrupted = true
      logNow(.warning, "camera", "interrupted", "The camera was interrupted")
    case .interruptionEnded:
      // The session restarted with a new world origin, so the old heading and desk height are void.
      isCameraInterrupted = false
      logNow(.info, "camera", "interruptionEnded")
      recorder?.record(.recenter)
      pipeline.recenter()
      drainPipelineEvents()
      sendIfChanged()
    case .failed(let problem):
      cameraProblem = problem
      logNow(.error, "camera", "failed", String(describing: problem))
    }
  }

  private func sendIfChanged() {
    guard let client else { return }
    let state = pipeline.state
    guard state != lastSent else { return }
    lastSent = state
    client.send(state)
  }

  // MARK: - Logging (on queue)

  private func logNow(
    _ level: LogLevel,
    _ category: String,
    _ event: String,
    _ message: String? = nil,
    fields: [String: LogValue] = [:]
  ) {
    logOutbox.enqueue(
      .log(
        LogEntry(
          level: level, category: category, event: event, message: message, fields: fields)))
  }

  /// The watchdog's report of a stall, logged once the queue runs again.
  private func logStall(_ stall: QueueWatchdog.Stall) {
    logNow(
      .warning, "app", "stall", "The pipeline queue was blocked",
      fields: [
        "ms": .double((stall.duration * 1000).rounded()),
        "lastWork": .string(stall.lastWork),
        "lastWorkAgeMs": .double((stall.lastWorkAge * 1000).rounded()),
        "arDelayMs": .double(pipeline.diagnostics.arDelayMs.rounded(places: 1)),
      ])
  }

  private func drainPipelineEvents() {
    let events = pipeline.drainEvents()
    guard !events.isEmpty else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let date = Date()
    for event in events {
      logOutbox.enqueue(.log(event.logEntry(now: now, date: date)))
    }
  }

  private func logLaunch(pipelineSettings: PipelineSettings) {
    let info = Bundle.main.infoDictionary ?? [:]
    var fields: [String: LogValue] = [
      "version": .string(info["CFBundleShortVersionString"] as? String ?? "?"),
      "build": .string(info["CFBundleVersion"] as? String ?? "?"),
      "system": .string(ProcessInfo.processInfo.operatingSystemVersionString),
      "device": .string(identity.name),
      "deviceID": .string(identity.id.uuidString),
      "logStream": .int(Int(logOutbox.streamID)),
    ]
    fields.merge(Self.fields(for: network)) { current, _ in current }
    logNow(.info, "app", "launch", "Souris started", fields: fields)
    logNow(.info, "settings", "pipelineAtLaunch", fields: SettingsDiff.leaves(of: pipelineSettings))
  }

  /// One `stats` entry: the live readings plus what happened since the previous one.
  private func logStats() {
    let diagnostics = pipeline.diagnostics
    let now = ProcessInfo.processInfo.systemUptime
    let state = pipeline.state
    var fields: [String: LogValue] = [
      "tracking": .string(diagnostics.tracking.rawValue),
      "gate": .string(diagnostics.cursorGate.rawValue),
      "arFps": .double(diagnostics.arFrameRate.rounded(places: 1)),
      "arDelayMs": .double(diagnostics.arDelayMs.rounded(places: 1)),
      "imuHz": .double(diagnostics.imuRate.rounded(places: 1)),
      "jitterMm": .double(diagnostics.jitterMm.rounded(places: 2)),
      "prediction": .string(diagnostics.prediction.rawValue),
      "predLeadMm": .double(diagnostics.predictionLeadMm.rounded(places: 1)),
      "predErrMm": .double(diagnostics.predictionErrorMm.rounded(places: 2)),
      "speedMmS": .double(diagnostics.speedMmPerSecond.rounded(places: 0)),
      "gain": .double(diagnostics.gain.rounded(places: 2)),
      "heightCm": .double(diagnostics.heightAboveDeskCm.rounded(places: 1)),
      "pitchDeg": .double(diagnostics.pitchDegrees.rounded(places: 1)),
      "scrollSpeed": .double(diagnostics.scrollSpeed.rounded(places: 0)),
      "flags": .int(Int(state.flags.rawValue)),
      "buttons": .int(Int(state.buttons.rawValue)),
      "cursorX": .double(state.cursor.x.rounded(places: 1)),
      "cursorY": .double(state.cursor.y.rounded(places: 1)),
      "scrollY": .double(state.scroll.y.rounded(places: 1)),
      "paused": .bool(isPipelinePaused),
      "client": .string(Self.name(of: clientStatus)),
    ]
    if let baseline = statsBaseline {
      let cursorTravel = diagnostics.cursorTravelPoints - baseline.cursorTravelPoints
      let sensorTravel = diagnostics.sensorTravelMm - baseline.sensorTravelMm
      fields["windowS"] = .double((now - statsBaselineTime).rounded(places: 3))
      fields["cursorTravelPt"] = .double(cursorTravel.rounded(places: 1))
      fields["sensorTravelMm"] = .double(sensorTravel.rounded(places: 2))
      if sensorTravel > 0.5 {
        fields["effectiveGain"] = .double((cursorTravel / sensorTravel).rounded(places: 2))
      }
      for gate in CursorGate.allCases where gate != .open {
        let seconds = diagnostics.gateSeconds[gate] - baseline.gateSeconds[gate]
        if seconds > 0.0005 {
          fields["blocked.\(gate.rawValue)S"] = .double(seconds.rounded(places: 3))
        }
      }
      let jumps = diagnostics.rejectedJumps - baseline.rejectedJumps
      if jumps > 0 {
        fields["rejectedJumps"] = .int(jumps)
      }
      let presses = diagnostics.scrollPresses - baseline.scrollPresses
      if presses > 0 {
        fields["scrollPresses"] = .int(presses)
      }
    }
    if let stats = client?.stats {
      if let median = stats.rttMedianMs {
        fields["rttP50Ms"] = .double(median.rounded(places: 1))
      }
      if let maximum = stats.rttMaxMs {
        fields["rttMaxMs"] = .double(maximum.rounded(places: 1))
      }
      fields["packetsPerS"] = .double(stats.packetsPerSecond.rounded(places: 0))
      fields["pingLoss"] = .double(stats.pingLoss.rounded(places: 3))
    }
    let outbox = logOutbox.stats
    fields["logQueued"] = .int(outbox.queuedRecords)
    if outbox.dropped > 0 {
      fields["logDropped"] = .int(outbox.dropped)
    }
    statsBaseline = diagnostics
    statsBaselineTime = now
    logNow(.debug, "stats", "stats", fields: fields)

    let thermal = ProcessInfo.processInfo.thermalState
    if thermal != thermalState {
      thermalState = thermal
      let level: LogLevel = thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        ? .warning : .info
      logNow(level, "app", "thermal", fields: ["state": .string(Self.name(of: thermal))])
    }
  }

  private static func fields(for network: NetworkSettings) -> [String: LogValue] {
    let target: String
    switch network.target {
    case .bonjour(let name): target = "bonjour:\(name ?? "any")"
    case .host(let host, let port): target = "host:\(host):\(port)"
    }
    return [
      "target": .string(target),
      "peerToPeer": .bool(network.includesPeerToPeer),
      "voiceClass": .bool(network.usesVoiceServiceClass),
      "bluetooth": .bool(network.usesBluetooth),
      "pausesPeerToPeerOnBluetooth": .bool(network.pausesPeerToPeerOnBluetooth),
    ]
  }

  private static func name(of status: ClientStatus) -> String {
    switch status {
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

  private static func name(of state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }

  // MARK: - Recording (on queue)

  private func startRecording() {
    guard recorder == nil else { return }
    recordingFailure = nil
    recordingID += 1
    let id = recordingID
    let outbox = logOutbox
    do {
      let recorder = try SessionRecorder(settings: pipeline.settings, isPaused: isPipelinePaused) {
        [queue] line in
        queue.async { outbox.enqueue(.recordingLine(recordingID: id, line: line)) }
      }
      // Enqueued before any line: every line hops to this queue after this returns.
      logOutbox.enqueue(.recordingStarted(recordingID: id, name: recorder.name))
      logNow(.info, "recording", "started", fields: ["name": .string(recorder.name)])
      self.recorder = recorder
    } catch {
      recordingFailure = "Couldn’t start recording: \(error.localizedDescription)"
      logNow(.error, "recording", "startFailed", error.localizedDescription)
    }
  }

  private func stopRecording() {
    guard let recorder else { return }
    recordingFailure = recorder.failure
    let id = recordingID
    let outbox = logOutbox
    let name = recorder.name
    recorder.finish { [queue] in
      queue.async {
        outbox.enqueue(.recordingEnded(recordingID: id))
        outbox.enqueue(
          .log(
            LogEntry(
              level: recorder.failure == nil ? .info : .error, category: "recording",
              event: "finished", message: recorder.failure, fields: ["name": .string(name)])))
      }
    }
    self.recorder = nil
  }

  // MARK: - Snapshot (on queue)

  private func startSnapshotTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
    timer.setEventHandler { [weak self] in self?.snapshotTick() }
    timer.resume()
    snapshotTimer = timer
  }

  private func snapshotTick() {
    watchdog?.note("snapshot")
    publishSnapshot()
    snapshotTicks += 1
    if isRunning && snapshotTicks % Self.statsEveryTicks == 0 {
      logStats()
    }
  }

  private func publishSnapshot() {
    var snapshot = EngineSnapshot()
    snapshot.clientStatus = clientStatus
    snapshot.linkStats = client?.stats ?? LinkStats()
    snapshot.bluetoothState = bluetoothState
    snapshot.logStats = logOutbox.stats
    snapshot.diagnostics = pipeline.diagnostics
    snapshot.buttons = pipeline.state.buttons
    snapshot.flags = pipeline.state.flags
    snapshot.isPaused = isPipelinePaused
    snapshot.thermalState = ProcessInfo.processInfo.thermalState
    snapshot.macNames = macNames
    snapshot.videoFormat = videoFormat
    snapshot.minimumFocusDistance = minimumFocusDistance
    snapshot.cameraProblem = cameraProblem
    snapshot.isCameraInterrupted = isCameraInterrupted
    snapshot.recordingStartedAt = recorder?.startedAt
    snapshot.recordingFailure = recorder?.failure ?? recordingFailure
    snapshotBox.store(snapshot)
  }

  /// In millimetres; `nil` when the device doesn't report it.
  private static func readMinimumFocusDistance() -> Int? {
    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    guard let distance = device?.minimumFocusDistance, distance > 0 else { return nil }
    return distance
  }
}
