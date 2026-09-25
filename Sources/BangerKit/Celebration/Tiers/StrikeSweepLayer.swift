//  StrikeSweepLayer.swift — the LINE. `finalTask`'s second act, and `streak`'s third.
//
//  WHY A STRIKETHROUGH, AND WHY IT IS THE RIGHT SHAPE FOR THE ENDING
//
//  The top tiers need a different gesture again, and a strikethrough sweep is the right
//  one for three reasons. The third is the one that decides it.
//
//    1. IT MEANS SOMETHING. Crossing a line through an item is the physical act this
//       entire product is a digital version of. On the last open task of the day, the
//       line is not decoration: it is the list being struck off.
//    2. IT IS THE ONLY STRAIGHT THING IN BANGER. The burst is a radial fan. The
//       shockwave and the bloom ring are circles. Everything else travels on a radius
//       from the checkbox. This travels along an axis, in one direction, with two ends —
//       and a line is not a fan or a ring at any radius, in any crop, at any brightness,
//       with the sound off. That is what lets a viewer name the tier from its shape.
//    3. IT CANNOT BE MISTAKEN FOR MORE OF THE TIER BELOW. A brighter ring is a ring. A
//       wider fan is a fan. There is no amount of `building` that turns into a line, so
//       when the line arrives the viewer knows something categorically different has
//       happened, before they have counted a single chip.
//
//  HOW IT IS DRAWN. Like a pen, not like a wipe.
//
//    - It is struck LEFT, across the empty black the widget sits beside, and it starts
//      to the RIGHT of the checkbox so that it passes THROUGH the box rather than
//      leaving it. The checkbox is the thing being struck off.
//    - The tip overshoots the end of the stroke by about a tenth and settles back onto
//      it — `TierEase.outBack` — which is what a hand does and what a ruled wipe never
//      does.
//    - The stroke has PRESSURE: it is thin where the nib lands, full through the middle,
//      and tapers off the far end. It also bows very slightly, because a struck line
//      drawn by a person is not level.
//    - Chips are thrown off the nib as it passes, not spawned in a clump: each one waits
//      for the tip to reach its own position along the line. They leave mostly downward
//      and leftward, in the direction of travel, and they fall out of the bottom of the
//      frame under real gravity. Nothing fades where it stands.
//    - The line does not dissolve. It THINS to nothing over 110 ms, which is the stroke
//      being drawn away rather than an opacity ramp doing the work of an exit.
//
//  Pure. Every random draw is consumed once at construction; the tip position is a
//  function of accumulated step time alone.

import CoreGraphics
import Foundation
import SwiftUI

struct StrikeSweepLayer: CelebrationLayer {

    private struct Fleck {
        /// Position along the stroke, 0...1, at which the nib throws this chip.
        var q: Double
        var velocity: CGVector
        var chip: TierChip
        var live: Bool
    }

    private var flecks: [Fleck]
    private let origin: CGPoint
    private let startAt: Double
    private let endsAt: Double
    private let p0: CGPoint
    private let p1: CGPoint
    private let normal: CGVector
    private let maxWidth: Double
    private let bow: Double
    private let intensity: Double
    private let fallExit: Double
    private let fallFade: Double
    private var elapsed: Double = 0

    /// Seconds of tip travel, including the overshoot and its settle.
    private let strikeFor: Double = 0.205
    /// Seconds the completed stroke is held at full width before it is drawn away.
    private let holdFor: Double = 0.062
    /// Seconds the stroke takes to thin to nothing.
    private let thinFor: Double = 0.240
    private let gravity: Double = 8600

    init(shape: TierShape, gesture: TierShape.Gesture) {
        origin = shape.origin
        startAt = gesture.at
        endsAt = gesture.at + gesture.ends
        intensity = shape.intensity
        fallExit = shape.fallExit
        fallFade = shape.fallFade

        // Starts a quarter of a reach to the RIGHT of the checkbox and ends 1.45 reaches
        // to its LEFT, tilted very slightly down — a struck line, not a ruled one.
        let span = shape.reach * gesture.span
        let start = CGPoint(x: shape.origin.x + span * 0.145,
                            y: shape.origin.y - shape.reach * 0.050)
        let end = CGPoint(x: shape.origin.x - span * 0.855,
                          y: shape.origin.y + shape.reach * 0.075)
        p0 = start
        p1 = end
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = max(1e-6, (dx * dx + dy * dy).squareRoot())
        normal = CGVector(dx: -dy / len, dy: dx / len)
        // Wide enough to be a LINE and not a hairline. At `finalTask` reach this is
        // about 22 pt against a 300 pt stroke — a 1:14 bar, which is what a felt pen
        // leaves and what reads as struck rather than as a scratch.
        maxWidth = shape.chipSide * 1.40
        bow = shape.reach * 0.038

        var rng = SeededRandom(seed: shape.seed &+ 0x3C_18_A4_F7)
        let n = max(1, gesture.count)
        var out: [Fleck] = []
        out.reserveCapacity(n)

        for i in 0..<n {
            // Spread along the stroke, with jitter, so the nib throws continuously
            // instead of in ranks.
            let q = min(0.995, max(0.005,
                                   Double(i) / Double(n) + rng.range(-0.4, 0.4) / Double(n)))
            let side = shape.chipSide * rng.range(0.88, 1.34)
            var chip = TierChipDraw.make(side: side, at: .zero, &rng)
            chip.angularVelocity = rng.range(-9.0, 9.0)
            chip.flipSpeed = rng.range(1.6, 5.4)

            // Mostly down and to the left, following the nib.
            // About one in twenty-five is thrown UP first, which is what stops the
            // spray reading as a curtain dropping off a bar: some of the material has to
            // arc. Any more than that and the arc becomes the tail that outlives the
            // gesture.
            let up = rng.unit() < 0.04
            let vy = up ? rng.range(-300, -120) : rng.range(900, 1700)
            let vx = -rng.range(90, 520) + rng.range(-70, 70)

            out.append(Fleck(q: q,
                             velocity: CGVector(dx: vx, dy: vy),
                             chip: chip,
                             live: false))
        }
        flecks = out
    }

    /// Where the nib is, as a fraction of the stroke. Goes past 1 and comes back.
    private func tipParameter(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        if t >= strikeFor { return 1 }
        return TierEase.outBack(t / strikeFor, 1.85)
    }

    /// A point on the stroke, including the bow.
    private func point(_ q: Double) -> CGPoint {
        let b = sin(.pi * BurstEase.clamp01(q)) * bow
        return CGPoint(x: p0.x + (p1.x - p0.x) * q + normal.dx * b,
                       y: p0.y + (p1.y - p0.y) * q + normal.dy * b)
    }

    /// Pen pressure: thin at the nib's landing, full through the middle, tapering off
    /// the far end so the overshoot leaves a fine tail rather than a blunt stop.
    private func pressure(_ q: Double) -> Double {
        guard q > 0, q < 1.14 else { return 0 }
        let lead = min(1, q / 0.085)
        let tail = min(1, max(0, (1.14 - q) / 0.26))
        return lead * tail * (0.62 + 0.38 * sin(.pi * min(1, q)))
    }

    mutating func step(dt: Double) {
        elapsed += dt
        let t = elapsed - startAt
        guard t >= 0 else { return }

        let tip = tipParameter(t)

        for i in flecks.indices {
            var f = flecks[i]
            if !f.live {
                guard tip >= f.q else { continue }
                f.live = true
                f.chip.position = point(f.q)
                f.chip.fadeIn = 1
            }
            f.velocity.dy += gravity * dt
            f.velocity.dx *= (1 - 1.4 * dt)
            f.chip.position.x += f.velocity.dx * dt
            f.chip.position.y += f.velocity.dy * dt
            f.chip.rotation += f.chip.angularVelocity * dt
            f.chip.flip += f.chip.flipSpeed * dt
            flecks[i] = f
        }
    }

    /// 1 while the stroke is being drawn and held, falling to 0 as it is drawn away.
    private func widthScale(_ t: Double) -> Double {
        let done = strikeFor + holdFor
        if t <= done { return 1 }
        return 1 - BurstEase.smoothstep(min(1, (t - done) / thinFor))
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let t = elapsed - startAt
        guard t >= 0 else { return }

        // --- the stroke ------------------------------------------------------
        let scale = widthScale(t)
        let tip = tipParameter(t)
        if scale > 0.004, tip > 0.004 {
            let steps = 40
            let top = maxWidth * scale
            var upper: [CGPoint] = []
            var lower: [CGPoint] = []
            upper.reserveCapacity(steps + 1)
            lower.reserveCapacity(steps + 1)

            for k in 0...steps {
                let q = tip * Double(k) / Double(steps)
                let w = top * pressure(q) * 0.5
                let p = point(q)
                upper.append(CGPoint(x: p.x + normal.dx * w, y: p.y + normal.dy * w))
                lower.append(CGPoint(x: p.x - normal.dx * w, y: p.y - normal.dy * w))
            }

            var path = Path()
            path.move(to: upper[0])
            for p in upper.dropFirst() { path.addLine(to: p) }
            for p in lower.reversed() { path.addLine(to: p) }
            path.closeSubpath()

            var ink = context
            ink.blendMode = .plusLighter
            let teal = BurstPalette.color(TierPalette.strokeIndex)
            ink.fill(path, with: .color(teal.opacity(0.92 * (0.70 + 0.30 * intensity))))

            // A hot core down the middle of the stroke, half the width and white. It is
            // what makes the line read as struck rather than as painted.
            var core = Path()
            let coreTop = top * 0.34
            var a: [CGPoint] = []
            var b: [CGPoint] = []
            for k in 0...steps {
                let q = tip * Double(k) / Double(steps)
                let w = coreTop * pressure(q) * 0.5
                let p = point(q)
                a.append(CGPoint(x: p.x + normal.dx * w, y: p.y + normal.dy * w))
                b.append(CGPoint(x: p.x - normal.dx * w, y: p.y - normal.dy * w))
            }
            core.move(to: a[0])
            for p in a.dropFirst() { core.addLine(to: p) }
            for p in b.reversed() { core.addLine(to: p) }
            core.closeSubpath()
            ink.fill(core, with: .color(.white.opacity(0.58 * scale)))
        }

        // --- the flecks ------------------------------------------------------
        let margin: CGFloat = 80
        let bounds = CGRect(x: -margin, y: -margin,
                            width: size.width + margin * 2, height: size.height + margin * 2)
        for f in flecks {
            guard f.live, bounds.contains(f.chip.position) else { continue }
            let exit = TierChipDraw.exitAlpha(y: f.chip.position.y,
                                              canvasHeight: size.height,
                                              originY: origin.y,
                                              fallExit: fallExit,
                                              fallFade: fallFade)
            guard exit > 0.004 else { continue }
            TierChipDraw.draw(f.chip, in: &context, extra: exit)
        }
    }

    var isFinished: Bool { elapsed >= endsAt }
}
