//  RenderOptions.swift — command line surface for bangerrender.

import CoreGraphics
import Foundation
import SwiftUI

enum CLIError: Error, CustomStringConvertible {
    case help
    case missingValue(String)
    case badValue(flag: String, value: String, expected: String)
    case unknownFlag(String)
    case missingRequired(String)
    case renderFailed(frame: Int)
    case pngWriteFailed(URL)
    case ffmpegMissing(String)
    case ffmpegFailed(status: Int32, output: String)

    var description: String {
        switch self {
        case .help:
            return RenderOptions.usage
        case .missingValue(let flag):
            return "\(flag) needs a value"
        case .badValue(let flag, let value, let expected):
            return "\(flag): '\(value)' is not \(expected)"
        case .unknownFlag(let flag):
            return "unknown option '\(flag)' (try --help)"
        case .missingRequired(let flag):
            return "\(flag) is required"
        case .renderFailed(let frame):
            return "ImageRenderer produced no image for frame \(frame)"
        case .pngWriteFailed(let url):
            return "could not write \(url.path)"
        case .ffmpegMissing(let path):
            return "ffmpeg not found at '\(path)' — source tools/env.sh or pass --ffmpeg"
        case .ffmpegFailed(let status, let output):
            return "ffmpeg exited \(status)\n\(output)"
        }
    }
}

struct RenderOptions {
    var outputDirectory: URL
    var framePrefix = "frame_"
    var fps = 60
    var seconds = 2.4
    var pixelWidth = 1512
    var pixelHeight = 982
    var scale: CGFloat = 1
    /// nil means a transparent background (straight alpha in the PNGs).
    var background: Color? = .black
    /// What the mp4 composites onto, as an ffmpeg colour literal.
    var backgroundLiteral = "0x000000"
    var keepPNGs = true
    var mp4: URL?
    var ffmpeg: String
    var quiet = false
    var config = CelebrationConfig()

    var isOpaque: Bool { background != nil }
    var frameCount: Int { max(1, Int((seconds * Double(fps)).rounded())) }
    var pointSize: CGSize { CGSize(width: Double(pixelWidth) / Double(scale),
                                   height: Double(pixelHeight) / Double(scale)) }

    static let usage = """
    bangerrender — render the Banger celebration offscreen, frame by frame.

    USAGE
      bangerrender --out <dir> [options]

    OUTPUT
      --out <dir>          directory for frame_00000.png ...   (required)
      --png-sequence       keep the PNGs (default unless --mp4 is given alone)
      --mp4 <path>         also encode H.264 / yuv420p to <path>
      --prefix <str>       frame filename prefix (default: frame_)
      --ffmpeg <path>      ffmpeg binary (default: $FFMPEG, then ffmpeg on PATH)

    TIMING
      --fps <n>            output frames per second (default: 60)
      --seconds <s>        simulated duration (default: 2.4)

    GEOMETRY
      --width <px>         output pixel width  (default: 1512)
      --height <px>        output pixel height (default: 982)
      --scale <f>          points -> pixels factor (default: 1)
      --bg <hex|none>      background: RRGGBB, #RRGGBB, or none/clear (default: 000000)

    CELEBRATION
      --tier <t>           standard | building | finalTask | streak
      --intensity <0..1>   master dial (default: 0.5)
      --origin-x <0..1>    burst origin, fraction of width  (default: 0.8)
      --origin-y <0..1>    burst origin, fraction of height (default: 0.18)
      --seed <u64>         deterministic seed (default: 12345)
      --task-index <n>     0-based index of the completed task
      --task-count <n>     tasks today
      --remaining <n>      tasks still open after this one
      --streak-days <n>    consecutive full-clear days before today
      --source <str>       thomas | iris | other

    MISC
      --quiet              only print the summary
      --help               this text
    """

    static func parse(_ arguments: [String]) throws -> RenderOptions {
        var outPath: String?
        var mp4Path: String?
        var explicitKeepPNGs = false
        var sawMP4 = false

        var fps = 60
        var seconds = 2.4
        var width = 1512
        var height = 982
        var scale: CGFloat = 1
        var bgSpec = "000000"
        var prefix = "frame_"
        var quiet = false
        var ffmpeg = ProcessInfo.processInfo.environment["FFMPEG"] ?? "ffmpeg"

        var intensity = 0.5
        var tier = CelebrationTier.standard
        var originX = 0.8
        var originY = 0.18
        var seed: UInt64 = 12345
        var taskIndex = 0
        var taskCount = 1
        var remaining = 0
        var streakDays = 0
        var source = "me"

        var i = 0
        func next(_ flag: String) throws -> String {
            i += 1
            guard i < arguments.count else { throw CLIError.missingValue(flag) }
            return arguments[i]
        }
        func nextInt(_ flag: String) throws -> Int {
            let raw = try next(flag)
            guard let v = Int(raw) else {
                throw CLIError.badValue(flag: flag, value: raw, expected: "an integer")
            }
            return v
        }
        func nextDouble(_ flag: String) throws -> Double {
            let raw = try next(flag)
            guard let v = Double(raw) else {
                throw CLIError.badValue(flag: flag, value: raw, expected: "a number")
            }
            return v
        }

        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--help", "-h":       throw CLIError.help
            case "--out", "-o":        outPath = try next(arg)
            case "--prefix":           prefix = try next(arg)
            case "--png-sequence":     explicitKeepPNGs = true
            case "--mp4":              mp4Path = try next(arg); sawMP4 = true
            case "--ffmpeg":           ffmpeg = try next(arg)
            case "--fps":              fps = try nextInt(arg)
            case "--seconds":          seconds = try nextDouble(arg)
            case "--width":            width = try nextInt(arg)
            case "--height":           height = try nextInt(arg)
            case "--scale":            scale = CGFloat(try nextDouble(arg))
            case "--bg":               bgSpec = try next(arg)
            case "--intensity":        intensity = try nextDouble(arg)
            case "--origin-x":         originX = try nextDouble(arg)
            case "--origin-y":         originY = try nextDouble(arg)
            case "--task-index":       taskIndex = try nextInt(arg)
            case "--task-count":       taskCount = try nextInt(arg)
            case "--remaining":        remaining = try nextInt(arg)
            case "--streak-days":      streakDays = try nextInt(arg)
            case "--source":           source = try next(arg)
            case "--quiet":            quiet = true
            case "--seed":
                let raw = try next(arg)
                guard let v = UInt64(raw) else {
                    throw CLIError.badValue(flag: arg, value: raw, expected: "an unsigned 64-bit integer")
                }
                seed = v
            case "--tier":
                let raw = try next(arg)
                guard let t = CelebrationTier(rawValue: raw) else {
                    let all = CelebrationTier.allCases.map(\.rawValue).joined(separator: " | ")
                    throw CLIError.badValue(flag: arg, value: raw, expected: "one of: \(all)")
                }
                tier = t
            default:
                throw CLIError.unknownFlag(arg)
            }
            i += 1
        }

        guard let outPath else { throw CLIError.missingRequired("--out") }
        guard fps > 0 else { throw CLIError.badValue(flag: "--fps", value: "\(fps)", expected: "positive") }
        guard seconds > 0 else { throw CLIError.badValue(flag: "--seconds", value: "\(seconds)", expected: "positive") }
        guard width > 0, height > 0 else {
            throw CLIError.badValue(flag: "--width/--height", value: "\(width)x\(height)", expected: "positive")
        }
        guard scale > 0 else { throw CLIError.badValue(flag: "--scale", value: "\(scale)", expected: "positive") }

        let (color, literal) = try Self.background(from: bgSpec)

        var options = RenderOptions(
            outputDirectory: URL(fileURLWithPath: outPath).standardizedFileURL,
            ffmpeg: ffmpeg
        )
        options.framePrefix = prefix
        options.fps = fps
        options.seconds = seconds
        options.pixelWidth = width
        options.pixelHeight = height
        options.scale = scale
        options.background = color
        options.backgroundLiteral = literal
        options.mp4 = mp4Path.map { URL(fileURLWithPath: $0).standardizedFileURL }
        // Encoding to mp4 without asking for stills means the stills are scratch.
        options.keepPNGs = explicitKeepPNGs || !sawMP4
        options.quiet = quiet

        options.config = CelebrationConfig(
            intensity: intensity,
            tier: tier,
            origin: CGPoint(x: originX * Double(width) / Double(scale),
                            y: originY * Double(height) / Double(scale)),
            seed: seed,
            taskIndex: taskIndex,
            taskCount: taskCount,
            remaining: remaining,
            streakDays: streakDays,
            source: source
        )
        return options
    }

    /// Returns the SwiftUI colour to paint behind the scene, and the matching ffmpeg
    /// colour literal the mp4 composites onto.
    private static func background(from spec: String) throws -> (Color?, String) {
        let lowered = spec.lowercased()
        if lowered == "none" || lowered == "clear" || lowered == "transparent" {
            // PNGs keep their alpha; the video still has to land on something.
            return (nil, "0x000000")
        }
        var hex = lowered
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt32(hex, radix: 16) else {
            throw CLIError.badValue(flag: "--bg", value: spec, expected: "RRGGBB, RRGGBBAA, or none")
        }
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        let rgb = String(hex.prefix(6))
        return (Color(.sRGB, red: r, green: g, blue: b, opacity: a), "0x\(rgb)")
    }
}
