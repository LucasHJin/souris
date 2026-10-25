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

  @Test func slowRoundTripsGrowTheIntervalOncePerHoldoff() {
    var pacer = BluetoothPacer()
    pacer.didMeasure(roundTrip: 0.03, at: 0)
    let start = pacer.interval
    // Two slow round trips 50 ms apart are the same queue: one growth.
    pacer.didMeasure(roundTrip: 0.09, at: 0.1)
    pacer.didMeasure(roundTrip: 0.09, at: 0.15)
    #expect(abs(pacer.interval - start * 1.25) < 1e-12)
    pacer.didMeasure(roundTrip: 0.09, at: 0.5)
    #expect(abs(pacer.interval - start * 1.25 * 1.25) < 1e-12)
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
