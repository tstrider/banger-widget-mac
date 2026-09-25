//  RibbonLayer.swift — the heavy tail.
//
//  Long streamers, launched slower than everything else and much heavier. They are still
//  in the air when the paper has gone, and they leave by falling out of the bottom of the
//  frame rather than by fading.
//
//  There is no kill line. A streamer is at full opacity until it is off the bottom of the
//  screen. Its fall is slower than the paper's, so it is plainly the slowest thing on
//  screen and the last to go, but fast enough to clear a full-height display before the
//  celebration's window closes. Alpha is a function of NOTHING: not height, not age. A
//  streamer leaves by leaving.

import CoreGraphics
import Foundation
import SwiftUI

public struct RibbonLayer: CelebrationLayer {

    private struct Ribbon {
        var p: Particle
        var phase: Double
        var rate: Double
        var delay: Double
        var launched: Bool
        var curl: Double
        var termV: Double
    }

    private var ribbons: [Ribbon]
    private var elapsed: Double = 0
    private let gravity: Double
    private let hardStop: Double
    private let origin: CGPoint
    /// Memory bound, not a kill line — see `BurstProfile.fallExit`.
    private let forgetDepth: Double

    public init(config: CelebrationConfig) {
        self.init(profile: BurstProfile(config: config))
    }

    public init(profile: BurstProfile) {
        // A streamer is mostly air, so it settles to a much slower terminal speed than a
        // card — but it does settle to one, and then it KEEPS COMING DOWN at it. That is
        // the difference between a tail and a clump left hanging in the frame.
        gravity = profile.gravity * 0.62
        hardStop = profile.hardStop
        origin = profile.origin
        forgetDepth = profile.fallExit

        var rng = SeededRandom(seed: profile.seed &+ 0x2B_99_2D_DF_A2_32)
        let fan = ClumpFan(axis: profile.axis, spread: profile.spread * 0.82,
                           lobes: 4, looseFraction: 0.40, rng: &rng)

        var out: [Ribbon] = []
        out.reserveCapacity(profile.ribbonCount)

        for _ in 0..<profile.ribbonCount {
            let beat2 = profile.beatCount >= 2 && rng.unit() < profile.beat2Share * 0.7
            let base = beat2 ? profile.beat2At : 0
            let scale = beat2 ? 0.80 : 1.0

            let sample = fan.sample(&rng)
            let speed = rng.range(180, 430) * sample.speed * profile.speedScale * scale
            let up = pow(max(0, -sin(sample.angle)), 0.5)
            let vy = -rng.range(250, 430) * profile.speedScale * scale * (0.42 + 0.58 * up)

            let w = rng.range(5.0, 7.6) * profile.ribbonScale
            let len = w * rng.range(4.0, 6.6)

            out.append(Ribbon(
                p: Particle(
                    position: CGPoint(x: profile.origin.x + rng.range(-9, 9),
                                      y: profile.origin.y + rng.range(-9, 9)),
                    velocity: CGVector(dx: cos(sample.angle) * speed, dy: vy),
                    rotation: rng.range(0, 2 * .pi),
                    angularVelocity: rng.range(-3.4, 3.4),
                    size: CGSize(width: w, height: len),
                    colorIndex: BurstPalette.pick(BurstPalette.ribbonWeights, &rng),
                    shape: .ribbon,
                    age: 0,
                    // INERT. Nothing in this file reads it. A streamer leaves by falling
                    // off the bottom of the screen and by nothing else.
                    lifetime: 9.0,
                    // Lateral drag only; the vertical is the quadratic law in step().
                    drag: rng.range(0.966, 0.980),
                    mass: rng.range(1.8, 2.8),
                    flip: rng.unit(),
                    flipSpeed: rng.range(0.20, 0.80) * (rng.unit() < 0.5 ? -1 : 1)
                ),
                phase: rng.range(0, 2 * .pi),
                rate: rng.range(1.0, 2.2),
                delay: base + rng.unit() * 0.035,
                launched: false,
                curl: rng.range(0.30, 0.95),
                // Spread across the population so the last few leave one at a time.
                // With the lighter gravity above, still unmistakably the slowest
                // material on screen and the last thing out, but fast enough that the
                // frame is EMPTY at ~1.3 s instead of streamers drifting on with no
                // event to justify them.
                termV: rng.range(1050, 1300)
            ))
        }

        ribbons = out
    }

    public mutating func step(dt: Double) {
        elapsed += dt
        guard !ribbons.isEmpty else { return }
        var anyPending = false

        for i in ribbons.indices {
            var r = ribbons[i]
            if !r.launched {
                if elapsed < r.delay { anyPending = true; ribbons[i] = r; continue }
                r.launched = true
            }
            r.p.age += dt
            var p = r.p

            let face = abs(cos(p.flip * 2 * .pi))
            let steps = dt * 60.0 / p.mass
            p.velocity.dx *= pow(p.drag, steps * 1.15)
            // Same quadratic law as the paper, with a much lower terminal speed. A
            // streamer that turns its face to the airflow slows; one that curls edge-on
            // slips and gains. That is why a real streamer descends in a lazy S.
            let vt = r.termV * (0.82 + 0.40 * (1 - face))
            let k = gravity / (vt * vt)
            let dyv = p.velocity.dy
            p.velocity.dy = dyv + (gravity - k * dyv * abs(dyv)) * dt

            // A streamer swings much wider and slower than a card; that big lazy arc is
            // what keeps the frame alive once the fast stuff is gone, and it is why the
            // last thing you see is a shape travelling sideways as well as down rather
            // than a dot descending in a straight line.
            let swing = sin(elapsed * r.rate + r.phase)
            p.velocity.dx += swing * 420 * dt / p.mass
            p.angularVelocity += swing * 1.35 * dt

            p.position.x += p.velocity.dx * dt
            p.position.y += p.velocity.dy * dt
            p.rotation += p.angularVelocity * dt
            let v = (p.velocity.dx * p.velocity.dx + p.velocity.dy * p.velocity.dy).squareRoot()
            let calm = pow(0.972 + 0.025 * min(1, v / 520), dt * 60.0)
            p.angularVelocity *= calm
            p.flipSpeed *= calm

            var flip = p.flip + p.flipSpeed * dt
            flip -= floor(flip)
            p.flip = flip

            r.p = p
            ribbons[i] = r
        }

        _ = anyPending
        // The only removal rule: it is below every display, or off to one side and never
        // coming back. No lifetime test, no alpha test, no floor part-way down the frame.
        let gone = origin.y + forgetDepth
        ribbons.removeAll {
            $0.launched && ($0.p.position.y > gone || abs($0.p.position.x - origin.x) > 2400)
        }
    }

    public var isFinished: Bool { ribbons.isEmpty || elapsed >= hardStop }

    public func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !ribbons.isEmpty else { return }
        let margin: CGFloat = 90
        let bounds = CGRect(x: -margin, y: -margin,
                            width: size.width + margin * 2, height: size.height + margin * 2)

        for r in ribbons {
            guard r.launched else { continue }
            let p = r.p
            // Off the canvas is off the canvas. Full opacity right to the bottom edge of
            // the screen, then the canvas clips it. Neither height nor age dims a
            // streamer at any point.
            guard bounds.contains(p.position) else { continue }

            let face = cos(p.flip * 2 * .pi)
            // A streamer is never allowed to vanish completely edge-on the way a card is.
            // It is the last thing left on screen, and a tail that strobes in and out
            // reads as a glitch rather than as paper.
            let squash = max(0.17, abs(face))

            var layer = context
            layer.translateBy(x: p.position.x, y: p.position.y)
            layer.rotate(by: .radians(p.rotation))

            let path = Self.curledPath(width: p.size.width * squash,
                                       height: p.size.height,
                                       curl: r.curl)
            layer.fill(path, with: .color(BurstPalette.color(p.colorIndex)))

            let shade = pow(1 - squash, 2.4) * 0.36
            if shade > 0.02 { layer.fill(path, with: .color(.black.opacity(shade))) }
            let spec = pow(max(0, face), 6)
            if spec > 0.02 {
                var hot = layer
                hot.blendMode = .plusLighter
                hot.fill(path, with: .color(.white.opacity(spec * 0.26)))
            }
        }
    }

    /// A long strip with an S-bend, so it reads as curled foil rather than a stick.
    private static func curledPath(width: Double, height: Double, curl: Double) -> Path {
        let hw = width / 2
        let hh = height / 2
        let bend = width * 1.35 * curl
        var path = Path()
        path.move(to: CGPoint(x: -hw, y: -hh))
        path.addCurve(to: CGPoint(x: -hw, y: hh),
                      control1: CGPoint(x: -hw + bend, y: -hh * 0.32),
                      control2: CGPoint(x: -hw - bend, y: hh * 0.32))
        path.addLine(to: CGPoint(x: hw, y: hh))
        path.addCurve(to: CGPoint(x: hw, y: -hh),
                      control1: CGPoint(x: hw - bend, y: hh * 0.32),
                      control2: CGPoint(x: hw + bend, y: -hh * 0.32))
        path.closeSubpath()
        return path
    }
}
