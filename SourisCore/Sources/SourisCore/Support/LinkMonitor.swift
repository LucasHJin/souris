/// The phone's running link statistics: round-trip times, ping loss and send rate.
///
/// All of it covers a sliding window of the last `windowSize` pings, so a Wi-Fi stall shows up in
/// the numbers for a few seconds and then ages out.
struct LinkMonitor {
  static let windowSize = 50

  /// A ping with no pong after this long counts as lost.
  static let lossThresholdMicros: UInt64 = 1_000_000

  private struct PingRecord {
    var id: UInt32
    var sentMicros: UInt64
    var isAnswered = false
  }

  /// Weight of the newest sample in the smoothed send rate.
  private static let rateSmoothing = 0.4

  private var roundTripsMs = RecentWindow<Double>(capacity: windowSize)
  private var pings = RecentWindow<PingRecord>(capacity: windowSize)
  private var smoothedRate: Double?

  mutating func recordPing(id: UInt32, sentMicros: UInt64) {
    pings.append(PingRecord(id: id, sentMicros: sentMicros))
  }

  /// Records a round trip when `id` matches a ping that is still unanswered and `echoedMicros` is
  /// the time that ping carried. Duplicate, forged and very late pongs are ignored.
  ///
  /// - Returns: The round-trip time recorded, in milliseconds, or `nil` if the pong was ignored.
  @discardableResult
  mutating func recordPong(id: UInt32, echoedMicros: UInt64, arrivalMicros: UInt64) -> Double? {
    guard let index = pings.lastIndex(where: { $0.id == id }),
          !pings[index].isAnswered,
          pings[index].sentMicros == echoedMicros,
          arrivalMicros >= echoedMicros
    else { return nil }
    pings[index].isAnswered = true
    let roundTripMs = Double(arrivalMicros - echoedMicros) / 1000
    roundTripsMs.append(roundTripMs)
    return roundTripMs
  }

  /// Folds `packets` sent over the last `seconds` into the smoothed send rate.
  mutating func recordSends(_ packets: Int, over seconds: Double) {
    guard seconds > 0 else { return }
    let sample = Double(packets) / seconds
    if let smoothedRate {
      self.smoothedRate = smoothedRate + Self.rateSmoothing * (sample - smoothedRate)
    } else {
      smoothedRate = sample
    }
  }

  func snapshot(nowMicros: UInt64) -> LinkStats {
    var stats = LinkStats()
    stats.rttMedianMs = median(of: roundTripsMs)
    stats.rttMaxMs = roundTripsMs.max()
    stats.packetsPerSecond = smoothedRate ?? 0

    var settled = 0
    var lost = 0
    for ping in pings {
      if ping.isAnswered {
        settled += 1
      } else if nowMicros > ping.sentMicros
        && nowMicros - ping.sentMicros > Self.lossThresholdMicros
      {
        settled += 1
        lost += 1
      }
    }
    stats.pingLoss = settled == 0 ? 0 : Double(lost) / Double(settled)
    return stats
  }

  private func median(of values: RecentWindow<Double>) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }
}
