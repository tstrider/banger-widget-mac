//  ReduceMotionFlash.swift — what happens instead of confetti when the user has
//  asked the system to reduce motion.
//
//  No particles, nothing that travels across the screen: one short bloom of the
//  accent colour at the spot the task was checked off, plus a defined edge band
//  so the acknowledgement still reads at the corner of the eye. Same fixed-step
//  contract as the real celebration, so the same driver runs it.

import SwiftUI
import BangerKit

struct FlashContent: OverlayContent {

    private(set) var elapsed: Double = 0

    let origin: CGPoint
    let intensity: Double
    /// Reduce Transparency is a separate setting: when it is on we drop the
    /// full-screen translucent bloom entirely and keep only the solid edge band.
    let reduceTransparency: Bool
    let duration: Double

    init(config: CelebrationConfig, reduceTransparency: Bool) {
        self.origin = config.origin
        self.intensity = bangerClamp(config.intensity, 0, 1)
        self.reduceTransparency = reduceTransparency
        self.duration = config.tier == .streak ? 0.62 : 0.45
    }

    mutating func step(dt: Double) { elapsed += dt }

    var isFinished: Bool { elapsed >= duration }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let t = min(1, elapsed / duration)
        let level = Self.envelope(t)
        guard level > 0.001 else { return }

        let tint = BangerPalette.accent

        if !reduceTransparency {
            let peak = 0.16 + 0.34 * intensity
            let alpha = level * peak
            let radius = max(size.width, size.height) * (0.34 + 0.26 * intensity)
            let gradient = Gradient(stops: [
                .init(color: tint.opacity(alpha), location: 0),
                .init(color: tint.opacity(alpha * 0.35), location: 0.45),
                .init(color: tint.opacity(0), location: 1),
            ])
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(gradient,
                                      center: clampedOrigin(in: size),
                                      startRadius: 0,
                                      endRadius: radius)
            )
        }

        // The edge band. Present in both modes; it is the part that survives
        // Reduce Transparency, so it carries the whole signal on its own.
        let inset = 8.0
        let bandWidth = 14.0 + 12.0 * intensity
        let rect = CGRect(origin: .zero, size: size)
            .insetBy(dx: inset + bandWidth / 2, dy: inset + bandWidth / 2)
        guard rect.width > 0, rect.height > 0 else { return }
        let bandAlpha = level * (reduceTransparency ? (0.55 + 0.40 * intensity)
                                                    : (0.30 + 0.35 * intensity))
        context.stroke(Path(roundedRect: rect, cornerRadius: 22),
                       with: .color(tint.opacity(min(0.95, bandAlpha))),
                       lineWidth: bandWidth)
    }

    private func clampedOrigin(in size: CGSize) -> CGPoint {
        CGPoint(x: bangerClamp(origin.x, 0, size.width),
                y: bangerClamp(origin.y, 0, size.height))
    }

    /// Fast attack, soft decay. Reads as an acknowledgement, not a strobe.
    private static func envelope(_ t: Double) -> Double {
        let attack = 0.16
        if t <= 0 { return 0 }
        if t < attack { return t / attack }
        let decay = (t - attack) / (1 - attack)
        return pow(max(0, 1 - decay), 2.2)
    }
}
