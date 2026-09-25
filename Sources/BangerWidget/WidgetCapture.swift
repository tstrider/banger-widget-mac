//  WidgetCapture.swift — the check transition, rendered offscreen frame by frame.
//
//  ROUTE, stated plainly because it matters for how the clip should be read:
//  the real widget cannot be driven headlessly. WidgetKit renders in the widget
//  host's process, there is no API to step it, and no way to synthesise a click on
//  a desktop widget from a script. So this renders THE SAME SwiftUI views, at the
//  widget's real point size, through ImageRenderer — the same technique
//  bangerrender uses for the celebration.
//
//  What makes that honest rather than a mock-up: the live widget animates the
//  transition with `.linear(duration:)` over an Animatable whose animatableData is
//  therefore elapsed time, and CheckMotion turns that time into every value on
//  screen. This evaluates the identical arithmetic at identical times and feeds the
//  identical views. The curve in the clip is the curve SwiftUI runs.
//
//  Nothing here is simulated. Nothing on screen waits for WidgetKit to run the
//  intent and hand back a new entry, so the clip renders the BEFORE entry from first
//  frame to last, and every change you see, including the counter and the progress
//  bar, comes from the optimistic toggle. That is exactly what the user gets before
//  the reload lands, and when it lands it agrees with what is drawn.
//
//  Two known divergences from the live widget, neither hidden:
//   - the day counter steps rather than rolling; `.numericText` needs a live
//     transition and ImageRenderer has none.
//   - no click cursor, because the renderer has no pointer.

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

// MARK: - Scenario

/// One check-off to replay. `checkIndex` is the task being checked.
struct WidgetCaptureScenario {

    var tasks: [WidgetTask]
    var checkIndex: Int
    var streak: Int
    var family: WidgetFamily
    var timeline: CheckTimeline

    /// The list the user actually has in front of them at the end of a day, with the last
    /// one still open. The biggest moment the widget has.
    static func lastOne(family: WidgetFamily = .systemMedium,
                        timeline: CheckTimeline = CheckTimeline()) -> WidgetCaptureScenario {
        let done = Date(timeIntervalSince1970: 1_000)
        return WidgetCaptureScenario(
            tasks: [
                WidgetTask(id: "t1", text: "Export authenticator codes", done: true,
                           source: "me", completedAt: done),
                WidgetTask(id: "t2", text: "Call the realtor", done: true,
                           source: "iris", completedAt: done),
                WidgetTask(id: "t3", text: "Book the van", done: true,
                           source: "iris", completedAt: done),
                WidgetTask(id: "t4", text: "Mix down the B-side", done: false,
                           source: "me", completedAt: nil)
            ],
            checkIndex: 3, streak: 4, family: family, timeline: timeline)
    }

    /// An ordinary mid-list task, for comparison against the one above.
    static func midList(family: WidgetFamily = .systemMedium,
                        timeline: CheckTimeline = CheckTimeline()) -> WidgetCaptureScenario {
        var scenario = lastOne(family: family, timeline: timeline)
        scenario.tasks[1].done = false
        scenario.tasks[2].done = false
        scenario.tasks[3].done = false
        scenario.checkIndex = 1
        return scenario
    }

    static func named(_ name: String, family: WidgetFamily, timeline: CheckTimeline) -> WidgetCaptureScenario? {
        switch name {
        case "lastOne": return lastOne(family: family, timeline: timeline)
        case "midList": return midList(family: family, timeline: timeline)
        default: return nil
        }
    }

    var taskID: String { tasks[checkIndex].id }

    var before: WidgetDay { WidgetDay(dayKey: "capture", tasks: tasks, streak: streak) }

    var after: WidgetDay {
        var updated = tasks
        updated[checkIndex].done = true
        updated[checkIndex].completedAt = Date(timeIntervalSince1970: 2_000)
        return WidgetDay(dayKey: "capture", tasks: updated, streak: streak)
    }
}

// MARK: - One frame

struct WidgetCaptureFrame: View {

    var scenario: WidgetCaptureScenario
    var time: Double
    /// Empty margin around the widget, so the clip shows it sitting on the desktop
    /// rather than cropped to its own edges.
    var margin: CGFloat = 18

    var body: some View {
        let line = scenario.timeline
        let size = WidgetMetrics.pointSize(for: scenario.family)
        let radius: CGFloat = scenario.family == .systemSmall ? 20 : 22

        // The BEFORE entry, for the whole clip. Everything that changes is
        // optimistic, which is precisely the claim being made.
        let entry = BangerEntry(date: Date(timeIntervalSince1970: 0),
                                state: .list(scenario.before))

        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        return ZStack {
            Color.black
            BangerWidgetView(entry: entry,
                             familyOverride: scenario.family,
                             captureTaskID: scenario.taskID,
                             capturePhase: CheckPhase(time: line.time(at: time)))
                .background { BangerContainerBackground() }
                .frame(width: size.width, height: size.height)
                .containerShape(shape)
                .clipShape(shape)
                .padding(margin)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Canvas size for a given scenario: the widget at its real point size plus the
    /// margin, squared off so a centre crop keeps the whole widget.
    static func canvasSize(for scenario: WidgetCaptureScenario, margin: CGFloat = 18) -> CGSize {
        let size = WidgetMetrics.pointSize(for: scenario.family)
        let side = max(size.width, size.height) + margin * 2
        return CGSize(width: side, height: side)
    }
}

// MARK: - A resting still

/// One resting widget, no transition: a list of `taskCount` tasks with `doneCount`
/// ticked, a given streak, drawn as of a given instant. Shows the streak pill
/// across its tiers and its at-risk state, which depends on the entry's date.
struct WidgetStillScenario {

    var taskCount: Int
    var doneCount: Int
    var streak: Int
    var family: WidgetFamily
    var now: Date
    /// The first row in view, for a list long enough to scroll. Nil is its resting place.
    var scrollOffset: Int? = nil
    /// A frame part of the way through a scroll that started with the window here.
    var scrollFrom: Int? = nil
    var scrollProgress: Double = 1
    /// A frame part of the way through checking this task off, `checkTime` seconds in.
    var checkIndex: Int? = nil
    var checkTime: Double = 0

    static let texts = ["Export authenticator codes", "Call the realtor", "Book the van",
                        "Mix down the B-side", "Renew the parking permit", "Reply to Dana",
                        "Back up the laptop", "Water the plants", "Pay the studio invoice",
                        "Order guitar strings", "Send the stems", "Stretch"]

    var day: WidgetDay {
        let tasks = (0..<taskCount).map { index in
            WidgetTask(id: "s\(index)", text: Self.texts[index % Self.texts.count],
                       done: index < doneCount, source: index % 3 == 1 ? "iris" : "me",
                       completedAt: index < doneCount ? Date(timeIntervalSince1970: Double(1_000 + index)) : nil)
        }
        return WidgetDay(dayKey: "still", tasks: tasks, streak: streak)
    }
}

struct WidgetStillFrame: View {

    var scenario: WidgetStillScenario
    var margin: CGFloat = 18

    var body: some View {
        let size = WidgetMetrics.pointSize(for: scenario.family)
        let radius: CGFloat = scenario.family == .systemSmall ? 20 : 22
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            Color.black
            BangerWidgetView(entry: BangerEntry(date: scenario.now, state: .list(scenario.day),
                                                scrollOffset: scenario.scrollOffset),
                             familyOverride: scenario.family,
                             captureTaskID: scenario.checkIndex.map { "s\($0)" },
                             capturePhase: scenario.checkIndex.map { _ in CheckPhase(time: scenario.checkTime) },
                             captureScroll: scenario.scrollFrom.map {
                                 CaptureScroll(from: $0, progress: scenario.scrollProgress)
                             })
                .background { BangerContainerBackground() }
                .frame(width: size.width, height: size.height)
                .containerShape(shape)
                .clipShape(shape)
                .padding(margin)
        }
        .environment(\.colorScheme, .dark)
    }

    @MainActor
    static func render(_ scenario: WidgetStillScenario, scale: CGFloat, margin: CGFloat, to url: URL) throws {
        let size = WidgetMetrics.pointSize(for: scenario.family)
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let renderer = ImageRenderer(
            content: WidgetStillFrame(scenario: scenario, margin: margin)
                .frame(width: canvas.width, height: canvas.height))
        renderer.scale = scale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(canvas)
        guard let image = renderer.cgImage else { throw WidgetCaptureError.renderFailed(0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WidgetCaptureError.writeFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WidgetCaptureError.writeFailed(url) }
    }
}

// MARK: - Renderer

/// Deliberately the same shape as bangerrender's FrameRenderer: derive each
/// frame's time from its index, render, write a PNG. No accumulated state, so a
/// render at 30 fps and a render at 60 fps are the same instants.
@MainActor
struct WidgetCaptureRenderer {

    var scenario: WidgetCaptureScenario
    var fps: Int
    var seconds: Double
    var scale: CGFloat
    var margin: CGFloat
    var outputDirectory: URL
    /// Seconds of the resting widget before the click, so the clip shows the resting
    /// look too; the springs simply evaluate to their start values at negative times.
    var preHold: Double = 0
    var framePrefix = "frame_"

    var frameCount: Int { max(1, Int((seconds * Double(fps)).rounded())) }

    func run() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for url in (try? manager.contentsOfDirectory(at: outputDirectory,
                                                     includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension.lowercased() == "png" && url.lastPathComponent.hasPrefix(framePrefix) {
            try? manager.removeItem(at: url)
        }

        let canvas = WidgetCaptureFrame.canvasSize(for: scenario, margin: margin)

        for index in 0..<frameCount {
            let time = Double(index) / Double(fps) - preHold
            let renderer = ImageRenderer(
                content: WidgetCaptureFrame(scenario: scenario, time: time, margin: margin)
                    .frame(width: canvas.width, height: canvas.height)
            )
            renderer.scale = scale
            renderer.isOpaque = true
            renderer.proposedSize = ProposedViewSize(canvas)

            guard let image = renderer.cgImage else {
                throw WidgetCaptureError.renderFailed(index)
            }
            let url = outputDirectory.appendingPathComponent(
                String(format: "%@%05d.png", framePrefix, index))
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw WidgetCaptureError.writeFailed(url)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw WidgetCaptureError.writeFailed(url)
            }
        }
    }
}

enum WidgetCaptureError: Error, CustomStringConvertible {
    case renderFailed(Int)
    case writeFailed(URL)

    var description: String {
        switch self {
        case .renderFailed(let frame): return "ImageRenderer produced no image for frame \(frame)"
        case .writeFailed(let url): return "could not write \(url.path)"
        }
    }
}
