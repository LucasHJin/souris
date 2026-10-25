import SwiftUI

import SourisCore

/// The settings sheet. Every change applies live through `AppModel.settings`.
struct SettingsView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var addressDraft = ""
  @State private var isConfirmingReset = false

  var body: some View {
    NavigationStack {
      Form {
        pointerSection
        volumeSection
        wheelSection
        tiltScrollSection
        clicksSection
        liftSection
        connectionSection
        networkSection
        trackingSection
        diagnosticsSection
        resetSection
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .preferredColorScheme(.dark)
    .onAppear { addressDraft = model.settings.manualAddress }
    .onDisappear { commitAddress() }
  }

  // MARK: - Pointer

  private var pointerSection: some View {
    Section {
      SliderRow(
        title: "Speed",
        value: $model.settings.pipeline.pointer.speedScale,
        range: 0.25...4,
        step: 0.05,
        isLogarithmic: true,
        fractionDigits: 2,
        unit: "×")
      SliderRow(
        title: "Acceleration",
        value: $model.settings.pipeline.pointer.accelerationRatio,
        range: 1...8,
        step: 0.1,
        unit: "×")
      SliderRow(
        title: "Smoothing",
        value: $model.settings.pipeline.pointer.filterMinCutoff,
        range: 0.3...5,
        step: 0.1,
        unit: " Hz")
      SliderRow(
        title: "Responsiveness",
        value: $model.settings.pipeline.pointer.filterBeta,
        range: 0...0.2,
        step: 0.005,
        fractionDigits: 3)
      SliderRow(
        title: "Swivel reach",
        value: $model.settings.pipeline.pointer.sensorReach,
        range: 0...0.25,
        step: 0.005,
        displayFactor: 100,
        unit: " cm")
      Toggle("Tilt moves up and down", isOn: $model.settings.pipeline.pointer.tiltPointing)
        .disabled(model.settings.pipeline.tiltScroll.isEnabled)
      SliderRow(
        title: "Tilt reach",
        value: $model.settings.pipeline.pointer.tiltReach,
        range: 0.01...0.25,
        step: 0.005,
        displayFactor: 100,
        unit: " cm")
        .disabled(
          !model.settings.pipeline.pointer.tiltPointing
            || model.settings.pipeline.tiltScroll.isEnabled)
      Toggle("Gyro assist", isOn: $model.settings.pipeline.pointer.gyroAssist)
      Toggle("Motion prediction", isOn: $model.settings.pipeline.prediction.isEnabled)
    } header: {
      Text("Pointer")
    } footer: {
      Text(
        "A lower Smoothing cutoff steadies the pointer at rest but adds lag. Higher "
          + "Responsiveness cuts that lag when moving fast. Swivel reach is how far ahead of the "
          + "camera the sensing point sits. With tilt on, tipping the front edge up moves the "
          + "pointer up as a push forward would; a shorter Tilt reach makes it gentler. Tilt to "
          + "scroll turns it off. Motion prediction uses the accelerometer to move the pointer "
          + "to where the phone is now, not where the camera saw it about 40 ms ago; it "
          + "switches itself on after a second or so of moving.")
    }
  }

  // MARK: - Volume buttons

  private var volumeSection: some View {
    Section {
      Toggle("Volume buttons", isOn: $model.settings.pipeline.volumeButtons.isEnabled)
      Group {
        Picker("Volume up", selection: $model.settings.pipeline.volumeButtons.up) {
          actionChoices
        }
        Picker("Volume down", selection: $model.settings.pipeline.volumeButtons.down) {
          actionChoices
        }
        if model.settings.pipeline.volumeButtons.up == .scroll
          || model.settings.pipeline.volumeButtons.down == .scroll
        {
          SliderRow(
            title: "Scroll step",
            value: $model.settings.pipeline.buttonScroll.step,
            range: 20...400,
            step: 10,
            fractionDigits: 0,
            unit: " px")
          Toggle("Reverse scrolling", isOn: $model.settings.pipeline.buttonScroll.isReversed)
        }
      }
      .disabled(!model.settings.pipeline.volumeButtons.isEnabled)
    } header: {
      Text("Volume buttons")
    } footer: {
      Text(
        "Mission Control, App windows, Show desktop and Spotlight press the Mac’s own shortcuts "
          + "for them, from System Settings → Keyboard → Keyboard Shortcuts. Holding a button "
          + "presses its shortcut once. Set to Scroll, volume up scrolls up one step, and "
          + "holding keeps scrolling faster. While Souris is open the phone’s volume stays at "
          + "50%.")
    }
  }

  private var actionChoices: some View {
    ForEach(PipelineSettings.VolumeButtons.Action.allCases, id: \.self) { action in
      Text(action.title).tag(action)
    }
  }

  // MARK: - Tilt scroll

  private var tiltScrollSection: some View {
    Section {
      Toggle("Tilt to scroll", isOn: $model.settings.pipeline.tiltScroll.isEnabled)
      if model.settings.pipeline.tiltScroll.isEnabled {
        SliderRow(
          title: "Tilt speed",
          value: $model.settings.pipeline.tiltScroll.speedFactor,
          range: 2...40,
          step: 1,
          fractionDigits: 0)
        SliderRow(
          title: "Tilt dead zone",
          value: $model.settings.pipeline.tiltScroll.deadZone,
          range: 5...25,
          step: 1,
          fractionDigits: 0,
          unit: "°")
        Toggle("Reverse tilt", isOn: $model.settings.pipeline.tiltScroll.isReversed)
      }
    } header: {
      Text("Tilt scroll")
    } footer: {
      Text(
        "Tilt to scroll freezes the pointer while it scrolls, and takes over tilting from the "
          + "pointer.")
    }
  }

  // MARK: - Scroll wheel

  private var wheelSection: some View {
    Section {
      Toggle("Scroll wheel", isOn: $model.settings.touch.wheel.isEnabled)
      Group {
        SliderRow(
          title: "Step",
          value: $model.settings.touch.wheel.pixelsPerNotch,
          range: 10...150,
          step: 5,
          fractionDigits: 0,
          unit: " px")
        SliderRow(
          title: "Notch spacing",
          value: $model.settings.touch.wheel.notchSpacing,
          range: 6...30,
          step: 1,
          fractionDigits: 0,
          unit: " pt")
        SliderRow(
          title: "Acceleration",
          value: $model.settings.touch.wheel.maxAcceleration,
          range: 1...8,
          step: 0.5,
          fractionDigits: 1,
          unit: "×")
        Toggle("Momentum", isOn: $model.settings.touch.wheel.hasMomentum)
        SliderRow(
          title: "Spin time",
          value: $model.settings.touch.wheel.momentumTime,
          range: 0.1...1,
          step: 0.05,
          displayFactor: 1000,
          fractionDigits: 0,
          unit: " ms")
          .disabled(!model.settings.touch.wheel.hasMomentum)
        SliderRow(
          title: "Tick strength",
          value: $model.settings.touch.wheel.tickIntensity,
          range: 0...1,
          step: 0.05,
          fractionDigits: 2)
        Toggle("Tick while spinning", isOn: $model.settings.touch.wheel.ticksWhileSpinning)
        Toggle("Tap for middle click", isOn: $model.settings.touch.wheel.tapClicksMiddle)
        Toggle("Reverse direction", isOn: $model.settings.touch.wheel.isReversed)
        SliderRow(
          title: "Width",
          value: $model.settings.touch.wheel.width,
          range: 28...90,
          step: 2,
          fractionDigits: 0,
          unit: " pt")
      }
      .disabled(!model.settings.touch.wheel.isEnabled)
    } header: {
      Text("Scroll wheel")
    } footer: {
      Text(
        "Roll a fingertip along the strip between the buttons like a mouse wheel: each notch "
          + "ticks and scrolls one step, more when you roll fast. Flick it to let it spin on; "
          + "touch it to stop. The pointer holds still while your finger is on it. Ticks need "
          + "Haptics on. If ticks while spinning make the pointer shake, turn them off.")
    }
  }

  // MARK: - Clicks

  private var clicksSection: some View {
    Section {
      SliderRow(
        title: "Click freeze",
        value: $model.settings.pipeline.click.freezeDuration,
        range: 0...0.2,
        step: 0.005,
        displayFactor: 1000,
        fractionDigits: 0,
        unit: " ms")
      Toggle("Haptics", isOn: $model.settings.hapticsEnabled)
    } header: {
      Text("Clicks")
    } footer: {
      Text(
        "Tap the left half of the top area to left-click and the right half to right-click. Two "
          + "quick taps on the left half double-click. A tap on the scroll wheel between them "
          + "middle-clicks.")
    }
  }

  // MARK: - Lift

  private var liftSection: some View {
    Section {
      Toggle("Lift to reposition", isOn: $model.settings.pipeline.lift.isEnabled)
      SliderRow(
        title: "Lift height",
        value: $model.settings.pipeline.lift.threshold,
        range: 0.015...0.06,
        step: 0.0025,
        displayFactor: 100,
        unit: " cm")
        .disabled(!model.settings.pipeline.lift.isEnabled)
      SliderRow(
        title: "Max rollback",
        value: $model.settings.pipeline.lift.rollbackLimit,
        range: 0...200,
        step: 5,
        fractionDigits: 0,
        unit: " pt")
        .disabled(!model.settings.pipeline.lift.isEnabled)
    } header: {
      Text("Lift to reposition")
    } footer: {
      Text(
        "Lift the phone quickly to pause the pointer, like lifting a mouse. Set it down to "
          + "resume. A lift takes back the pointer motion the rise itself caused, up to Max "
          + "rollback; 0 turns that off.")
    }
  }

  // MARK: - Connection

  private var connectionSection: some View {
    Section {
      LabeledContent("Status") {
        HStack(spacing: 8) {
          StatusDot(level: model.snapshot.connectionLine.level)
          Text(model.snapshot.connectionLine.text)
            .multilineTextAlignment(.trailing)
        }
      }
      Button("Reconnect") { model.reconnect() }
      Picker("Mac", selection: $model.settings.macName) {
        Text("Automatic").tag(String?.none)
        ForEach(macChoices, id: \.self) { name in
          Text(name).tag(String?.some(name))
        }
      }
      .disabled(ManualAddress.parse(addressDraft) != nil)
      LabeledContent("Address") {
        TextField("Automatic", text: $addressDraft)
          .multilineTextAlignment(.trailing)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit { commitAddress() }
      }
    } header: {
      Text("Connection")
    } footer: {
      Text(addressFooter)
    }
  }

  private var networkSection: some View {
    Section {
      Toggle(isOn: $model.settings.usesBluetooth) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Bluetooth")
          if model.settings.usesBluetooth {
            Text(bluetoothStatus)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      Toggle("Peer-to-peer Wi-Fi", isOn: $model.settings.includesPeerToPeer)
      if model.settings.usesBluetooth && model.settings.includesPeerToPeer {
        Toggle(
          "Pause peer-to-peer on Bluetooth", isOn: $model.settings.pausesPeerToPeerOnBluetooth)
      }
      Toggle("Wi-Fi voice priority", isOn: $model.settings.usesVoiceServiceClass)
    } header: {
      Text("Network")
    } footer: {
      Text(
        "Without the cable, Bluetooth gives steadier timing than busy Wi-Fi; turn it off if "
          + "Wi-Fi works better where you are. It needs Use Bluetooth on in the Mac menu too. "
          + "Peer-to-peer is only for networks that stop devices seeing each other. Also turn it "
          + "on in the Mac menu. It adds latency, and its searching shares the radio with "
          + "Bluetooth: pausing it on Bluetooth may steady Bluetooth, but falling back to Wi-Fi "
          + "then takes a few seconds. Voice priority sends packets in the Wi-Fi voice queue.")
    }
  }

  private var bluetoothStatus: String {
    switch model.snapshot.bluetoothState {
    case .stopped: "Off"
    case .unavailable(let reason): "Unavailable: Bluetooth is \(reason)"
    case .advertising: "Waiting for the Mac"
    case .connected:
      model.snapshot.linkStats.transport == .bluetooth ? "Carrying the link" : "Linked, standing by"
    }
  }

  /// The discovered Macs, plus the chosen one if Bonjour doesn't currently see it.
  private var macChoices: [String] {
    var names = model.snapshot.macNames
    if let chosen = model.settings.macName, !names.contains(chosen) {
      names.append(chosen)
    }
    return names
  }

  private var addressFooter: String {
    let trimmed = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty && ManualAddress.parse(trimmed) == nil {
      return "That address isn’t readable, so Souris is using Bonjour."
    }
    return "Leave Address empty to find your Mac with Bonjour. The port defaults to "
      + "\(WireProtocol.defaultPort)."
  }

  private func commitAddress() {
    let trimmed = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed != model.settings.manualAddress {
      model.settings.manualAddress = trimmed
    }
  }

  // MARK: - Tracking

  private var trackingSection: some View {
    Section {
      Toggle("Autofocus", isOn: $model.settings.autoFocus)
      Button("Recenter") { model.recenter() }
    } header: {
      Text("Tracking")
    } footer: {
      Text(
        "Changing Autofocus restarts the camera. Recenter captures the forward direction, scroll "
          + "level and desk height again, as if you had just set the phone down.")
    }
  }

  // MARK: - Diagnostics

  private var diagnosticsSection: some View {
    Section {
      Toggle("Show debug overlay", isOn: $model.settings.showsDebugOverlay)
      Toggle(isOn: $model.isRecording) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Record sensor session")
          if model.isRecording {
            recordingElapsed
          }
        }
      }
    } header: {
      Text("Diagnostics")
    } footer: {
      if let failure = model.snapshot.recordingFailure {
        Text(failure)
      } else {
        Text(
          "Recordings and logs are in Files → On My iPhone → Souris, and are sent to the Mac’s "
            + "~/Library/Logs/Souris.")
      }
    }
  }

  private var recordingElapsed: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      Text(elapsedText)
        .font(.footnote)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }

  private var elapsedText: String {
    guard let start = model.snapshot.recordingStartedAt else { return "Starting…" }
    let seconds = max(0, Int(ProcessInfo.processInfo.systemUptime - start))
    return String(format: "%ld:%02ld", seconds / 60, seconds % 60)
  }

  // MARK: - Reset

  private var resetSection: some View {
    Section {
      Button("Reset to Defaults", role: .destructive) {
        isConfirmingReset = true
      }
      .confirmationDialog(
        "Reset every setting to its default?",
        isPresented: $isConfirmingReset,
        titleVisibility: .visible
      ) {
        Button("Reset to Defaults", role: .destructive) {
          model.resetSettings()
          addressDraft = ""
        }
      }
    }
  }
}

extension PipelineSettings.VolumeButtons.Action {
  /// The name in the volume-button pickers.
  fileprivate var title: String {
    switch self {
    case .scroll: "Scroll"
    case .missionControl: "Mission Control"
    case .appWindows: "App windows"
    case .showDesktop: "Show desktop"
    case .spotlight: "Spotlight"
    }
  }
}
