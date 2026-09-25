//  EscalationPlan.swift — the per-tier overrides the layers are expected to respect.
//
//  WHY THIS TYPE EXISTS
//
//  `CelebrationConfig` carries a tier and an intensity. Intensity alone is a volume knob,
//  and a volume knob is not escalation: a bigger version of the same gesture is the single
//  most common way a "reward" feature turns into noise by week two.
//
//  So the engine emits a PLAN alongside the config. The plan says what the celebration
//  DOES, not merely how loud it is: how many statements it makes, whether it holds before
//  it ends, how it ends, what the audio resolves to, where the haptics land.
//
//  The four tiers differ here in KIND: what changes between them is not how big the
//  second beat is but WHAT IT IS.
//
//    standard   ONE statement. Fires, falls, gone, and it is the shortest thing Banger
//               does because it is the thing it does most often. NOTHING ARRIVES AFTER
//               IT — no ring, no line, no accent, no coda. That emptiness is deliberate
//               and load-bearing: it is what makes the ring mean something on the tier
//               above and the line mean something on the tier above that. 0.55 s. Under
//               rapid fire it degrades further, to a 0.40 s tap.
//
//    building   TWO statements, and the second is a CIRCLE. The field is cleared to
//               nothing by ~370 ms and then a ring of chips blooms OUTWARD off the
//               checkbox, overshoots its radius by a tenth, settles onto it, keeps
//               turning, and is released into the fall. It never holds still and it
//               never contracts. No accent: it stops, it does not end. 0.88 s.
//
//    finalTask  Two statements AND an ending, and the second statement is a LINE. A
//               strikethrough struck left through the checkbox — the physical act of
//               crossing something off, and the only straight, single-direction move in
//               the product. It overshoots its end and settles back like a pen, is drawn
//               away by thinning to nothing, and ONE bright accent lands on the box it
//               started from. 0.98 s.
//
//    streak     BOTH GESTURES, IN SEQUENCE: the ring blooms and is released, and then the
//               line is struck through the space it left, and then the accent lands. It
//               is the only tier whose second act has two acts of its own, and that — not
//               its radius — is how a viewer tells it from `finalTask`. Nothing follows
//               the accent. 1.26 s.
//
//  The re-arrival is not a fixed fraction of the opening. Second-beat chip counts
//  run 0 / 96 / 132 / 254 against openings of roughly 143 / 190 / 240 / 270 bodies: a
//  second beat worth 0 %, 67 %, 61 % and 117 % of its own first, rather than one
//  envelope template being multiplied.
//
//  Nothing in here reads a clock or draws anything. It is a description that the
//  celebration layers, the sound bank and the haptic performer consume.

import CoreGraphics
import Foundation

// MARK: - Gesture

/// What shape the celebration is. Not a size — a shape.
public enum EscalationGesture: String, Codable, CaseIterable, Sendable {
    /// A single statement that fires and falls, and nothing else. `standard`.
    case burst
    /// The burst, then a ring blooming outward off the checkbox. A circle. `building`.
    case burstAndRing
    /// The burst, then a strikethrough struck through the checkbox, then an accent that
    /// lands. A line. `finalTask`.
    case burstAndStrike
    /// The burst, then the ring, then the strikethrough, then the accent. Both gestures
    /// in sequence, which is what `streak` has and no other tier does. `streak`.
    case ringThenStrike
    /// Rapid-fire suppression: a short acknowledgement, no burst.
    case tap
    /// Reduce-motion: a single non-moving flash. No particles, no translation.
    case flash
}

/// How the celebration leaves the screen. An ending that fades is not an ending.
public enum EscalationSettle: String, Codable, CaseIterable, Sendable {
    /// Particles fall out of frame under gravity. The default, and what EVERY moving
    /// tier does: nothing in the celebration travels back toward the checkbox, because
    /// an inward-closing gesture reads as the reward being taken back.
    case fall
    /// The gesture is taken off the screen by a stroke thinning to nothing and a single
    /// accent landing on the checkbox. An ending, not a decay. `finalTask`, `streak`.
    case strikeAndLand
    /// Opacity only. Reduce-motion.
    case dissolve
}

// MARK: - Beats

/// One statement inside the celebration.
public struct EscalationBeat: Equatable, Codable, Sendable {
    /// Milliseconds after the trigger.
    public var atMS: Int
    /// Share of the total particle budget this beat spends. Shares sum to 1.
    public var share: Double
    /// Radians offset applied to the emission axis, so a later beat occupies the gap the
    /// earlier one left instead of repeating it.
    public var axisOffset: Double
    /// Speed multiplier. A late beat that is slower than the first reads as a coda.
    public var speedScale: Double
    /// Particle size multiplier.
    public var sizeScale: Double

    public init(atMS: Int, share: Double, axisOffset: Double = 0,
                speedScale: Double = 1, sizeScale: Double = 1) {
        self.atMS = atMS
        self.share = share
        self.axisOffset = axisOffset
        self.speedScale = speedScale
        self.sizeScale = sizeScale
    }
}

// MARK: - Audio

/// The audio recipe, as an envelope plan.
/// The sound bank owns the synthesis; this says which parts of it are in play.
public struct EscalationAudio: Equatable, Codable, Sendable {
    /// Broadband transient at t=0. Always on unless the whole thing is muted.
    public var click: Bool
    /// 80–160 Hz body under the click. Off in quiet hours.
    public var body: Bool
    /// How many notes of the rising figure sound (0...3).
    public var noteCount: Int
    /// Milliseconds of held resolution after the last note. 0 = the phrase just stops.
    /// Only the ending tiers hold; that hold is most of why they end rather than stop.
    public var holdMS: Int
    /// The late octave-up shimmer. `streak` only.
    public var sparkle: Bool
    /// Linear gain, 0...1. Quiet hours and rapid-fire trim this, never the pitch content.
    public var gain: Double
    /// True when nothing should sound at all.
    public var muted: Bool

    public init(click: Bool = true, body: Bool = true, noteCount: Int = 2,
                holdMS: Int = 0, sparkle: Bool = false, gain: Double = 1,
                muted: Bool = false) {
        self.click = click
        self.body = body
        self.noteCount = noteCount
        self.holdMS = holdMS
        self.sparkle = sparkle
        self.gain = gain
        self.muted = muted
    }

    /// Total sounding length implied by the recipe, milliseconds.
    public var soundingMS: Int {
        if muted { return 0 }
        let notes = [0, 120, 200, 260][min(max(noteCount, 0), 3)]
        let tail = holdMS > 0 ? holdMS : 180
        let sparkleTail = sparkle ? 200 : 0
        return notes + tail + sparkleTail
    }
}

// MARK: - The plan

/// Everything the layers need beyond `intensity`. Produced by `EscalationEngine`.
public struct EscalationPlan: Equatable, Codable, Sendable {

    public var tier: CelebrationTier
    public var gesture: EscalationGesture
    public var settle: EscalationSettle

    /// Total on-screen length, milliseconds. Hard-capped at 2000.
    public var durationMS: Int
    /// Ordered statements. `beats.count` is the tier's beat count.
    public var beats: [EscalationBeat]
    /// Milliseconds after the trigger at which the terminal accent lands, or nil for a
    /// tier that stops rather than ends.
    ///
    /// There is no hold: a still plateau reads as a freeze, not an ending. What
    /// distinguishes an ending is that something LANDS.
    public var accentAtMS: Int?

    /// Milliseconds after the trigger at which a `.levelChange` haptic fires.
    public var hapticsMS: [Int]

    public var audio: EscalationAudio

    /// Index into `BangerPalette.confetti` that leads the burst. Normally the accent
    /// teal; a task an agent added leads on gold so its tasks feel like its own.
    public var paletteLead: Int

    /// True when the visual must not translate, scale or scatter (reduce-motion).
    public var isReducedMotion: Bool

    public init(tier: CelebrationTier,
                gesture: EscalationGesture,
                settle: EscalationSettle,
                durationMS: Int,
                beats: [EscalationBeat],
                accentAtMS: Int? = nil,
                hapticsMS: [Int],
                audio: EscalationAudio,
                paletteLead: Int = 0,
                isReducedMotion: Bool = false) {
        self.tier = tier
        self.gesture = gesture
        self.settle = settle
        self.durationMS = durationMS
        self.beats = beats
        self.accentAtMS = accentAtMS
        self.hapticsMS = hapticsMS
        self.audio = audio
        self.paletteLead = paletteLead
        self.isReducedMotion = isReducedMotion
    }

    /// Seconds, for callers that render or schedule.
    public var duration: Double { Double(durationMS) / 1000 }

    /// The tier's canonical plan, before the engine applies fatigue, quiet hours or
    /// reduce-motion. This is the table that says the tiers differ in kind.
    public static func base(for tier: CelebrationTier) -> EscalationPlan {
        switch tier {

        case .standard:
            // One statement. It does not resolve; it stops. Nothing arrives afterwards.
            return EscalationPlan(
                tier: .standard,
                gesture: .burst,
                settle: .fall,
                durationMS: 550,
                beats: [EscalationBeat(atMS: 0, share: 1.0)],
                hapticsMS: [0],
                audio: EscalationAudio(noteCount: 2, holdMS: 0)
            )

        case .building:
            // A second statement, and it is a CIRCLE: a ring blooming outward off the
            // checkbox, overshooting, settling, turning, released into the fall. Its
            // share is 0.38 of the budget against a first beat of 0.62 — a re-arrival
            // worth about half its own opening.
            return EscalationPlan(
                tier: .building,
                gesture: .burstAndRing,
                settle: .fall,
                durationMS: 880,
                beats: [
                    EscalationBeat(atMS: 0, share: 0.60),
                    // The bloom ring. `axisOffset` is pi because this beat's material
                    // starts at the checkbox and travels away from it on every axis at
                    // once, rather than converging on it.
                    EscalationBeat(atMS: 400, share: 0.40, axisOffset: .pi,
                                   speedScale: 0.94, sizeScale: 3.4),
                ],
                hapticsMS: [0, 400],
                audio: EscalationAudio(noteCount: 3, holdMS: 0)
            )

        case .finalTask:
            // A second statement that is a LINE, and then something LANDS. The strike
            // is 0.36 of the budget and the accent at 700 ms is what makes this an
            // ending rather than a stop. No hold anywhere: the gesture is continuous
            // from 400 ms to 775 ms and then it is over.
            return EscalationPlan(
                tier: .finalTask,
                gesture: .burstAndStrike,
                settle: .strikeAndLand,
                durationMS: 980,
                beats: [
                    EscalationBeat(atMS: 0, share: 0.62),
                    // The strikethrough. A quarter turn off the burst's axis because it
                    // does not fan at all: it runs flat, in one direction, through the
                    // checkbox.
                    EscalationBeat(atMS: 400, share: 0.38, axisOffset: 1.57,
                                   speedScale: 1.10, sizeScale: 3.6),
                ],
                accentAtMS: 790,
                hapticsMS: [0, 400, 790],
                audio: EscalationAudio(noteCount: 3, holdMS: 240)
            )

        case .streak:
            // BOTH gestures, in sequence, and then the accent. Three beats, and the
            // second and third are different KINDS rather than two helpings of one.
            // Together they are 0.52 of the budget against an opening of 0.48 — the only
            // tier whose re-arrival outweighs its own impact.
            //
            // Nothing follows the accent: anything after the landing dilutes the ending.
            return EscalationPlan(
                tier: .streak,
                gesture: .ringThenStrike,
                settle: .strikeAndLand,
                durationMS: 1260,
                beats: [
                    EscalationBeat(atMS: 0, share: 0.46),
                    EscalationBeat(atMS: 400, share: 0.24, axisOffset: .pi,
                                   speedScale: 0.94, sizeScale: 3.4),
                    EscalationBeat(atMS: 700, share: 0.30, axisOffset: 1.57,
                                   speedScale: 1.10, sizeScale: 3.6),
                ],
                accentAtMS: 1070,
                hapticsMS: [0, 400, 700, 1070],
                audio: EscalationAudio(noteCount: 3, holdMS: 260, sparkle: true)
            )
        }
    }

    /// The reduce-motion form of any plan: one still flash at the origin, the same
    /// duration budget cut to a third, audio kept (sound is not motion), haptics kept.
    public func reducedMotion() -> EscalationPlan {
        var plan = self
        plan.gesture = .flash
        plan.settle = .dissolve
        plan.durationMS = min(600, max(260, durationMS / 3))
        plan.beats = [EscalationBeat(atMS: 0, share: 1.0)]
        plan.accentAtMS = nil
        plan.hapticsMS = Array(hapticsMS.prefix(1))
        plan.isReducedMotion = true
        return plan
    }

    /// True when this plan ends rather than merely stops: something lands at the end of
    /// it. `standard` and `building` are false and that is the escalation.
    public var resolves: Bool { accentAtMS != nil }
}
