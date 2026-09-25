//  SoundBank.swift — finds the celebration wavs, decodes them once, and pre-renders
//  the handful of pitch variants we ever use.
//
//  Why pre-render instead of pitching at play time: AVAudioUnitTimePitch is a
//  time-domain processor and carries tens of milliseconds of algorithmic latency.
//  This sound has to land on the click, so we cannot afford any. Resampling the
//  buffer up front costs a few milliseconds once, at launch, and leaves the play
//  path as nothing but `scheduleBuffer`.
//
//  Everything here is deterministic: same wav in, same buffers out, every launch.

import AVFoundation
import Foundation

/// The four celebration sounds, decoded and ready to schedule.
public final class SoundBank: @unchecked Sendable {

    /// Semitone-hundredths of upward shift available. The figure climbs through
    /// the day: an early task is the sound as written, the last one before the
    /// final-task tier sits a whole tone higher. Only ever upward, so a variant
    /// is never LONGER than the wav it came from (which would risk the audio
    /// outlasting the picture).
    public static let variantCents: [Double] = [0, 45, 90, 140, 190, 240]

    public struct Key: Hashable {
        public let tier: CelebrationTier
        public let variant: Int
    }

    public let format: AVAudioFormat
    private let buffers: [Key: AVAudioPCMBuffer]

    public init?(searchPaths: [URL] = SoundBank.defaultSearchPaths()) {
        var decoded: [CelebrationTier: AVAudioPCMBuffer] = [:]
        var fmt: AVAudioFormat?

        for tier in CelebrationTier.allCases {
            guard let url = SoundBank.locate(tier: tier, in: searchPaths),
                  let file = try? AVAudioFile(forReading: url) else { continue }
            let processing = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processing,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { continue }
            decoded[tier] = buffer
            if fmt == nil { fmt = processing }
        }

        guard let baseFormat = fmt, !decoded.isEmpty else { return nil }
        self.format = baseFormat

        var built: [Key: AVAudioPCMBuffer] = [:]
        for (tier, buffer) in decoded {
            for (i, cents) in SoundBank.variantCents.enumerated() {
                let shifted = cents == 0 ? buffer : SoundBank.resample(buffer, cents: cents)
                if let shifted { built[Key(tier: tier, variant: i)] = shifted }
            }
        }
        self.buffers = built
    }

    public func buffer(tier: CelebrationTier, variant: Int) -> AVAudioPCMBuffer? {
        let v = min(max(variant, 0), SoundBank.variantCents.count - 1)
        if let b = buffers[Key(tier: tier, variant: v)] { return b }
        if let b = buffers[Key(tier: tier, variant: 0)] { return b }
        // A tier whose file is missing still makes a noise rather than nothing.
        for fallback in CelebrationTier.allCases {
            if let b = buffers[Key(tier: fallback, variant: 0)] { return b }
        }
        return nil
    }

    // MARK: - Locating the files

    public static func defaultSearchPaths() -> [URL] {
        var paths: [URL] = []
        // 1. An explicit override, so the offscreen renderer and any test can
        //    point at a freshly synthesised set without reinstalling the app.
        if let override = ProcessInfo.processInfo.environment["BANGER_SOUNDS_DIR"] {
            paths.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        // 2. Inside the app bundle: Resources/ is a resource build phase of the
        //    Banger target, so the wavs land flat in Contents/Resources.
        if let res = Bundle.main.resourceURL {
            paths.append(res)
            paths.append(res.appendingPathComponent("sounds", isDirectory: true))
        }
        // 3. Inside BangerKit itself, if the wavs are ever moved into the framework.
        let kit = Bundle(for: BundleToken.self)
        if let res = kit.resourceURL {
            paths.append(res)
            paths.append(res.appendingPathComponent("sounds", isDirectory: true))
        }
        return paths
    }

    private static func locate(tier: CelebrationTier, in paths: [URL]) -> URL? {
        let name = "banger_\(tier.rawValue).wav"
        for dir in paths {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private final class BundleToken {}

    // MARK: - Pitch variants

    /// Linear-interpolated resample. Pitching up by `cents` also shortens the
    /// buffer by the same ratio, which is exactly what a harder strike does.
    static func resample(_ source: AVAudioPCMBuffer, cents: Double) -> AVAudioPCMBuffer? {
        let ratio = pow(2.0, cents / 1200.0)          // > 1 == higher and shorter
        guard ratio > 0, let src = source.floatChannelData else { return nil }
        let srcFrames = Int(source.frameLength)
        guard srcFrames > 1 else { return nil }
        let dstFrames = max(1, Int(Double(srcFrames) / ratio))
        guard let out = AVAudioPCMBuffer(pcmFormat: source.format,
                                         frameCapacity: AVAudioFrameCount(dstFrames)),
              let dst = out.floatChannelData else { return nil }

        let channels = Int(source.format.channelCount)
        for ch in 0..<channels {
            let s = src[ch]
            let d = dst[ch]
            for i in 0..<dstFrames {
                let pos = Double(i) * ratio
                let i0 = Int(pos)
                if i0 + 1 >= srcFrames {
                    d[i] = s[srcFrames - 1]
                } else {
                    let frac = Float(pos - Double(i0))
                    d[i] = s[i0] + (s[i0 + 1] - s[i0]) * frac
                }
            }
        }
        out.frameLength = AVAudioFrameCount(dstFrames)
        return out
    }
}
