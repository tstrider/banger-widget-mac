//  SparkLayer.swift — the leading edge.
//
//  A burst needs something that OUTRUNS the rest of it. Sparks leave at two to three
//  times the speed of the paper, brake hard, and are gone before 500 ms. For the first
//  six frames they are the whole silhouette: the eye sees the shape of the explosion
//  before it can resolve a single card. Then they disappear and the paper takes over.
//
//  They also carry the short motion trail. A trail on everything looks like a filter;
//  a trail only on the fastest 15 % looks like speed.

import CoreGraphics
import Foundation
import SwiftUI

public struct SparkLayer: CelebrationLayer {

    private struct Spark {
        var position: CGPoint
        var velocity: CGVector
        var drag: Double
        var age: Double
        var lifetime: Double
        var delay: Double
        var length: Double      // head size, points
        var width: Double
        var colorIndex: Int
        var launched: Bool
    }

    private var sparks: [Spark]
    private var elapsed: Double = 0
    private let gravity: Double
    private let hardStop: Double

    public init(config: CelebrationConfig) {
        self.init(profile: BurstProfile(config: config))
    }

    public init(profile: BurstProfile) {
        gravity = profile.gravity * 0.34   // sparks are light; they stop before they fall
        var rng = SeededRandom(seed: profile.seed &* 0x2545F491 &+ 0x9E37)

        let fan1 = ClumpFan(axis: profile.axis, spread: profile.spread * 1.06,
                            lobes: 5, looseFraction: 0.30, rng: &rng)
        let fan2 = ClumpFan(axis: profile.axisBeat2, spread: profile.spreadBeat2 * 1.25,
                            lobes: 2, looseFraction: 0.26, rng: &rng)

        let total = profile.sparkCount
        var out: [Spark] = []
        out.reserveCapacity(total)

        for i in 0..<total {
            // Beat assignment. Sparks are what makes a beat read as an event, so the
            // second beat gets a slightly larger share of them than the paper does.
            let roll = rng.unit()
            let beat2 = profile.beatCount >= 2 && roll < profile.beat2Share * 1.30
            let beat3 = !beat2 && profile.beatCount >= 3
                && roll > 1 - profile.beat3Share * 1.30

            let base: Double
            let scale: Double
            let sample: (angle: Double, speed: Double)
            if beat3 {
                base = profile.beat3At; scale = 0.62
                sample = fan2.sample(&rng)
            } else if beat2 {
                base = profile.beat2At; scale = 0.74
                sample = fan2.sample(&rng)
            } else {
                base = 0; scale = 1.0
                sample = fan1.sample(&rng)
            }

            // The very first sparks leave together — that is the struck-event read. The
            // stagger is tiny and heavily biased to zero.
            let jitter = rng.unit() * rng.unit() * rng.unit() * 0.030
            let speedT = rng.unit()
            // A MODERATE MUZZLE SPEED.
            //
            // Too fast and the trail length saturates its cap on most of the
            // population, and a few hundred long streaks all pointing away from one
            // point is a radial speed-line preset. Moderate speed, large heads and no
            // white core turn the leading edge into a shell of coloured chips that
            // outruns the paper.
            let speed = (1400 + 1500 * speedT * speedT) * sample.speed
                * profile.speedScale * scale

            let scatterA = rng.range(0, 2 * .pi)
            // A WIDE MUZZLE. From a single point every spark in the shell is stacked on
            // every other one for the first two frames, and a few hundred coloured
            // chips added together under `.plusLighter` sum to WHITE, which blows out
            // the core. Spreading the launch over 26 pt keeps the same shell and lets
            // it keep its colour.
            let scatterR = 26.0 * sqrt(rng.unit())
            let w = rng.range(2.4, 4.3) * profile.sparkScale
            // Fine sparks bleed speed fastest; that spread is what gives the leading edge
            // a soft ragged front instead of a clean expanding circle.
            let drag = rng.range(0.905, 0.948)

            out.append(Spark(
                position: CGPoint(x: profile.origin.x + scatterR * cos(scatterA),
                                  y: profile.origin.y + scatterR * sin(scatterA)),
                velocity: CGVector(dx: cos(sample.angle) * speed, dy: sin(sample.angle) * speed),
                drag: drag,
                age: 0,
                // Short and nearly uniform. The leading edge has to be AT FULL COUNT
                // while the eye is still on the click and GONE before the paper has
                // finished spreading — that is what puts the peak of the whole effect
                // at ~110 ms instead of wherever the confetti happens to be widest.
                lifetime: rng.range(0.085, 0.215) * (0.88 + 0.24 * profile.intensity),
                delay: base + jitter,
                length: rng.range(5.0, 9.0) * profile.sparkScale,
                width: w,
                colorIndex: BurstPalette.pick(BurstPalette.sparkWeights, &rng),
                launched: false
            ))
            _ = i
        }

        sparks = out
        hardStop = profile.hardStop
    }

    public mutating func step(dt: Double) {
        elapsed += dt
        guard !sparks.isEmpty else { return }
        let g = gravity * dt
        var anyAlive = false

        for i in sparks.indices {
            var s = sparks[i]
            if !s.launched {
                if elapsed < s.delay { anyAlive = true; sparks[i] = s; continue }
                s.launched = true
            }
            guard s.age < s.lifetime else { sparks[i] = s; continue }
            anyAlive = true

            s.age += dt
            let steps = dt * 60.0
            let k = pow(s.drag, steps)
            s.velocity.dx *= k
            s.velocity.dy *= k
            s.velocity.dy += g
            s.position.x += s.velocity.dx * dt
            s.position.y += s.velocity.dy * dt
            sparks[i] = s
        }

        if !anyAlive { sparks.removeAll(keepingCapacity: false) }
    }

    public var isFinished: Bool { sparks.isEmpty || elapsed >= hardStop }

    public func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !sparks.isEmpty else { return }
        let bounds = CGRect(x: -60, y: -60, width: size.width + 120, height: size.height + 120)

        var layer = context
        layer.blendMode = .plusLighter

        for s in sparks {
            guard s.launched, s.age < s.lifetime else { continue }
            guard bounds.contains(s.position) else { continue }

            let t = s.age / s.lifetime
            // Bright and flat for the first third, then a fast clean drop. Sparks that
            // fade slowly turn into a haze and cost the burst its edges.
            let alpha = t < 0.58 ? 1.0 : pow(1 - (t - 0.58) / 0.42, 1.6)
            guard alpha > 0.01 else { continue }

            let speed = sqrt(s.velocity.dx * s.velocity.dx + s.velocity.dy * s.velocity.dy)
            let color = BurstPalette.color(s.colorIndex)

            // Trail: a tapered wedge back along the velocity, only while the spark is
            // actually moving fast enough to earn one.
            if speed > 620 {
                // Short. A trail is a hint of travel, not a ray: the cap is low and
                // the speed gate high, so only the leading fraction of the shell
                // carries one at all.
                let len = min(17.0, speed * 0.0072)
                let ux = s.velocity.dx / speed
                let uy = s.velocity.dy / speed
                let px = -uy, py = ux
                let hw = s.width * 0.5
                let tail = CGPoint(x: s.position.x - ux * len, y: s.position.y - uy * len)
                var path = Path()
                path.move(to: CGPoint(x: s.position.x + px * hw, y: s.position.y + py * hw))
                path.addLine(to: CGPoint(x: s.position.x - px * hw, y: s.position.y - py * hw))
                path.addLine(to: tail)
                path.closeSubpath()
                let trailAlpha = alpha * 0.30 * min(1, (speed - 620) / 900)
                layer.fill(path, with: .linearGradient(
                    Gradient(colors: [color.opacity(trailAlpha), color.opacity(0)]),
                    startPoint: s.position, endPoint: tail))
            }

            // Head: a small capsule aligned to travel, so even the dot has direction.
            let hl = max(s.width, min(s.length, s.length * 0.35 + speed * 0.006))
            let angle = atan2(s.velocity.dy, s.velocity.dx)
            var head = layer
            head.opacity = alpha
            head.translateBy(x: s.position.x, y: s.position.y)
            head.rotate(by: .radians(angle))
            let rect = CGRect(x: -hl / 2, y: -s.width / 2, width: hl, height: s.width)
            head.fill(Path(roundedRect: rect, cornerSize: CGSize(width: s.width / 2,
                                                                 height: s.width / 2)),
                      with: .color(color))
            // NO WHITE CORE. A white core makes the leading edge read as
            // light-from-a-preset rather than as coloured material. Instead the
            // spark's OWN hue is
            // laid over itself once more under `.plusLighter`, which saturates it
            // toward its own bright end instead of toward white — so the shell keeps
            // its colour identity all the way through the apex.
            if speed > 1000 {
                head.fill(Path(roundedRect: rect.insetBy(dx: hl * 0.20, dy: s.width * 0.24),
                               cornerSize: CGSize(width: s.width / 3, height: s.width / 3)),
                          with: .color(color.opacity(0.62)))
            }
        }
    }
}
