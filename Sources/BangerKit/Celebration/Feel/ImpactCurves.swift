//  ImpactCurves.swift — the two curves the whole "feel" layer is built out of.
//
//  There are exactly two, and the difference between them is the entire idea:
//
//    StruckSpring   MASS. Struck once at t=0 with an impulse, then left alone.
//                   Starts at rest, rises to an overshoot in 60–90 ms, crosses
//                   back through rest, undershoots, and settles. Asymmetric by
//                   construction: the rise is one quarter-cycle, the settle is
//                   an exponential envelope four times longer. A symmetric
//                   ease-in-out is a transition; this is a hit.
//
//    strikeDecay    LIGHT. Full on the trigger frame, then exponential decay.
//                   No rise at all, because light has no inertia. This is what
//                   changes on the exact frame of the click.
//
//  Everything visible in ImpactFlashLayer is one of these two evaluated somewhere.
//  Nothing here reads a clock, nothing here calls Double.random, and the spring is
//  integrated at the contract's fixed timestep, so the offscreen render and the
//  live overlay produce identical numbers.

import Foundation

// MARK: - Mass

/// A damped harmonic oscillator that starts at rest and is given one impulse.
///
/// Parameterised the way an animator thinks rather than the way a physicist does:
/// you say *when* the overshoot should peak, *how much* it should overshoot, and
/// *how bouncy* the settle is, and the constructor solves for the stiffness and the
/// impulse that produce exactly that.
///
/// For an impulse response `x(t) = (v0/ωd)·e^(−ζω₀t)·sin(ωd·t)`:
///   * the first peak is at `t = atan(ωd / (ζω₀)) / ωd`
///   * so `ω₀ = atan2(√(1−ζ²), ζ) / (√(1−ζ²) · tPeak)`
///   * and `v0` is chosen so the analytic peak equals `overshoot` exactly.
public struct StruckSpring: Equatable, Sendable {

    /// Displacement from rest. Scale is `1 + displacement`.
    public private(set) var displacement: Double = 0
    /// Rate of change, in units per second. Drives the squash/stretch.
    public private(set) var velocity: Double

    /// Undamped natural frequency, rad/s.
    public let omega: Double
    /// Damping ratio. < 1 is underdamped, which is the only interesting case.
    public let zeta: Double
    /// The impulse the spring was struck with. Used to normalise velocity.
    public let impulse: Double
    /// The analytic first-peak displacement, i.e. the requested overshoot.
    public let overshoot: Double

    /// - Parameters:
    ///   - peakTime: seconds from the strike to maximum displacement. 0.06–0.09
    ///     is the window that reads as an impact rather than a transition.
    ///   - damping: 0…1. 0.40 gives one clear bounce, 0.70 gives almost none.
    ///   - overshoot: peak displacement, e.g. 0.076 for a 7.6 % scale punch.
    public init(peakTime: Double, damping: Double, overshoot: Double) {
        let z = min(max(damping, 0.02), 0.98)
        let r = (1 - z * z).squareRoot()          // ωd / ω₀
        let phase = atan2(r, z)                   // ωd · tPeak
        let w0 = phase / (r * max(peakTime, 1e-4))
        let wd = w0 * r
        let tPeak = phase / wd
        let unitPeak = (1 / wd) * exp(-z * w0 * tPeak) * sin(wd * tPeak)

        self.zeta = z
        self.omega = w0
        self.overshoot = overshoot
        self.impulse = overshoot / max(unitPeak, 1e-9)
        self.velocity = self.impulse
    }

    /// Semi-implicit (symplectic) Euler. At the contract's 240 Hz timestep and
    /// ω₀ ≈ 16 rad/s this tracks the closed form to better than 0.1 %, and unlike
    /// explicit Euler it cannot gain energy.
    public mutating func step(dt: Double) {
        let acceleration = -omega * omega * displacement - 2 * zeta * omega * velocity
        velocity += acceleration * dt
        displacement += velocity * dt
    }

    /// −1…1-ish. Positive while the punch is expanding, negative on the way back.
    /// Squash and stretch reads off this, which is why the stretch is not a
    /// separate timed animation — it is the same motion seen from the side.
    public var normalisedVelocity: Double {
        impulse > 0 ? max(-1, min(1, velocity / impulse)) : 0
    }

    /// How far the body is compressed past rest, 0…1. The rebound glow reads off
    /// this, so the second flash happens because the row bounced, not because a
    /// timer said 180 ms.
    public var compression: Double {
        overshoot > 0 ? max(0, min(1, -displacement / overshoot)) : 0
    }

    /// How hard the row is still ringing, 1 at the strike and 0 at rest.
    ///
    /// This is the phase-space amplitude √(x² + (v/ωd)²) normalised to its value at
    /// the strike, which for a damped oscillator decays monotonically as e^(−ζω₀t).
    /// It is the honest answer to "is this thing still moving", and the row's
    /// residual glow is driven by it rather than by a timer — which is why the glow
    /// reaches exactly zero at exactly the moment the spring stops, with no fade to
    /// schedule and no residue left behind.
    public var ringingAmplitude: Double {
        guard impulse > 0 else { return 0 }
        let wd = omega * (1 - zeta * zeta).squareRoot()
        guard wd > 0 else { return 0 }
        let a = (displacement * displacement + (velocity / wd) * (velocity / wd)).squareRoot()
        return min(1, a / (impulse / wd))
    }

    public var isAtRest: Bool {
        abs(displacement) < 2e-5 && abs(velocity) < 2e-4
    }
}

// MARK: - Light

/// Full brightness on the trigger frame, exponential decay after it.
///
/// `t` may be negative, which is how the wavefront works: a point 120 pt away from
/// the strike gets `t = elapsed − 120/speed`, so it is dark until the energy
/// reaches it. That is the whole mechanism behind the flash sweeping outward from
/// the checkbox instead of the row lighting up as one slab.
@inline(__always)
public func bangerStrikeDecay(_ t: Double, tau: Double) -> Double {
    t < 0 ? 0 : exp(-t / max(tau, 1e-6))
}

/// The second beat's envelope: a short rise to 1 at `t = 0`, then the same
/// exponential decay the strike uses.
///
/// Not a strike, because a re-arrival is not a strike: something travels in, so it
/// is visibly approaching before it lands. `rise` is the approach. But the rise is
/// a quarter of the decay, so the shape is still the asymmetry that reads as an
/// event — a symmetric in-and-out here would turn the whole second beat back into
/// a transition rather than a hit.
///
/// `t` is seconds relative to ARRIVAL: negative while the front is still inbound.
@inline(__always)
public func bangerArrival(_ t: Double, rise: Double, tau: Double) -> Double {
    let r = max(rise, 1e-6)
    if t <= -r { return 0 }
    if t < 0 {
        // Quadratic approach: slow to start, steep at the moment of arrival, so the
        // energy appears to be gathering rather than cross-fading in.
        let u = (t + r) / r
        return u * u
    }
    return exp(-t / max(tau, 1e-6))
}

/// Where an expanding front has got to, 0…1 of its total reach, given 0…1 of its
/// expansion time.
///
/// `1 − (1−u)^p`: fastest at the instant of emission, decelerating the whole way
/// out. That is what a pressure front in a medium does, and it is also the only
/// shape that makes the expansion legible — a linear ramp spends as many frames
/// near the end, where the front is huge and dim, as it does near the start where
/// the direction of travel is actually readable.
@inline(__always)
public func bangerExpansion(_ u: Double, power: Double = 2.3) -> Double {
    let t = feelClamp(u, 0, 1)
    return 1 - pow(1 - t, power)
}

/// A cosine taper to zero over the last `fraction` of `lifetime`.
///
/// Exists for one reason: nothing this layer draws is allowed to be switched off
/// while it is still visible. An expanding shell that hits an
/// `if t > limit { return nil }` would visibly pop out of existence. By the time
/// this taper starts, the shell is already under 1 % opacity; the taper only
/// guarantees it reaches exactly zero.
@inline(__always)
public func bangerTerminalTaper(_ t: Double, lifetime: Double, fraction: Double = 0.26) -> Double {
    guard lifetime > 0 else { return 0 }
    let start = lifetime * (1 - feelClamp(fraction, 0.01, 1))
    if t <= start { return 1 }
    if t >= lifetime { return 0 }
    let u = (t - start) / (lifetime - start)
    return 0.5 + 0.5 * cos(.pi * u)
}

@inline(__always)
func feelClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}
