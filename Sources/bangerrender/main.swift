//  main.swift — bangerrender entry point.
//
//  Headless by design: an .accessory activation policy means no Dock icon, no menu
//  bar, no window, and no stolen focus, so this is safe to run from an agent while
//  someone else is using the machine. NSApplication is still brought up because
//  ImageRenderer draws through AppKit and wants a live app object; the run loop is
//  never started, so the tool does its work synchronously and exits.

import AppKit
import Foundation

let exitCode: Int32 = MainActor.assumeIsolated { () -> Int32 in
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
        let options = try RenderOptions.parse(arguments)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        if !options.quiet {
            print("bangerrender: \(options.frameCount) frames, "
                  + "\(options.pixelWidth)x\(options.pixelHeight) @\(options.fps)fps, "
                  + "tier=\(options.config.tier.rawValue) "
                  + "intensity=\(options.config.intensity) seed=\(options.config.seed)")
        }

        let started = Date()
        let summary = try FrameRenderer(options: options).run()
        let wall = Date().timeIntervalSince(started)

        print("frames: \(summary.frameCount)")
        print("size: \(summary.pixelWidth)x\(summary.pixelHeight)")
        print("duration: \(String(format: "%.3f", summary.duration))s")
        print("pngs: \(summary.keptPNGs ? summary.directory.path : "(discarded)")")
        if let mp4 = summary.mp4 { print("mp4: \(mp4.path)") }
        print("wall: \(String(format: "%.1f", wall))s")
        return 0

    } catch CLIError.help {
        print(RenderOptions.usage)
        return 0
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("bangerrender: \(error.description)\n".utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("bangerrender: \(error)\n".utf8))
        return 1
    }
}

exit(exitCode)
