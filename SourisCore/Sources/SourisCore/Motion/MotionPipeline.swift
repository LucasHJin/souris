import Foundation
import simd

/// Live readouts for the phone's debug overlay.
public struct PipelineDiagnostics: Equatable, Sendable {
  public var tracking: TrackingStatus = .notAvailable

  /// ARKit frames per second, smoothed.
  public var arFrameRate: Double = 0

  /// ARKit delivery delay: arrival − capture timestamp, milliseconds, smoothed.
  public var arDelayMs: Double = 0

  /// Core Motion samples per second, smoothed.
  public var imuRate: Double = 0

  /// Core Motion delivery delay: arrival − sample timestamp, milliseconds, smoothed. Together with
  /// `arDelayMs` this checks that both clocks are the uptime clock (both should be small and
  /// positive).
  public var imuDelayMs: Double = 0

  /// RMS deviation of the sensor point's horizontal position over the last 0.5 s, millimetres.
  /// Hold the phone still to read the tracking jitter.
  public var jitterMm: Double = 0

  /// Filtered sensor-point speed, mm/s.
  public var speedMmPerSecond: Double = 0

  /// Current pointer gain, points per mm.
  public var gain: Double = 0

  /// Camera height above the captured desk height, centimetres.
  public var heightAboveDeskCm: Double = 0

  /// Pitch relative to the captured level angle, degrees, front edge up positive.
  public var pitchDegrees: Double = 0

  /// Current scroll speed, px/s, signed like `MouseState.scroll.y`: the tilt-scroll speed plus
  /// the rate at which a button-scroll glide is releasing its queue.
  public var scrollSpeed: Double = 0

  /// A click freeze is holding the cursor.
  public var isFrozen = false

  /// ARKit frame timestamps fall outside the gyro history, so gyro assist is skipped.
  public var clockMismatch = false

  /// ARKit deltas dropped as implausible jumps since start.
  public var rejectedJumps = 0

  /// Why the cursor is or isn't following the sensor, as of the latest cursor step.
  public var cursorGate: CursorGate = .waitingForTracking

  /// Seconds spent in each gate since start, by input arrival time.
  public var gateSeconds = GateSeconds()

  /// Path length of the filtered sensor point, mm, summed over the steps that moved the cursor.
  /// Cursor travel divided by this over a window is the effective gain.
  public var sensorTravelMm: Double = 0

  /// Path length of the cursor output, points, summed over the same steps.
  public var cursorTravelPoints: Double = 0

  /// Volume-button presses accepted since start.
  public var scrollPresses = 0

  /// Events discarded because the buffer held 512 undrained ones.
  public var droppedEvents = 0

  public init() {}
}

/// The phone's whole motion model: ARKit and Core Motion samples and touch events in, absolute
/// mouse state out. Pure and deterministic (every time comes from its inputs), so recorded
/// sessions replay identically on the Mac.
///
/// See `docs/architecture.md` (motion pipeline, scroll tilt, lift clutch) for the behavior.
/// Not thread-safe: the app drives it from one serial queue.
public struct MotionPipeline: Sendable {
  /// After this long without an ARKit frame (by arrival, relative to the latest IMU sample) the
  /// tracking is reported as limited.
  static let staleARKitInterval: TimeInterval = 0.25

  /// Cutoff (Hz) of the low-pass on the filtered position's velocity, the speed the gain curve
  /// reads. Much quicker than the 1€ derivative, so a flick reaches fast gain promptly.
  static let gainSpeedCutoff: Double = 8

  /// The most undrained events kept; past it the oldest are dropped.
  static let eventCapacity = 512

  /// Changes take effect from the next input.
  public var settings: PipelineSettings

  /// The latest output. The app sends it whenever it changes.
  public private(set) var state = MouseState()

  public private(set) var diagnostics = PipelineDiagnostics()

  // ARKit input.
  private var previousARPosition: SIMD3<Double>?
  private var previousARTimestamp: TimeInterval?
  private var latestARArrival: TimeInterval?
  private var latestTracking = TrackingStatus.notAvailable
  private var isLatestFrameGood = false
  private var lastGoodArrival: TimeInterval?
  private var recoveryFramesLeft = 0
  private var arMeter = StreamMeter()

  /// `P`: the camera position integrated from accepted ARKit deltas only, metres. Starts at the
  /// first frame's position.
  private(set) var integratedPosition = SIMD3<Double>.zero

  /// The latest `.normal` frame's orientation (camera → world) and capture time.
  private var anchorOrientation: simd_quatd?
  private var anchorTime: TimeInterval = 0

  // Core Motion input.
  private var attitudes = AttitudeHistory()
  private var latestIMUArrival: TimeInterval?
  private var latestPitch: Double?
  private var imuMeter = StreamMeter()

  /// `R_now`: the camera orientation used for the lever, carried forward by the gyro when gyro
  /// assist is on.
  private(set) var currentOrientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

  /// Gyro assist is on and the clocks agree, so IMU samples drive the cursor too.
  private var isAssistActive = false

  // Engagement.
  private var needsEngage = true
  private var hasHeading = false
  private var needsLevel = false
  private var wasTrackingLost = false

  /// The heading captured at engage: pushing this way moves the cursor up.
  private(set) var forward = SIMD3<Double>(0, 0, -1)

  /// `forward × up`: pushing this way moves the cursor right.
  private(set) var right = SIMD3<Double>(1, 0, 0)

  // Cursor output.
  private var filter = OneEuroFilter2D()
  private var gainSpeed = VelocityMeter()
  private var lastFiltered = SIMD2<Double>.zero
  private var needsFilterReset = true
  private var breakoutPoint = SmoothedPoint()
  private var jitter = JitterMeter()

  // Gates and gestures.
  private var isPaused = false
  private var scrollTilt = ScrollTilt()
  private var buttonScroll = ButtonScroll()
  private var liftClutch = LiftClutch()

  /// The latest lift height, the height the lift clutch watches, metres.
  private var liftHeight: Double = 0
  private var clickFreeze = ClickFreeze()
  private var lastTouchTime: TimeInterval?

  /// Signed distance the current tilt scroll has covered, px.
  private var tiltScrolled: Double = 0

  // Events and gate accounting.
  private var events = RingBuffer<PipelineEvent>(capacity: MotionPipeline.eventCapacity)

  /// The time stamped on new events: the input being processed. Nil before the first input.
  private var inputTime: TimeInterval?

  /// The arrival time up to which `gateSeconds` is accounted.
  private var gateClock: TimeInterval?

  public init(settings: PipelineSettings = PipelineSettings()) {
    self.settings = settings
  }

  /// The pipeline has captured a heading and is producing (or ready to produce) output.
  var isEngaged: Bool { !needsEngage }

  /// The lever `r_cam = C · (0, sensorReach, 0)`: from the camera to the sensor point, camera
  /// frame.
  private var leverInCamera: SIMD3<Double> {
    Frames.topEdgeInCamera * settings.pointer.sensorReach
  }

  /// Feeds one ARKit frame.
  public mutating func process(_ sample: ARSample) {
    inputTime = sample.arrival
    arMeter.record(timestamp: sample.timestamp, arrival: sample.arrival)
    if sample.tracking != latestTracking {
      emit(.trackingChanged(sample.tracking))
    }
    latestTracking = sample.tracking
    latestARArrival = sample.arrival

    let isNormal = sample.tracking == .normal
    var isGood = false
    if !isNormal {
      recoveryFramesLeft = max(0, settings.tracking.recoveryFrames)
    } else if recoveryFramesLeft > 0 {
      recoveryFramesLeft -= 1
    } else {
      isGood = true
    }

    var isJump = false
    if let previousARPosition, let previousARTimestamp {
      let delta = sample.position - previousARPosition
      let interval = sample.timestamp - previousARTimestamp
      if isGood && interval > 0 {
        let speed = simd_length(delta) / interval
        if speed > settings.tracking.maxPlausibleSpeed {
          diagnostics.rejectedJumps += 1
          isJump = true
          emit(.jumpRejected(speedMetresPerSecond: speed))
        } else {
          integratedPosition += delta
        }
      }
    } else {
      integratedPosition = sample.position
    }
    previousARPosition = sample.position
    previousARTimestamp = sample.timestamp

    if isNormal {
      anchorOrientation = simd_normalize(sample.quaternion)
      anchorTime = sample.timestamp
    }
    isLatestFrameGood = isGood
    if isGood {
      lastGoodArrival = sample.arrival
    }
    updateOrientation()

    if isGood {
      if needsEngage {
        engage(time: sample.timestamp)
      } else if wasTrackingLost || isJump {
        // A relocalization can turn the world as well as move it, so re-take the axes.
        reanchor(time: sample.timestamp, reason: wasTrackingLost ? .trackingRecovered : .jump)
      }
      if !needsEngage && !isPaused {
        runLiftClutch(time: sample.timestamp)
      }
    }
    if clickFreeze.expire(arkitTime: sample.timestamp) {
      needsFilterReset = true
    }
    stepCursor(time: sample.arrival, sampleTime: sample.timestamp)
    advanceButtonScroll(to: sample.arrival)
    finishInput()
  }

  /// Feeds one Core Motion sample.
  public mutating func process(_ sample: IMUSample) {
    inputTime = sample.arrival
    imuMeter.record(timestamp: sample.timestamp, arrival: sample.arrival)
    latestIMUArrival = sample.arrival
    attitudes.append(time: sample.timestamp, attitude: sample.quaternion)
    updateOrientation()

    let pitch = ScrollTilt.pitch(gravity: sample.gravity)
    latestPitch = pitch
    if needsLevel && isEngaged {
      if !captureLevel(pitch: pitch) {
        emit(.levelRejected(pitchDegrees: pitch))
      }
      needsLevel = false
    }
    let isSuppressed = lastTouchTime.map {
      sample.timestamp < $0 + settings.tiltScroll.touchSuppression
    } ?? false
    let isScrollAllowed = settings.tiltScroll.isEnabled && !isPaused && isEngaged
      && !liftClutch.isLifted && state.buttons.isEmpty && !isSuppressed
    let wasTiltActive = scrollTilt.isActive
    let tiltDistance = scrollTilt.update(
      pitch: pitch,
      time: sample.timestamp,
      isAllowed: isScrollAllowed,
      settings: settings.tiltScroll)
    if !wasTiltActive && scrollTilt.isActive {
      tiltScrolled = 0
      emit(.scrollStarted(source: .tilt))
    }
    state.scroll.y += tiltDistance
    tiltScrolled += tiltDistance
    if wasTiltActive && !scrollTilt.isActive {
      emit(.scrollEnded(source: .tilt, pixels: tiltScrolled))
    }
    advanceButtonScroll(to: sample.arrival)

    if clickFreeze.expire(imuTime: sample.timestamp) {
      needsFilterReset = true
    }
    if isAssistActive {
      stepCursor(time: sample.arrival, sampleTime: sample.timestamp)
    }
    finishInput()
  }

  /// Feeds one event from the touch classifier.
  public mutating func handle(_ event: TouchEvent) {
    inputTime = event.time
    switch event {
    case .contact:
      break
    case .button(let button, let isDown, _):
      if !isDown {
        state.buttons.remove(button.mask)
      } else if !isPaused {
        state.buttons.insert(button.mask)
      }
    }
    clickFreeze.trigger(at: event.time, duration: settings.click.freezeDuration)
    lastTouchTime = max(lastTouchTime ?? event.time, event.time)
    if !state.buttons.isEmpty {
      endTiltScroll()
    }
    finishInput()
  }

  /// Feeds one volume-button press. Ignored while paused or with button scroll off. Otherwise it
  /// queues a step of scrolling (see `PipelineSettings.ButtonScroll`) and starts a click freeze,
  /// since the thumb's push nudges the phone.
  public mutating func handle(_ press: ScrollButtonPress) {
    inputTime = press.time
    guard settings.buttonScroll.isEnabled, !isPaused else { return }
    let queued = buttonScroll.press(press, settings: settings.buttonScroll)
    diagnostics.scrollPresses += 1
    if queued.startedGlide {
      emit(.scrollStarted(source: .buttons))
    }
    emit(.scrollPress(direction: press.direction, pixels: queued.pixels))
    clickFreeze.trigger(at: press.time, duration: settings.click.freezeDuration)
    finishInput()
  }

  /// Pausing releases every button, ends any scroll and stops output until unpaused. Unpausing
  /// re-engages like setting the phone down: it re-captures the heading, level angle and desk
  /// height from the next samples.
  public mutating func setPaused(_ isPaused: Bool) {
    if isPaused {
      state.buttons = []
      endTiltScroll()
      endButtonScroll()
      clickFreeze.cancel()
    } else if self.isPaused {
      needsEngage = true
    }
    if isPaused != self.isPaused {
      emit(.paused(isPaused))
    }
    self.isPaused = isPaused
    refreshGate(at: inputTime)
    finishInput()
  }

  /// Re-captures the forward heading, scroll level and desk height from the next samples, as if
  /// the phone had just been set down.
  public mutating func recenter() {
    needsEngage = true
    endTiltScroll()
    emit(.recentered)
    finishInput()
  }

  /// Returns the events recorded since the last call, oldest first. The buffer holds 512; past
  /// that the oldest are dropped and counted in `diagnostics.droppedEvents`. Call after every
  /// input to keep each event's cause obvious.
  public mutating func drainEvents() -> [PipelineEvent] {
    var drained: [PipelineEvent] = []
    drained.reserveCapacity(events.count)
    for index in 0..<events.count {
      drained.append(events[index])
    }
    events.removeAll()
    return drained
  }

  // MARK: - Engagement

  /// Captures the heading, scroll level and desk height, and restarts the filter, on a good frame.
  private mutating func engage(time: TimeInterval) {
    guard captureHeading() else { return }
    var isLevelCaptured = false
    if let latestPitch {
      isLevelCaptured = captureLevel(pitch: latestPitch)
      needsLevel = false
    } else {
      needsLevel = true
    }
    endTiltScroll()
    let edges = edgeHeights
    liftHeight = edges.lower
    liftClutch.reset(edges: edges, time: time)
    needsFilterReset = true
    wasTrackingLost = false
    needsEngage = false
    emit(.engaged(pitchDegrees: latestPitch, levelCaptured: isLevelCaptured))
    if let latestPitch, !isLevelCaptured {
      emit(.levelRejected(pitchDegrees: latestPitch))
    }
  }

  /// Takes `pitch` as the tilt-scroll level unless it is past `levelCaptureLimit`, in which case
  /// the previous level stays.
  ///
  /// - Returns: Whether the level was captured.
  private mutating func captureLevel(pitch: Double) -> Bool {
    guard abs(pitch) <= settings.tiltScroll.levelCaptureLimit else { return false }
    scrollTilt.level = pitch
    return true
  }

  /// After a tracking loss or a pose jump: re-takes the heading and desk height and restarts the
  /// filter. The scroll level stays, since the user may be mid-tilt and Core Motion never lost it.
  private mutating func reanchor(time: TimeInterval, reason: PipelineEvent.ReanchorReason) {
    _ = captureHeading()
    if !liftClutch.isLifted {
      let edges = edgeHeights
      liftHeight = edges.lower
      liftClutch.reset(edges: edges, time: time)
    }
    needsFilterReset = true
    wasTrackingLost = false
    emit(.reanchored(reason: reason))
  }

  /// Sets `forward` and `right` from the current orientation. Keeps the previous heading if the
  /// phone is near vertical.
  ///
  /// - Returns: False if there is no usable heading at all yet.
  private mutating func captureHeading() -> Bool {
    if let heading = Frames.heading(of: currentOrientation) {
      forward = heading
      right = Frames.right(ofHeading: heading)
      hasHeading = true
    }
    return hasHeading
  }

  /// The heights of the front and back points the lift clutch watches. They sit
  /// `lift.frontDistance` toward the top edge and `lift.backDistance` toward the bottom edge of
  /// the camera, along the long axis, and a point's height is `(P + R_k · offset).y`. A tilt moves
  /// the two ends in opposite directions; a real lift raises both.
  private var edgeHeights: EdgeHeights {
    guard let anchorOrientation else {
      return EdgeHeights(front: integratedPosition.y, back: integratedPosition.y)
    }
    let front = Frames.topEdgeInCamera * settings.lift.frontDistance
    let back = Frames.topEdgeInCamera * -settings.lift.backDistance
    return EdgeHeights(
      front: (integratedPosition + anchorOrientation.act(front)).y,
      back: (integratedPosition + anchorOrientation.act(back)).y)
  }

  private mutating func runLiftClutch(time: TimeInterval) {
    let edges = edgeHeights
    liftHeight = edges.lower
    guard settings.lift.isEnabled else {
      liftClutch.reset(edges: edges, time: time)
      return
    }
    let event = liftClutch.update(
      edges: edges,
      time: time,
      cursor: state.cursor,
      canLift: !scrollTilt.isActive,
      settings: settings.lift)
    switch event {
    case .none:
      break
    case .lifted(let rollback, let rise):
      var rolledBack: Double = 0
      if settings.lift.rollsBackCursor {
        rolledBack = simd_length(state.cursor - rollback)
        state.cursor = rollback
      }
      endTiltScroll()
      emit(.lifted(riseCm: rise * 100, rolledBackPoints: rolledBack))
    case .setDown(let drop):
      emit(.setDown(dropCm: drop * 100))
      engage(time: time)
    }
  }

  // MARK: - Orientation

  /// Sets `R_now` (and whether gyro assist is usable) from the anchor frame and the gyro.
  private mutating func updateOrientation() {
    guard let anchorOrientation else { return }
    guard settings.pointer.gyroAssist, let latest = attitudes.latest else {
      currentOrientation = anchorOrientation
      diagnostics.clockMismatch = false
      isAssistActive = settings.pointer.gyroAssist
      return
    }
    switch attitudes.attitude(at: anchorTime) {
    case .found(let anchorAttitude):
      // Core Motion attitudes map device → reference, so q(t_k)⁻¹ · q(now) is the rotation from
      // t_k to now in the body frame. In the camera frame it is C · ΔR · Cᵀ, applied on the right
      // of the camera → world anchor: R_now = R_k · C · ΔR · Cᵀ.
      let deviceRotation = anchorAttitude.inverse * latest
      currentOrientation = simd_normalize(
        anchorOrientation * Frames.cameraRotation(fromDeviceRotation: deviceRotation))
      diagnostics.clockMismatch = false
      isAssistActive = true
    case .notCovered:
      currentOrientation = anchorOrientation
      diagnostics.clockMismatch = false
      isAssistActive = true
    case .outOfRange:
      currentOrientation = anchorOrientation
      diagnostics.clockMismatch = true
      isAssistActive = false
    }
  }

  // MARK: - Cursor

  /// Tracking counts as bad with no good ARKit frame recently. With gyro assist the lever keeps
  /// moving through a grace period; without it the cursor stops at the first bad frame.
  private var isTrackingBad: Bool {
    guard let lastGoodArrival else { return true }
    guard isAssistActive else { return !isLatestFrameGood }
    let latest = max(latestIMUArrival ?? lastGoodArrival, latestARArrival ?? lastGoodArrival)
    return latest - lastGoodArrival > settings.tracking.gyroGracePeriod
  }

  /// Turns the current sensor point into cursor motion.
  ///
  /// - Parameters:
  ///   - time: The input's arrival time; monotonic, so it drives the filter.
  ///   - sampleTime: The input's capture time, which decides whether a click freeze covers it.
  private mutating func stepCursor(time: TimeInterval, sampleTime: TimeInterval) {
    guard anchorOrientation != nil else {
      refreshGate(at: time)
      return
    }
    let point = integratedPosition + currentOrientation.act(leverInCamera)
    let worldPoint = SIMD2(point.x, point.z) * 1000
    jitter.record(worldPoint, time: time)
    diagnostics.jitterMm = jitter.rms
    let smoothedStep = breakoutPoint.update(worldPoint, time: time)

    var isFrozen = clickFreeze.isFrozen(at: sampleTime)
    if isFrozen && clickFreeze.accumulate(smoothedStep, breakout: settings.click.freezeBreakout) {
      isFrozen = false
      needsFilterReset = true
    }

    let gate = refreshGate(at: time)
    guard isEngaged else { return }
    let position = SIMD2(simd_dot(point, right), simd_dot(point, forward)) * 1000
    let pointer = settings.pointer
    let filtered = filter.update(
      position,
      time: time,
      minimumCutoff: pointer.filterMinCutoff,
      beta: pointer.filterBeta,
      derivativeCutoff: pointer.filterDerivativeCutoff)
    let speed = gainSpeed.update(filtered, time: time, cutoff: Self.gainSpeedCutoff)
    let gain = GainCurve.gain(speed: speed, settings: pointer)
    diagnostics.speedMmPerSecond = speed
    diagnostics.gain = gain

    if isTrackingBad {
      wasTrackingLost = true
    }
    if gate != .open && gate != .clickFreeze {
      needsFilterReset = true
      lastFiltered = filtered
      return
    }
    if needsFilterReset {
      // Whatever moved while the output was closed stays discarded. Restarting from the smoothed
      // point rather than this one sample keeps the sample's jitter out of the cursor.
      let smoothed = breakoutPoint.value ?? worldPoint
      let restart = SIMD2(
        simd_dot(smoothed, SIMD2(right.x, right.z)),
        simd_dot(smoothed, SIMD2(forward.x, forward.z)))
      filter.reset(to: restart, time: time)
      gainSpeed.reset(to: restart, time: time)
      lastFiltered = restart
      needsFilterReset = false
      diagnostics.speedMmPerSecond = 0
      return
    }
    let travel = filtered - lastFiltered
    lastFiltered = filtered
    // The gate can read `clickFreeze` for a sample captured before the touch, which still counts.
    guard !isFrozen else { return }
    // Forward travel is cursor up, and screen y grows downward.
    let increment = gain * SIMD2(travel.x, -travel.y)
    state.cursor += increment
    diagnostics.sensorTravelMm += simd_length(travel)
    diagnostics.cursorTravelPoints += simd_length(increment)
  }

  /// Works out the cursor gate from the current conditions, books the time since the previous
  /// call to the previous gate and records a change.
  ///
  /// - Parameter time: The input's arrival time, or nil before the first input. Times not after
  ///   the previous call book nothing.
  /// - Returns: The current gate.
  @discardableResult
  private mutating func refreshGate(at time: TimeInterval?) -> CursorGate {
    var conditions: CursorGate.Conditions = []
    if isPaused { conditions.insert(.paused) }
    if anchorOrientation == nil { conditions.insert(.waitingForTracking) }
    if !isEngaged { conditions.insert(.notEngaged) }
    if liftClutch.isLifted { conditions.insert(.lifted) }
    if isTrackingBad { conditions.insert(.trackingLost) }
    if scrollTilt.isActive { conditions.insert(.tiltScrolling) }
    if clickFreeze.isActive { conditions.insert(.clickFreeze) }
    let gate = CursorGate(highestOf: conditions)

    if let time {
      if let gateClock {
        if time > gateClock {
          diagnostics.gateSeconds[diagnostics.cursorGate] += time - gateClock
          self.gateClock = time
        }
      } else {
        gateClock = time
      }
    }
    if gate != diagnostics.cursorGate {
      emit(.gateChanged(from: diagnostics.cursorGate, to: gate))
      diagnostics.cursorGate = gate
    }
    return gate
  }

  // MARK: - Scroll

  private mutating func endTiltScroll() {
    guard scrollTilt.isActive else { return }
    scrollTilt.end()
    emit(.scrollEnded(source: .tilt, pixels: tiltScrolled))
  }

  private mutating func endButtonScroll() {
    guard buttonScroll.isActive else { return }
    buttonScroll.end()
    emit(.scrollEnded(source: .buttons, pixels: buttonScroll.scrolled))
  }

  /// Releases the part of the button-scroll queue due by `time`.
  ///
  /// - Parameter time: An input's arrival time.
  private mutating func advanceButtonScroll(to time: TimeInterval) {
    guard buttonScroll.isActive else { return }
    state.scroll.y += buttonScroll.advance(to: time, settings: settings.buttonScroll)
    if !buttonScroll.isActive {
      emit(.scrollEnded(source: .buttons, pixels: buttonScroll.scrolled))
    }
  }

  // MARK: - Events

  private mutating func emit(_ kind: PipelineEvent.Kind) {
    if events.count == events.capacity {
      diagnostics.droppedEvents += 1
    }
    events.append(PipelineEvent(time: inputTime ?? 0, kind: kind))
  }

  // MARK: - Output

  /// Refreshes the flags and the diagnostics that summarize state.
  private mutating func finishInput() {
    var flags: StateFlags = []
    if liftClutch.isLifted {
      flags.insert(.lifted)
    }
    if isTrackingLimited {
      flags.insert(.trackingLimited)
    }
    if scrollTilt.isActive || buttonScroll.isActive {
      flags.insert(.scrollActive)
    }
    if isPaused {
      flags.insert(.paused)
    }
    state.flags = flags

    diagnostics.tracking = latestTracking
    diagnostics.arFrameRate = arMeter.rate
    diagnostics.arDelayMs = arMeter.delay * 1000
    diagnostics.imuRate = imuMeter.rate
    diagnostics.imuDelayMs = imuMeter.delay * 1000
    diagnostics.isFrozen = clickFreeze.isActive
    diagnostics.pitchDegrees = scrollTilt.relativePitch
    diagnostics.scrollSpeed = scrollTilt.speed
      + buttonScroll.speed(glideTime: settings.buttonScroll.glideTime)
    diagnostics.heightAboveDeskCm = isEngaged
      ? (liftHeight - liftClutch.deskHeight) * 100 : 0
  }

  private var isTrackingLimited: Bool {
    guard let latestARArrival, latestTracking == .normal else { return true }
    guard let latestIMUArrival else { return false }
    return latestIMUArrival - latestARArrival > Self.staleARKitInterval
  }
}
