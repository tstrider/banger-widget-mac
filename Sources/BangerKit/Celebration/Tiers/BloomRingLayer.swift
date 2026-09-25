//  BloomRingLayer.swift — the RING. `building`'s whole second act, and `streak`'s first.
//
//  IT GOES OUT. A ring that closes onto the checkbox reads as the gift being taken back:
//  a celebration that ends by retracting onto the thing you clicked reads as the screen
//  tidying itself up. Everything here travels away from the checkbox, from the first
//  frame to the last.
//
//  AND IT NEVER PARKS. A ring that arrives and then holds still is a sticker held on
//  screen. This one has three movements and no stillness anywhere in it:
//
//    1. BLOOM (185 ms). Chips start a tenth of a reach off the checkbox and fly out to
//       the ring radius on an overshoot curve — past the target by about a tenth, then
//       back onto it. A staggered lead opens it like a shutter rather than snapping it
//       on. A stroke ring runs ahead of the chips, expanding, the same shape the opening
//       shockwave draws.
//    2. BREATHE. It keeps turning, and keeps easing outward by another 7 %, so the frames
//       between arrival and release still carry motion. It is a held note, not a held
//       picture.
//    3. RELEASE. The ring lets go: every chip keeps the outward direction it had and
//       falls out of the bottom of the frame under real gravity. Nothing dims where it
//       stands, and the tier is clear well inside 900 ms.
//
//  A CIRCLE IS THE POINT. `standard` shows nothing after 300 ms, `finalTask` shows a
//  straight line, and this shows a circle. With the radius and the brightness normalised
//  away those are still three different pictures.
//
//  Pure: every random draw is consumed once at construction, and position is a function
//  of the accumulated step count.

import CoreGraphics
import Foundation
import SwiftUI

struct BloomRingLayer: CelebrationLayer {

    private struct Spoke {
        var angle: Double
        var r0: Double
        var rTarget: Double
        /// Seconds this chip takes to cover the bloom.
        var travel: Double
        /// Seconds after the beat before this chip starts moving.
        var lead: Double
        var spin: Double
        /// Speed away from the checkbox at the moment of release, points/second.
        var kickOut: Double
        var kickDown: Double
        /// Seconds after the beat at which THIS chip is thrown.
        var releaseAt: Double
        /// The furthest this chip has been from the origin so far. `outBack` overshoots
        /// its target and then settles back onto it, and that settle-back shows as a
        /// visible inward contraction — the gift being taken back. A ring may
        /// overshoot; it may not retract. Clamping to the running maximum keeps the
        /// overshoot, which is what gives the arrival its snap, and drops only the
        /// retraction.
        var rMax: Double = 0
        var chip: TierChip
        var released: Bool
        var velocity: CGVector
    }

    private var spokes: [Spoke]
    private let origin: CGPoint
    private let startAt: Double
    private let dwell: Double
    private let endsAt: Double
    private let strokeReach: Double
    private let intensity: Double
    private let fallExit: Double
    private let fallFade: Double
    private var elapsed: Double = 0

    /// Seconds the leading stroke takes to cross the ring.
    private let strokeFor: Double = 0.132
    /// The ring is an ELLIPSE, 0.55 as tall as it is wide.
    ///
    /// Two reasons, one aesthetic and one practical. A mathematically perfect circle of
    /// particles around an emitter is the single most recognisable default-preset shape
    /// there is; foreshortened, it reads as a physical wreath lying at an angle rather
    /// than as a circle a program drew. And the checkbox sits near the TOP of the
    /// display, so a true circle at this radius would push its upper arc off the screen
    /// and the gesture would be a cropped arc instead of a ring.
    private let squash: Double = 0.55
    /// How far the ring keeps easing outward after it has settled.
    private let breathe: Double = 0.055
    private let breatheFor: Double = 0.075
    private let gravity: Double = 11000

    init(shape: TierShape, gesture: TierShape.Gesture) {
        origin = shape.origin
        startAt = gesture.at
        dwell = gesture.release
        endsAt = gesture.at + gesture.ends
        strokeReach = shape.reach * gesture.span
        intensity = shape.intensity
        fallExit = shape.fallExit
        fallFade = shape.fallFade

        var rng = SeededRandom(seed: shape.seed &+ 0x51_B7_2C_6A)
        let n = max(1, gesture.count)
        var out: [Spoke] = []
        out.reserveCapacity(n)

        for i in 0..<n {
            // Evenly spaced with jitter. A perfectly even ring reads as UI; a random one
            // reads as spray. A third of the gap is the band where it still reads as a
            // ring made of separate things.
            let base = (Double(i) / Double(n)) * 2 * .pi
            let angle = base + rng.range(-0.34, 0.34) * (2 * .pi / Double(n))

            let side = shape.chipSide * rng.range(0.95, 1.45)
            let chip = TierChipDraw.make(side: side, at: origin, &rng)

            out.append(Spoke(
                angle: angle,
                r0: shape.reach * rng.range(0.06, 0.15),
                // A BAND, not a hoop. Spread over 0.62…1.26 of the nominal radius, the
                // ring lands two or three chips deep and reads as a cloud of paper
                // arranged in a circle. Pinned to one radius, a hundred chips at this
                // size simply touch each other and the whole thing draws as a solid
                // outline.
                rTarget: shape.reach * gesture.span * rng.range(0.62, 1.26),
                // 120–155 ms, plus up to 45 ms of stagger: the whole arrival lands inside
                // a 160–200 ms window and no chip is still moving
                // outward after it.
                travel: rng.range(0.105, 0.138),
                lead: rng.range(0, 0.036),
                spin: rng.range(0.55, 1.65),
                // The release is a THROW, not a drop: a big outward component so the
                // ring is still opening as it leaves, and enough downward speed that the
                // last chip is off the bottom of the display inside 200 ms. A tier that
                // is over has to look over before its clock runs out.
                kickOut: rng.range(700, 1150),
                kickDown: rng.range(1400, 1850),
                releaseAt: 0,
                chip: chip,
                released: false,
                velocity: .zero
            ))
        }
        for i in out.indices {
            out[i].releaseAt = out[i].lead + out[i].travel + dwell
        }
        spokes = out
    }

    mutating func step(dt: Double) {
        elapsed += dt
        let t = elapsed - startAt
        guard t >= 0 else { return }

        for i in spokes.indices {
            var s = spokes[i]

            if s.released {
                s.velocity.dy += gravity * dt
                // A little air on the horizontal only: the outward throw reads as a
                // spread opening up, and then gravity owns the motion.
                s.velocity.dx *= (1 - 1.9 * dt)
                s.chip.position.x += s.velocity.dx * dt
                s.chip.position.y += s.velocity.dy * dt
                s.chip.rotation += s.chip.angularVelocity * dt
                s.chip.flip += s.chip.flipSpeed * dt
                spokes[i] = s
                continue
            }

            let local = t - s.lead
            if local <= 0 {
                s.chip.fadeIn = 0
                spokes[i] = s
                continue
            }

            // --- the bloom, with overshoot ------------------------------------
            var r: Double
            if local < s.travel {
                r = s.r0 + (s.rTarget - s.r0) * TierEase.outBack(local / s.travel)
                r = max(r, s.rMax)          // overshoot yes, retraction no
            } else {
                // --- the breathe ----------------------------------------------
                // Breathe out from wherever the chip actually got to, not from rTarget,
                // so the handover from bloom to breathe cannot step backwards either.
                let b = BurstEase.clamp01((local - s.travel) / breatheFor)
                r = max(s.rTarget, s.rMax) * (1 + breathe * BurstEase.smoothstep(b))
                s.angle += s.spin * dt
            }
            s.rMax = max(s.rMax, r)

            s.chip.position = CGPoint(x: origin.x + cos(s.angle) * r,
                                      y: origin.y + sin(s.angle) * r * squash)
            s.chip.rotation += s.chip.angularVelocity * dt
            s.chip.flip += s.chip.flipSpeed * dt
            s.chip.fadeIn = min(1, s.chip.fadeIn + dt * 30)

            // --- the release --------------------------------------------------
            if t >= s.releaseAt {
                s.released = true
                let out = CGVector(dx: cos(s.angle), dy: sin(s.angle) * squash)
                // The outward throw is unconditional sideways, but only ever DOWNWARD
                // vertically: a chip at the top of the ring must not be flicked up, or
                // it hangs above the checkbox for a fifth of a second after every other
                // piece has gone.
                s.velocity = CGVector(dx: out.dx * s.kickOut,
                                      dy: max(0, out.dy) * s.kickOut + s.kickDown)
                s.chip.angularVelocity *= 1.8
                s.chip.flipSpeed *= 1.7
            }

            spokes[i] = s
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let t = elapsed - startAt
        guard t >= 0 else { return }

        // The expanding front. One stroke, 132 ms, the same shape the opening shockwave
        // draws — and it leads the chips out by a couple of frames, so the eye is already
        // travelling outward when they arrive.
        if t < strokeFor {
            let u = BurstEase.clamp01(t / strokeFor)
            let r = strokeReach * (0.12 + 1.34 * BurstEase.outPow(u, 2.1))
            let alpha = (1 - u * u) * 0.88 * (0.70 + 0.30 * intensity)
            if alpha > 0.01, r > 2 {
                let ry = r * squash
                let rect = CGRect(x: origin.x - r, y: origin.y - ry,
                                  width: r * 2, height: ry * 2)
                var ring = context
                ring.opacity = alpha
                ring.stroke(Path(ellipseIn: rect),
                            with: .color(BurstPalette.color(TierPalette.strokeIndex)),
                            lineWidth: 3.0 + 12.0 * (1 - u))
            }
        }

        let margin: CGFloat = 80
        let bounds = CGRect(x: -margin, y: -margin,
                            width: size.width + margin * 2, height: size.height + margin * 2)
        for s in spokes {
            guard s.chip.fadeIn > 0.004, bounds.contains(s.chip.position) else { continue }
            let exit = TierChipDraw.exitAlpha(y: s.chip.position.y,
                                              canvasHeight: size.height,
                                              originY: origin.y,
                                              fallExit: fallExit,
                                              fallFade: fallFade)
            guard exit > 0.004 else { continue }
            TierChipDraw.draw(s.chip, in: &context, extra: exit)
        }
    }

    var isFinished: Bool { elapsed >= endsAt }
}
