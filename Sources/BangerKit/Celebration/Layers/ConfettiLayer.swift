//  ConfettiLayer.swift — the burst, as one layer.
//
//  The burst is not one emitter. It is four sub-layers with genuinely different
//  physics (see SceneFactory.swift for the stack and the draw order), because a single
//  uniform emitter is the thing that makes confetti read as a preset no matter how many
//  particles it throws.
//
//  This type stays as the single public entry point so the overlay, the widget and the
//  offscreen renderer all keep constructing the burst the same way: `ConfettiLayer(config:)`.
//
//  Everything below is a pure function of (config, number of steps taken). The only
//  randomness is SeededRandom, consumed at spawn time, so two runs with the same seed
//  produce byte-identical frames. Nothing here reads a clock.

import CoreGraphics
import Foundation
import SwiftUI

public struct ConfettiLayer: CelebrationLayer {

    private var layers: [any CelebrationLayer]

    public init(config: CelebrationConfig) {
        layers = BangerBurst.layers(config: config)
    }

    public mutating func step(dt: Double) {
        for i in layers.indices { layers[i].step(dt: dt) }
    }

    public func draw(in context: inout GraphicsContext, size: CGSize) {
        for layer in layers { layer.draw(in: &context, size: size) }
    }

    public var isFinished: Bool { layers.allSatisfy(\.isFinished) }
}
