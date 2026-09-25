//  CelebrationPresenter.swift — owns the overlay window's whole life.
//
//  Rules it enforces:
//   * exactly one overlay window exists, ever;
//   * a completion arriving while one is running escalates and restarts it
//     rather than stacking a second full-screen window;
//   * Reduce Motion swaps the particle scene for a short flash;
//   * when it is over, the window and its hosting view are gone — no retained
//     Canvas, no compositing, nothing on the GPU.

import AppKit
import SwiftUI
import BangerKit

@MainActor
final class CelebrationPresenter {

    static let shared = CelebrationPresenter()

    /// The trackpad thump. If BangerKit's effect stack grows its
    /// own haptic layer, turn this off so it does not fire twice.
    var performsHaptics = true

    /// Two completions inside this window are the same moment as far as the user
    /// is concerned. Anything already on screen escalates regardless, so this
    /// only decides whether we treat the burst as one event for bookkeeping.
    private let coalescingWindow: TimeInterval = 0.25

    private var window: CelebrationOverlayWindow?
    private var activeConfig: CelebrationConfig?
    /// Kept in global top-left space so the overlay can follow a display change.
    private var activeGlobalOrigin: CGPoint = .zero
    private var activeStartedAt: Date?
    private var escalationCount = 0

    /// Guards against a finished celebration tearing down its successor.
    private var generation: UInt64 = 0
    private var watchdog: DispatchWorkItem?

    /// Hotkey demo state: one press per tier, in order.
    private var demoTierIndex = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLayoutChanged() }
        }
    }

    var isRunning: Bool { window != nil }

    // MARK: - Entry points

    /// `config.origin` is expected in GLOBAL top-left coordinates.
    func celebrate(_ incoming: CelebrationConfig) {
        let resolved: CelebrationConfig
        var suppressHaptics = false
        if let current = activeConfig {
            resolved = escalated(from: current, with: incoming)
            // Two thumps 40ms apart read as a glitch, not as two wins.
            if let startedAt = activeStartedAt,
               Date().timeIntervalSince(startedAt) < coalescingWindow {
                suppressHaptics = true
            }
        } else {
            escalationCount = 0
            resolved = incoming
        }
        present(resolved, suppressHaptics: suppressHaptics)
    }

    /// Control-Option-Command-B. Walks the four tiers so all of them can be felt.
    func celebrateDemoCyclingTier() {
        let tiers = CelebrationTier.allCases
        let tier = tiers[demoTierIndex % tiers.count]
        demoTierIndex += 1

        let taskCount = 6
        let taskIndex: Int
        let remaining: Int
        let streakDays: Int
        switch tier {
        case .standard:  taskIndex = 1; remaining = 4; streakDays = 0
        case .building:  taskIndex = 4; remaining = 1; streakDays = 0
        case .finalTask: taskIndex = 5; remaining = 0; streakDays = 0
        case .streak:    taskIndex = 5; remaining = 0; streakDays = 7
        }

        let config = CelebrationConfig(
            intensity: CelebrationConfig.inferIntensity(tier: tier,
                                                        taskIndex: taskIndex,
                                                        taskCount: taskCount,
                                                        streakDays: streakDays),
            tier: tier,
            origin: ScreenGeometry.widgetHomeGlobalTopLeft,
            // Deterministic but different per press, so repeated presses show the
            // spread of the burst rather than the same frames four times.
            seed: 0xBA46_E200_0000_0000 &+ UInt64(demoTierIndex),
            taskIndex: taskIndex,
            taskCount: taskCount,
            remaining: remaining,
            streakDays: streakDays,
            source: "me"
        )
        celebrate(config)
    }

    func dismissImmediately() {
        generation &+= 1
        teardown()
    }

    // MARK: - Presentation

    private func present(_ globalConfig: CelebrationConfig, suppressHaptics: Bool = false) {
        // No display at all (every monitor asleep or detached): nothing to show.
        guard let screen = ScreenGeometry.screen(forGlobalTopLeft: globalConfig.origin) else {
            teardown()
            return
        }

        var windowConfig = globalConfig
        windowConfig.origin = ScreenGeometry.windowLocalTopLeft(
            fromGlobalTopLeft: globalConfig.origin, on: screen)

        activeConfig = globalConfig
        activeGlobalOrigin = globalConfig.origin
        activeStartedAt = Date()

        // THE SOUND. Fired here, on the same turn as the window is built and before the
        // first frame is drawn: sound does more emotional work per kilobyte than any
        // visual, and it must not arrive late.
        //
        // Coalesced completions deliberately re-fire: suppressHaptics stops two thumps
        // 40ms apart reading as a glitch, but the sound has its own per-tier variant and
        // an escalated second win should be heard.
        BangerSound.shared.play(globalConfig)

        generation &+= 1
        let token = generation

        let overlay: CelebrationOverlayWindow
        if let existing = window {
            existing.setFrame(screen.frame, display: false)
            overlay = existing
        } else {
            overlay = CelebrationOverlayWindow(screen: screen)
            window = overlay
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        let hostingView: NSView
        let safetyDuration: Double
        if reduceMotion {
            let content = FlashContent(config: windowConfig, reduceTransparency: reduceTransparency)
            safetyDuration = content.duration + 0.5
            let driver = FixedStepDriver(content: content,
                                         minimumDuration: 0.1,
                                         maximumDuration: content.duration)
            driver.onFinished = { [weak self] in self?.finish(token: token) }
            hostingView = NSHostingView(rootView: OverlayHostView(driver: driver))
        } else {
            // The one place this target touches the celebration factory.
            let scene = CelebrationScene.make(config: windowConfig)
            safetyDuration = 6.5
            let driver = FixedStepDriver(content: scene,
                                         minimumDuration: 0.2,
                                         maximumDuration: 6.0)
            driver.onFinished = { [weak self] in self?.finish(token: token) }
            hostingView = NSHostingView(rootView: OverlayHostView(driver: driver))
        }

        overlay.setOverlayContent(hostingView)
        overlay.present()

        if performsHaptics && !suppressHaptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }

        // Belt and braces: if the content never reports itself finished, the
        // window still goes away.
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(token: token) }
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + safetyDuration, execute: item)
    }

    private func finish(token: UInt64) {
        guard token == generation else { return }   // a newer celebration took over
        teardown()
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        window?.tearDown()
        window = nil
        activeConfig = nil
        activeStartedAt = nil
        activeGlobalOrigin = .zero
        escalationCount = 0
    }

    // MARK: - Escalation

    /// Bump rather than stack. Intensity climbs, tier takes the higher of the
    /// two, and the seed is perturbed deterministically so the restart does not
    /// replay the identical burst.
    private func escalated(from current: CelebrationConfig,
                           with incoming: CelebrationConfig) -> CelebrationConfig {
        escalationCount += 1

        var result = incoming
        result.intensity = bangerClamp(max(current.intensity, incoming.intensity) + 0.15, 0, 1)
        result.tier = Self.higherTier(current.tier, incoming.tier)
        result.seed = incoming.seed ^ (UInt64(escalationCount) &* 0x9E37_79B9_7F4A_7C15)
        result.taskCount = max(current.taskCount, incoming.taskCount)
        result.remaining = min(current.remaining, incoming.remaining)
        result.streakDays = max(current.streakDays, incoming.streakDays)
        return result
    }

    private static func higherTier(_ a: CelebrationTier, _ b: CelebrationTier) -> CelebrationTier {
        let order = CelebrationTier.allCases
        let ra = order.firstIndex(of: a) ?? 0
        let rb = order.firstIndex(of: b) ?? 0
        return ra >= rb ? a : b
    }

    // MARK: - Displays

    /// A monitor arrived or left mid-celebration. Move the overlay to whichever
    /// screen the completion now belongs on instead of leaving it stranded.
    private func screenLayoutChanged() {
        guard let overlay = window,
              let screen = ScreenGeometry.screen(forGlobalTopLeft: activeGlobalOrigin) else { return }
        overlay.setFrame(screen.frame, display: true)
    }
}
