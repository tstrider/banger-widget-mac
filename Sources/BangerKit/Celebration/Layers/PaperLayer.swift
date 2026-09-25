//  PaperLayer.swift — the body of the burst: tumbling paper that is thrown, and then
//  falls off the bottom of the screen.
//
//  HOW A PIECE LEAVES
//
//  A field that is braked to a hover and then removed where it hangs is not a burst with
//  a short tail. Two rules keep that from happening:
//
//  1. THERE IS NO KILL LINE. No function of position takes a piece's opacity away. A
//     piece is at full strength until it is off the bottom of the canvas, at which point
//     the canvas clips it. That is the entire exit mechanism.
//  2. LIFETIME DOES NOT DECIDE VISIBILITY. Removing pieces by age erodes the field from
//     the top down. Lifetime plays no part in whether a card is drawn: `draw` does not
//     consult it, and the only removal test is "is it below the bottom of the world".
//
//  WHAT MAKES THE FALL REAL
//
//  * QUADRATIC DRAG, dv/dt = g − k·v|v| with k = g/vt². Resistance rises with the SQUARE
//    of speed, so a card leaving the muzzle at 1400 pt/s is braked at four g and crests
//    inside a third of a second, while the same card falling at 300 pt/s is barely
//    resisted and keeps accelerating. Exponential per-step damping — what almost every
//    confetti system uses — cannot do that: it caps paper at a slow terminal velocity
//    and the fall becomes a drift. The steady state here is FALLING AT A CONSTANT SPEED,
//    never STOPPED.
//  * ANISOTROPIC DRAG. A card presenting its face to the airflow brakes hard; a card
//    knifing edge-on barely brakes at all, so terminal velocity is modulated by attitude
//    every step and a tumbling card surges and checks once per revolution.
//  * FORESHORTENING. `flip` collapses a card's width toward a line as its face turns
//    away, and the flip rate varies by an order of magnitude across the population.
//  * LATERAL FLUTTER THAT DOES NOT SWITCH OFF. Falling paper does not descend in
//    straight lines. The sway here is driven by the card's own phase clock, is strongest
//    when the card is edge-on, and is NOT gated on the card being slow: fading the
//    flutter out as |vy| grows would make it vanish exactly when the cards start
//    actually falling.
//
//  Beats are baked in at spawn as launch delays, so the simulation stays a pure function
//  of (config, steps taken). Nothing here reads a clock.

import CoreGraphics
import Foundation
import SwiftUI

public struct PaperLayer: CelebrationLayer {

    private struct Card {
        var p: Particle
        var swayPhase: Double
        var swayRate: Double
        var delay: Double
        var launched: Bool
        var bright: Double        // per-card value jitter, 0.94...1.0
        var backIndex: Int        // the colour printed on the reverse
        /// Terminal fall speed of this card face-on, points per second. Attitude
        /// modulates it every step, so a card that knifes edge-on genuinely surges.
        var termV: Double
    }

    private var cards: [Card]
    private var elapsed: Double = 0
    private let gravity: Double
    private let hardStop: Double
    private let swayStrength: Double
    private let origin: CGPoint
    /// How far below the origin a card has to be before it can never come back on
    /// screen and is dropped from the simulation. A MEMORY BOUND, not a kill line: it
    /// is deeper than the tallest display this will ever run on, so no card is ever
    /// removed while any part of it could still be drawn.
    private let forgetDepth: Double

    public init(config: CelebrationConfig) {
        self.init(profile: BurstProfile(config: config))
    }

    public init(profile: BurstProfile) {
        gravity = profile.gravity
        // Flutter is the thing that stops a descending field reading as a curtain. It
        // is strong, it is per-card, and nothing damps it out.
        swayStrength = 1450
        hardStop = profile.hardStop
        origin = profile.origin
        forgetDepth = profile.fallExit

        var rng = SeededRandom(seed: profile.seed &+ 0x51_7C_C1_B7)
        let fan1 = ClumpFan(axis: profile.axis, spread: profile.spread,
                            lobes: 5, looseFraction: 0.26, rng: &rng)
        // Beat two's emitter: a narrow, near-vertical plume with only two lobes, so
        // it comes up as a COLUMN rather than as a second fan. Same material, wholly
        // different silhouette.
        let fan2 = ClumpFan(axis: profile.axisBeat2, spread: profile.spreadBeat2,
                            lobes: 2, looseFraction: 0.22, rng: &rng)

        var out: [Card] = []
        out.reserveCapacity(profile.bodyCount)

        for _ in 0..<profile.bodyCount {
            let roll = rng.unit()
            let beat2 = profile.beatCount >= 2 && roll < profile.beat2Share
            let beat3 = !beat2 && profile.beatCount >= 3 && roll > 1 - profile.beat3Share

            let base: Double
            let scale: Double
            let sample: (angle: Double, speed: Double)
            let later = beat2 || beat3
            if beat3 {
                base = profile.beat3At; scale = 0.52; sample = fan2.sample(&rng)
            } else if beat2 {
                base = profile.beat2At; scale = 0.60; sample = fan2.sample(&rng)
            } else {
                base = 0; scale = 1.0; sample = fan1.sample(&rng)
            }
            // A launch stagger of 28 ms at most, squared hard toward zero. The whole
            // field is out of the muzzle inside two frames — that is the struck-event
            // read, and it keeps the density apex at ~100 ms so the energy curve has
            // one top instead of a long mesa.
            let delay = base + rng.unit() * rng.unit() * 0.028

            // Horizontal spread comes from the fan. Muzzle velocity is high and the air
            // does the rest: quadratic drag takes a 1400 pt/s card down to a few hundred
            // inside two frames, so the field reaches its full width while the eye is
            // still on the click and then simply stops widening.
            //
            // ONE CARD IN TEN IS A FLOATER: light, floppy, a much lower terminal speed.
            // It is the piece you can follow all the way down and the LAST thing out of
            // frame. It still falls at 600-800 pt/s — slow enough to watch, far too fast
            // to read as stationary, and quick enough to be off the bottom of a 982 pt
            // display inside 1.4 s.
            // No floaters in the later beats: a floater is the piece you follow all
            // the way down, and one launched at 320 ms would still be on screen at
            // 1.5 s, drizzling on after the rest of the burst has gone.
            let isFloater = !later && rng.unit() < 0.10
            // ONE CARD IN TWELVE IS NEAR-FIELD: noticeably bigger, faster, heavier.
            // Real confetti has pieces that pass close to your eye.
            let isNear = !isFloater && rng.unit() < 0.12

            let launch = isFloater ? 0.74 : (isNear ? 1.16 : 1.0)
            let speed = (1600 + 2800 * pow(rng.unit(), 0.78))
                * sample.speed * profile.speedScale * scale * launch
            let vx = cos(sample.angle) * speed
            let up = pow(max(0, -sin(sample.angle)), 0.55)
            // THREE LAUNCH CLASSES, AND THIS IS WHAT GIVES THE BURST ITS ENVELOPE.
            //
            // A popper does not throw everything at the sky. It throws an arc: most of
            // the charge up and across, a band of it nearly flat, and a real share of it
            // straight down out of the muzzle. Because a piece leaves the burst by
            // FALLING PAST THE BOTTOM OF THE SCREEN, how high a piece goes decides how
            // long it stays — so a fan with three launch classes empties itself in three
            // overlapping waves, the first pieces gone by ~650 ms and the last by
            // ~1.5 s, with no two pieces switching off together and nothing waiting
            // around to be removed.
            //
            // Getting the decay out of the launch distribution rather than out of a
            // lifetime is the whole difference between a burst that resolves and a burst
            // that is turned off.
            //
            // A DELIBERATELY BOUNDED RISE, too. The checkbox sits 0.18 of the way down
            // the screen, so there is very little room above the muzzle: a launch hard
            // enough to send paper off the top of the display throws away the apex,
            // which is the one moment this burst is built around.
            let launchRoll = rng.unit()
            var vy: Double
            if later {
                // THE PLUME. Everything in beat two goes UP, in a narrow band of
                // speeds, so the column rises together, hangs for about a tenth of a
                // second and rains back through itself. No spill class and no flat
                // class: a second event that sprays in every direction is just the
                // first event again, quieter.
                vy = -rng.range(480, 880) * profile.speedScale
            } else if launchRoll < 0.42 {
                // Spill: out of the muzzle and straight down past the checkbox. These
                // are the first pieces off the bottom of the screen, and they are the
                // reason the field starts thinning before the shockwave has finished.
                vy = rng.range(250, 1300)
            } else if launchRoll < 0.60 {
                // Flat: barely rises, crests almost at once, gone by about 1.0 s.
                vy = -rng.range(150, 380) * profile.speedScale * scale * launch
            } else {
                vy = -rng.range(640, 1150) * profile.speedScale * scale * launch
                    * (0.40 + 0.60 * up)
            }

            // A real popper has a muzzle, not a point. Spawning every card on top of
            // every other card is what produces the solid bright core that merges a
            // hundred distinct pieces into a dozen legible shapes.
            let scatterA = rng.range(0, 2 * .pi)
            // Beat two comes out of a tighter muzzle than beat one — that is what
            // makes it read as a column leaving one point rather than as a field
            // appearing. Beat one's muzzle is wide because a wider muzzle is free
            // coverage: the same cards stop stacking on each other.
            let scatterR = (later ? 34.0 : 92.0) * sqrt(rng.unit())

            let isDisc = rng.unit() < 0.12
            // Beat two's cards are noticeably larger. Fewer, bigger, slower-looking
            // pieces are how a smaller event still reads as an event.
            let w = rng.range(6.2, 9.8) * profile.sizeScale
                * (isNear ? 1.42 : 1.0) * (later ? 1.26 : 1.0)
            let aspect = isDisc ? 1.0 : rng.range(1.18, 1.86)

            // Bigger pieces are heavier and shed less speed to the air.
            let mass = (0.70 + (w / profile.sizeScale / (isNear ? 1.42 : 1.0) - 6.2) / 3.6 * 0.85)
                * (isFloater ? 0.55 : (isNear ? 1.45 : 1.0))
            // LATERAL drag stays exponential: sideways a card always presents an edge,
            // it brakes inside a fifth of a second, and the burst stops widening instead
            // of creeping outward. Vertical drag is the quadratic law in step(); `drag`
            // never touches it.
            let drag = isFloater ? rng.range(0.944, 0.962) : rng.range(0.948, 0.970)

            // TERMINAL FALL SPEED. The spread across the population is what makes the descent read as many
            // separate objects rather than one sheet coming down, and what staggers the
            // exits across 850 ms instead of clumping them.
            // The later beats fall HARDER than the first one. They arrive 320 ms in
            // and they still have to be off the bottom of the display before the
            // celebration's window closes, so the second wave is the heavier paper.
            // It is also why the second beat reads as a drop rather than as a spray:
            // it goes up slowly, hangs, and comes down faster than anything else.
            let termV = profile.terminalFall * (later ? 1.25 : 1.0)
                * (isFloater ? rng.range(0.80, 0.95)
                             : (isNear ? rng.range(1.15, 1.35) : rng.range(0.86, 1.15)))

            // Flip rate spans nearly an order of magnitude. A narrow range is the single
            // most preset-looking thing a confetti system can do. The top end is
            // capped: at 5 rev/s and above a card strobes faster than the eye can
            // resolve, which reads as flicker and holds the frame's motion energy up
            // on a plateau long after the field has stopped travelling.
            let flipSpeed = rng.range(0.45, 3.10) * (rng.unit() < 0.5 ? -1 : 1)

            // Lifetime is INERT. Nothing in this file reads it: not `step`, not
            // `draw`, not the removal test. It is left on the particle because the
            // contract declares it, and it is set far beyond any possible flight time
            // so that nothing downstream can mistake it for a schedule.
            let life = 9.0

            out.append(Card(
                p: Particle(
                    position: CGPoint(x: profile.origin.x + scatterR * cos(scatterA),
                                      y: profile.origin.y + scatterR * sin(scatterA)),
                    velocity: CGVector(dx: vx, dy: vy),
                    rotation: rng.range(0, 2 * .pi),
                    angularVelocity: rng.range(-9.5, 9.5),
                    size: CGSize(width: w, height: w * aspect),
                    colorIndex: BurstPalette.pick(BurstPalette.bodyWeights, &rng),
                    shape: isDisc ? .circle : .rectangle,
                    age: 0,
                    lifetime: life,
                    drag: drag,
                    mass: mass,
                    flip: rng.unit(),
                    flipSpeed: flipSpeed
                ),
                swayPhase: rng.range(0, 2 * .pi),
                // 0.7 to 2.3 flutters a second. Wide, because a field that all sways at
                // one rate reads as a single sheet rippling.
                swayRate: rng.range(0.70, 2.30),
                delay: delay,
                launched: false,
                bright: rng.range(0.94, 1.0),
                backIndex: BurstPalette.pick(BurstPalette.backWeights, &rng),
                termV: termV
            ))
        }

        cards = out
    }

    // MARK: - Simulation

    public mutating func step(dt: Double) {
        elapsed += dt
        guard !cards.isEmpty else { return }

        for i in cards.indices {
            var c = cards[i]
            if !c.launched {
                if elapsed < c.delay { cards[i] = c; continue }
                c.launched = true
            }

            c.p.age += dt
            var p = c.p

            // |cos| of the flip angle: 1 when the face is square to the viewer (and to
            // the airflow), 0 when the card is edge-on.
            let face = abs(cos(p.flip * 2 * .pi))
            let steps = dt * 60.0 / p.mass
            // Sideways, a card always presents an edge to the airflow and brakes hard:
            // the burst reaches its width fast and then simply stops widening. This one
            // stays exponential, because here a hard stop is exactly what is wanted.
            p.velocity.dx *= pow(p.drag, steps * 1.08)

            // VERTICAL: QUADRATIC DRAG TOWARD A TERMINAL VELOCITY.
            //
            //     dv/dt = g - k v|v|,   k = g / vt²
            //
            // The steady state of this law is "falling at vt", not "stopped". That is
            // the whole point: exponential damping has a steady state of zero, which
            // makes the field hover.
            //
            // Terminal velocity is modulated by the card's own attitude: face-on it
            // presents its full area and settles slower, edge-on it knifes and surges.
            // A tumbling card therefore speeds up and checks once per revolution, which
            // is the single most recognisable thing falling paper does.
            let vt = c.termV * (0.80 + 0.45 * (1 - face))
            let k = gravity / (vt * vt)
            let dyv = p.velocity.dy
            p.velocity.dy = dyv + (gravity - k * dyv * abs(dyv)) * dt

            // LATERAL FLUTTER. Driven by the card's own phase clock, strongest when the
            // card is edge-on and slipping, and NEVER gated on the card being slow:
            // scaling it down as |vy| grows would switch the flutter off at precisely
            // the moment the cards begin to fall, and the descent would be a set of
            // parallel straight lines. The faster a piece falls the more it slides
            // from side to side, which is what falling paper actually does.
            c.swayPhase += c.swayRate * 2 * .pi * dt
            let slip = 0.42 + 0.96 * (1 - face)
            p.velocity.dx += sin(c.swayPhase) * swayStrength * slip * dt / p.mass

            p.position.x += p.velocity.dx * dt
            p.position.y += p.velocity.dy * dt

            p.rotation += p.angularVelocity * dt

            // Spin is damped IN PROPORTION TO SPEED. A card ripping out of the muzzle
            // keeps whipping over; a card that has settled into its descent turns over
            // lazily. Without this, paper carries on strobing at the rate it left at,
            // which is the exact moment a burst stops reading as physical — and it is
            // also what pins motion energy to a plateau.
            let v = (p.velocity.dx * p.velocity.dx + p.velocity.dy * p.velocity.dy).squareRoot()
            let calm = pow(0.958 + 0.039 * min(1, v / 900), dt * 60.0)
            p.angularVelocity *= calm
            p.flipSpeed *= calm

            var flip = p.flip + p.flipSpeed * dt
            flip -= floor(flip)
            p.flip = flip

            c.p = p
            cards[i] = c
        }

        forgetUnreachable()
    }

    /// The ONLY removal rule: the card is so far below the origin that no display could
    /// still be showing it, or so far to one side that it can never come back.
    ///
    /// Note what is absent. There is no lifetime test. There is no alpha threshold.
    /// There is no fixed floor part-way down the frame. A card that is still on screen
    /// is still in this array, at full opacity, travelling.
    private mutating func forgetUnreachable() {
        let gone = origin.y + forgetDepth
        func unreachable(_ c: Card) -> Bool {
            guard c.launched else { return false }
            return c.p.position.y > gone || abs(c.p.position.x - origin.x) > 2400
        }
        guard cards.contains(where: unreachable) else { return }
        cards.removeAll(where: unreachable)
    }

    public var isFinished: Bool { cards.isEmpty || elapsed >= hardStop }

    // MARK: - Draw

    public func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !cards.isEmpty else { return }
        let margin: CGFloat = 90
        let bounds = CGRect(x: -margin, y: -margin,
                            width: size.width + margin * 2, height: size.height + margin * 2)

        for c in cards {
            guard c.launched else { continue }
            let p = c.p
            // Off the canvas is off the canvas. Nothing here fades: a card is drawn at
            // full strength right up to the bottom edge of the screen, and then the
            // canvas clips it away as it crosses. That is what "it left the frame" means.
            guard bounds.contains(p.position) else { continue }

            // Signed face: +1 looking straight at the front, -1 at the back, 0 edge-on.
            let face = cos(p.flip * 2 * .pi)
            let squash = max(0.045, abs(face))

            var layer = context
            layer.translateBy(x: p.position.x, y: p.position.y)
            layer.rotate(by: .radians(p.rotation))

            let path = Self.path(for: p, squash: squash)
            // Two-sided. Turning the card over changes its COLOUR, which is what real
            // printed confetti does and what a shadow can only imitate. It also keeps
            // every pixel on the palette instead of smearing the burst toward black.
            let showingBack = face < 0
            let index = showingBack ? c.backIndex : p.colorIndex
            let value = c.bright * (showingBack ? 0.94 : 1.0)
            layer.fill(path, with: .color(BurstPalette.color(index).opacity(value)))

            // Only the near-edge-on sliver darkens, and only a little. A card that goes
            // dark across half its rotation reads as a lighting trick; a card that just
            // gets thin and changes colour reads as paper.
            let shade = pow(1 - squash, 3.0) * 0.34
            if shade > 0.02 {
                layer.fill(path, with: .color(.black.opacity(shade)))
            }
            // ...and once per revolution the face comes square to the light and flashes.
            // This twinkle is what sells the tumble as three-dimensional; a card that only
            // gets darker reads as a rectangle changing width.
            let spec = pow(max(0, face), 7)
            if spec > 0.02 {
                var hot = layer
                hot.blendMode = .plusLighter
                hot.fill(path, with: .color(.white.opacity(spec * 0.26)))
            }
        }
    }

    private static func path(for p: Particle, squash: Double) -> Path {
        switch p.shape {
        case .circle:
            let d = p.size.width
            let ew = max(d * squash, 0.5)
            return Path(ellipseIn: CGRect(x: -ew / 2, y: -d / 2, width: ew, height: d))
        default:
            let w = p.size.width * squash
            let h = p.size.height
            let r = min(w, h) * 0.18
            return Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                        cornerSize: CGSize(width: r, height: r))
        }
    }
}
