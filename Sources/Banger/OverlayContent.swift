//  OverlayContent.swift — what the overlay window is allowed to draw.
//
//  Two things go on screen: the real celebration (a BangerKit CelebrationScene)
//  and the reduce-motion flash. Both are fixed-timestep simulations with a pure
//  draw, so one driver and one host view serve both.

import SwiftUI
import BangerKit

protocol OverlayContent {
    mutating func step(dt: Double)
    func draw(in context: inout GraphicsContext, size: CGSize)
    var isFinished: Bool { get }
    var elapsed: Double { get }
}

// CelebrationScene already has exactly this shape. Nothing to implement.
extension CelebrationScene: OverlayContent {}

/// Advances an OverlayContent in fixed `celebrationTimestep` increments.
///
/// The wall clock is read here and only here, to decide HOW MANY fixed steps to
/// run before the next frame is drawn. The simulation itself never sees a date,
/// so the state after N steps is byte-identical to the offscreen renderer's
/// state after N steps — which is the whole point of the contract.
///
/// Main-thread only. `@unchecked Sendable` because SwiftUI's Canvas renderer
/// closure is not statically isolated, but runs on the main thread while
/// `rendersAsynchronously` is false.
final class FixedStepDriver<Content: OverlayContent>: @unchecked Sendable {

    private var content: Content
    private var lastFrameDate: Date?
    private var accumulator: Double = 0
    private var hasFinished = false

    private let minimumDuration: Double
    private let maximumDuration: Double

    /// Ceiling on catch-up work in one frame. 64 steps is 0.27s of simulation,
    /// far more than any real frame gap; past that we drop the backlog rather
    /// than spiral.
    private let maximumStepsPerFrame = 64

    /// Called once, on the main thread, when the content is done.
    var onFinished: (() -> Void)?

    init(content: Content, minimumDuration: Double = 0.2, maximumDuration: Double = 6.0) {
        self.content = content
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
    }

    /// Step up to `date` and hand back an immutable snapshot to draw.
    func advance(to date: Date) -> Content {
        guard !hasFinished else { return content }

        guard let last = lastFrameDate else {
            lastFrameDate = date
            return content            // frame zero draws the spawn state
        }
        lastFrameDate = date

        // Clamp the gap: a stall (display sleep, a Space switch) must not make the
        // celebration fast-forward through itself in one frame.
        accumulator += min(max(0, date.timeIntervalSince(last)), 0.25)

        var steps = 0
        while accumulator >= celebrationTimestep && steps < maximumStepsPerFrame {
            content.step(dt: celebrationTimestep)
            accumulator -= celebrationTimestep
            steps += 1
        }
        if steps == maximumStepsPerFrame { accumulator = 0 }

        let done = (content.isFinished && content.elapsed >= minimumDuration)
            || content.elapsed >= maximumDuration
        if done {
            hasFinished = true
            let callback = onFinished
            onFinished = nil
            // Never tear the window down from inside a draw pass.
            DispatchQueue.main.async { callback?() }
        }
        return content
    }
}

/// The SwiftUI side of the overlay. One TimelineView, one Canvas, no state of
/// its own: the driver owns everything and the view is a pure projection of it.
struct OverlayHostView<Content: OverlayContent>: View {

    let driver: FixedStepDriver<Content>

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                let snapshot = driver.advance(to: now)
                snapshot.draw(in: &context, size: size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .background(Color.clear)
    }
}
