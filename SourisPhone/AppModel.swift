import Observation
import SwiftUI
import UIKit

import SourisCore

/// The UI's view of the app: settings, a 10 Hz copy of the engine's state, and the lifecycle.
///
/// Nothing here is on the sensor hot path. Setting `settings` saves it and applies each changed
/// part live.
@MainActor @Observable
final class AppModel {
  var settings: AppSettings {
    didSet { settingsDidChange(from: oldValue) }
  }

  /// Presenting the sheet cancels touches and pauses the pipeline; dismissing resumes it.
  var isSettingsPresented = false {
    didSet {
      guard isSettingsPresented != oldValue else { return }
      if isSettingsPresented {
        touchController.cancelAll()
      }
      engine.setSettingsOpen(isSettingsPresented)
    }
  }

  var isRecording = false {
    didSet {
      guard isRecording != oldValue else { return }
      engine.setRecording(isRecording)
    }
  }

  private(set) var snapshot = EngineSnapshot()

  let touchController: TouchController

  /// Its volume view must be in the window; `MainView` hosts it.
  @ObservationIgnored let volumeButtons = VolumeButtons()

  @ObservationIgnored private let engine: MouseEngine
  @ObservationIgnored private var isActive = false
  @ObservationIgnored private var refreshTimer: Timer?

  init() {
    let settings = SettingsStore.load()
    let engine = MouseEngine(
      identity: DeviceIdentity.load(),
      pipelineSettings: settings.pipeline,
      network: settings.network,
      autoFocus: settings.autoFocus)
    self.settings = settings
    self.engine = engine
    let touchController = TouchController(
      engine: engine, settings: settings.touch, hapticsEnabled: settings.hapticsEnabled)
    self.touchController = touchController
    engine.observeDictationListening { [weak touchController] listening in
      touchController?.setDictationListening(listening)
    }
    volumeButtons.onPress = { [engine] direction, time in
      engine.handle(scrollPress: ScrollButtonPress(direction: direction, time: time))
    }
    volumeButtons.onLog = { [engine] level, event, message, fields in
      engine.log(level, "volume", event, message, fields)
    }
  }

  // MARK: - Lifecycle

  func scenePhaseDidChange(to phase: ScenePhase) {
    engine.log(.info, "app", "scenePhase", nil, ["phase": .string(String(describing: phase))])
    switch phase {
    case .active:
      activate()
    case .inactive:
      deactivate()
    case .background:
      deactivate()
      isRecording = false
    @unknown default:
      deactivate()
    }
  }

  private func activate() {
    isActive = true
    UIApplication.shared.isIdleTimerDisabled = true
    engine.activate()
    updateVolumeButtons()
    refresh()
    guard refreshTimer == nil else { return }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    // Common modes keep it firing while a slider or scroll view is tracking a touch.
    RunLoop.main.add(timer, forMode: .common)
    refreshTimer = timer
  }

  private func deactivate() {
    isActive = false
    touchController.cancelAll()
    updateVolumeButtons()
    engine.deactivate()
    refreshTimer?.invalidate()
    refreshTimer = nil
    UIApplication.shared.isIdleTimerDisabled = false
  }

  private func refresh() {
    let latest = engine.snapshot()
    if latest != snapshot {
      snapshot = latest
    }
    if isRecording, latest.recordingFailure != nil {
      isRecording = false
    }
  }

  // MARK: - Actions

  func recenter() {
    engine.log(.info, "app", "recenter", "Recenter tapped")
    engine.recenter()
  }

  func reconnect() {
    engine.reconnect()
  }

  func resetSettings() {
    engine.log(.info, "app", "resetSettings", "Settings reset to defaults")
    settings = AppSettings()
  }

  /// Souris takes the volume buttons only while the app is in front and they are on; otherwise
  /// they change the volume as usual.
  private func updateVolumeButtons() {
    if isActive && settings.pipeline.volumeButtons.isEnabled {
      volumeButtons.start()
    } else {
      volumeButtons.stop()
    }
  }

  private func settingsDidChange(from old: AppSettings) {
    SettingsStore.save(settings)
    if settings.pipeline != old.pipeline {
      engine.update(pipelineSettings: settings.pipeline)
      updateVolumeButtons()
    }
    if settings.touch != old.touch {
      touchController.settings = settings.touch
    }
    touchController.hapticsEnabled = settings.hapticsEnabled
    if settings.network != old.network {
      engine.update(network: settings.network)
    }
    if settings.autoFocus != old.autoFocus {
      engine.update(autoFocus: settings.autoFocus)
    }
  }
}
