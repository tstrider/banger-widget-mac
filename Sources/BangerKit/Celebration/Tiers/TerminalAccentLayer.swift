//  TerminalAccentLayer.swift — the thing that makes it LAND.
//
//  A celebration that stops because it runs out of particles has not finished; it has
//  run out. A tail of specks after the last gesture is the same fault.
//
//  This is the ending gesture, and it is the LAST thing that happens. When the struck line
//  has been drawn away, one small, hard, bright accent punches out of the checkbox the
//  whole celebration started from, and then there is nothing at all. It occupies 190 ms.
//
//  Four rules it obeys:
//    - NOT a flash. Peak radius is 0.46 of reach and its rim 1.25 — a quarter of the
//      length of the line it follows — and mean frame luma moves by well under a point.
//      A full-screen white flash is what software does instead of choreography.
//    - It EXPANDS. Outward, from the checkbox, like everything else in this directory.
//    - It is LATE and it is SMALL. It must never become the peak of the energy curve —
//      the peak belongs at about 110 ms, on the click.
//    - `standard` and `building` do not get one. The ending is the escalation, and a
//      quieter version of an ending on every tier is exactly the volume knob the tiers
//      are built to avoid.
//
//  NO SOFT CLOSE. The biggest tier ends on its accent, in silence, like the tier below
//  it. Anything dimmer after the ending has landed reads as a tail, not an ending.

import CoreGraphics
import Foundation
import SwiftUI

struct TerminalAccentLayer: CelebrationLayer {

    private let origin: CGPoint
    private let at: Double
    private let duration: Double = 0.190
    private let radius: Double
    private let rimRadius: Double
    private let rim: Double
    private let endsAt: Double
    private var elapsed: Double = 0

    init?(shape: TierShape) {
        guard let at = shape.accentAt else { return nil }
        self.at = at
        origin = shape.origin
        let energy = 0.72 + 0.28 * shape.intensity
        radius = shape.reach * 0.46
        rimRadius = shape.reach * 1.25
        rim = 0.92 * energy
        endsAt = at + duration + 0.015
    }

    mutating func step(dt: Double) { elapsed += dt }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let t = elapsed - at
        guard t >= 0, t < duration else { return }
        let u = t / duration

        // Alpha is baked into the shading, NOT applied with `context.opacity`.
        // `.plusLighter` inside a transparency layer composites against black and the
        // accent comes out as a dark disc; this is the same pattern `ShockwaveLayer`
        // uses, and it is the one that actually adds light.
        var layer = context
        layer.blendMode = .plusLighter

        let r = max(1.0, radius * BurstEase.outPow(u, 4.2))
        // Bright immediately, then a clean power decay. No hold: the accent is a
        // consonant, not a note.
        let alpha = pow(1 - u, 2.2)

        if alpha > 0.006 {
            let rect = CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2)
            // Hot in the middle, nothing at the edge. A flat disc reads as a circle being
            // drawn; a graded one reads as light coming off a point.
            let teal = BurstPalette.color(TierPalette.strokeIndex)
            layer.fill(Path(ellipseIn: rect),
                       with: .radialGradient(
                        Gradient(stops: [
                            .init(color: teal.opacity(alpha), location: 0.0),
                            .init(color: teal.opacity(alpha * 0.52), location: 0.55),
                            .init(color: teal.opacity(0), location: 1.0),
                        ]),
                        center: origin, startRadius: 0, endRadius: r))

            let cr = max(0.8, r * 0.52)
            let crect = CGRect(x: origin.x - cr, y: origin.y - cr,
                               width: cr * 2, height: cr * 2)
            layer.fill(Path(ellipseIn: crect),
                       with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(alpha), location: 0.0),
                            .init(color: .white.opacity(0), location: 1.0),
                        ]),
                        center: origin, startRadius: 0, endRadius: cr))
        }

        let rr = rimRadius * BurstEase.outPow(u, 2.1)
        let ra = rim * pow(1 - u, 2.6)
        if ra > 0.006, rr > 2 {
            let rect = CGRect(x: origin.x - rr, y: origin.y - rr,
                              width: rr * 2, height: rr * 2)
            layer.stroke(Path(ellipseIn: rect),
                         with: .color(BurstPalette.color(TierPalette.strokeIndex).opacity(ra)),
                         lineWidth: 1.6 + 6.2 * (1 - u))
        }
    }

    var isFinished: Bool { elapsed >= endsAt }
}
