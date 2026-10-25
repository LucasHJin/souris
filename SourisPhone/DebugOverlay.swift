import Foundation
import SwiftUI

/// A compact monospaced block of live readouts for tuning.
struct DebugOverlay: View {
  let snapshot: EngineSnapshot

  var body: some View {
    Text(DebugReadout.lines(for: snapshot).joined(separator: "\n"))
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(.secondary)
      .lineSpacing(2)
      .lineLimit(nil)
      .fixedSize()
  }
}

/// Formats the readouts with fixed-width numbers so the block doesn't jitter.
enum DebugReadout {
  static func lines(for snapshot: EngineSnapshot) -> [String] {
    let diagnostics = snapshot.diagnostics
    let link = snapshot.linkStats
    let isLifted = snapshot.flags.contains(.lifted)
    let video = snapshot.videoFormat.map { "\($0.width)x\($0.height)@\($0.framesPerSecond)" }
    let focus = snapshot.minimumFocusDistance.map { "\($0) mm" }
    let tracking = pad(diagnostics.tracking.rawValue, to: 20)
    let thermal = pad(thermalName(snapshot.thermalState), to: 8)

    return [
      "AR  \(tracking) \(number(diagnostics.arFrameRate, 5, 1)) fps"
        + " \(number(diagnostics.arDelayMs, 6, 1)) ms",
      "IMU \(number(diagnostics.imuRate, 5, 1)) Hz \(number(diagnostics.imuDelayMs, 6, 1)) ms"
        + "  clock \(diagnostics.clockMismatch ? "MISMATCH" : "ok")",
      "jitter \(number(diagnostics.jitterMm, 5, 2)) mm"
        + "  speed \(number(diagnostics.speedMmPerSecond, 6, 0)) mm/s"
        + "  gain \(number(diagnostics.gain, 4, 2))",
      "height \(number(diagnostics.heightAboveDeskCm, 6, 1, signed: true)) cm"
        + "  lifted \(yesNo(isLifted))",
      "pitch \(number(diagnostics.pitchDegrees, 6, 1, signed: true))°"
        + "  scroll \(number(diagnostics.scrollSpeed, 6, 0, signed: true)) px/s"
        + "  frozen \(yesNo(diagnostics.isFrozen))",
      "RTT \(optionalNumber(link.rttMedianMs, 5, 1))/\(optionalNumber(link.rttMaxMs, 6, 1)) ms"
        + "  \(number(link.packetsPerSecond, 4, 0))/s"
        + "  loss \(number(link.pingLoss * 100, 3, 0))%"
        + (link.isUSB ? "  USB" : "  Wi-Fi"),
      "cursor \(pad(diagnostics.cursorGate.rawValue, to: 18))"
        + " presses \(String(format: "%4ld", diagnostics.scrollPresses))",
      "thermal \(thermal)  jumps \(String(format: "%4ld", diagnostics.rejectedJumps))"
        + "  log \(String(format: "%5ld", snapshot.logStats.queuedRecords))"
        + (snapshot.logStats.dropped > 0 ? " -\(snapshot.logStats.dropped)" : ""),
      "\(video ?? "--")  focus \(focus ?? "--")",
    ]
  }

  private static func number(
    _ value: Double, _ width: Int, _ decimals: Int, signed: Bool = false
  ) -> String {
    String(format: "%\(signed ? "+" : "")\(width).\(decimals)f", value)
  }

  private static func optionalNumber(_ value: Double?, _ width: Int, _ decimals: Int) -> String {
    guard let value else { return pad("--", to: width, leading: true) }
    return number(value, width, decimals)
  }

  private static func pad(_ text: String, to width: Int, leading: Bool = false) -> String {
    let padding = String(repeating: " ", count: max(0, width - text.count))
    return leading ? padding + text : text + padding
  }

  private static func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no "
  }

  private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
