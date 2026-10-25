import CoreAudio
import Foundation

/// Reads whether macOS's Dictation is recording, from Core Audio's per-process state.
///
/// Dictation records through `corespeechd` (`com.apple.CoreSpeech`), whose input runs exactly
/// while Dictation's own log says it listens, plus the 0.25 s before that while the microphone
/// opens. Siri records through it too. Dictation's input method (`com.apple.inputmethod.ironwood`)
/// counts as well, in case a macOS version records there. Reading this needs no microphone
/// permission.
///
/// `corespeechd`'s input also runs while the Mac plays sound, for Siri's self-trigger detector,
/// which taps the Mac's output, and this can't yet tell that from Dictation. Requiring the
/// microphone to be running didn't work: the built-in microphone's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` stays 0 while Dictation records through it
/// (2026-10-25). `details()` reads the other candidates for the log.
///
/// Core Audio sends no change notifications for other processes' state (tested on macOS 26.6), so
/// call `isRecording(at:)` on a timer. Not thread-safe.
final class DictationRecordingProbe {
  private static let bundleIDs: Set<String> = [
    "com.apple.CoreSpeech",
    "com.apple.inputmethod.ironwood",
  ]

  /// Device transports that aren't microphones: BlackHole and other loopback drivers, and devices
  /// built from others.
  private static let nonMicrophoneTransports: Set<UInt32> = [
    kAudioDeviceTransportTypeVirtual,
    kAudioDeviceTransportTypeAggregate,
    kAudioDeviceTransportTypeAutoAggregate,
  ]

  /// How often the lists of processes and devices are read again, seconds, to find Dictation's
  /// processes when they launch or relaunch and microphones when they connect.
  private static let rescanInterval: TimeInterval = 1

  /// The Core Audio process objects of Dictation's processes.
  private var processes: [AudioObjectID] = []

  /// The Core Audio devices that are microphones.
  private var microphones: [AudioObjectID] = []
  private var scannedAt: TimeInterval?

  /// Every process object seen, with its bundle identifier, so a rescan reads only new ones.
  private var bundleIDs: [AudioObjectID: String] = [:]

  /// Every device seen, with whether it is a microphone, so a rescan reads only new ones.
  private var isMicrophone: [AudioObjectID: Bool] = [:]

  /// What else Core Audio shows while Dictation's processes record or stop, for the log.
  struct Details {
    /// A microphone (not a virtual or aggregate device) is running.
    var isMicrophoneRunning: Bool

    /// The input devices Core Audio lists for `corespeechd`.
    var speechInputDevices: Int

    /// `corespeechd` runs output.
    var isSpeechOutputRunning: Bool

    /// The default output device runs, as while the Mac plays sound.
    var isOutputRunning: Bool
  }

  /// Whether one of Dictation's processes is recording now.
  func isRecording(at time: TimeInterval) -> Bool {
    if scannedAt.map({ time - $0 >= Self.rescanInterval }) ?? true {
      rescan()
      scannedAt = time
    }
    return processes.contains(where: Self.isRunningInput)
  }

  /// Reads the `Details` now, from the last scan's processes and devices.
  func details() -> Details {
    let speech = processes.first { bundleIDs[$0] == "com.apple.CoreSpeech" }
    let output = Self.value(
      of: kAudioHardwarePropertyDefaultOutputDevice, for: AudioObjectID(kAudioObjectSystemObject))
    return Details(
      isMicrophoneRunning: microphones.contains(where: Self.isRunningSomewhere),
      speechInputDevices: speech.map {
        Self.objects(kAudioProcessPropertyDevices, of: $0, scope: kAudioObjectPropertyScopeInput)
          .count
      } ?? 0,
      isSpeechOutputRunning: speech.map {
        Self.value(of: kAudioProcessPropertyIsRunningOutput, for: $0).map { $0 != 0 } ?? false
      } ?? false,
      isOutputRunning: output.map(Self.isRunningSomewhere) ?? false)
  }

  private func rescan() {
    let allProcesses = Self.objects(kAudioHardwarePropertyProcessObjectList)
    var knownProcesses: [AudioObjectID: String] = [:]
    for process in allProcesses {
      knownProcesses[process] = bundleIDs[process] ?? Self.bundleID(of: process)
    }
    bundleIDs = knownProcesses
    processes = allProcesses.filter { knownProcesses[$0].map(Self.bundleIDs.contains) ?? false }

    let allDevices = Self.objects(kAudioHardwarePropertyDevices)
    var knownDevices: [AudioObjectID: Bool] = [:]
    for device in allDevices {
      knownDevices[device] = isMicrophone[device] ?? Self.isMicrophone(device)
    }
    isMicrophone = knownDevices
    microphones = allDevices.filter { knownDevices[$0] ?? false }
  }

  // MARK: - Core Audio

  private static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  /// The objects a property of `object` lists, such as the system's processes or devices.
  private static func objects(
    _ selector: AudioObjectPropertySelector,
    of object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [AudioObjectID] {
    var address = address(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
      return []
    }
    var objects = [AudioObjectID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr
    else { return [] }
    return objects
  }

  private static func value(
    of selector: AudioObjectPropertySelector, for object: AudioObjectID
  ) -> UInt32? {
    var address = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  private static func isRunningInput(_ process: AudioObjectID) -> Bool {
    value(of: kAudioProcessPropertyIsRunningInput, for: process).map { $0 != 0 } ?? false
  }

  private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
    value(of: kAudioDevicePropertyDeviceIsRunningSomewhere, for: device).map { $0 != 0 } ?? false
  }

  /// Whether `device` records and is a real one rather than a virtual or aggregate device.
  private static func isMicrophone(_ device: AudioObjectID) -> Bool {
    let inputStreams = objects(
      kAudioDevicePropertyStreams, of: device, scope: kAudioObjectPropertyScopeInput)
    guard !inputStreams.isEmpty,
      let transport = value(of: kAudioDevicePropertyTransportType, for: device)
    else { return false }
    return !nonMicrophoneTransports.contains(transport)
  }

  private static func bundleID(of process: AudioObjectID) -> String {
    var address = address(kAudioProcessPropertyBundleID)
    var bundleID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &bundleID) { pointer in
      AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let bundleID else { return "" }
    return bundleID.takeRetainedValue() as String
  }
}
