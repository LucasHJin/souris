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
/// Core Audio sends no change notifications for other processes' state (tested on macOS 26.6), so
/// call `isRecording(at:)` on a timer. Not thread-safe.
final class DictationRecordingProbe {
  private static let bundleIDs: Set<String> = [
    "com.apple.CoreSpeech",
    "com.apple.inputmethod.ironwood",
  ]

  /// How often the list of processes is read again, seconds, to find Dictation's processes when
  /// they launch or relaunch.
  private static let rescanInterval: TimeInterval = 1

  /// The Core Audio process objects of Dictation's processes.
  private var processes: [AudioObjectID] = []
  private var scannedAt: TimeInterval?

  /// Every process object seen, with its bundle identifier, so a rescan reads only new ones.
  private var bundleIDs: [AudioObjectID: String] = [:]

  /// Whether one of Dictation's processes is recording now.
  func isRecording(at time: TimeInterval) -> Bool {
    if scannedAt.map({ time - $0 >= Self.rescanInterval }) ?? true {
      rescan()
      scannedAt = time
    }
    return processes.contains(where: Self.isRunningInput)
  }

  private func rescan() {
    let all = Self.processObjects()
    var known: [AudioObjectID: String] = [:]
    for process in all {
      known[process] = bundleIDs[process] ?? Self.bundleID(of: process)
    }
    bundleIDs = known
    processes = all.filter { known[$0].map(Self.bundleIDs.contains) ?? false }
  }

  // MARK: - Core Audio

  private static func address(_ selector: AudioObjectPropertySelector)
    -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private static func processObjects() -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
      return []
    }
    var processes = [AudioObjectID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr
    else { return [] }
    return processes
  }

  private static func isRunningInput(_ process: AudioObjectID) -> Bool {
    var address = address(kAudioProcessPropertyIsRunningInput)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr
      && value != 0
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
