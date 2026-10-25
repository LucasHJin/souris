import Foundation
import Testing

@testable import SourisCore

@Suite struct BluetoothPacerTests {
  @Test func notificationsAreSpacedByTheInterval() {
    var pacer = BluetoothPacer()
    #expect(pacer.canSend(at: 1))
    pacer.didSend(at: 1)
    #expect(!pacer.canSend(at: 1 + BluetoothPacer.initialInterval / 2))
    #expect(pacer.canSend(at: 1 + BluetoothPacer.initialInterval))
    #expect(pacer.nextSendTime == 1 + BluetoothPacer.initialInterval)
  }

  @Test func aRefusalGrowsTheIntervalByHalf() {
    var pacer = BluetoothPacer()
    pacer.didRefuse(at: 1)
    #expect(abs(pacer.interval - BluetoothPacer.initialInterval * 1.5) < 1e-12)
    for step in 0..<20 {
      pacer.didRefuse(at: 1 + Double(step) * 0.01)
    }
    #expect(pacer.interval == BluetoothPacer.maximumInterval)
  }

  @Test func roundTripsThatStaySlowGrowTheIntervalOnceForEachFreshSet() {
    var pacer = BluetoothPacer()
    let count = BluetoothPacer.recentCount
    for step in 0..<count {
      pacer.didMeasure(roundTrip: 0.03, at: Double(step) * 0.2)
    }
    let start = pacer.interval
    var time = 1.0
    func measureSlow(_ times: Int) {
      for _ in 0..<times {
        pacer.didMeasure(roundTrip: 0.09, at: time)
        time += 0.2
      }
    }
    // One quick round trip among the recent ones means the queue can still be clear.
    measureSlow(count - 1)
    #expect(pacer.interval <= start)
    measureSlow(1)
    let grown = pacer.interval
    #expect(grown > start)
    // The next change waits for a whole set measured after this one.
    measureSlow(count - 1)
    #expect(pacer.interval == grown)
    measureSlow(1)
    #expect(abs(pacer.interval - grown * 1.25) < 1e-12)
  }

  @Test func connectionEventNoiseAloneNeverGrowsTheInterval() {
    // With nothing queued each round trip still waits 0–30 ms for a connection event on the way
    // out, and the reply rides the next one back. Read one at a time against the fastest, as the
    // first pacer did, that noise grew the interval to its maximum within a second.
    var pacer = BluetoothPacer()
    var seed: UInt64 = 1
    for step in 0..<300 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let phase = Double(seed >> 11) / Double(1 << 53) * 0.03
      pacer.didMeasure(roundTrip: 0.032 + phase, at: Double(step) * 0.2)
    }
    #expect(pacer.interval <= BluetoothPacer.initialInterval, "interval \(pacer.interval)")
  }

  @Test func quickRoundTripsShrinkTheIntervalDownToTheMinimum() {
    var pacer = BluetoothPacer()
    for step in 0..<100 {
      pacer.didMeasure(roundTrip: 0.03, at: Double(step) * 0.2)
    }
    #expect(pacer.interval == BluetoothPacer.minimumInterval)
  }

  @Test func theBaselineForgetsOldRoundTrips() {
    var pacer = BluetoothPacer()
    pacer.didMeasure(roundTrip: 0.02, at: 0)
    pacer.didMeasure(roundTrip: 0.05, at: 5)
    #expect(pacer.baselineRoundTrip == 0.02)
    // Past the window the old quick one no longer counts, so 50 ms is the new normal and isn't
    // read as queuing.
    let interval = pacer.interval
    pacer.didMeasure(roundTrip: 0.05, at: 11)
    #expect(pacer.baselineRoundTrip == 0.05)
    #expect(pacer.interval <= interval)
  }
}
