//  BaseBurstGate.swift — the thing that opens the GAP.
//
//  THE PROBLEM IT SOLVES.
//
//  Left alone, the burst plateaus: from about 300 ms to 650 ms the piece count and the
//  motion energy barely change. Nothing arrives in that window and nothing leaves it. A
//  second beat dropped into that field would be invisible, because there is no "into" —
//  the field is already as busy as the beat would make it.
//
//  A second event lands as a gift when the screen has gone quiet enough to make room for
//  it. That gap is not something you can add; it is something you have to clear.
//
//  So this wrapper runs the base burst's own simulation clock faster once the attack has
//  landed. Every frame before `warpStart` — the shockwave, the spike ball, the first
//  spray of pieces — is byte-identical to the unwrapped burst, because the warp factor is
//  exactly 1.0 there. After it the field falls away faster, which is a gust and not a
//  fast-forward: the cards are already accelerating under gravity and quadratic drag, so
//  running their clock on reads as the burst clearing out, because that is literally
//  what it is.
//
//  WHY NOT JUST SPAWN FEWER PARTICLES. Because the attack is made of exactly those
//  particles. Cutting the count cuts the opening. Clearing them early costs the opening
//  nothing and buys the entire middle of the curve.
//
//  DETERMINISM. `step` is a pure function of the sequence of steps taken: the warp factor
//  is read from accumulated step time, the inner layer is advanced by whole timesteps,
//  and the fractional remainder is carried in a Double. No clock, no randomness, nothing
//  that differs between the live overlay and the offscreen renderer.

import CoreGraphics
import Foundation
import SwiftUI

struct BaseBurstGate: CelebrationLayer {

    private var inner: any CelebrationLayer
    private let shape: TierShape

    /// Real time elapsed since the trigger, accumulated from whole fixed timesteps.
    private var outerTime: Double = 0
    /// Accumulated inner simulation time, in seconds.
    private var innerTime: Double = 0
    /// Inner steps already handed to `inner`.
    private var innerSteps: Int = 0

    init(config: CelebrationConfig, shape: TierShape) {
        self.shape = shape
        // The base burst is always built as ONE statement.
        //
        // `BurstProfile` gives `building`/`finalTask`/`streak` a second and third beat of
        // its own, both of which are more chips on a neighbouring axis. That is the
        // defect this whole directory exists to remove, so the base is constructed at
        // `.standard` — one beat, shortest life — and every later statement in the
        // celebration comes from a tier gesture with its own axis of travel.
        //
        // THE FIRST BEAT IS COMPRESSED.
        //
        // The first impact SHOULD be bigger for a bigger tier — but 0.30 to 0.94 is a
        // 3.1x range on ONE gesture, and passed through untouched that range would BE
        // the escalation: the same emitter throwing bigger, brighter, faster pieces,
        // which is the definition of a volume knob.
        //
        // `TierShape.baseIntensity` compresses that to roughly 0.30…0.62. The opening
        // still grows with the tier, by about 1.8x rather than 3.1x, and every tier's
        // opening is recognisably the same event — which is what makes the gesture that
        // arrives AFTER it read as a difference in kind rather than as more of the same.
        // A damped celebration passes through untouched; the compression can never make
        // a suppressed burst louder than the engine asked for.
        var base = config
        base.tier = .standard
        base.intensity = shape.baseIntensity
        inner = ConfettiLayer(config: base)
    }

    mutating func step(dt: Double) {
        innerTime += dt * shape.warp(at: outerTime)
        outerTime += dt

        let wanted = Int((innerTime + 1e-9) / dt)
        while innerSteps < wanted {
            inner.step(dt: dt)
            innerSteps += 1
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let a = handoff
        guard a > 0.004 else { return }
        if a >= 0.999 {
            inner.draw(in: &context, size: size)
        } else {
            var faded = context
            faded.opacity = a
            inner.draw(in: &faded, size: size)
        }
    }

    /// The last few stragglers handing off, so the screen is EMPTY — not "nearly empty" —
    /// at the moment the second beat lands.
    ///
    /// This is deliberately small and deliberately late. The warp has already taken the
    /// field down to a handful of pieces by `handoffStart`; an opacity ramp doing more
    /// than that would be alpha doing the job physics should be doing (a straggler
    /// dimming where it stands).
    /// Its whole job is to stop one unlucky card from sitting in the gap and filling it.
    private var handoff: Double {
        guard shape.handoffEnd > shape.handoffStart else { return 1 }
        if outerTime <= shape.handoffStart { return 1 }
        if outerTime >= shape.handoffEnd { return 0 }
        let u = (outerTime - shape.handoffStart) / (shape.handoffEnd - shape.handoffStart)
        return 1 - BurstEase.smoothstep(u)
    }

    var isFinished: Bool {
        inner.isFinished
            || (shape.handoffEnd > shape.handoffStart && outerTime >= shape.handoffEnd)
    }
}
