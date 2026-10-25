import Foundation
import Observation
import QuartzCore
import UIKit

import SourisCore

/// Runs the `TouchClassifier` and the `ScrollWheel` on the main thread and forwards their events
/// to the engine.
///
/// A touch that begins on the wheel rolls it instead of pressing a button, a tap on it is a
/// middle click, and holding it still dictates on the Mac until it lifts: a firm tap says the
/// Mac's Dictation is listening, a light one that the hold ended. A tap on the Enter key presses
/// Return on the Mac with a firm tap. While the wheel is touched,
/// spinning or letting out its scrolling, a display link advances it every refresh, and each
/// notch it passes plays a haptic tick.
///
/// UIKit touch timestamps and `ProcessInfo.systemUptime` share a clock, so the classifier's
/// deadlines are scheduled directly on the main queue.
@MainActor @Observable
final class TouchController {
  /// Ticks closer together than this are dropped; the Taptic Engine blurs faster ones.
  private static let minimumTickInterval: TimeInterval = 0.015

  /// The buttons the classifier reports as held, for the press feedback on screen.
  private(set) var heldButtons: MouseButtons = []

  /// Whether a finger is on the Enter key, for its feedback on screen.
  private(set) var isReturnKeyTouched = false

  /// The wheel's turn in notches, whether a finger is on it, whether it is dictating and whether
  /// the Mac's Dictation listens to that, for drawing it.
  private(set) var wheelRotation: Double = 0
  private(set) var isWheelTouched = false
  private(set) var isDictating = false
  private(set) var isDictationListening = false

  /// What the Mac last said: Dictation listens for the phone.
  @ObservationIgnored private var isMacListening = false

  @ObservationIgnored private var classifier: TouchClassifier
  @ObservationIgnored private var wheel = ScrollWheel()
  @ObservationIgnored private var wheelTouch: Int?
  @ObservationIgnored private let engine: MouseEngine
  @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .light)
  @ObservationIgnored private let tickHaptic = UIImpactFeedbackGenerator(style: .rigid)
  /// For Dictation listening and the Enter key.
  @ObservationIgnored private let firmHaptic = UIImpactFeedbackGenerator(style: .medium)
  @ObservationIgnored private var lastTickAt: TimeInterval = 0
  @ObservationIgnored private var frameTicker: FrameTicker?
  @ObservationIgnored private var pendingAdvance: DispatchWorkItem?
  @ObservationIgnored var hapticsEnabled: Bool

  init(engine: MouseEngine, settings: TouchSettings, hapticsEnabled: Bool) {
    self.engine = engine
    self.hapticsEnabled = hapticsEnabled
    classifier = TouchClassifier(settings: settings)
  }

  var settings: TouchSettings {
    get { classifier.settings }
    set {
      classifier.settings = newValue
      if !newValue.wheel.isEnabled {
        cancelWheel()
      }
    }
  }

  /// The wheel's strip in a surface of `size`, or nil with the wheel off.
  func wheelRect(in size: CGSize) -> CGRect? {
    classifier.wheelRect(in: size)
  }

  func touchesBegan(_ touches: Set<UITouch>, in view: UIView) {
    let size = view.bounds.size
    for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
      let location = touch.location(in: view)
      let id = ObjectIdentifier(touch).hashValue
      if classifier.isOnWheel(location, in: size) {
        // A second finger on the wheel is ignored; the first one rolls it.
        guard wheelTouch == nil else { continue }
        wheelTouch = id
        if hapticsEnabled {
          tickHaptic.prepare()
          haptic.prepare()
          firmHaptic.prepare()
        }
        handle(wheel.touchBegan(y: Double(location.y), time: touch.timestamp))
        continue
      }
      if hapticsEnabled {
        if classifier.isOnReturnKey(location, in: size) {
          firmHaptic.prepare()
        } else if location.y < size.height * classifier.settings.acceptedFraction {
          haptic.prepare()
        }
      }
      forward(classifier.touchBegan(id: id, location: location, in: size, time: touch.timestamp))
    }
    didClassify()
  }

  func touchesMoved(_ touches: Set<UITouch>, in view: UIView) {
    guard let wheelTouch,
      let touch = touches.first(where: { ObjectIdentifier($0).hashValue == wheelTouch })
    else { return }
    let y = Double(touch.location(in: view).y)
    handle(wheel.touchMoved(y: y, time: touch.timestamp, settings: settings.wheel))
  }

  /// Handles both ended and cancelled touches; the classifier treats cancels as lifts.
  func touchesEnded(_ touches: Set<UITouch>) {
    for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
      let id = ObjectIdentifier(touch).hashValue
      if id == wheelTouch {
        wheelTouch = nil
        let update = wheel.touchEnded(time: touch.timestamp, settings: settings.wheel)
        handle(update)
        if update.isTap {
          forward(classifier.middleClick(at: touch.timestamp))
        }
        continue
      }
      forward(classifier.touchEnded(id: id, time: touch.timestamp))
    }
    didClassify()
  }

  /// The Mac's Dictation started or stopped listening for the phone.
  func setDictationListening(_ listening: Bool) {
    isMacListening = listening
    updateDictationListening()
  }

  /// Releases any held button, stops the wheel and forgets every touch.
  func cancelAll() {
    cancelWheel()
    forward(classifier.cancelAll(time: ProcessInfo.processInfo.systemUptime))
    didClassify()
  }

  private func advance() {
    pendingAdvance = nil
    forward(classifier.advance(to: ProcessInfo.processInfo.systemUptime))
    didClassify()
  }

  private func forward(_ events: [TouchEvent]) {
    guard !events.isEmpty else { return }
    if hapticsEnabled {
      for event in events {
        switch event {
        case .button(_, true, _): haptic.impactOccurred()
        case .returnKey: firmHaptic.impactOccurred(intensity: 1)
        case .button, .contact: break
        }
      }
    }
    engine.handle(touchEvents: events)
  }

  /// Publishes the held buttons and re-arms the timer for the classifier's next deadline.
  private func didClassify() {
    let held = classifier.heldButtons
    if held != heldButtons {
      heldButtons = held
    }
    if classifier.isReturnKeyTouched != isReturnKeyTouched {
      isReturnKeyTouched = classifier.isReturnKeyTouched
    }

    pendingAdvance?.cancel()
    pendingAdvance = nil
    guard let deadline = classifier.nextDeadline else { return }
    let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.advance() }
    }
    pendingAdvance = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  // MARK: - Wheel

  private func cancelWheel() {
    wheelTouch = nil
    handle(wheel.cancel(time: ProcessInfo.processInfo.systemUptime))
  }

  /// Forwards the wheel's events, plays its ticks and keeps the display link running while the
  /// wheel needs it.
  private func handle(_ update: ScrollWheel.Update) {
    if !update.events.isEmpty {
      engine.handle(wheelEvents: update.events)
    }
    if update.ticks > 0 {
      playTick()
    }
    for case .dictation(false, _) in update.events where hapticsEnabled {
      haptic.impactOccurred()
    }
    if wheel.isDictating != isDictating {
      isDictating = wheel.isDictating
      updateDictationListening()
    }
    if wheel.rotation != wheelRotation {
      wheelRotation = wheel.rotation
    }
    if wheel.isTouching != isWheelTouched {
      isWheelTouched = wheel.isTouching
    }
    updateFrameTicker()
  }

  /// Shows the Mac listening only while this hold dictates, with a firm tap when it starts.
  private func updateDictationListening() {
    let listening = isDictating && isMacListening
    guard listening != isDictationListening else { return }
    isDictationListening = listening
    if listening && hapticsEnabled {
      firmHaptic.impactOccurred(intensity: 1)
    }
  }

  private func playTick() {
    let intensity = settings.wheel.tickIntensity
    guard hapticsEnabled, intensity > 0 else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastTickAt >= Self.minimumTickInterval else { return }
    lastTickAt = now
    tickHaptic.impactOccurred(intensity: CGFloat(min(1, intensity)))
    tickHaptic.prepare()
  }

  private func updateFrameTicker() {
    let isNeeded = wheel.needsFrames || wheel.isTouching
    if isNeeded && frameTicker == nil {
      frameTicker = FrameTicker { [weak self] in
        guard let self else { return }
        handle(
          wheel.advance(to: ProcessInfo.processInfo.systemUptime, settings: settings.wheel))
      }
    } else if !isNeeded, let frameTicker {
      frameTicker.stop()
      self.frameTicker = nil
    }
  }
}

/// Calls `onFrame` every display refresh until stopped.
@MainActor
private final class FrameTicker: NSObject {
  private let onFrame: @MainActor () -> Void
  private var link: CADisplayLink?

  init(onFrame: @escaping @MainActor () -> Void) {
    self.onFrame = onFrame
    super.init()
    let link = CADisplayLink(target: self, selector: #selector(step))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func step() {
    onFrame()
  }
}
