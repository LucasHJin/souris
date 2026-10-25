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
        scrollSection
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
      Toggle("Gyro assist", isOn: $model.settings.pipeline.pointer.gyroAssist)
    } header: {
      Text("Pointer")
    } footer: {
      Text(
        "A lower Smoothing cutoff steadies the pointer at rest but adds lag. Higher "
          + "Responsiveness cuts that lag when moving fast. Swivel reach is how far ahead of the "
          + "camera the sensing point sits.")
    }
  }

  // MARK: - Scroll

  private var scrollSection: some View {
    Section {
      Toggle("Volume buttons scroll", isOn: $model.settings.pipeline.buttonScroll.isEnabled)
      Group {
        SliderRow(
          title: "Step",
          value: $model.settings.pipeline.buttonScroll.step,
          range: 20...400,
          step: 10,
          fractionDigits: 0,
          unit: " px")
        Toggle("Reverse direction", isOn: $model.settings.pipeline.buttonScroll.isReversed)
      }
      .disabled(!model.settings.pipeline.buttonScroll.isEnabled)
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
      Text("Scroll")
    } footer: {
      Text(
        "Volume up scrolls up one step; hold a button to keep scrolling faster. While Souris is "
          + "open the phone’s volume stays at 50%. Tilt to scroll freezes the pointer while it "
          + "scrolls.")
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
          + "quick taps on the left half double-click.")
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
      Toggle("Peer-to-peer Wi-Fi", isOn: $model.settings.includesPeerToPeer)
      Toggle("Wi-Fi voice priority", isOn: $model.settings.usesVoiceServiceClass)
    } header: {
      Text("Network")
    } footer: {
      Text(
        "Peer-to-peer is only for networks that stop devices seeing each other. Also turn it on "
          + "in the Mac menu. It adds latency. Voice priority sends packets in the Wi-Fi voice "
          + "queue.")
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
