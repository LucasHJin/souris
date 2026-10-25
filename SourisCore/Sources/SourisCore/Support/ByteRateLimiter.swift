/// A token bucket that holds a stream of sends to an average byte rate.
///
/// A send may go whenever the bucket isn't in debt, and its whole size is then charged, so one
/// send larger than the bucket still goes out and the next waits until the rate has paid it
/// back. The bucket starts full and holds at most `burst` bytes of credit.
struct ByteRateLimiter: Sendable {
  let bytesPerSecond: Double
  let burst: Double

  private var balance: Double
  private var lastRefill: ContinuousClock.Instant?

  init(bytesPerSecond: Double, burst: Double) {
    self.bytesPerSecond = max(0, bytesPerSecond)
    self.burst = max(0, burst)
    balance = self.burst
  }

  /// Whether a send may go at `now`.
  mutating func canSend(now: ContinuousClock.Instant) -> Bool {
    if let lastRefill, now > lastRefill {
      balance = min(burst, balance + bytesPerSecond * (now - lastRefill).seconds)
    }
    lastRefill = max(lastRefill ?? now, now)
    return balance > 0
  }

  /// Charges a send of `bytes`.
  mutating func charge(_ bytes: Int) {
    balance -= Double(bytes)
  }
}
