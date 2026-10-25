import Foundation
import Observation
import UIKit

import SourisCore

/// Runs the `TouchClassifier` on the main thread and forwards its events to the engine.
///
/// UIKit touch timestamps and `ProcessInfo.systemUptime` share a clock, so the classifier's
/// deadlines are scheduled directly on the main queue.
@MainActor @Observable
final class TouchController {
  /// The buttons the classifier reports as held, for the press feedback on screen.
  private(set) var heldButtons: MouseButtons = []

  @ObservationIgnored private var classifier: TouchClassifier
  @ObservationIgnored private let engine: MouseEngine
  @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .light)
  @ObservationIgnored private var pendingAdvance: DispatchWorkItem?
  @ObservationIgnored var hapticsEnabled: Bool

  init(engine: MouseEngine, settings: TouchSettings, hapticsEnabled: Bool) {
    self.engine = engine
    self.hapticsEnabled = hapticsEnabled
    classifier = TouchClassifier(settings: settings)
  }

  var settings: TouchSettings {
    get { classifier.settings }
    set { classifier.settings = newValue }
  }

  func touchesBegan(_ touches: Set<UITouch>, in view: UIView) {
    let size = view.bounds.size
    for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
      let location = touch.location(in: view)
      if hapticsEnabled, location.y < size.height * classifier.settings.acceptedFraction {
        haptic.prepare()
      }
      forward(
        classifier.touchBegan(
          id: ObjectIdentifier(touch).hashValue,
          location: location,
          in: size,
          time: touch.timestamp))
    }
    didClassify()
  }

  /// Handles both ended and cancelled touches; the classifier treats cancels as lifts.
  func touchesEnded(_ touches: Set<UITouch>) {
    for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
      forward(
        classifier.touchEnded(id: ObjectIdentifier(touch).hashValue, time: touch.timestamp))
    }
    didClassify()
  }

  /// Releases any held button and forgets every touch.
  func cancelAll() {
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
      for case .button(_, true, _) in events {
        haptic.impactOccurred()
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
}
