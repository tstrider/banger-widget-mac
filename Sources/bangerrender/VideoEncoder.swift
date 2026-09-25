//  VideoEncoder.swift — hands the PNG sequence to ffmpeg.

import Foundation

struct VideoEncoder {
    let options: RenderOptions

    func encode(frameCount: Int, to output: URL) throws {
        let ffmpeg = try resolveFFmpeg()

        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)

        let pattern = options.outputDirectory
            .appendingPathComponent("\(options.framePrefix)%05d.png").path

        // The frames carry straight alpha, so they are composited onto an explicit
        // colour before the yuv420p conversion. Dropping alpha instead would blow out
        // every transparent pixel to full-brightness colour.
        let arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-framerate", "\(options.fps)", "-start_number", "0", "-i", pattern,
            "-f", "lavfi", "-i",
            "color=c=\(options.backgroundLiteral):s=\(options.pixelWidth)x\(options.pixelHeight)",
            "-filter_complex",
            "[1:v][0:v]overlay=shortest=1:format=auto,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
            "-frames:v", "\(frameCount)",
            "-c:v", "libx264", "-preset", "medium", "-crf", "16",
            "-r", "\(options.fps)", "-movflags", "+faststart",
            output.path
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.ffmpegFailed(status: process.terminationStatus,
                                        output: String(decoding: data, as: UTF8.self))
        }
    }

    private func resolveFFmpeg() throws -> String {
        let candidate = options.ffmpeg
        if candidate.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: candidate) else {
                throw CLIError.ffmpegMissing(candidate)
            }
            return candidate
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in searchPath.split(separator: ":") {
            let path = "\(directory)/\(candidate)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw CLIError.ffmpegMissing(candidate)
    }
}
