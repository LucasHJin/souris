import Foundation

/// Something notable the pipeline did, for the phone's log and the replay timeline. Read them
/// with `MotionPipeline.drainEvents()`.
public struct PipelineEvent: Equatable, Codable, Sendable {
  /// What a scroll came from.
  public enum ScrollSource: String, Codable, Sendable {
    case tilt
    case buttons
  }

  /// Why the heading and desk height were re-taken without a full engage.
  public enum ReanchorReason: String, Codable, Sendable {
    /// Tracking returned to normal after a loss.
    case trackingRecovered

    /// An ARKit pose jump was rejected.
    case jump
  }

  /// What happened.
  public enum Kind: Equatable, Codable, Sendable {
    /// Heading and desk height were captured. `pitchDegrees` is the phone's pitch (nil before
    /// the first Core Motion sample), and `levelCaptured` whether it became the tilt-scroll
    /// level.
    case engaged(pitchDegrees: Double?, levelCaptured: Bool)

    /// The pitch was past `tiltScroll.levelCaptureLimit`, so the previous level stays.
    case levelRejected(pitchDegrees: Double)

    case reanchored(reason: ReanchorReason)

    /// The lift clutch opened. `riseCm` is the rise that tripped it, and `rolledBackPoints` how
    /// far the cursor was set back.
    case lifted(riseCm: Double, rolledBackPoints: Double)

    /// The lift clutch closed after a descent of `dropCm` from the lift's peak.
    case setDown(dropCm: Double)

    /// An ARKit delta faster than `tracking.maxPlausibleSpeed` was dropped.
    case jumpRejected(speedMetresPerSecond: Double)

    case trackingChanged(TrackingStatus)

    case gateChanged(from: CursorGate, to: CursorGate)

    case scrollStarted(source: ScrollSource)

    /// A scroll finished. `pixels` is the signed distance it scrolled in total.
    case scrollEnded(source: ScrollSource, pixels: Double)

    /// A volume-button press was accepted and queued `pixels` (signed, hold multiplier
    /// included).
    case scrollPress(direction: ScrollButtonPress.Direction, pixels: Double)

    case paused(Bool)

    case recentered
  }

  /// The causing input's time: a sample's arrival, or a touch's or press's own time. Pause and
  /// recenter calls carry no time and take the previous input's (0 before any input).
  public var time: TimeInterval

  public var kind: Kind

  public init(time: TimeInterval, kind: Kind) {
    self.time = time
    self.kind = kind
  }
}
