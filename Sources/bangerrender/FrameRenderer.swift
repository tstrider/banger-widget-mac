//  FrameRenderer.swift — steps the scene and renders each output frame offscreen.
//
//  The only reason this file exists is to advance time. The pixels come from
//  CelebrationFrameView, which is the same Canvas + CelebrationScene.draw the live
//  overlay runs, so the frames written here are the frames the user will see.

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct RenderSummary: Sendable {
    var frameCount: Int
    var directory: URL
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
    var mp4: URL?
    var keptPNGs: Bool
}

@MainActor
struct FrameRenderer {
    let options: RenderOptions

    func run() throws -> RenderSummary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        try clearStaleFrames(in: options.outputDirectory, using: fileManager)

        var scene = CelebrationScene.make(config: options.config)
        var stepsTaken = 0

        let frameCount = options.frameCount
        let pointSize = options.pointSize

        for frame in 0..<frameCount {
            // Derive the step count from the frame's absolute time rather than
            // accumulating per-frame steps. This is what makes the output
            // fps-independent: frame 30 at 60 fps and frame 15 at 30 fps are the
            // same simulated instant and therefore the same pixels.
            let targetTime = Double(frame) / Double(options.fps)
            let wantedSteps = Int((targetTime + 1e-9) / celebrationTimestep)
            while stepsTaken < wantedSteps {
                scene.step(dt: celebrationTimestep)
                stepsTaken += 1
            }

            let image = try render(scene: scene, pointSize: pointSize, frame: frame)
            let url = options.outputDirectory.appendingPathComponent(
                String(format: "%@%05d.png", options.framePrefix, frame))
            try writePNG(image, to: url)

            if !options.quiet, frame % 24 == 0 || frame == frameCount - 1 {
                print("  frame \(frame + 1)/\(frameCount)")
            }
        }

        var summary = RenderSummary(
            frameCount: frameCount,
            directory: options.outputDirectory,
            pixelWidth: options.pixelWidth,
            pixelHeight: options.pixelHeight,
            duration: Double(frameCount) / Double(options.fps),
            mp4: nil,
            keptPNGs: options.keepPNGs
        )

        if let mp4 = options.mp4 {
            try VideoEncoder(options: options).encode(frameCount: frameCount, to: mp4)
            summary.mp4 = mp4
        }

        if !options.keepPNGs {
            try? clearStaleFrames(in: options.outputDirectory, using: fileManager)
        }

        return summary
    }

    // MARK: - One frame

    private func render(scene: CelebrationScene, pointSize: CGSize, frame: Int) throws -> CGImage {
        let renderer = ImageRenderer(
            content: CelebrationFrameView(scene: scene, background: options.background)
                .frame(width: pointSize.width, height: pointSize.height)
        )
        renderer.scale = options.scale
        renderer.isOpaque = options.isOpaque
        renderer.colorMode = CelebrationRendering.colorMode
        renderer.proposedSize = ProposedViewSize(pointSize)

        guard let image = renderer.cgImage else { throw CLIError.renderFailed(frame: frame) }
        return image
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CLIError.pngWriteFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.pngWriteFailed(url)
        }
    }

    /// A shorter render must not leave a longer render's tail behind, or the mp4
    /// encode and every frame-count check downstream silently picks up stale frames.
    private func clearStaleFrames(in directory: URL, using fileManager: FileManager) throws {
        let contents = (try? fileManager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension.lowercased() == "png"
            && url.lastPathComponent.hasPrefix(options.framePrefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}
