//  CelebrationView.swift — the live overlay's view, and the one place the layer
//  stack is assembled.
//
//  The live view and the offscreen renderer must never diverge. They diverge the
//  moment there are two lists of layers or two Canvas configurations, so there is
//  exactly one of each and both live here.

import Foundation
import SwiftUI

// MARK: - The layer stack

extension CelebrationScene {
    /// Builds the standard celebration. The overlay window and `bangerrender` both
    /// call this and nothing else, which is what makes the rendered video a true
    /// preview of what lands on screen.
    public static func make(config: CelebrationConfig) -> CelebrationScene {
        // The tier stack. `BangerTiers.layers` builds the burst (via `ConfettiLayer`)
        // and then whatever gestures this tier has that the tiers below it do not.
        // See Celebration/Tiers/TierStack.swift for the per-tier table.
        // Feel layers, when they are wired, prepend to this list.
        CelebrationScene(config: config, layers: BangerTiers.layers(config: config))
    }
}

// MARK: - Shared rendering settings

public enum CelebrationRendering {
    /// Both the live Canvas and the offscreen ImageRenderer use this. Changing it in
    /// one place only would silently break frame-for-frame equivalence.
    public static let colorMode: ColorRenderingMode = .nonLinear
    /// Longest the overlay will ever stay up, even if a layer misbehaves.
    public static let maxDuration: Double = 6.0
}

// MARK: - Simulation driver

/// Owns the mutable scene for a live `CelebrationView`.
///
/// Deliberately a plain class that SwiftUI does not observe: `TimelineView` already
/// drives the redraws, and if SwiftUI watched this, stepping it during a draw pass
/// would be a state-mutation-during-update violation.
///
/// Only ever touched from the main thread, on the SwiftUI render path.
final class CelebrationDriver: @unchecked Sendable {
    private(set) var scene: CelebrationScene
    private(set) var isFinished = false

    private var realTime: Double = 0
    private var stepsTaken: Int = 0
    private var lastTick: Date?

    init(config: CelebrationConfig) {
        self.scene = .make(config: config)
    }

    /// Catches the simulation up to `date` using whole fixed timesteps.
    ///
    /// The step count is derived from total elapsed time rather than accumulated
    /// per-frame remainders, so a stutter, a 60 Hz display and a 120 Hz display all
    /// land on the same step count — and on the same step count the offscreen
    /// renderer uses for the same moment.
    func advance(to date: Date) {
        guard !isFinished else { return }
        guard let last = lastTick else {
            lastTick = date
            return
        }
        lastTick = date

        // Clamp: a stall (app suspended, display sleep) must not fast-forward the
        // whole celebration in one frame.
        realTime += min(max(date.timeIntervalSince(last), 0), 0.25)

        let wanted = Int(realTime / celebrationTimestep)
        while stepsTaken < wanted {
            scene.step(dt: celebrationTimestep)
            stepsTaken += 1
        }

        if scene.isFinished || scene.elapsed >= CelebrationRendering.maxDuration {
            isFinished = true
        }
    }
}

// MARK: - Live view

/// The full-screen celebration, for the transparent click-through overlay window.
public struct CelebrationView: View {
    private let onFinished: () -> Void

    @State private var driver: CelebrationDriver
    @State private var didFinish = false

    public init(config: CelebrationConfig, onFinished: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        _driver = State(initialValue: CelebrationDriver(config: config))
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: didFinish)) { timeline in
            let _ = driver.advance(to: timeline.date)
            let finished = driver.isFinished

            Canvas(opaque: false,
                   colorMode: CelebrationRendering.colorMode,
                   rendersAsynchronously: false) { context, size in
                driver.scene.draw(in: &context, size: size)
            }
            .onChange(of: finished) { _, done in
                guard done, !didFinish else { return }
                didFinish = true
                onFinished()
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Static frame

/// One frozen frame of a scene. `bangerrender` feeds this to `ImageRenderer`.
///
/// It draws through the same `CelebrationScene.draw` the live view uses; there is no
/// second drawing implementation anywhere in the project.
public struct CelebrationFrameView: View {
    private let scene: CelebrationScene
    private let background: Color?

    public init(scene: CelebrationScene, background: Color? = nil) {
        self.scene = scene
        self.background = background
    }

    public var body: some View {
        Canvas(opaque: false,
               colorMode: CelebrationRendering.colorMode,
               rendersAsynchronously: false) { context, size in
            scene.draw(in: &context, size: size)
        }
        .background(background ?? Color.clear)
    }
}
