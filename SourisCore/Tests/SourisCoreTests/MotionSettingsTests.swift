import Foundation
import Testing

@testable import SourisCore

@Suite struct MotionSettingsTests {
  /// The settings JSON the app saved before tilt and button scroll were separate groups: a
  /// `scroll` group with tilt enabled, and a lift group with `pivotDistance`. Every value that
  /// still exists differs from its default.
  static let savedBeforeButtonScroll = """
    {
      "pointer": {
        "slowGain": 3.25, "accelerationRatio": 3, "slowSpeed": 25, "fastSpeed": 300,
        "speedScale": 1.2, "filterMinCutoff": 2, "filterBeta": 0.07,
        "filterDerivativeCutoff": 1.5, "sensorReach": 0.05, "gyroAssist": false
      },
      "scroll": {
        "isEnabled": true, "deadZone": 14, "hysteresis": 3, "speedFactor": 9, "exponent": 1.2,
        "maxSpeed": 2000, "isReversed": true, "touchSuppression": 0.2
      },
      "click": { "freezeDuration": 0.1, "freezeBreakout": 4 },
      "lift": {
        "isEnabled": false, "threshold": 0.04, "window": 0.4, "deskTimeConstant": 3,
        "reengageDescent": 0.02, "reengageSpeed": 0.06, "reengageHold": 0.15,
        "rollsBackCursor": false, "pivotDistance": 0.2
      },
      "tracking": { "maxPlausibleSpeed": 4, "recoveryFrames": 5, "gyroGracePeriod": 0.4 }
    }
    """

  static func decode(_ json: String) throws -> PipelineSettings {
    try JSONDecoder().decode(PipelineSettings.self, from: Data(json.utf8))
  }

  @Test func newDefaults() {
    let settings = PipelineSettings()
    #expect(!settings.tiltScroll.isEnabled)
    #expect(settings.tiltScroll.levelCaptureLimit == 20)
    #expect(settings.tiltScroll.deadZone == 10)
    #expect(settings.buttonScroll.isEnabled)
    #expect(settings.buttonScroll.step == 100)
    #expect(settings.buttonScroll.glideTime == 0.08)
    #expect(!settings.buttonScroll.isReversed)
    #expect(settings.buttonScroll.holdInterval == 0.3)
    #expect(settings.buttonScroll.holdRampTime == 1)
    #expect(settings.buttonScroll.maxHoldMultiplier == 3)
    #expect(settings.lift.frontDistance == 0.03)
    #expect(settings.lift.backDistance == 0.13)
  }

  @Test func settingsSavedBeforeButtonScrollKeepEverythingButTheScrollGroup() throws {
    let settings = try Self.decode(Self.savedBeforeButtonScroll)

    // The old `scroll` group is ignored: tilt is off and every tilt value is a default.
    #expect(settings.tiltScroll == PipelineSettings.TiltScroll())
    #expect(!settings.tiltScroll.isEnabled)
    #expect(settings.tiltScroll.deadZone == 10)
    #expect(settings.buttonScroll == PipelineSettings.ButtonScroll())

    // The groups that kept their shape keep their saved values.
    #expect(settings.pointer.slowGain == 3.25)
    #expect(settings.pointer.accelerationRatio == 3)
    #expect(settings.pointer.sensorReach == 0.05)
    #expect(!settings.pointer.gyroAssist)
    #expect(settings.click.freezeDuration == 0.1)
    #expect(settings.click.freezeBreakout == 4)
    #expect(settings.tracking.maxPlausibleSpeed == 4)
    #expect(settings.tracking.recoveryFrames == 5)
    #expect(settings.tracking.gyroGracePeriod == 0.4)

    // The lift group keeps its saved values, drops `pivotDistance` and gets the new distances.
    #expect(!settings.lift.isEnabled)
    #expect(settings.lift.threshold == 0.04)
    #expect(settings.lift.window == 0.4)
    #expect(settings.lift.deskTimeConstant == 3)
    #expect(settings.lift.reengageDescent == 0.02)
    #expect(settings.lift.reengageSpeed == 0.06)
    #expect(settings.lift.reengageHold == 0.15)
    #expect(!settings.lift.rollsBackCursor)
    #expect(settings.lift.frontDistance == 0.03)
    #expect(settings.lift.backDistance == 0.13)
  }

  @Test func theOldShapeStillDrivesThePipeline() throws {
    // Replaying with settings saved by the old app: no tilt scroll even in a steep tilt.
    let settings = try Self.decode(Self.savedBeforeButtonScroll)
    var session = SyntheticSession(duration: 3)
    session.path.pitch = { time in 15 * .pi / 180 * Synthetic.ramp(time, 0.5, 1) }
    let steps = session.replay(settings)
    #expect(steps.allSatisfy { !$0.state.flags.contains(.scrollActive) })
  }

  @Test func settingsRoundTrip() throws {
    var settings = PipelineSettings()
    settings.pointer.slowGain = 4
    settings.tiltScroll.isEnabled = true
    settings.tiltScroll.levelCaptureLimit = 30
    settings.buttonScroll.step = 150
    settings.buttonScroll.glideTime = 0.1
    settings.buttonScroll.isReversed = true
    settings.buttonScroll.holdInterval = 0.25
    settings.buttonScroll.holdRampTime = 2
    settings.buttonScroll.maxHoldMultiplier = 4
    settings.lift.frontDistance = 0.05
    settings.lift.backDistance = 0.1
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(PipelineSettings.self, from: data) == settings)
    let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let groups: Set = ["pointer", "tiltScroll", "buttonScroll", "click", "lift", "tracking"]
    #expect(Set(keys.keys) == groups)
    let lift = try #require(keys["lift"] as? [String: Any])
    #expect(lift["pivotDistance"] == nil)
  }

  @Test func missingGroupsAndFieldsTakeTheirDefaults() throws {
    #expect(try Self.decode("{}") == PipelineSettings())

    let partial = try Self.decode("""
      {
        "tiltScroll": { "deadZone": 12 },
        "buttonScroll": { "step": 150, "isReversed": true },
        "lift": { "threshold": 0.05 }
      }
      """)
    var expected = PipelineSettings()
    expected.tiltScroll.deadZone = 12
    expected.buttonScroll.step = 150
    expected.buttonScroll.isReversed = true
    expected.lift.threshold = 0.05
    #expect(partial == expected)
    #expect(!partial.tiltScroll.isEnabled)
    #expect(partial.buttonScroll.isEnabled)
  }

  @Test func aGroupThatFailsToDecodeFallsBackWithoutLosingTheOthers() throws {
    let settings = try Self.decode("""
      {
        "pointer": { "slowGain": "fast" },
        "tiltScroll": [1, 2, 3],
        "buttonScroll": { "step": 150, "glideTime": "slow" },
        "click": { "freezeDuration": 0.2, "freezeBreakout": 5 },
        "lift": { "threshold": 0.05 }
      }
      """)
    #expect(settings.pointer == PipelineSettings.Pointer())
    #expect(settings.tiltScroll == PipelineSettings.TiltScroll())
    #expect(settings.buttonScroll == PipelineSettings.ButtonScroll())
    #expect(settings.click.freezeDuration == 0.2)
    #expect(settings.click.freezeBreakout == 5)
    #expect(settings.lift.threshold == 0.05)
    #expect(settings.tracking == PipelineSettings.Tracking())
  }

  @Test func aLiftGroupWithOnlyTheOldKeyGetsTheDefaults() throws {
    let settings = try Self.decode(#"{ "lift": { "pivotDistance": 0.2 } }"#)
    #expect(settings.lift == PipelineSettings.Lift())
  }
}
