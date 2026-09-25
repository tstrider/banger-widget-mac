//  BurstCore.swift — the shared vocabulary of the particle burst.
//
//  Four layers make up the burst (shockwave, sparks, paper, ribbons) and they have to
//  agree about where the cannon points, how hard it fires and what colour the event is.
//  That agreement lives here, derived once from `CelebrationConfig`, so a tuning change
//  moves all four layers together instead of drifting them apart.
//
//  Coordinate space is the overlay window's: origin top-left, +y points DOWN.
//  "Up" is therefore negative y and gravity is positive y. Straight up is -pi/2.
//
//  Nothing here reads a clock. Every random draw comes from SeededRandom.

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Profile

/// The burst, as numbers, before any particle exists.
public struct BurstProfile: Sendable {

    // Where and how hard.
    public let origin: CGPoint
    public let intensity: Double
    public let tier: CelebrationTier
    public let seed: UInt64

    /// Main cone axis in radians. The checkbox lives in the top right of the screen,
    /// so the cannon is deliberately canted up-and-LEFT: the burst is thrown across the
    /// empty black instead of into the corner it was fired from. The asymmetry is the
    /// composition, not an accident.
    public let axis: Double
    /// The second beat fires on a different axis so it occupies the gap the first beat
    /// left rather than repeating it.
    public let axisBeat2: Double
    /// Half-width of the fan, radians.
    public let spread: Double
    /// Half-width of the second beat's plume. Deliberately a quarter of `spread`:
    /// beat two is a column, beat one is a fan.
    public let spreadBeat2: Double

    // How many of each kind.
    public let bodyCount: Int
    public let sparkCount: Int
    public let ribbonCount: Int

    // Beat structure. `standard` is one beat; `building`/`finalTask` two; `streak` three.
    public let beatCount: Int
    public let beat2At: Double
    public let beat2Share: Double
    public let beat3At: Double
    public let beat3Share: Double

    // Physics and scale.
    public let gravity: Double
    /// Terminal fall speed, points per second, for a typical face-on card.
    public let terminalFall: Double
    public let sizeScale: Double
    /// Sparks and ribbons are sized off their own scales. At confetti size, reusing
    /// `sizeScale` for everything would turn sparks into chips and streamers into
    /// planks; the three materials are different sizes on purpose.
    public let sparkScale: Double
    public let ribbonScale: Double
    public let speedScale: Double
    public let lifeScale: Double
    /// Shockwave reach in points.
    public let reach: Double
    /// Depth below the origin past which a piece is unreachable and can be forgotten.
    /// Deliberately deeper than any display: it is a memory bound, NOT a kill line.
    public let fallExit: Double
    /// Width of the hand-off band at the bottom of the canvas, in points. It sits below
    /// the visible frame, so nothing visible fades; it exists to keep the shared exit
    /// law's denominator non-zero.
    public let fallFade: Double

    public init(config: CelebrationConfig) {
        let t = config.intensity.isFinite ? min(max(config.intensity, 0), 1) : 0
        origin = config.origin
        intensity = t
        tier = config.tier
        seed = config.seed

        // Tier chooses the shape, not only the size.
        //
        // EVERY TIER GETS THE SECOND EMISSION, INCLUDING `standard`.
        //
        // One impulse followed by a long stretch of chips separating has no event
        // anywhere in it and only one peak of energy. A second, smaller, DIFFERENTLY
        // SHAPED emission after a gap gives the burst a second arrival.
        //
        // `standard` gets it too, and that is deliberate rather than an oversight:
        // the base burst is constructed at `.standard` wherever it is wrapped, so
        // making the second beat a property of the BURST rather than of the TIER is
        // the only way it survives into every celebration Banger fires.
        let countScale: Double
        switch config.tier {
        case .standard:  countScale = 0.90; beatCount = 2
        case .building:  countScale = 1.00; beatCount = 2
        case .finalTask: countScale = 1.06; beatCount = 2
        case .streak:    countScale = 1.24; beatCount = 3
        }
        switch config.tier {
        case .standard:  lifeScale = 0.88
        case .building:  lifeScale = 0.94
        case .finalTask: lifeScale = 1.00
        case .streak:    lifeScale = 1.15
        }

        // PIECES WITH REAL SIZE.
        //
        // A numerous field of tiny cards is not confetti, it is spray: you cannot
        // follow one piece, so you cannot see it fall, so the whole burst has to be
        // sold with brightness instead of with motion (see
        // `TierTuning.baseChipScaleRequest`). Every piece here is big enough that the
        // eye can lock onto one and watch it leave.
        let raw = (161.0 + 322.0 * t) * countScale
        // Coverage comes from the number and size of pieces, not from brightness, so
        // the burst registers over a bright window without anything getting brighter.
        bodyCount = max(24, Int((raw / 1.62).rounded()))
        // Sparks are the leading edge and they are all gone by 300 ms, so they are the
        // cheapest way to buy energy in the window where energy has to be spent — and
        // they are what makes the apex a spike rather than a mesa, because they take
        // two thirds of the frame's energy away with them when they go.
        sparkCount = max(12, Int((raw * 1.60).rounded()))
        // The tail is not a garnish. It is what is left in the air after 900 ms, and it
        // has to LEAVE — by falling out of the bottom of the display, not by dimming.
        ribbonCount = max(6, Int((raw * 0.055).rounded()))

        axis = -Double.pi / 2 - 0.30
        // BEAT TWO IS A DIFFERENT SHAPE, NOT A SECOND SPRAY.
        //
        // The first beat is a wide fan thrown up and to the LEFT, across the empty
        // black. The second is a narrow near-vertical PLUME fired straight up out of
        // the same checkbox: a column, not a fan. Silhouette is the most legible
        // difference two particle events can have and it survives the sound being
        // off, which is the whole reason the second beat reads as an EVENT rather
        // than as more confetti arriving.
        axisBeat2 = -Double.pi / 2 + 0.05
        // Wider fan. A narrow cone concentrates the same paper into a column, which is
        // what made the field read as thin against a real desktop.
        spread = 1.22
        spreadBeat2 = 0.30

        // 320 ms. By then the first wave is down to roughly a third of its peak
        // density, so there is a gap for the second beat to land IN.
        beat2At = 0.320
        beat2Share = beatCount >= 2 ? 0.26 : 0.0
        beat3At = 0.78
        beat3Share = beatCount >= 3 ? 0.12 : 0.0

        // GRAVITY THAT ARRIVES, AND A TERMINAL VELOCITY INSTEAD OF A STOP.
        //
        //   1. There is no kill line. A piece leaves by falling off the BOTTOM OF THE
        //      SCREEN and being clipped by the canvas, and by nothing else.
        //   2. The whole population has a genuine terminal speed it actually reaches,
        //      spread wide enough that the field empties in overlapping waves instead
        //      of all at once.
        //
        // Quadratic drag is what makes that work: dv/dt = g - k·v|v|, k = g/vt². It
        // brakes the 1400 pt/s muzzle velocity in two frames — so the burst reaches its
        // full width while the eye is still on the click — and then all but disappears
        // once the piece has slowed, so the fall genuinely accelerates into a steady
        // descent rather than creeping.
        //
        // Gravity and terminal fall are set so the first wave clears by about
        // 700–900 ms, leaving the rest of the runtime to the second beat. At intensity
        // 0.9 a card crests ~100 pt above the checkbox inside 180 ms and is off the
        // bottom of a 982 pt display about 700 ms later.
        gravity = 4400
        /// Terminal fall speed of a typical card presenting its face to the airflow.
        /// A card that turns edge-on falls appreciably faster, which is why real
        /// confetti surges and checks on the way down.
        terminalFall = 1200 + 320 * t
        sizeScale = (0.845 + 0.225 * t) * 2.42
        // Sparks are most of the apex, so they are where coverage is cheapest to buy.
        // Bigger and blunter also avoids a radial-ray read: a 4–8 pt chip of colour is
        // material, a 3 pt dot with a long white tail is a speed-line out of a stock
        // preset.
        sparkScale = (0.845 + 0.225 * t) * 1.60
        ribbonScale = (0.845 + 0.225 * t) * 1.62
        speedScale = 0.80 + 0.30 * t
        reach = 128 + 58 * t
        // NOT A KILL LINE. Deep enough that it is below the bottom of any display this
        // ever runs on, so `min(canvasHeight + fallFade, originY + fallExit)` — the
        // shared exit law every layer in the celebration uses — always resolves to the
        // BOTTOM OF THE CANVAS. Pieces are at full opacity right up to the edge of the
        // screen and then they are simply not on it any more.
        fallExit = 2600
        // The width of the hand-off band, which sits entirely BELOW the bottom of
        // the frame. It exists so the shared law has a non-zero denominator, not so
        // anything visible fades.
        fallFade = 70
    }

    /// Seconds of SIMULATED time from trigger until every piece is certainly off the
    /// bottom of the screen. It is what `isFinished` reports, so it is also how long the
    /// overlay stays up.
    ///
    /// It is a BACKSTOP, not the mechanism: by design the field has fallen out of the
    /// bottom of the display before this fires. If anything is still drawn when it does,
    /// the burst is being switched off and the physics needs retuning — so this number
    /// is deliberately set BEYOND the expected clear time rather than at it. Note that
    /// the celebration runs this clock faster than real time once the attack has landed
    /// (see `BaseBurstGate`), so the real-time life of the burst is shorter than this.
    public var hardStop: Double {
        let lastSpawn = beatCount >= 3 ? beat3At : (beatCount >= 2 ? beat2At : 0)
        return lastSpawn + 1.95 * lifeScale
    }
}

// MARK: - Palette weighting

/// Six equally weighted colours is the single loudest tell that a burst came out of a
/// preset. These weights put the accent
/// teal in charge and demote lime below the 5 % threshold that would make it count as a
/// fifth hue family.
public enum BurstPalette {

    /// Index order matches `BangerPalette.confetti`:
    /// teal, gold, hot pink, periwinkle, lime, white.
    ///
    /// Teal leads without taking over: past about half the bright pixels the burst
    /// reads as one flat colour. The weights aim at roughly teal 45, gold 22, pink 15,
    /// periwinkle 8, lime 5, white 5, and the SHOCKWAVE — which paints large, bright
    /// areas — does not fire every front on the lead hue.
    public static let bodyWeights: [Double] = [0.335, 0.285, 0.185, 0.110, 0.045, 0.040]
    /// The reverse face of a card. Real confetti is printed both sides and the two sides
    /// are rarely the same colour; the flip is therefore a COLOUR change as well as a
    /// width collapse, which is far more legible than a shadow and costs nothing.
    public static let backWeights: [Double] = [0.300, 0.260, 0.190, 0.140, 0.070, 0.040]
    /// Sparks read as light more than as colour, so white is allowed to lead a little here.
    /// They are tiny and short-lived, so this barely moves the overall share.
    public static let sparkWeights: [Double] = [0.330, 0.280, 0.170, 0.100, 0.065, 0.055]
    /// Ribbons are the big slow shapes that hold the frame at the end; keeping them on the
    /// lead hue is what makes the tail read as one colour story.
    public static let ribbonWeights: [Double] = [0.340, 0.280, 0.200, 0.120, 0.060, 0.000]

    public static func pick(_ weights: [Double], _ rng: inout SeededRandom) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var roll = rng.unit() * total
        for (i, w) in weights.enumerated() {
            roll -= w
            if roll <= 0 { return i }
        }
        return weights.count - 1
    }

    public static func color(_ index: Int) -> Color {
        let palette = BangerPalette.confetti
        guard !palette.isEmpty else { return .white }
        return palette[((index % palette.count) + palette.count) % palette.count]
    }
}

// MARK: - Non-uniform emission

/// A real burst has clumps and gaps. A uniform fan reads as cheap no matter how many
/// particles are in it, because nothing in nature distributes evenly.
///
/// The fan is a handful of lobes with their own weight, width and muzzle velocity. A
/// minority of particles ignore the lobes entirely so the gaps never become hard bands.
public struct ClumpFan: Sendable {
    private let center: [Double]
    private let cumulative: [Double]
    private let sigma: [Double]
    private let speed: [Double]
    private let axis: Double
    private let spread: Double
    /// Fraction of particles emitted uniformly across the fan instead of into a lobe.
    private let looseFraction: Double

    public init(axis: Double, spread: Double, lobes: Int, looseFraction: Double = 0.26,
                rng: inout SeededRandom) {
        self.axis = axis
        self.spread = spread
        self.looseFraction = looseFraction

        var c: [Double] = []
        var w: [Double] = []
        var s: [Double] = []
        var v: [Double] = []
        let n = max(2, lobes)
        for i in 0..<n {
            let slot = Double(i) / Double(n - 1) - 0.5           // -0.5 ... 0.5
            c.append(axis + slot * 2 * spread * 0.86 + rng.range(-0.13, 0.13))
            // Wide weight range: some lobes are a shower, one or two are a puff.
            w.append(0.28 + rng.unit() * rng.unit() * 1.6)
            s.append(spread * rng.range(0.085, 0.235))
            v.append(rng.range(0.74, 1.26))
        }
        let total = w.reduce(0, +)
        var acc = 0.0
        var cum: [Double] = []
        for x in w { acc += x / total; cum.append(acc) }

        center = c
        cumulative = cum
        sigma = s
        speed = v
    }

    /// Returns the launch angle and a per-lobe speed multiplier.
    public func sample(_ rng: inout SeededRandom) -> (angle: Double, speed: Double) {
        if rng.unit() < looseFraction {
            let u = rng.range(-1, 1)
            return (axis + u * abs(u) * spread, rng.range(0.72, 1.12))
        }
        let roll = rng.unit()
        var idx = cumulative.count - 1
        for (i, c) in cumulative.enumerated() where roll <= c { idx = i; break }
        let a = center[idx] + rng.gaussian() * sigma[idx]
        return (a, speed[idx])
    }
}

// MARK: - Easing

public enum BurstEase {
    /// Fast out, slow in. u in 0...1.
    public static func outPow(_ u: Double, _ p: Double) -> Double {
        1 - pow(max(0, 1 - min(1, u)), p)
    }
    public static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
    public static func smoothstep(_ v: Double) -> Double {
        let x = clamp01(v)
        return x * x * (3 - 2 * x)
    }
}
