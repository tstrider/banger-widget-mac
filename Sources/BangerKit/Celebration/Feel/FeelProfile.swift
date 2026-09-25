//  FeelProfile.swift — every tunable number for the impact, in one place,
//  derived from CelebrationConfig and nothing else.
//
//  Four rules encoded here that the rest of the file is downstream of:
//
//   1. The BOX LEADS THE ROW. The box's spring peaks at 60 % of the row's peak
//      time. The eye is on the checkbox when the click happens, so the checkbox
//      is what must move first; the row answering 30 ms later is what makes the
//      moment read as cause → effect rather than as one slab of animation.
//
//   2. LIGHT DECAYS FASTER THAN MASS. `flashTau` is 55 ms; the scale spring takes
//      ~500 ms to settle. The flash is therefore all but gone while the row is
//      still visibly moving, which is the difference between a lit impact and a
//      colour swap that fades.
//
//   3. THE EVENT HAS A SECOND COLOUR. A single teal ramp end to end reads as
//      monolithic. The strike is white, the travelling front is accent teal, and
//      the energy COOLS into `secondary` (gold, or hot pink on a streak) as it
//      leaves. The second beat is entirely in that second hue, so the event has
//      somewhere to go rather than one brightness ramp that stops registering
//      inside a week.
//
//   4. THE SECOND BEAT EXPANDS. At 335 ms the checkbox emits again: a fast
//      outward pulse that re-lights the row and its neighbours in the second hue
//      exactly the way t=0 did, plus an expanding SHELL — a front with a wake
//      behind it that crosses 560 pt in 175 ms and leaves. Its radius only ever
//      grows. Nothing converges, nothing retracts, nothing parks: a front that
//      runs back in to the checkbox reads as the animation retracting.
//
//      The shell is also what makes the second beat loud enough. Perceived motion
//      scales with lit area, not brightness — a thin row cannot match the energy
//      of a full confetti field however bright it is. The shell supplies the area.

import CoreGraphics
import Foundation

/// A colour, as three linear-ish sRGB components. Kept as a plain triple rather
/// than a `Color` so the profile stays `Equatable`, `Sendable` and arithmetic —
/// the draw path mixes these per gradient stop.
public struct FeelTint: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    /// Linear interpolation. `t = 0` is self, `t = 1` is `other`.
    public func mixed(_ other: FeelTint, _ t: Double) -> FeelTint {
        let u = feelClamp(t, 0, 1)
        return FeelTint(r + (other.r - r) * u,
                        g + (other.g - g) * u,
                        b + (other.b - b) * u)
    }
    /// Push toward white by `t`. The only desaturating operation in the file, and
    /// it is deliberately hard to reach: see `hotGain`.
    public func lifted(_ t: Double) -> FeelTint {
        let u = feelClamp(t, 0, 1)
        return FeelTint(r + (1 - r) * u, g + (1 - g) * u, b + (1 - b) * u)
    }

    /// Rec.709 relative luminance.
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Blend toward `other` THROUGH THE HUE CIRCLE, not through RGB.
    ///
    /// Straight RGB interpolation between the accent teal and gold passes through
    /// a desaturated olive — and then the draw path, which is additive, stacks that
    /// olive with the teal underneath it and the result goes white instead of
    /// resolving back into hue.
    ///
    /// Rotating the hue instead keeps saturation up the whole way across: teal ->
    /// lime -> gold, every step of which is a real colour and every step of which
    /// is already in `BangerPalette`.
    public func hueMixed(_ other: FeelTint, _ t: Double) -> FeelTint {
        let u = feelClamp(t, 0, 1)
        if u <= 0 { return self }
        if u >= 1 { return other }
        let a = FeelHSV(self), b = FeelHSV(other)
        var dh = b.h - a.h
        if dh > 180 { dh -= 360 }
        if dh < -180 { dh += 360 }
        return FeelHSV(h: a.h + dh * u,
                       s: a.s + (b.s - a.s) * u,
                       v: a.v + (b.v - a.v) * u).rgb
    }

    /// The same hue, dimmed so it carries no more luminance than `other`.
    ///
    /// THIS IS NOT COSMETIC. Gold at full is 16 % brighter than the accent teal, and
    /// because the draw path is additive its red channel stacks from 0.05 to 1.00.
    /// Unmatched, the hue gets BRIGHTER underneath the flash as it decays and partly
    /// cancels the decay, softening the steep rise/decay asymmetry the impact depends
    /// on. Matching luminance makes the cooling a pure hue change, visible in colour
    /// and invisible in the envelope.
    ///
    /// Only ever dims, never brightens: a secondary darker than the primary (hot pink
    /// is) is left alone rather than pushed until its channels clip.
    public func lumaMatched(to other: FeelTint) -> FeelTint {
        let mine = luma
        guard mine > 1e-6 else { return self }
        let k = min(1, other.luma / mine)
        return FeelTint(r * k, g * k, b * k)
    }
}

/// Minimal HSV, for `FeelTint.hueMixed` only.
struct FeelHSV {
    var h: Double   // degrees
    var s: Double
    var v: Double

    init(h: Double, s: Double, v: Double) { self.h = h; self.s = s; self.v = v }

    init(_ t: FeelTint) {
        let mx = max(t.r, max(t.g, t.b))
        let mn = min(t.r, min(t.g, t.b))
        let d = mx - mn
        v = mx
        s = mx > 1e-9 ? d / mx : 0
        if d < 1e-9 { h = 0 }
        else if mx == t.r { h = 60 * (((t.g - t.b) / d).truncatingRemainder(dividingBy: 6)) }
        else if mx == t.g { h = 60 * (((t.b - t.r) / d) + 2) }
        else { h = 60 * (((t.r - t.g) / d) + 4) }
        if h < 0 { h += 360 }
    }

    var rgb: FeelTint {
        let hh = h.truncatingRemainder(dividingBy: 360) < 0
            ? h.truncatingRemainder(dividingBy: 360) + 360
            : h.truncatingRemainder(dividingBy: 360)
        let c = v * s
        let x = c * (1 - abs((hh / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hh / 60) {
        case 0:  (r1, g1, b1) = (c, x, 0)
        case 1:  (r1, g1, b1) = (x, c, 0)
        case 2:  (r1, g1, b1) = (0, c, x)
        case 3:  (r1, g1, b1) = (0, x, c)
        case 4:  (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return FeelTint(r1 + m, g1 + m, b1 + m)
    }
}

public struct FeelProfile: Equatable, Sendable {

    // MARK: Mass

    /// Peak scale of the row, minus one. 0.076 at finalTask.
    public var rowOvershoot: Double
    /// Seconds from the strike to that peak. Must stay inside 0.060…0.090.
    public var rowPeakTime: Double
    /// Damping ratio for the row. Lower = more visible bounce on the settle.
    public var rowDamping: Double

    /// The checkbox pops harder and earlier than the row — less mass, struck
    /// directly.
    public var boxOvershoot: Double
    public var boxPeakTime: Double
    public var boxDamping: Double

    /// How much of the spring's velocity turns into squash and stretch. Small:
    /// this is a card on a desktop, not jelly.
    public var anisotropy: Double

    // MARK: Light

    /// Decay constant of the accent flash, seconds.
    public var flashTau: Double
    /// Decay constant of the white specular at the point of contact. Deliberately
    /// a third of `flashTau` so the hot core is gone within two frames.
    public var specularTau: Double
    /// The box holds its light a little longer than the row: it is the anchor.
    public var boxTau: Double
    /// How brightly the row glows simply because it is still ringing. Kept low on
    /// purpose: a louder ring-down smears light across the 200–300 ms window, which
    /// has to be EMPTY for the second beat to land as a gift. The gap is the gift.
    public var ringingGain: Double
    /// The bounce-compression glow. Same reasoning: kept, but small enough that
    /// it colours the settle rather than filling the gap.
    public var reboundGain: Double
    /// Peak opacity of the accent fill at the strike point.
    public var flashAmplitude: Double
    /// How much white the travelling front carries at its hottest, and how tightly
    /// that white is confined to the front. 0.40 at an exponent of 5 puts the
    /// white where the energy actually is — a few tens of points around the
    /// contact — and leaves the rest of the row chromatic instead of whitening
    /// the whole row body.
    public var hotGain: Double
    public var hotExponent: Double

    /// Peak opacity and radius of the light the strike throws onto everything
    /// around it. Small on purpose: a real light source spills, but a full-screen
    /// flash is too much.
    ///
    /// The radius is FIXED. An animated radius makes a concentric ring too faint
    /// to see. The burst's own `ShockwaveLayer` owns the propagating ring; this is
    /// a light source, not a second shockwave, and it can be brighter and shorter
    /// for leaving the ring to that layer.
    public var spillAmplitude: Double
    public var spillRadius: Double
    /// The spill's own decay constant, DELIBERATELY SHORTER than `flashTau`.
    ///
    /// A spill that decays on the flash's clock is a lamp switching off, and it
    /// softens the steepness of the impact's decay once it is bright enough to see.
    /// 38 ms keeps both the steepness and the brightness: it is a flash-bulb, not
    /// a lamp.
    public var spillTau: Double

    // MARK: Colour

    /// The lead hue: BangerPalette.accent, teal.
    public var primary: FeelTint
    /// The off-hue the energy cools into, and the body colour of the second beat.
    /// Gold for every tier but `streak`, which gets hot pink — so the biggest thing
    /// the product does is also the only place that colour appears.
    public var secondary: FeelTint
    /// The third hue, carried ONLY by the leading edge of the second beat's shell.
    ///
    /// Periwinkle `#738CFF`, or gold on `streak` where `secondary` has taken the
    /// pink. A hue that only ever appears on a few hundred confetti cards cannot
    /// register; a hue that appears on the leading edge of the biggest lit area in
    /// the celebration can. Confined to the front, it stays a small enough share
    /// that it does not read as a fourth hue FAMILY on a non-streak tier.
    public var tertiary: FeelTint
    /// How far toward `secondary` the light has cooled by the time the primary
    /// flash is spent. 0 = a single teal ramp.
    public var coolGain: Double
    /// Seconds over which that cooling happens.
    public var coolTau: Double

    // MARK: The second beat

    /// When the checkbox emits for the second time, seconds. 335 ms puts the light
    /// 65 ms AHEAD of the burst's own converging ring at 400 ms. Light first, mass
    /// second — the same order the opening uses.
    public var secondBeatAt: Double
    /// Seconds of approach before the emission. Short, and a quarter of the decay,
    /// so the beat keeps the rise-faster-than-fall asymmetry the strike has. A
    /// symmetric in-and-out here would turn the second beat back into a transition.
    public var secondBeatRise: Double
    /// Decay constant after the emission.
    public var secondBeatTau: Double
    /// Peak brightness of the row/box re-light, as a fraction of the primary strike.
    public var secondBeatGain: Double
    /// How fast the second emission travels along the row, points per second.
    /// Faster than the strike's 2400: the medium is already excited.
    public var secondBeatSpeed: Double
    /// `streak` only: a third emission, in the third hue.
    public var thirdBeatAt: Double?
    public var thirdBeatGain: Double

    // MARK: The shell — the thing that makes the second beat a beat

    /// Peak additive opacity at the front of the expanding shell.
    ///
    /// This is the single number that decides whether the second beat reads as a
    /// gift or as debris, because motion energy is mean |ΔY| over the WHOLE frame
    /// and therefore scales with lit AREA, not with brightness. A 34 pt-tall row
    /// cannot carry much energy even at full white. The shell is ~250 000 pt² of
    /// moving light, which carries real energy at an opacity that is nowhere near
    /// a white-out.
    public var shellGain: Double
    /// Radius of the front at the moment of emission, points. Starts ON the
    /// checkbox, so the beat visibly comes FROM the thing that was clicked.
    public var shellStartRadius: Double
    /// Radius at which the front has spent itself.
    public var shellEndRadius: Double
    /// Seconds from emission to `shellEndRadius`.
    public var shellExpand: Double
    /// The wake behind the front at emission, points, and how much wider that wake
    /// gets per point of radius. A real front spreads as it travels, which is also
    /// what fades it out: by the end the same energy is smeared over four times the
    /// depth, so it leaves by THINNING rather than by being switched off.
    public var shellTail: Double
    public var shellTailGrow: Double
    /// How far the front reaches AHEAD of its nominal radius, as a fraction of the
    /// wake. Small: the leading edge is crisp and the wake is long, which is what
    /// makes the direction of travel unmistakable on a still frame.
    public var shellLead: Double
    /// Radius, in points, over which the front fades UP from nothing as it leaves
    /// the checkbox. Without it the shell's brightest moment is a 24 pt disc
    /// sitting on the box, which reads as a white blob rather than an emission.
    public var shellFormRadius: Double

    // MARK: Geometry, in points

    /// Distance from the checkbox centre to the row's leading edge.
    public var rowLead: Double
    public var rowWidth: Double
    public var rowHeight: Double
    public var rowCorner: Double
    public var boxSize: Double
    public var boxCorner: Double
    /// How fast the pulse of light travels outward from the checkbox, points per
    /// second. 2400 pt/s crosses a 300 pt row in 125 ms — slow enough to see, fast
    /// enough that the far end is lit before the scale peaks.
    public var wavefrontSpeed: Double
    /// Distance, in points, over which the pulse loses half its brightness to
    /// spreading. Energy that covers more area covers it more thinly.
    public var falloffDistance: Double
    /// Vertical offsets of the neighbouring rows in the list, and how much of the
    /// pulse reaches them. They are not struck, they never move and they are never
    /// swept: each one switches on WHOLE when the front reaches its distance, and
    /// decays on its own clock. See `ImpactFlashLayer.drawNeighbours` for why.
    public var neighbourOffsets: [Double]
    public var neighbourGains: [Double]

    // MARK: Accessibility

    /// Reduce Motion: no scale, no travel, no specular. The accent lift survives,
    /// because an acknowledgement that does nothing is worse than none.
    public var reduceMotion: Bool

    /// The far corner of the struck row, measured from the checkbox. The inbound
    /// second beat starts here.
    public var rowSpan: Double { rowWidth - rowLead }

    public init(config: CelebrationConfig, reduceMotion: Bool = false) {
        let i = feelClamp(config.intensity, 0, 1)

        // A bigger event punches further and gets there sooner. Both ends of the
        // range stay inside the 60–90 ms window that reads as a strike.
        rowOvershoot = 0.030 + 0.058 * i
        rowPeakTime  = 0.086 - 0.020 * i
        rowDamping   = 0.52 - 0.10 * i

        boxOvershoot = rowOvershoot * 1.95
        boxPeakTime  = rowPeakTime * 0.58
        boxDamping   = 0.50 - 0.06 * i

        anisotropy   = 0.085 + 0.035 * i

        flashTau     = 0.055
        specularTau  = 0.018
        boxTau       = 0.090
        reboundGain  = 0.20 + 0.06 * i
        ringingGain  = 0.055 + 0.020 * i
        flashAmplitude = 0.60 + 0.26 * i
        hotGain      = 0.40
        hotExponent  = 5.0
        spillAmplitude = 0.17 + 0.07 * i
        spillRadius    = 235
        spillTau       = 0.038

        primary   = FeelTint(0.05, 0.85, 0.75)   // #0DD9BF, the accent
        secondary = FeelTint(1.00, 0.78, 0.12)    // #FFC71F, gold
        tertiary  = FeelTint(0.45, 0.55, 1.00)    // #738CFF, periwinkle
        coolGain  = 0.92
        coolTau   = 0.085

        secondBeatAt     = 0.335
        secondBeatRise   = 0.036
        secondBeatTau    = 0.090
        secondBeatGain   = 0.46 + 0.16 * i
        secondBeatSpeed  = 3400
        thirdBeatAt      = nil
        thirdBeatGain    = 0

        shellGain        = 0.80 + 0.52 * i
        shellStartRadius = 24
        shellEndRadius   = 560
        shellExpand      = 0.175
        shellTail        = 86
        shellTailGrow    = 0.34
        shellLead        = 0.17
        shellFormRadius  = 104

        rowLead    = 26
        rowWidth   = 296
        rowHeight  = 34
        rowCorner  = 9
        boxSize    = 21
        boxCorner  = 6.5
        wavefrontSpeed = 2400
        falloffDistance = 290
        neighbourOffsets = [-92, -46, 46, 92]
        neighbourGains   = [0.10, 0.27, 0.27, 0.10]

        // The last task of the day gets a wider row of light, a longer hold on the
        // box and a louder re-arrival, so the shape and the COLOUR of the hit —
        // not a badge, not a number — say which tier it was.
        switch config.tier {
        case .standard:
            // One beat. The shell never launches, so the tier is legible from the
            // SHAPE of the event.
            secondBeatGain = 0
            shellGain = 0
        case .building:
            rowWidth += 8
            shellGain *= 0.72
            shellEndRadius = 430
        case .finalTask:
            rowWidth += 16; boxTau += 0.02
        case .streak:
            rowWidth += 24; boxTau += 0.04
            secondary = FeelTint(1.00, 0.30, 0.42)   // #FF4D6B, hot pink
            tertiary  = FeelTint(1.00, 0.78, 0.12)   // #FFC71F, gold on the front
            secondBeatGain *= 1.10
            shellGain *= 1.10
            shellEndRadius = 660
            // The third emission is the only place in the product where three
            // hues appear in one celebration.
            thirdBeatAt   = 0.800
            thirdBeatGain = 0.34
        }

        // Whatever the tier chose, the off-hues carry the primary's luminance and
        // not a photon more. See FeelTint.lumaMatched.
        secondary = secondary.lumaMatched(to: primary)
        tertiary  = tertiary.lumaMatched(to: primary)

        self.reduceMotion = reduceMotion
        if reduceMotion {
            rowOvershoot = 0
            boxOvershoot = 0
            anisotropy = 0
            wavefrontSpeed = 1e9         // effectively instantaneous: no travel
            neighbourGains = [0.06, 0.16, 0.16, 0.06]
            ringingGain = 0
            reboundGain = 0
            flashTau = 0.16
            boxTau = 0.20
            specularTau = 0.001
            spillAmplitude *= 0.6
            spillTau = 0.14
            // The second beat survives as a brightness and hue change — an
            // acknowledgement that does nothing is worse than none — but it does
            // not travel and there is no shell, because a 560 pt front crossing
            // the screen is precisely the thing reduce-motion exists to suppress.
            secondBeatSpeed = 1e9
            secondBeatRise = 0.004
            secondBeatTau = 0.095
            // Scaled hard. With no travel the whole list lights at once, so the same
            // gain that reads as a re-emission when it sweeps reads as a SECOND,
            // BIGGER flash when it does not, which inverts the one ordering the
            // effect is built on.
            secondBeatGain *= 0.42
            shellGain = 0
            thirdBeatAt = nil
            hotGain = 0.18
        }
    }
}
