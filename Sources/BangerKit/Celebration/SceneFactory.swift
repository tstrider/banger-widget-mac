//  SceneFactory.swift — the one place that decides which layers make up the burst,
//  and in what order they are drawn.
//
//  Draw order is back to front:
//     shockwave   the struck-event ring and its pressure bloom, underneath everything
//     ribbons     big, slow, dark-edged; they belong behind the paper
//     paper       the body of the burst
//     sparks      the fast leading edge, additive, always on top
//
//  Kept separate from the layer files so that adding or reordering a layer is a one-line
//  change in one file, and so the live overlay and the offscreen renderer can never end
//  up with two different stacks.

import Foundation

public enum BangerBurst {

    /// The full particle-burst stack for a celebration.
    public static func layers(config: CelebrationConfig) -> [any CelebrationLayer] {
        let profile = BurstProfile(config: config)
        return [
            ShockwaveLayer(profile: profile),
            RibbonLayer(profile: profile),
            PaperLayer(profile: profile),
            SparkLayer(profile: profile),
        ]
    }
}

extension CelebrationScene {
    /// The burst on its own, without whatever else the overlay stacks around it.
    /// `CelebrationScene.make` is the full celebration; this is the particles alone.
    public static func particleLayers(config: CelebrationConfig) -> [any CelebrationLayer] {
        BangerBurst.layers(config: config)
    }
}
