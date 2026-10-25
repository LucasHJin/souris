import CoreAudio
import Dispatch
import Foundation

/// Reports when an app starts or stops recording from a microphone, so the log can time macOS's
/// Dictation against the shortcut that toggles it.
///
/// It reads Core Audio's per-process state, which needs no microphone permission and still
/// shows Dictation starting while another app (a call, System Settings' level meter) already
/// holds the microphone.
///
/// Not thread-safe: call it only on the queue it was created with, which also runs `onChange`.
final class MicrophoneWatcher: @unchecked Sendable {
  /// An app that started or stopped recording.
  struct Change {
    /// Its bundle identifier, or its process id when it has none.
    var app: String
    var isRecording: Bool
  }

  private let queue: DispatchQueue
  private let onChange: (Change) -> Void

  /// The watched Core Audio process objects: their listeners and whether each was last seen
  /// recording.
  private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
  private var isRecording: [AudioObjectID: Bool] = [:]
  private var processListListener: AudioObjectPropertyListenerBlock?

  init(queue: DispatchQueue, onChange: @escaping (Change) -> Void) {
    self.queue = queue
    self.onChange = onChange
  }

  /// The apps recording now.
  var recordingApps: [String] {
    isRecording.filter(\.value).keys.map(Self.app(of:)).sorted()
  }

  /// Starts watching every app that uses audio, and those that start later.
  func start() {
    guard processListListener == nil else { return }
    var address = Self.address(kAudioHardwarePropertyProcessObjectList)
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.watchProcesses(reportingNew: true)
    }
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    guard status == noErr else { return }
    processListListener = listener
    watchProcesses(reportingNew: false)
  }

  /// Watches the processes using audio now and forgets the ones that stopped.
  ///
  /// - Parameter reportingNew: Report a new process that is already recording; false for the
  ///   first scan, whose recordings started before Souris was watching.
  private func watchProcesses(reportingNew: Bool) {
    let processes = Set(Self.processIDs())
    var address = Self.address(kAudioProcessPropertyIsRunningInput)
    for (process, listener) in listeners where !processes.contains(process) {
      AudioObjectRemovePropertyListenerBlock(process, &address, queue, listener)
      listeners[process] = nil
      if isRecording.removeValue(forKey: process) == true {
        onChange(Change(app: Self.app(of: process), isRecording: false))
      }
    }
    for process in processes where listeners[process] == nil {
      let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.update(process)
      }
      guard AudioObjectAddPropertyListenerBlock(process, &address, queue, listener) == noErr
      else { continue }
      listeners[process] = listener
      isRecording[process] = false
      if reportingNew {
        update(process)
      } else {
        isRecording[process] = Self.isRecording(process)
      }
    }
  }

  private func update(_ process: AudioObjectID) {
    let recording = Self.isRecording(process)
    guard recording != isRecording[process] else { return }
    isRecording[process] = recording
    onChange(Change(app: Self.app(of: process), isRecording: recording))
  }

  // MARK: - Core Audio

  private static func address(_ selector: AudioObjectPropertySelector)
    -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private static func processIDs() -> [AudioObjectID] {
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

  private static func isRecording(_ process: AudioObjectID) -> Bool {
    var address = address(kAudioProcessPropertyIsRunningInput)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr
      && value != 0
  }

  private static func app(of process: AudioObjectID) -> String {
    var address = address(kAudioProcessPropertyBundleID)
    var bundleID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &bundleID) { pointer in
      AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
    }
    if status == noErr, let bundleID {
      let name = bundleID.takeRetainedValue() as String
      if !name.isEmpty {
        return name
      }
    }
    address = Self.address(kAudioProcessPropertyPID)
    var pid: pid_t = 0
    size = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
    return "pid \(pid)"
  }
}
