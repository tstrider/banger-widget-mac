//  TierGrammar.swift — the shared vocabulary of the TIER gestures.
//
//  WHY THIS DIRECTORY EXISTS
//
//  `Sources/BangerKit/Celebration/Layers/` owns THE BURST: one struck event, fired from
//  the checkbox, that answers the click inside two frames. It does that well and nothing
//  in here touches it.
//
//  What the burst cannot do, on its own, is escalate. Scaling one gesture up produces a
//  volume knob: the same radial fan at every stage, so you can name the stage only from
//  its radius, never from its shape.
//
//  ─────────────────────────────────────────────────────────────────────────────────
//  THE KIND OF THE SECOND BEAT IS THE ESCALATION
//  ─────────────────────────────────────────────────────────────────────────────────
//
//  Every tier's FIRST beat is the same event: the click was answered. It is allowed to
//  grow a little with the tier (it would be perverse if the last task of a streak week
//  hit no harder than the second task of a Tuesday) but it is deliberately NOT where the
//  escalation lives — `baseIntensity` compresses the burst's 0.30…0.94 intensity range
//  into 0.30…0.62 for exactly that reason.
//
//  What differs is what happens AFTER 300 ms, and it differs in SILHOUETTE:
//
//      standard    nothing. The screen is black by 300 ms and stays black.
//      building    a RING blooms outward off the checkbox, overshoots, settles, lets go.
//      finalTask   a LINE is struck left through the checkbox, overshoots, is drawn
//                  away, and a single accent lands on the box it started from.
//      streak      the RING, then the LINE, then the accent. Both gestures, in sequence.
//
//  Nothing / circle / line / circle-then-line. Normalise the radius and the brightness
//  away and those four are still four different pictures at 500 ms. That is the only
//  thing this table exists to guarantee.
//
//  And the second beat is not a fixed fraction of the first: a fixed fraction is what
//  one envelope template multiplied by a gain looks like from the outside. Chip counts
//  rise with the tier, so the top tier's re-arrival is about as large as its own impact,
//  the tier below it about two thirds, and the tier below that about a half.
//
//  RULES EVERY GESTURE FOLLOWS:
//    - OUTWARD only. A gesture that contracts onto the checkbox reads as the gift being
//      taken back.
//    - No PARKED hold. The ring arrives with a 185 ms overshoot move and is released
//      before it can sit still and become a sticker.
//    - No TAIL. Every tier stops when its last gesture stops.
//
//  Everything here is a pure function of (config, number of steps taken). No clock reads,
//  no `Double.random`, `SeededRandom` only.

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - The knob the particle layers should honour

/// Sizing the tier gestures share, and the matching scale for the base burst.
public enum TierTuning: Sendable {

    /// Chip edge length as a fraction of `BurstProfile.reach`. At `finalTask` intensity
    /// this lands a chip at ~13 pt.
    public static let chipSideOverReach: Double = 0.098

    /// What `BurstProfile.sizeScale` should be multiplied by, and `bodyCount` divided by,
    /// for the base burst's pieces to match the tier chips' size. Not read by code; it
    /// records the target scale in one place.
    public static let baseChipScaleRequest: Double = 2.9
    public static let baseCountScaleRequest: Double = 1.0 / 2.9
}

// MARK: - The signature colour

/// THE TIER GESTURES ARE TEAL. Not "teal-leaning": teal.
///
/// Five or six hue families at similar weights read as generic party-popper confetti.
/// One strongly led hue can read rich rather than monotonous, because a signature colour
/// is what makes a celebration belong to a product instead of to a preset.
///
/// So everything this directory draws — every ring chip, every struck chip, every stroke,
/// the accent and its rim — comes out of a FOUR-family palette led hard by the product's
/// accent teal. Periwinkle and lime are not merely demoted here, they are zero: a hue
/// that appears at 4 % is a hue that makes the histogram look like a preset without ever
/// being seen.
///
/// The base burst's own palette lives in `Layers/BurstCore.swift`. This one covers
/// everything after 300 ms, which — with the second beat half to nearly all of the
/// first — is most of the chromatic mass in a `building`, `finalTask` or `streak`
/// celebration.
enum TierPalette {
    /// teal, gold, hot pink, periwinkle, lime, white.
    static let body: [Double]  = [0.615, 0.185, 0.075, 0.0, 0.0, 0.125]
    /// The reverse face of a card. Real confetti is printed both sides; keeping the
    /// backs on the same four families is what stops the flip from reintroducing a
    /// fifth hue every time a chip turns over.
    static let back: [Double]  = [0.530, 0.210, 0.095, 0.0, 0.0, 0.165]
    /// Strokes and fronts are the lead hue outright.
    static let strokeIndex: Int = 0
}

// MARK: - Easing this directory owns

enum TierEase {
    /// Overshoot-and-settle. Reaches ~1.10 at u≈0.6, crosses back and lands exactly on
    /// 1.0 at u == 1. The settle is guaranteed by the algebra, not by a second ramp, so
    /// an arrival can never park short of its target or drift past it.
    static func outBack(_ u: Double, _ tension: Double = 1.70) -> Double {
        let x = BurstEase.clamp01(u) - 1
        let c3 = tension + 1
        return 1 + c3 * x * x * x + tension * x * x
    }
}

// MARK: - The shape table

/// Every time, count and KIND that distinguishes one tier from another, in one place.
public struct TierShape: Sendable {

    /// The two second-beat gestures this product owns. They share no axis, no
    /// silhouette and no exit.
    public enum GestureKind: String, Sendable {
        /// A ring of chips blooming OUTWARD off the checkbox, with a leading stroke.
        /// A circle. `building`, and `streak`'s first half.
        case bloomRing
        /// A single straight line struck left through the checkbox, drawn like a pen
        /// stroke: pressure-tapered, overshooting its end and settling back, throwing
        /// chips off its edge as it goes. `finalTask`, and `streak`'s second half.
        case strikeSweep
    }

    /// One second-beat gesture, placed in time.
    public struct Gesture: Sendable {
        public let kind: GestureKind
        /// Seconds after the trigger at which it begins arriving.
        public let at: Double
        /// Chips it is made of.
        public let count: Int
        /// Seconds each chip dwells at the end of its own arrival before the gesture
        /// lets go of it. Per-chip, not global: the ring releases as a wave in the order
        /// it arrived, which is what stops the whole thing snapping off at one instant
        /// and looking switched off. Unused by `strikeSweep`, which throws its material
        /// as the nib passes.
        public let release: Double
        /// Seconds after `at` by which nothing of it is on screen.
        public let ends: Double
        /// Its size, as a multiple of `reach`.
        public let span: Double
    }

    public let tier: CelebrationTier
    public let intensity: Double
    /// The intensity the BASE BURST is built at. See the note on the compression above.
    public let baseIntensity: Double
    public let origin: CGPoint
    public let seed: UInt64
    public let reach: Double
    public let fallExit: Double
    public let fallFade: Double

    // --- the gap -------------------------------------------------------------
    /// Seconds of real time during which the base burst runs at its own speed. The
    /// attack is inside this window and is never touched.
    public let warpStart: Double
    /// Seconds of real time by which the base burst's clock is running at `warpRate`.
    public let warpFull: Double
    /// Terminal multiplier on the base burst's clock. 1.0 = no gap is opened.
    public let warpRate: Double
    /// Real-time window over which whatever the warp has not already cleared hands off.
    public let handoffStart: Double
    public let handoffEnd: Double

    // --- the beats -----------------------------------------------------------
    /// In order. Empty for `standard`, one for `building` and `finalTask`, two for
    /// `streak` — and the two are different KINDS, not two of the same.
    public let gestures: [Gesture]
    /// When the terminal accent fires. `nil` for the tiers that stop rather than end.
    public let accentAt: Double?

    public let duration: Double
    public let chipSide: Double
    /// True when this celebration has been damped to an acknowledgement rather than a
    /// burst.
    public let isTap: Bool

    /// Below this intensity a `standard` celebration is, by construction, a damped one.
    ///
    /// `CelebrationConfig` is the frozen contract and it carries intensity and tier but
    /// not the `EscalationPlan`, so a layer cannot be told "this one is a tap". It can
    /// INFER it: `EscalationEngine.Tuning.floor[.standard]` is 0.10 and an undamped
    /// `standard` never sits below ~0.30, so anything under this threshold arrived here
    /// through the rapid-fire bucket or the re-check guard.
    public static let tapIntensityCeiling: Double = 0.148

    /// The same idea one tier up: at or below this intensity a `building` celebration has
    /// been damped past the point where the engine still gives it a second beat, so the
    /// ring is not built at all and the tier falls back to one statement.
    public static let singleBeatIntensityCeiling: Double = 0.455

    public init(config: CelebrationConfig) {
        let profile = BurstProfile(config: config)
        tier = config.tier
        let t = config.intensity.isFinite ? min(max(config.intensity, 0), 1) : 0
        intensity = t
        origin = config.origin
        seed = config.seed
        reach = profile.reach
        fallExit = profile.fallExit
        fallFade = profile.fallFade
        chipSide = profile.reach * TierTuning.chipSideOverReach

        // THE FIRST BEAT IS NOT THE ESCALATION.
        //
        // The engine hands this layer 0.30 for a mid-list task and 0.94 for the last
        // task of a streak week. Fed straight into the burst, that would be the same
        // emitter throwing bigger, brighter, faster pieces: a 3.1x range on one
        // gesture and nothing else changing. Compressed to 1.8x, the opening still
        // acknowledges that this task was a bigger deal — and every tier's opening is
        // recognisably the same event, which is what makes the difference AFTER it read
        // as a difference in kind rather than as more of the same.
        //
        // `min` rather than a straight remap, so a damped celebration (rapid fire, a
        // re-check) still passes its low intensity through untouched. The compression
        // must never make a suppressed celebration louder than the engine asked for.
        let u = BurstEase.clamp01((t - 0.30) / 0.64)
        baseIntensity = min(t, 0.32 + 0.30 * u)

        switch config.tier {

        case .standard:
            let damped = t <= Self.tapIntensityCeiling
            isTap = damped
            gestures = []
            accentAt = nil
            if damped {
                // RAPID FIRE. Five boxes in ten seconds must not be five bangs. The
                // acknowledgement keeps the first ~120 ms of the burst — the part that
                // answers the click — and then clears.
                warpStart = 0.058; warpFull = 0.132; warpRate = 2.10
                handoffStart = 0.180; handoffEnd = 0.400
                duration = 0.46
            } else {
                // ONE statement, and it is the SHORTEST full thing Banger does, because
                // it is the thing it does most often. IT ENDS FLAT. Nothing arrives
                // after it, there is no accent, there is no coda — and that emptiness is
                // load-bearing: it is what makes the ring mean something when it turns
                // up on the tier above, and the line when it turns up on the tier above
                // that. A `standard` that had a small version of the ending would make
                // the ending a volume setting.
                warpStart = 0.038; warpFull = 0.112; warpRate = 2.40
                handoffStart = 0.300; handoffEnd = 0.580
                // Must outlast handoffEnd, or the scene is torn down before the fade
                // finishes and the last of the field leaves in one step - on the tier
                // that fires on every ordinary task.
                duration = 0.62
            }

        case .building:
            // TWO statements, and the second one is a RING. The field is cleared hard
            // from 0.042 s so that by 0.37 s there is NOTHING on screen, and then a ring
            // of chips blooms outward off the checkbox, overshoots its radius by a tenth,
            // settles, breathes for a beat and lets go.
            //
            // It is a circle, and there is no circle anywhere else in a Banger
            // celebration except the opening shockwave it deliberately rhymes with. It
            // does not hold and it does not contract: it arrives, moves for 185 ms, and
            // is released into the fall before it can become a sticker.
            warpStart = 0.042; warpFull = 0.120; warpRate = 2.60
            handoffStart = 0.300; handoffEnd = 0.600
            isTap = false
            let damped = t <= Self.singleBeatIntensityCeiling
            accentAt = nil
            if damped {
                gestures = []
                duration = 0.62
            } else {
                gestures = [Gesture(kind: .bloomRing, at: 0.400,
                                    count: Int((88.0 + 24.0 * t).rounded()),
                                    release: 0.030, ends: 0.450, span: 0.82)]
                duration = 0.88
            }

        case .finalTask:
            // Two statements AND an ending, and the second statement is a LINE.
            //
            // A strikethrough. It is the gesture of crossing something off a list — the
            // literal, physical meaning of what just happened — and it is the only
            // straight, single-direction, non-radial move in the entire product. A fan
            // and a ring are both round; a line is not, at any radius, in any crop, with
            // the sound off. That is why it is a line and not a brighter ring: it is the
            // one silhouette that cannot be mistaken for a bigger version of the tier
            // below.
            //
            // It is struck LEFT, across the empty black the widget sits beside, passing
            // through the checkbox rather than starting at it — so the checkbox is the
            // thing being struck through, not the thing throwing. It overshoots its end
            // by a tenth and settles back, the way a pen does. Then it is drawn away by
            // thinning to nothing (a physical collapse, not an opacity fade) and ONE
            // accent lands on the box it started from.
            warpStart = 0.042; warpFull = 0.120; warpRate = 2.60
            handoffStart = 0.300; handoffEnd = 0.600
            isTap = false
            gestures = [Gesture(kind: .strikeSweep, at: 0.400,
                                count: Int((196.0 + 46.0 * t).rounded()),
                                release: 0.0, ends: 0.560, span: 1.70)]
            accentAt = 0.790
            duration = 0.98

        case .streak:
            // BOTH, IN SEQUENCE. The ring blooms and is released; the screen is nearly
            // clear again; and then the line is struck through the space it left, and
            // the accent lands.
            //
            // This is the one tier whose second act has two acts of its own, and it is
            // the only reason a viewer can tell `streak` from `finalTask` with the radius
            // normalised: `finalTask` is one line, `streak` is a circle and then a line.
            // Neither is a louder version of the other.
            //
            // Nothing is added after the accent. Chips drifting on behind an ending
            // that has already landed are not restraint; they are the celebration
            // running out of material in public.
            warpStart = 0.042; warpFull = 0.120; warpRate = 2.60
            handoffStart = 0.300; handoffEnd = 0.600
            isTap = false
            gestures = [
                Gesture(kind: .bloomRing, at: 0.400,
                        count: Int((132.0 + 36.0 * t).rounded()),
                        release: 0.022, ends: 0.390, span: 0.88),
                Gesture(kind: .strikeSweep, at: 0.700,
                        count: Int((172.0 + 42.0 * t).rounded()),
                        release: 0.0, ends: 0.560, span: 1.78),
            ]
            accentAt = 1.070
            duration = 1.16
        }
    }

    /// The base burst's clock speed at real time `t`. Always 1.0 before `warpStart`.
    public func warp(at t: Double) -> Double {
        guard warpRate > 1.0001 else { return 1.0 }
        if t <= warpStart { return 1.0 }
        if t >= warpFull { return warpRate }
        let u = (t - warpStart) / max(1e-6, warpFull - warpStart)
        return 1.0 + (warpRate - 1.0) * BurstEase.smoothstep(u)
    }

    /// Total chips across every second-beat gesture: the re-arrival's size, for
    /// comparing against the opening's.
    public var secondBeatChips: Int { gestures.reduce(0) { $0 + $1.count } }
}

// MARK: - Chips

/// A tier-gesture chip. Deliberately the same two-sided, foreshortened card the paper
/// layer draws, at roughly three times the size, so a second beat reads as the same
/// material arriving rather than as a different effect switched on.
struct TierChip {
    var position: CGPoint
    var velocity: CGVector
    var rotation: Double
    var angularVelocity: Double
    var side: Double
    var aspect: Double
    var colorIndex: Int
    var backIndex: Int
    var flip: Double
    var flipSpeed: Double
    var bright: Double
    /// 0 before the chip exists, 1 once it is fully in. Used only for arrivals, never
    /// as a substitute for an exit.
    var fadeIn: Double = 1
    var alpha: Double = 1
}

enum TierChipDraw {

    /// One chip, drawn the way `PaperLayer` draws one: two-sided, foreshortened, with a
    /// once-per-revolution specular flash.
    static func draw(_ c: TierChip, in context: inout GraphicsContext, extra: Double = 1) {
        let a = c.alpha * c.fadeIn * extra
        guard a > 0.006 else { return }

        let face = cos(c.flip * 2 * .pi)
        let squash = max(0.05, abs(face))

        var layer = context
        layer.opacity = a
        layer.translateBy(x: c.position.x, y: c.position.y)
        layer.rotate(by: .radians(c.rotation))

        let w = c.side * squash
        let h = c.side * c.aspect
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let path = Path(roundedRect: rect, cornerRadius: min(w, h) * 0.22)

        let showingBack = face < 0
        let index = showingBack ? c.backIndex : c.colorIndex
        let value = c.bright * (showingBack ? 0.94 : 1.0)
        layer.fill(path, with: .color(BurstPalette.color(index).opacity(value)))

        let shade = pow(1 - squash, 3.0) * 0.32
        if shade > 0.02 {
            layer.fill(path, with: .color(.black.opacity(shade)))
        }
        let spec = pow(max(0, face), 7)
        if spec > 0.02 {
            var hot = layer
            hot.blendMode = .plusLighter
            hot.fill(path, with: .color(.white.opacity(spec * 0.26)))
        }
    }

    /// The only thing that takes a chip's opacity away on the way OUT: where it is, not
    /// how old it is. Same law the paper layer uses, so a tier chip leaves the frame the
    /// way a burst chip does.
    static func exitAlpha(y: Double, canvasHeight: Double,
                          originY: Double, fallExit: Double, fallFade: Double) -> Double {
        let floorY = min(canvasHeight + fallFade, originY + fallExit)
        if y >= floorY { return 0 }
        let d = floorY - y
        if d >= fallFade { return 1 }
        return BurstEase.smoothstep(d / max(1e-6, fallFade))
    }

    /// A tier chip, seeded once, in the signature palette.
    static func make(side: Double, at position: CGPoint, _ rng: inout SeededRandom) -> TierChip {
        TierChip(
            position: position,
            velocity: .zero,
            rotation: rng.range(0, 2 * .pi),
            angularVelocity: rng.range(-4.0, 4.0),
            side: side,
            aspect: rng.range(1.0, 1.45),
            colorIndex: BurstPalette.pick(TierPalette.body, &rng),
            backIndex: BurstPalette.pick(TierPalette.back, &rng),
            flip: rng.unit(),
            flipSpeed: rng.range(0.9, 3.4),
            bright: rng.range(0.94, 1.0),
            fadeIn: 0
        )
    }
}
