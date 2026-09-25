//  TierStack.swift — the one place that says what each TIER is made of.
//
//  `SceneFactory.swift` says which layers make up THE BURST. This says which gestures
//  make up the CELEBRATION, and the lists are deliberately different KINDS per tier,
//  because that difference is the escalation.
//
//      standard   [ burst ]
//      building   [ burst(gated) , bloom ring ]
//      finalTask  [ burst(gated) , strike sweep , terminal accent ]
//      streak     [ burst(gated) , bloom ring , strike sweep , terminal accent ]
//
//  Read down that table with the sound off and you can name the tier from the shape
//  alone. Read it across and you can
//  see that no tier is the tier above it with the gain turned down: `standard` has no
//  second event of any kind, `building`'s second event is a circle, `finalTask`'s is a
//  line, and `streak` is the only one that performs both, in sequence.
//
//  Note what is NOT in the table. There is no third beat, no soft close, no late drift
//  after a tier's ending has landed. Every tier stops on the frame its last gesture stops.
//
//  Draw order is back to front: the burst underneath, the second beat over it, the line
//  over the ring, the terminal accent on top of everything. The accent has to sit above
//  the stroke it follows, or the landing reads as one more chip.

import CoreGraphics
import Foundation
import SwiftUI

public enum BangerTiers {

    /// The full celebration stack for a config. The overlay window and `bangerrender`
    /// both reach this through `CelebrationScene.make`, so the rendered frames are the
    /// frames that land on screen.
    public static func layers(config: CelebrationConfig,
                              reduceMotion: Bool = false) -> [any CelebrationLayer] {
        let shape = TierShape(config: config)

        // Reduce-motion: one still, local flash at the checkbox. No particles, no
        // translation, no scatter. The escalation survives as brightness and duration,
        // because those are not motion.
        if reduceMotion {
            return [ReducedMotionFlashLayer(shape: shape)]
        }

        var out: [any CelebrationLayer] = [BaseBurstGate(config: config, shape: shape)]

        for gesture in shape.gestures {
            switch gesture.kind {
            case .bloomRing:
                out.append(BloomRingLayer(shape: shape, gesture: gesture))
            case .strikeSweep:
                out.append(StrikeSweepLayer(shape: shape, gesture: gesture))
            }
        }

        if let accent = TerminalAccentLayer(shape: shape) {
            out.append(accent)
        }
        // A floor on the scene's life, so a tier that has cleared early still occupies
        // its planned slot and the overlay's teardown matches the plan the engine
        // published. It draws nothing.
        out.append(TierCurtain(duration: shape.duration))
        return out
    }

    /// What the engine's plan says this tier's celebration is, for callers that schedule
    /// audio, haptics or the overlay's dismissal off the same numbers the pixels use.
    public static func shape(for config: CelebrationConfig) -> TierShape {
        TierShape(config: config)
    }
}

// MARK: - Curtain

/// Draws nothing; keeps the scene alive for exactly as long as the tier's plan says.
///
/// Without it, a scene reports finished the moment its last particle leaves, which makes
/// the celebration's LENGTH a side effect of physics rather than a decision. The tiers
/// differ in how long they occupy the screen and that has to be a stated number.
struct TierCurtain: CelebrationLayer {
    private let duration: Double
    private var elapsed: Double = 0
    init(duration: Double) { self.duration = duration }
    mutating func step(dt: Double) { elapsed += dt }
    func draw(in context: inout GraphicsContext, size: CGSize) {}
    var isFinished: Bool { elapsed >= duration }
}

// MARK: - Reduce motion

/// The reduce-motion celebration: a single soft disc at the checkbox that brightens and
/// goes. It never translates, never scales the frame, and spawns nothing.
///
/// It still escalates — a `streak` flash is brighter, wider and a third longer than a
/// `standard` one — because the accessibility setting asks for less MOTION, not for less
/// acknowledgement.
struct ReducedMotionFlashLayer: CelebrationLayer {
    private let origin: CGPoint
    private let radius: Double
    private let peak: Double
    private let duration: Double
    private var elapsed: Double = 0

    init(shape: TierShape) {
        origin = shape.origin
        let tierWeight: Double
        switch shape.tier {
        case .standard:  tierWeight = 0.70
        case .building:  tierWeight = 0.84
        case .finalTask: tierWeight = 1.00
        case .streak:    tierWeight = 1.14
        }
        radius = shape.reach * 0.46 * tierWeight
        peak = 0.30 * (0.7 + 0.3 * shape.intensity) * tierWeight
        duration = min(0.60, max(0.26, shape.duration / 3))
    }

    mutating func step(dt: Double) { elapsed += dt }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard elapsed < duration else { return }
        let u = elapsed / duration
        // Up in two frames, then a clean decay. No radius animation at all: the disc is
        // the same size for its whole life, so nothing on screen moves.
        let alpha = peak * (u < 0.06 ? u / 0.06 : pow(1 - (u - 0.06) / 0.94, 2.0))
        guard alpha > 0.005 else { return }
        var layer = context
        layer.blendMode = .plusLighter
        let rect = CGRect(x: origin.x - radius, y: origin.y - radius,
                          width: radius * 2, height: radius * 2)
        // Alpha goes into the shading, not into `context.opacity`: under `.plusLighter`
        // a transparency layer composites against black and the flash comes out dark.
        layer.fill(Path(ellipseIn: rect),
                   with: .radialGradient(
                        Gradient(stops: [
                            .init(color: BurstPalette.color(0).opacity(alpha), location: 0.0),
                            .init(color: BurstPalette.color(0).opacity(alpha * 0.45), location: 0.6),
                            .init(color: BurstPalette.color(0).opacity(0), location: 1.0),
                        ]),
                        center: origin, startRadius: 0, endRadius: radius))
    }

    var isFinished: Bool { elapsed >= duration }
}
