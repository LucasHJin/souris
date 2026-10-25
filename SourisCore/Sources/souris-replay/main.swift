import Foundation
import SourisCore

/// `souris-replay <file.jsonl> [--csv out.csv] [--events] [--set key=value ...]`
///
/// Replays a recorded session through the motion pipeline on the Mac, prints a summary and
/// optionally writes every step to a CSV file or prints the pipeline's event timeline. `--set`
/// overrides one setting by its path, such as `pointer.slowGain=3` or `lift.isEnabled=false`, on
/// top of the recording's own settings.

struct UsageError: Error, CustomStringConvertible {
  var description: String
}

struct Options {
  var recording: URL
  var csv: URL?
  var showsEvents = false
  var overrides: [(path: String, value: String)] = []

  static let usage = """
    usage: souris-replay <recording.jsonl> [--csv out.csv] [--events] [--set key=value ...]
      --csv     write every step (cursor, scroll, buttons, flags, gate, ...) to a CSV file
      --events  print the pipeline's event timeline (gate changes, lifts, scrolls, ...)
      --set     override one setting by its PipelineSettings path, for the whole replay,
                e.g. pointer.slowGain=3, tiltScroll.deadZone=12, buttonScroll.step=150,
                lift.backDistance=0.1, lift.isEnabled=false
    """

  init(arguments: [String]) throws {
    var recording: URL?
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--csv":
        index += 1
        guard index < arguments.count else { throw UsageError(description: Self.usage) }
        csv = URL(fileURLWithPath: arguments[index])
      case "--events":
        showsEvents = true
      case "--set":
        index += 1
        guard index < arguments.count, let equals = arguments[index].firstIndex(of: "=") else {
          throw UsageError(description: Self.usage)
        }
        let pair = arguments[index]
        overrides.append(
          (String(pair[..<equals]), String(pair[pair.index(after: equals)...])))
      case "-h", "--help":
        throw UsageError(description: Self.usage)
      default:
        guard recording == nil, !argument.hasPrefix("--") else {
          throw UsageError(description: Self.usage)
        }
        recording = URL(fileURLWithPath: argument)
      }
      index += 1
    }
    guard let recording else { throw UsageError(description: Self.usage) }
    self.recording = recording
  }
}

/// Applies `key=value` overrides by round-tripping the settings through a JSON dictionary, so
/// every field is reachable without listing them here.
func applying(
  _ overrides: [(path: String, value: String)],
  to settings: PipelineSettings
) throws -> PipelineSettings {
  guard !overrides.isEmpty else { return settings }
  let data = try JSONEncoder().encode(settings)
  guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw UsageError(description: "settings didn't encode as an object")
  }
  for (path, value) in overrides {
    let keys = path.split(separator: ".").map(String.init)
    root = try setting(value, at: keys[...], in: root, path: path)
  }
  let edited = try JSONSerialization.data(withJSONObject: root)
  return try JSONDecoder().decode(PipelineSettings.self, from: edited)
}

func setting(
  _ value: String,
  at keys: ArraySlice<String>,
  in object: [String: Any],
  path: String
) throws -> [String: Any] {
  guard let key = keys.first, let existing = object[key] else {
    throw UsageError(description: "unknown setting \(path)")
  }
  var object = object
  if keys.count > 1 {
    guard let child = existing as? [String: Any] else {
      throw UsageError(description: "unknown setting \(path)")
    }
    object[key] = try setting(value, at: keys.dropFirst(), in: child, path: path)
    return object
  }
  guard let number = existing as? NSNumber else {
    throw UsageError(description: "\(path) is a group, not a value")
  }
  if CFGetTypeID(number) == CFBooleanGetTypeID() {
    guard let flag = Bool(value) else {
      throw UsageError(description: "\(path) takes true or false")
    }
    object[key] = flag
  } else if let integer = Int(value) {
    object[key] = integer
  } else if let double = Double(value) {
    object[key] = double
  } else {
    throw UsageError(description: "\(path) takes a number")
  }
  return object
}

/// The `fraction` quantile of `values` (nearest rank), or 0 if empty.
func quantile(_ values: [Double], _ fraction: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  let rank = Int((fraction * Double(sorted.count - 1)).rounded())
  return sorted[min(max(rank, 0), sorted.count - 1)]
}

func format(_ value: Double, _ decimals: Int = 1) -> String {
  String(format: "%.\(decimals)f", value)
}

/// One line per event: its time, then a description.
func describe(_ event: PipelineEvent) -> String {
  let kind: String
  switch event.kind {
  case .engaged(let pitch, let levelCaptured):
    kind = "engaged pitch \(pitch.map { format($0) + " deg" } ?? "unknown"), "
      + (levelCaptured ? "level captured" : "level not captured")
  case .levelRejected(let pitch):
    kind = "level rejected: pitch \(format(pitch)) deg is past the capture limit"
  case .reanchored(let reason):
    kind = "reanchored (\(reason.rawValue))"
  case .lifted(let rise, let rolledBack):
    kind = "lifted after a \(format(rise)) cm rise, rolled back \(format(rolledBack)) pt"
  case .setDown(let drop):
    kind = "set down \(format(drop)) cm below the peak"
  case .jumpRejected(let speed):
    kind = "jump rejected at \(format(speed, 2)) m/s"
  case .trackingChanged(let status):
    kind = "tracking \(status.rawValue)"
  case .gateChanged(let from, let to):
    kind = "gate \(from.rawValue) -> \(to.rawValue)"
  case .scrollStarted(let source):
    kind = "scroll started (\(source.rawValue))"
  case .scrollEnded(let source, let pixels):
    kind = "scroll ended (\(source.rawValue)), \(format(pixels)) px"
  case .scrollPress(let direction, let pixels):
    kind = "scroll press \(direction.rawValue), \(format(pixels)) px queued"
  case .paused(let isPaused):
    kind = isPaused ? "paused" : "unpaused"
  case .recentered:
    kind = "recentered"
  }
  return "\(format(event.time, 3))  \(kind)"
}

func run(_ options: Options) throws {
  let events = try RecordingReader.events(at: options.recording)
  guard !events.isEmpty else { throw UsageError(description: "no events in the recording") }

  var override: PipelineSettings?
  if !options.overrides.isEmpty {
    // Overrides sit on top of the recording's first settings line and then hold for the whole
    // replay, replacing any later settings lines.
    var base = PipelineSettings()
    for case .settings(let recorded) in events {
      base = recorded
      break
    }
    override = try applying(options.overrides, to: base)
  }
  let steps = RecordingReplay.run(events, settings: override)

  var arTimes: [TimeInterval] = []
  var imuTimes: [TimeInterval] = []
  var limitedFrames = 0
  var jitters: [Double] = []
  for (event, step) in zip(events, steps) {
    switch event {
    case .ar(let sample):
      arTimes.append(sample.timestamp)
      jitters.append(step.diagnostics.jitterMm)
      if step.state.flags.contains(.trackingLimited) {
        limitedFrames += 1
      }
    case .imu(let sample):
      imuTimes.append(sample.timestamp)
    case .settings, .touch, .scrollPress, .paused, .recenter:
      break
    }
  }

  var pathLength: Double = 0
  var lifts = 0
  var clicks = 0
  var previous = MouseState()
  for step in steps {
    pathLength += ((step.state.cursor - previous.cursor) * (step.state.cursor - previous.cursor))
      .sum().squareRoot()
    if step.state.flags.contains(.lifted) && !previous.flags.contains(.lifted) {
      lifts += 1
    }
    let pressed = step.state.buttons.subtracting(previous.buttons)
    clicks += pressed.rawValue.nonzeroBitCount
    previous = step.state
  }

  func rate(_ times: [TimeInterval]) -> Double {
    guard let first = times.first, let last = times.last, last > first else { return 0 }
    return Double(times.count - 1) / (last - first)
  }

  let duration = (steps.last?.time ?? 0) - (steps.first?.time ?? 0)
  let final = steps.last?.state ?? MouseState()
  let finalDiagnostics = steps.last?.diagnostics ?? PipelineDiagnostics()
  var buttonScroll: Double = 0
  for case .scrollEnded(.buttons, let pixels) in steps.flatMap(\.events).map(\.kind) {
    buttonScroll += pixels
  }
  print("recording      \(options.recording.path) (\(events.count) events)")
  print("duration       \(format(duration, 2)) s")
  print("ARKit          \(arTimes.count) frames, \(format(rate(arTimes))) Hz")
  print("Core Motion    \(imuTimes.count) samples, \(format(rate(imuTimes))) Hz")
  print("cursor path    \(format(pathLength)) pt, net (\(format(final.cursor.x)), "
    + "\(format(final.cursor.y))) pt")
  print("net scroll     \(format(final.scroll.y)) px")
  print("scroll presses \(finalDiagnostics.scrollPresses), net button scroll "
    + "\(format(buttonScroll)) px")
  print("lifts          \(lifts)")
  print("clicks         \(clicks)")
  print("jitter         p50 \(format(quantile(jitters, 0.5), 2)) mm, "
    + "p95 \(format(quantile(jitters, 0.95), 2)) mm")
  print("rejected jumps \(finalDiagnostics.rejectedJumps)")
  print("limited frames \(limitedFrames) of \(arTimes.count)")
  let gateTotal = finalDiagnostics.gateSeconds.total
  let shares = CursorGate.allCases.compactMap { gate -> String? in
    let seconds = finalDiagnostics.gateSeconds[gate]
    guard seconds > 0 else { return nil }
    return "\(gate.rawValue) \(format(100 * seconds / gateTotal))%"
  }
  print("cursor gates   \(shares.isEmpty ? "n/a" : shares.joined(separator: ", "))")
  let sensorTravel = finalDiagnostics.sensorTravelMm
  if sensorTravel > 0 {
    print("effective gain \(format(finalDiagnostics.cursorTravelPoints / sensorTravel, 2)) pt/mm "
      + "(\(format(finalDiagnostics.cursorTravelPoints)) pt over \(format(sensorTravel)) mm)")
  } else {
    print("effective gain n/a (the sensor never moved the cursor)")
  }

  if options.showsEvents {
    print("")
    print("events")
    for event in steps.flatMap(\.events) {
      print("  " + describe(event))
    }
  }

  if let csv = options.csv {
    var text = "time,cursorX,cursorY,scrollY,buttons,flags,speed,gain,jitter,gate\n"
    for step in steps {
      let fields = [
        format(step.time, 6),
        format(step.state.cursor.x, 3),
        format(step.state.cursor.y, 3),
        format(step.state.scroll.y, 3),
        String(step.state.buttons.rawValue),
        String(step.state.flags.rawValue),
        format(step.diagnostics.speedMmPerSecond, 3),
        format(step.diagnostics.gain, 4),
        format(step.diagnostics.jitterMm, 4),
        step.diagnostics.cursorGate.rawValue,
      ]
      text += fields.joined(separator: ",") + "\n"
    }
    try text.write(to: csv, atomically: true, encoding: .utf8)
    print("csv            \(csv.path) (\(steps.count) rows)")
  }
}

do {
  try run(Options(arguments: Array(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
  FileHandle.standardError.write(Data((error.description + "\n").utf8))
  exit(2)
} catch {
  FileHandle.standardError.write(Data("souris-replay: \(error)\n".utf8))
  exit(1)
}
