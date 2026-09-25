//  HapticPlan.swift — WHEN the trackpad fires and HOW HARD, as pure data.
//
//  Deliberately in BangerKit and deliberately free of AppKit, for two reasons:
//  the plan can be unit-tested and printed without a window server, and the
//  app layer (Sources/Banger/Haptics.swift) is left with
//  nothing to decide except which NSHapticFeedbackManager pattern maps to which
//  weight.
//
//  THE ONE NUMBER THAT MATTERS: the first pulse is at offset 0.0 and is dispatched
//  SYNCHRONOUSLY, on the same call stack that creates the overlay, before the
//  first frame is drawn. A haptic that arrives after the picture reads as broken
//  in a way no amount of visual polish rescues; a haptic that arrives a few
//  milliseconds before it reads as the click itself. So the design target is
//  "never late", not "exactly on time": the haptic-to-picture offset is expected
//  to be NEGATIVE (haptic first).
//
//  Offsets after the first are in seconds from the strike and line up with the
//  visual beats ImpactFlashLayer draws. Its second beat lands at +335 ms
//  (`FeelProfile.secondBeatAt`, chosen so the light leads the burst's own
//  converging ring at +400 ms). The haptic follows the picture rather than the
//  other way round: a second pulse that fires before the thing it is supposed to
//  be the feel of is worse than no second pulse.

import Foundation

/// How heavy one pulse should feel.
public enum HapticWeight: String, Codable, CaseIterable, Sendable {
    /// One pulse. The acknowledgement for an ordinary mid-list task.
    case tap
    /// Two pulses inside the fusion window, which the hand receives as one
    /// heavier event rather than as two taps. See Sources/Banger/Haptics.swift
    /// for the measurement and the caveat.
    case thump
    /// Three fused pulses. Reserved for the streak clear.
    case slam

    /// Number of physical `perform` calls this weight makes.
    public var pulseCount: Int {
        switch self {
        case .tap: 1
        case .thump: 2
        case .slam: 3
        }
    }
}

/// One scheduled pulse.
public struct HapticPulse: Equatable, Sendable {
    /// Seconds after the trigger.
    public var offset: Double
    public var weight: HapticWeight

    public init(offset: Double, weight: HapticWeight) {
        self.offset = offset
        self.weight = weight
    }
}

public enum HapticPlan {

    /// Spacing between the pulses that make up a single fused `thump` or `slam`.
    ///
    /// Two taps closer together than roughly 30 ms are not resolved as two events
    /// by the hand; they combine into one hit with more weight. 12 ms sits well
    /// inside that, with enough margin that main-queue jitter (well under 1 ms)
    /// cannot push a pair apart into two audible ticks.
    public static let fusionGap: Double = 0.012

    /// Spacing that deliberately reads as two separate events.
    public static let separationGap: Double = 0.090

    /// The pulses for a completion, in order. Offsets are seconds from the click.
    public static func pulses(for config: CelebrationConfig) -> [HapticPulse] {
        switch config.tier {
        case .standard:
            return [HapticPulse(offset: 0, weight: .tap)]
        case .building:
            return [HapticPulse(offset: 0, weight: .thump)]
        case .finalTask:
            return [HapticPulse(offset: 0, weight: .thump),
                    HapticPulse(offset: 0.335, weight: .tap)]
        case .streak:
            return [HapticPulse(offset: 0, weight: .slam),
                    HapticPulse(offset: 0.335, weight: .thump),
                    HapticPulse(offset: 0.800, weight: .tap)]
        }
    }

    /// Every individual `perform` call the plan will make, flattened and sorted.
    /// Timestamps of the actual `perform` calls can be checked against this.
    public static func schedule(for config: CelebrationConfig) -> [Double] {
        var out: [Double] = []
        for pulse in pulses(for: config) {
            for index in 0..<pulse.weight.pulseCount {
                out.append(pulse.offset + Double(index) * fusionGap)
            }
        }
        return out.sorted()
    }
}
