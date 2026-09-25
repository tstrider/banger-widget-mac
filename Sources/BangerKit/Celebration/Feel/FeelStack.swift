//  NOT IN THE LIVE PATH.
//
//  `BangerFeel.full` is not called by the live overlay or the offscreen renderer.
//  Both go through `CelebrationScene.make` (Celebration/CelebrationView.swift), which
//  uses `BangerTiers.layers` only. So `ImpactFlashLayer` is compiled into every target
//  but drawn by none of them, and the impact flash and scale punch are not on screen.
//  Enabling them is the one-line change to `CelebrationScene.make` shown below.
//
//  The trackpad haptic DOES fire: CelebrationPresenter calls
//  NSHapticFeedbackManager directly, not through HapticPlan.
//
//  FeelStack.swift — the one place that says which layers make up "feel", and how
//  they compose with the rest of the celebration.
//
//  INTEGRATION, one line:
//
//      // in CelebrationScene.make(config:)
//      CelebrationScene(config: config, layers: BangerFeel.full(config: config))
//
//  Order matters and is not negotiable: the feel layers go FIRST, underneath the
//  burst. The hit is what the confetti is a consequence of, so the confetti is
//  drawn over it, not the other way round. If the burst covers the flash, the
//  sequence loses its order and the whole thing reads as everything starting at
//  once.
//
//  WHY `full` EXISTS. The impact on its own is a single glowing rectangle, and it
//  is never shown alone. `full` is the composite: the impact underneath, the tier
//  stack's burst and beats over it.
//
//  This file does not modify the tier stack; it only reads `BangerTiers.layers`.

import Foundation

public enum BangerFeel {

    /// The visible half of the impact: the scale punch and the flash.
    public static func layers(config: CelebrationConfig,
                              reduceMotion: Bool = false) -> [any CelebrationLayer] {
        [ImpactFlashLayer(config: config, reduceMotion: reduceMotion)]
    }

    /// The whole celebration: impact underneath, the tier stack's burst over it.
    /// This is the composite the overlay should present and the renderer should
    /// render.
    public static func full(config: CelebrationConfig,
                            reduceMotion: Bool = false) -> [any CelebrationLayer] {
        layers(config: config, reduceMotion: reduceMotion)
            + BangerTiers.layers(config: config, reduceMotion: reduceMotion)
    }

    /// The impact on its own, for the offscreen renderer and for tuning. Nothing
    /// else is in it, so what you measure is the hit and not the burst.
    public static func scene(config: CelebrationConfig,
                             reduceMotion: Bool = false) -> CelebrationScene {
        CelebrationScene(config: config, layers: layers(config: config,
                                                        reduceMotion: reduceMotion))
    }

    /// The composite scene. Same fixed timestep, same draw path, same everything —
    /// the only difference from `scene` is that the rest of the celebration is in it.
    public static func fullScene(config: CelebrationConfig,
                                 reduceMotion: Bool = false) -> CelebrationScene {
        CelebrationScene(config: config, layers: full(config: config,
                                                      reduceMotion: reduceMotion))
    }
}
