import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

import SourisCore

/// Reports volume-button presses, which the pipeline turns into scrolling or Mac shortcuts.
///
/// iOS has no button events for apps while ARKit holds the camera, so this watches the media
/// volume instead: each press moves it one step, and the volume goes back to the middle after
/// every press so presses keep registering at either end. A held button repeats, which arrives
/// as a stream of presses. See `docs/limitations-and-fixes.md`, iOS volume buttons.
@MainActor
final class VolumeButtons {
  /// The volume parked between presses.
  private static let middle: Float = 0.5

  /// How long a reset to `middle` is expected to come back through the observer.
  private static let resetAllowance: TimeInterval = 0.5

  /// Must be in the view hierarchy (see `VolumeViewHost`): it is how the volume is reset, and
  /// while it is on screen iOS doesn't show its volume pop-up.
  let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

  /// Called on the main actor for every press.
  var onPress: ((ScrollButtonPress.Direction, TimeInterval) -> Void)?

  /// Called on the main actor for anything worth logging.
  var onLog: ((LogLevel, String, String?, [String: LogValue]) -> Void)?

  private var observation: NSKeyValueObservation?
  private var interruptionObserver: (any NSObjectProtocol)?
  private var isSessionActive = false
  private var isRunning = false

  /// The value the last reset set, until it is seen or `resetAllowance` passes.
  private var expectedReset: (value: Float, deadline: TimeInterval)?

  /// Starts watching the buttons. The audio session is activated once and never deactivated:
  /// reactivating it can leave `outputVolume` stale.
  func start() {
    guard !isRunning else { return }
    isRunning = true
    activateSession()
    let session = AVAudioSession.sharedInstance()
    observation = session.observe(\.outputVolume, options: [.old, .new]) {
      @Sendable [weak self] _, change in
      guard let old = change.oldValue, let new = change.newValue else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.volumeChanged(from: old, to: new)
        }
      }
    }
    if interruptionObserver == nil {
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: session, queue: .main
      ) { [weak self] notification in
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        MainActor.assumeIsolated {
          self?.interruptionChanged(rawType: rawType)
        }
      }
    }
    log(.info, "start", "Watching the volume buttons", ["volume": .double(Double(session.outputVolume))])
    resetVolume(from: session.outputVolume)
  }

  /// Stops watching. The buttons go back to changing the volume.
  func stop() {
    guard isRunning else { return }
    isRunning = false
    observation?.invalidate()
    observation = nil
    expectedReset = nil
    log(.info, "stop", "Stopped watching the volume buttons", [:])
  }

  // MARK: - Private

  private func activateSession() {
    guard !isSessionActive else { return }
    let session = AVAudioSession.sharedInstance()
    do {
      // Playback mixed with others: the buttons then control the media volume without stopping
      // anything else that is playing.
      try session.setCategory(.playback, options: [.mixWithOthers])
      try session.setActive(true)
      isSessionActive = true
    } catch {
      log(
        .error, "session", "Couldn’t activate the audio session, so the volume buttons may not work",
        ["error": .string(error.localizedDescription)])
    }
  }

  private func volumeChanged(from old: Float, to new: Float) {
    guard isRunning else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if let expected = expectedReset {
      if now > expected.deadline {
        expectedReset = nil
      } else if abs(new - expected.value) < 0.001 {
        expectedReset = nil
        return
      }
    }
    guard new != old else { return }
    onPress?(new > old ? .up : .down, now)
    resetVolume(from: new)
  }

  private func resetVolume(from current: Float) {
    guard abs(current - Self.middle) > 0.001 else { return }
    guard let slider = volumeView.subviews.lazy.compactMap({ $0 as? UISlider }).first else {
      log(.warning, "slider", "The volume slider isn’t available, so the volume can’t be reset", [:])
      return
    }
    expectedReset = (Self.middle, ProcessInfo.processInfo.systemUptime + Self.resetAllowance)
    slider.value = Self.middle
  }

  private func interruptionChanged(rawType: UInt?) {
    guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
      return
    }
    switch type {
    case .began:
      isSessionActive = false
      log(.warning, "interruption", "Audio session interrupted", [:])
    case .ended:
      log(.info, "interruption", "Audio session interruption ended", [:])
      activateSession()
    @unknown default:
      break
    }
  }

  private func log(
    _ level: LogLevel, _ event: String, _ message: String?, _ fields: [String: LogValue]
  ) {
    onLog?(level, event, message, fields)
  }
}

/// Puts `VolumeButtons.volumeView` in the window: practically invisible, never touchable.
struct VolumeViewHost: UIViewRepresentable {
  let buttons: VolumeButtons

  func makeUIView(context: Context) -> MPVolumeView {
    let view = buttons.volumeView
    // Hidden or fully transparent views stop suppressing the system volume pop-up.
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
