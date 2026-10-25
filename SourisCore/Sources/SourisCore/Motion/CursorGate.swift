import Foundation

/// Why the cursor is or isn't following the sensor point right now. When several reasons apply,
/// the first in this declaration order after `open` wins: paused, waitingForTracking, notEngaged,
/// lifted, trackingLost, tiltScrolling, wheelHeld, clickFreeze.
public enum CursorGate: String, Codable, Sendable, CaseIterable {
  /// Nothing holds the cursor back.
  case open

  /// The app is paused (settings open, app inactive).
  case paused

  /// No ARKit frame with normal tracking has arrived yet, so there is no orientation anchor.
  case waitingForTracking

  /// Tracking is up but the heading, level and desk height aren't captured yet (just after
  /// unpausing or Recenter).
  case notEngaged

  /// The lift clutch is open.
  case lifted

  /// No good ARKit frame within the gyro grace period.
  case trackingLost

  /// A tilt scroll is in progress.
  case tiltScrolling

  /// A finger is on the scroll wheel.
  case wheelHeld

  /// A click freeze is holding the cursor.
  case clickFreeze
}

extension CursorGate {
  /// The conditions that can close the cursor, one bit each.
  struct Conditions: OptionSet, Sendable {
    static let paused = Conditions(rawValue: 1 << 0)
    static let waitingForTracking = Conditions(rawValue: 1 << 1)
    static let notEngaged = Conditions(rawValue: 1 << 2)
    static let lifted = Conditions(rawValue: 1 << 3)
    static let trackingLost = Conditions(rawValue: 1 << 4)
    static let tiltScrolling = Conditions(rawValue: 1 << 5)
    static let clickFreeze = Conditions(rawValue: 1 << 6)
    static let wheelHeld = Conditions(rawValue: 1 << 7)

    let rawValue: Int
  }

  private static let precedence: [(Conditions, CursorGate)] = [
    (.paused, .paused),
    (.waitingForTracking, .waitingForTracking),
    (.notEngaged, .notEngaged),
    (.lifted, .lifted),
    (.trackingLost, .trackingLost),
    (.tiltScrolling, .tiltScrolling),
    (.wheelHeld, .wheelHeld),
    (.clickFreeze, .clickFreeze),
  ]

  /// The gate for a set of conditions: the highest-precedence one present, or `open` if none.
  init(highestOf conditions: Conditions) {
    self = Self.precedence.first { conditions.contains($0.0) }?.1 ?? .open
  }
}

/// Cumulative seconds spent in each `CursorGate`, indexed by gate. A fixed set of stored
/// properties, so copying a diagnostics snapshot never allocates.
public struct GateSeconds: Equatable, Sendable {
  private var open: Double = 0
  private var paused: Double = 0
  private var waitingForTracking: Double = 0
  private var notEngaged: Double = 0
  private var lifted: Double = 0
  private var trackingLost: Double = 0
  private var tiltScrolling: Double = 0
  private var wheelHeld: Double = 0
  private var clickFreeze: Double = 0

  public init() {}

  /// The seconds spent in `gate`.
  public subscript(gate: CursorGate) -> Double {
    get { self[keyPath: Self.storage(of: gate)] }
    set { self[keyPath: Self.storage(of: gate)] = newValue }
  }

  /// The seconds accounted across all gates.
  public var total: Double {
    CursorGate.allCases.reduce(0) { $0 + self[$1] }
  }

  private static func storage(of gate: CursorGate) -> WritableKeyPath<GateSeconds, Double> {
    switch gate {
    case .open: \.open
    case .paused: \.paused
    case .waitingForTracking: \.waitingForTracking
    case .notEngaged: \.notEngaged
    case .lifted: \.lifted
    case .trackingLost: \.trackingLost
    case .tiltScrolling: \.tiltScrolling
    case .wheelHeld: \.wheelHeld
    case .clickFreeze: \.clickFreeze
    }
  }
}
