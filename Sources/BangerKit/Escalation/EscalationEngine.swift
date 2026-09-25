//  NOT IN THE LIVE PATH. Read this before you change anything below it.
//
//  Nothing outside Sources/BangerKit/Escalation/ calls anything in it. No caller for
//  `EscalationEngine.decide`, for `TaskStore.escalate`, or for `EscalationLedger`. The
//  tier and intensity that actually reach the screen are computed by
//  `CelebrationConfig.inferTier` / `.inferIntensity` in Sources/Banger/
//  BangerNotifications.swift, which are a much simpler rule: last task -> finalTask,
//  last task with a live streak -> streak, past 60% of the list -> building, otherwise
//  standard.
//
//  So the things this subsystem describes are NOT happening: no fatigue damping, no
//  quiet hours, no comeback bonus, no per-task farm guard from this ledger, no
//  "recentCompletions" bucket. (Re-checking a box is still guarded, by a different and
//  much smaller thing: Sources/BangerWidget/CelebrationLedger.swift, which writes
//  celebrated.json.)
//
//  It is kept, unwired, as a documented alternative to that rule.
//
//  EscalationEngine.swift — (context) -> (CelebrationConfig, EscalationPlan).
//
//  PURE. No clock, no file, no randomness. Same context in, same decision out, forever.
//
//  ─────────────────────────────────────────────────────────────────────────────────
//  THE DESIGN, IN FIVE CLAIMS
//  ─────────────────────────────────────────────────────────────────────────────────
//
//  1. THE TIER IS KEYED ON WHAT IS LEFT, NOT ON HOW MANY ARE DONE.
//     Escalation that ramps with task index is wrong, not just boring: it says a
//     twelve-task day's tenth task matters more than a three-task day's third, when in
//     fact the three-task day just ENDED and the twelve-task day did not. So `remaining`
//     picks the tier. Both days get exactly one ending, exactly two "closing" steps, and
//     everything before that is flat. Completing a SET is the event.
//
//  2. THE SECOND STATEMENT IS A DIFFERENT KIND OF THING, NOT A LOUDER ONE.
//     `standard` has no second statement at all. `building`'s is a CIRCLE: a ring that
//     blooms outward off the checkbox, overshoots, settles and is released. `finalTask`'s
//     is a LINE: a strikethrough struck through the checkbox, which then hands off to a
//     single accent that LANDS. `streak` performs BOTH, in sequence, and that sequence —
//     not its radius — is how you tell it from `finalTask`. Nothing / circle / line /
//     circle-then-line: four silhouettes, legible with the radius normalised away. See
//     `Celebration/Tiers/TierGrammar.swift` for the table the pixels are built from, and
//     `EscalationPlan.base(for:)` for the engine's copy of it. This can be checked
//     without watching anything: `plan.gesture` names four different shapes and
//     `plan.resolves` is false for standard and building and true for the two endings.
//
//  3. THE RE-ARRIVAL GROWS FASTER THAN THE IMPACT, AND THE CLIP ENDS WHEN IT ENDS.
//     Second-beat budget share runs 0 / 0.38 / 0.36 / 0.52 against openings of
//     1.00 / 0.62 / 0.64 / 0.48, so the re-arrival is worth 0 %, 61 %, 56 % and 108 % of
//     its own first beat, rather than one envelope template multiplied by a gain.
//     And nothing is bolted on after the last gesture.
//     The streak intensity curve still RISES to day ~5 and then eases back down,
//     settling near 0.94 by day 30, because a ritual that gets louder every single day
//     is a ritual you disable.
//
//  4. STARTING AGAIN IS REWARDED.
//     The first task of a day that follows a gap gets `building` — a real step up at the
//     exact moment a habit usually dies. Almost nothing does this, and it is the single
//     highest-leverage line in the file.
//
//  5. IT GETS OUT OF THE WAY WHEN THE USER IS MOVING FAST.
//     Recent completions fill a leaky bucket (18 s time constant). Five boxes in ten
//     seconds leaves the fifth at about a third of the first, half as long, and no longer
//     a burst at all — a tap, with the melody and the low body gone. Push harder and it
//     goes silent and becomes a haptic only. Under fire `building` loses its second beat.
//     So the dampening is a change in shape, not a change in gain. Endings are floored
//     and never demoted: clearing the list is an ending even if they cleared it in forty
//     seconds flat.

import CoreGraphics
import Foundation

// MARK: - Decision

/// What the engine produced, plus why. The `reasons` are for `bangerctl` and for the
/// next person who wonders why a particular check-off felt the way it did.
public struct EscalationDecision: Equatable, Sendable {
    public var config: CelebrationConfig
    public var plan: EscalationPlan
    public var reasons: [String]

    public init(config: CelebrationConfig, plan: EscalationPlan, reasons: [String]) {
        self.config = config
        self.plan = plan
        self.reasons = reasons
    }

    public var tier: CelebrationTier { config.tier }
    public var intensity: Double { config.intensity }
}

// MARK: - Engine

public enum EscalationEngine {

    // MARK: Tuning constants, all in one place

    public enum Tuning {
        /// Leaky-bucket time constant for attention fatigue, seconds.
        public static let fatigueTau = 18.0
        /// How hard fatigue bites, per tier.
        public static let fatigueK: [CelebrationTier: Double] = [
            .standard: 0.55, .building: 0.30, .finalTask: 0.10, .streak: 0.06,
        ]
        /// Intensity floors: how quiet a tier is ever allowed to get.
        public static let floor: [CelebrationTier: Double] = [
            .standard: 0.10, .building: 0.42, .finalTask: 0.68, .streak: 0.78,
        ]
        /// Below this damping factor a `standard` celebration stops making noise.
        public static let muteBelow = 0.28
        /// Below this, `standard` degrades from a burst to a tap.
        public static let tapBelow = 0.46
        /// Below this, `building` loses its second beat.
        public static let singleBeatBelow = 0.52
        /// Quiet-hours audio gain and intensity trim.
        public static let quietGain = 0.55
        public static let quietIntensity = 0.90
        /// A re-checked box pays this fraction of a standard celebration.
        public static let repeatScale = 0.35
        /// Hard ceiling on a celebration's running time.
        public static let maxDurationMS = 2000
    }

    // MARK: The public entry point

    /// The whole engine. Pure.
    public static func decide(_ context: EscalationContext) -> EscalationDecision {
        var reasons: [String] = []

        let tier = self.tier(for: context, reasons: &reasons)
        var intensity = baseIntensity(tier: tier, context: context, reasons: &reasons)
        var plan = EscalationPlan.base(for: tier)

        // --- the noise guard ---------------------------------------------------
        let fatigue = context.fatigue
        let k = Tuning.fatigueK[tier] ?? 0.4
        let damping = 1.0 / (1.0 + k * fatigue)

        if fatigue > 0.15 {
            reasons.append(String(format: "fatigue %.2f from %d recent completions -> x%.2f",
                                  fatigue, context.secondsSinceRecentCompletions.count, damping))
        }

        intensity *= damping
        plan = applyFatigue(plan, damping: damping, tier: tier, reasons: &reasons)

        // --- re-check of a box that already paid out ---------------------------
        if context.isRepeat {
            intensity *= Tuning.repeatScale
            plan.gesture = .tap
            plan.settle = .fall
            plan.durationMS = 420
            plan.beats = [EscalationBeat(atMS: 0, share: 1.0)]
            plan.accentAtMS = nil
            plan.hapticsMS = [0]
            plan.audio = EscalationAudio(click: true, body: false, noteCount: 1,
                                         holdMS: 0, sparkle: false, gain: 0.5)
            reasons.append("repeat completion of the same task today -> acknowledgement only")
        }

        // --- time of day -------------------------------------------------------
        if context.isQuietHours {
            intensity *= Tuning.quietIntensity
            plan.audio.gain *= Tuning.quietGain
            plan.audio.body = false
            plan.audio.sparkle = false
            plan.hapticsMS = Array(plan.hapticsMS.prefix(2))
            reasons.append("quiet hours -> audio trimmed, no low body, no sparkle")
        }

        // --- agent-added tasks lead on gold -----------------------------------
        if context.source == BangerSource.iris {
            plan.paletteLead = 1
            reasons.append("task came from the agent -> gold leads the palette")
        }

        // --- floors and ceilings ----------------------------------------------
        let lower = Tuning.floor[tier] ?? 0.12
        if context.isRepeat {
            intensity = min(max(intensity, 0.12), 0.30)
        } else {
            intensity = min(max(intensity, lower), 1.0)
        }
        plan.durationMS = min(plan.durationMS, Tuning.maxDurationMS)

        // --- accessibility -----------------------------------------------------
        if context.reduceMotion {
            plan = plan.reducedMotion()
            reasons.append("reduce-motion -> still flash, sound and haptics kept")
        }

        // Audio must never outlast the picture.
        // Under reduce-motion the answer is to hold the flash for the phrase, not to cut
        // the phrase: sound is not motion, and taking their sound away is not an
        // accessibility feature.
        if plan.audio.soundingMS > plan.durationMS {
            if plan.isReducedMotion {
                plan.durationMS = min(Tuning.maxDurationMS, plan.audio.soundingMS)
            } else {
                let slack = max(0, plan.durationMS - (plan.audio.soundingMS - plan.audio.holdMS))
                plan.audio.holdMS = min(plan.audio.holdMS, slack)
            }
        }

        let config = CelebrationConfig(
            intensity: intensity,
            tier: tier,
            origin: context.origin,
            seed: context.seed,
            taskIndex: context.taskIndex,
            taskCount: context.taskCount,
            remaining: context.remaining,
            streakDays: context.streakDays,
            source: context.source
        )

        return EscalationDecision(config: config, plan: plan, reasons: reasons)
    }

    // MARK: Tier

    private static func tier(for context: EscalationContext,
                             reasons: inout [String]) -> CelebrationTier {

        // A box that already paid out today never buys an ending again, no matter what
        // `remaining` says. This is the farm guard: uncheck-and-recheck the last task and
        // you get an acknowledgement, not the finale.
        if context.isRepeat {
            reasons.append("task already completed today -> tier capped at standard")
            return .standard
        }

        if context.clearsTheSet {
            // Re-clearing a day that has already been closed out is the other farm route.
            if context.endingAlreadyFired {
                reasons.append("today's ending already fired -> not repeated")
                return .building
            }
            if context.hasLiveStreak {
                reasons.append("clears the set AND a \(context.streakDays)-day streak survives -> streak")
                return .streak
            }
            reasons.append("clears the set (\(context.taskCount) task\(context.taskCount == 1 ? "" : "s")) -> finalTask")
            return .finalTask
        }

        if context.isComeback {
            reasons.append("first task back after \(context.daysSinceLastActivity) days away -> building")
            return .building
        }

        if context.isClosing {
            reasons.append("\(context.remaining) left of \(context.taskCount) -> building")
            return .building
        }

        reasons.append("mid-list (\(context.remaining) of \(context.taskCount) left) -> standard")
        return .standard
    }

    // MARK: Intensity

    private static func baseIntensity(tier: CelebrationTier,
                                      context: EscalationContext,
                                      reasons: inout [String]) -> Double {
        switch tier {

        case .standard:
            // A gentle, almost subliminal drift across the day so the flat stretch is not
            // literally flat — but it moves 0.10 across a whole list, which is a drift,
            // not a ramp. The ramp is the tier change.
            let shoulder = pow(context.setProgress, 1.8)
            return 0.30 + 0.10 * shoulder

        case .building:
            if context.isComeback { return 0.58 }
            return 0.52 + 0.06 * pow(context.setProgress, 1.8)

        case .finalTask:
            // A ten-task day's ending is a little bigger than a two-task day's, but they
            // are the SAME SHAPE. Size acknowledges the work; shape marks the ending.
            let setSize = min(1.0, Double(context.taskCount - 1) / 9.0)
            let value = 0.76 + 0.06 * setSize
            reasons.append(String(format: "ending of a %d-task day -> intensity %.2f",
                                  context.taskCount, value))
            return value

        case .streak:
            let value = streakIntensity(context.streakDays)
            reasons.append(String(format: "streak day %d -> intensity %.2f (curve peaks day 5, eases after)",
                                  context.streakDays + 1, value))
            return value
        }
    }

    /// Rises fast, peaks around the fifth consecutive day, then eases back to a plateau.
    ///
    /// The easing is the designed part. A celebration that is louder every single day is
    /// one they disable in week three; a celebration that swells, arrives, and then settles
    /// into a confident, slightly quieter ritual is one they keep. The streak's growth
    /// after day five shows up in the PLAN (the late sparkle, the third haptic), not in
    /// the volume.
    public static func streakIntensity(_ days: Int) -> Double {
        let d = Double(max(0, days))
        let rise = 1 - exp(-d / 1.8)
        let fatigue = 1 - exp(-Double(max(0, days - 5)) / 12.0)
        return min(1.0, max(0.80, 0.83 + 0.19 * rise - 0.09 * fatigue))
    }

    // MARK: Fatigue applied to the plan

    private static func applyFatigue(_ plan: EscalationPlan,
                                     damping: Double,
                                     tier: CelebrationTier,
                                     reasons: inout [String]) -> EscalationPlan {
        var plan = plan

        switch tier {
        case .standard, .building:
            // Shortening is a far better noise guard than quietening: a short thing that
            // is over before you look at it never becomes clutter.
            let scale = 0.55 + 0.45 * damping
            plan.durationMS = Int(Double(plan.durationMS) * scale)
            plan.audio.gain *= (0.50 + 0.50 * damping)

            if tier == .building, damping < Tuning.singleBeatBelow, plan.beats.count > 1 {
                plan.beats = [EscalationBeat(atMS: 0, share: 1.0)]
                plan.gesture = .burst
                plan.audio.noteCount = 2
                reasons.append("rapid fire -> building drops its second beat")
            }
            if tier == .standard, damping < Tuning.tapBelow {
                // Not a smaller burst — a different, smaller gesture, with the melody
                // taken away. What is left is a click and a thump: an acknowledgement.
                plan.gesture = .tap
                plan.durationMS = min(plan.durationMS, 460)
                plan.audio.noteCount = 1
                plan.audio.body = false
                reasons.append("rapid fire -> standard degrades to a tap, melody dropped")
            }
            if damping < Tuning.muteBelow {
                plan.audio.muted = true
                plan.hapticsMS = [0]
                reasons.append("rapid fire -> silent; haptic only")
            }

        case .finalTask, .streak:
            // An ending is an ending even at the bottom of a blitz. Trim it, never
            // demote it: at most 15 % off the running time, and the hold is untouchable.
            let scale = 0.85 + 0.15 * damping
            plan.durationMS = Int(Double(plan.durationMS) * scale)
            if damping < 0.9 {
                reasons.append("ending trimmed slightly for a busy minute, shape unchanged")
            }
        }

        return plan
    }
}

// MARK: - Convenience

public extension EscalationEngine {

    /// The canonical decision for a tier, with no fatigue, no quiet hours and a full
    /// list behind it. This is what a tier-by-tier render shows.
    static func canonical(_ tier: CelebrationTier,
                          origin: CGPoint = CGPoint(x: 1209, y: 176),
                          seed: UInt64 = 12345) -> EscalationDecision {
        let context: EscalationContext
        switch tier {
        case .standard:
            context = EscalationContext(origin: origin, taskIndex: 1, taskCount: 6,
                                        remaining: 4, streakDays: 0,
                                        isFirstCompletionToday: false, seed: seed)
        case .building:
            context = EscalationContext(origin: origin, taskIndex: 3, taskCount: 6,
                                        remaining: 2, streakDays: 0,
                                        isFirstCompletionToday: false, seed: seed)
        case .finalTask:
            context = EscalationContext(origin: origin, taskIndex: 5, taskCount: 6,
                                        remaining: 0, streakDays: 0,
                                        isFirstCompletionToday: false, seed: seed)
        case .streak:
            context = EscalationContext(origin: origin, taskIndex: 5, taskCount: 6,
                                        remaining: 0, streakDays: 5,
                                        isFirstCompletionToday: false, seed: seed)
        }
        return decide(context)
    }
}
