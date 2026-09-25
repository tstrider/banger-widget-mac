//  ShockwaveLayer.swift — the thing that makes it read as ONE STRUCK EVENT.
//
//  Without this, a particle burst reads as a spray turning on: the field simply becomes
//  denser over the first few frames and there is no instant you can point at. A ring that
//  leaves the origin faster than any particle, and is gone before 140 ms, supplies that
//  instant. It is also most of the reason the energy of the effect peaks at ~110 ms
//  rather than late.
//
//  Deliberately small and deliberately brief. No full-screen flash: that is what cheap
//  celebration code does instead of choreography.

import CoreGraphics
import Foundation
import SwiftUI

public struct ShockwaveLayer: CelebrationLayer {

    private struct Ring {
        var start: Double
        var duration: Double
        var r0: Double
        var r1: Double
        var w0: Double
        var w1: Double
        var colorIndex: Int
        var peakAlpha: Double
        /// Higher = the ring holds its brightness longer before it lets go.
        var hold: Double
        var expo: Double
        /// Brightness of the thin outer rim, 0 = none. A crisp rim on a faint, wide,
        /// slow front is what turns a shock into a sonar ping; only the leading ring
        /// gets one.
        var rim: Double = 0.45
    }

    /// A soft pressure front. Very low alpha, very wide: it is felt rather than seen, and
    /// it is what stops the first frames looking like a hole with confetti around it.
    private struct Bloom {
        var start: Double
        var duration: Double
        var r1: Double
        var peakAlpha: Double
        var colorIndex: Int
        /// How fast the bloom reaches its full radius. HIGH = snaps out and then holds.
        var rExpo: Double = 1.8
        /// Fraction of the life spent at full brightness before the decay starts.
        var hold: Double = 0.12
    }

    private let origin: CGPoint
    private let rings: [Ring]
    private let blooms: [Bloom]
    private let endsAt: Double
    private var elapsed: Double = 0

    public init(config: CelebrationConfig) {
        let profile = BurstProfile(config: config)
        self.init(profile: profile)
    }

    public init(profile: BurstProfile) {
        origin = profile.origin
        let reach = profile.reach
        let energy = 0.70 + 0.30 * profile.intensity

        var rings: [Ring] = []
        var blooms: [Bloom] = []

        // Beat 1. Two rings 28 ms apart: one wide and fast, one tight and white just
        // behind it. Two edges read as an impact; one edge reads as a circle animating.
        // Short. Three concentric circles still legible at 170 ms read as a sonar ping,
        // which is the single most preset-looking thing a burst can do. These are gone
        // before the eye can count them: what is left is the impression that the paper
        // was pushed out by something, not that it was switched on.
        // The expo is what decides how much of the ring is already out at 17 ms — one
        // frame. That single frame decides whether it answers the click, so the front
        // is deliberately most of the way out before the second frame is drawn.
        rings.append(Ring(start: 0, duration: 0.090, r0: 11, r1: reach * 1.06,
                          w0: 16 * energy, w1: 2.2, colorIndex: 0,
                          peakAlpha: 0.70 * energy, hold: 0.20, expo: 3.6, rim: 0.14))
        // Gold, not white: a white ring with a white rim blows out the opening frames.
        // Gold is still the brightest thing in the opening, still a second distinct
        // edge, and it carries hue instead of bleaching the middle.
        rings.append(Ring(start: 0.018, duration: 0.070, r0: 6, r1: reach * 0.70,
                          w0: 10 * energy, w1: 1.4, colorIndex: 1,
                          peakAlpha: 0.66 * energy, hold: 0.12, expo: 3.0, rim: 0.12))
        // A third, much wider and much dimmer front, running slower than the other two.
        // It is the reason the first impression keeps growing until ~110 ms instead of
        // being over in three frames, and it is too faint to read as a flash.
        rings.append(Ring(start: 0.010, duration: 0.128, r0: 24, r1: reach * 1.46,
                          w0: 26 * energy, w1: 4.0, colorIndex: 3,
                          peakAlpha: 0.19 * energy, hold: 0.28, expo: 3.0, rim: 0.0))
        // Pressure bloom. Kept narrower than the rings it sits under, on purpose: a
        // bloom wide enough to cover most of the frame stops being light coming off an
        // event and starts being a tint over the desktop.
        blooms.append(Bloom(start: 0, duration: 0.19, r1: reach * 0.98,
                            peakAlpha: 0.16 * energy, colorIndex: 0,
                            rExpo: 3.6, hold: 0.05))
        // MUZZLE GLOW. Small and tight, centred on the checkbox the burst came out of,
        // still lit for half a second after the cards have left it. It is what makes the
        // origin read as a place something happened rather than as the corner the spray
        // happens to start in.
        //
        // Deliberately narrow. A wide teal wash over most of the frame looks like fog,
        // and lifts the whole frame's brightness enough that the burst stops reading as
        // sharp objects against black.
        blooms.append(Bloom(start: 0.004, duration: 0.62, r1: reach * 0.62,
                            peakAlpha: 0.15 * energy, colorIndex: 0,
                            rExpo: 5.0, hold: 0.14))

        // BEAT 2. A SMALLER, GOLD, SLOWER FRONT.
        //
        // The ring is what tells the eye a second EVENT happened rather than that
        // more confetti arrived, and it has to be recognisably the same grammar at a
        // smaller size — otherwise the second beat is a different effect switched on.
        // It is gold rather than teal both to keep the lead hue from dominating and
        // because a colour change is the cheapest way to say "this is the second
        // one" without adding a shape.
        if profile.beatCount >= 2 {
            rings.append(Ring(start: profile.beat2At, duration: 0.094,
                              r0: 5, r1: reach * 0.62,
                              w0: 11 * energy, w1: 1.3, colorIndex: 1,
                              peakAlpha: 0.70 * energy, hold: 0.15, expo: 2.4, rim: 0.14))
            blooms.append(Bloom(start: profile.beat2At, duration: 0.20, r1: reach * 0.70,
                                peakAlpha: 0.14 * energy, colorIndex: 1,
                                rExpo: 3.2, hold: 0.08))
        }

        // Beat 3, streak only.
        if profile.beatCount >= 3 {
            rings.append(Ring(start: profile.beat3At, duration: 0.125,
                              r0: 6, r1: reach * 0.60,
                              w0: 8 * energy, w1: 1.1, colorIndex: 1,
                              peakAlpha: 0.62 * energy, hold: 0.12, expo: 2.6, rim: 0.20))
        }

        self.rings = rings
        self.blooms = blooms
        endsAt = max(rings.map { $0.start + $0.duration }.max() ?? 0,
                     blooms.map { $0.start + $0.duration }.max() ?? 0)
    }

    public mutating func step(dt: Double) { elapsed += dt }

    public var isFinished: Bool { elapsed >= endsAt }

    public func draw(in context: inout GraphicsContext, size: CGSize) {
        guard elapsed < endsAt else { return }

        var layer = context
        layer.blendMode = .plusLighter

        for bloom in blooms {
            let u = (elapsed - bloom.start) / bloom.duration
            guard u >= 0, u < 1 else { continue }
            let r = max(1, BurstEase.outPow(u, bloom.rExpo) * bloom.r1)
            // Rises over the first eighth, then lets go. A bloom that fades linearly
            // reads as a dissolve; this reads as pressure passing.
            let a = bloom.peakAlpha
                * (u < bloom.hold ? u / bloom.hold
                                  : pow(1 - (u - bloom.hold) / (1 - bloom.hold), 2.0))
            guard a > 0.004 else { continue }

            let rect = CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2)
            let shading = GraphicsContext.Shading.radialGradient(
                Gradient(stops: [
                    .init(color: BurstPalette.color(bloom.colorIndex).opacity(a * 0.35), location: 0.0),
                    .init(color: BurstPalette.color(bloom.colorIndex).opacity(a), location: 0.72),
                    .init(color: BurstPalette.color(bloom.colorIndex).opacity(0), location: 1.0),
                ]),
                center: CGPoint(x: origin.x, y: origin.y),
                startRadius: 0, endRadius: r)
            layer.fill(Path(ellipseIn: rect), with: shading)
        }

        for ring in rings {
            let u = (elapsed - ring.start) / ring.duration
            guard u >= 0, u < 1 else { continue }
            let r = ring.r0 + BurstEase.outPow(u, ring.expo) * (ring.r1 - ring.r0)
            let w = max(0.6, ring.w0 + (ring.w1 - ring.w0) * BurstEase.outPow(u, 1.6))
            let a: Double
            if u < ring.hold {
                a = ring.peakAlpha
            } else {
                let k = (u - ring.hold) / (1 - ring.hold)
                a = ring.peakAlpha * pow(1 - k, 1.9)
            }
            guard a > 0.004 else { continue }

            let rect = CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2)
            // The leading edge of a real shock is brighter than the trailing edge, so the
            // ring is stroked twice: a wide soft body and a thin bright rim just outside it.
            layer.stroke(Path(ellipseIn: rect),
                         with: .color(BurstPalette.color(ring.colorIndex).opacity(a * 0.55)),
                         lineWidth: w)
            guard ring.rim > 0 else { continue }
            let rimRect = rect.insetBy(dx: -w * 0.30, dy: -w * 0.30)
            layer.stroke(Path(ellipseIn: rimRect),
                         with: .color(BurstPalette.color(5).opacity(a * ring.rim)),
                         lineWidth: max(0.5, w * 0.24))
        }
    }
}
