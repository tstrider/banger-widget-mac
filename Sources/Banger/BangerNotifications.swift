//  BangerNotifications.swift — how a completion becomes a CelebrationConfig.
//
//  The notification NAMES live in BangerKit (enum BangerNotification), because the
//  poster and the listener have to agree and BangerKit is the only thing both the
//  widget extension and this app link against. This file only does the translation.
//
//  Nothing in here touches tasks.json. The App
//  Intent already knows everything about the completion it just wrote, so it hands
//  us the numbers in the notification and the agent never re-reads the file on the
//  hot path.

import Foundation
import CoreGraphics
import BangerKit

// MARK: - Lenient field access

/// Distributed notifications flatten everything to property-list types, and a
/// payload written by hand in a shell will send numbers as strings. Read both.
struct PayloadFields {
    private let raw: [String: Any]

    init(json: [String: Any]) { self.raw = json }

    func double(_ keys: String...) -> Double? {
        for key in keys {
            guard let value = raw[key] else { continue }
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String, let d = Double(s) { return d }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            guard let value = raw[key] else { continue }
            if let n = value as? NSNumber { return n.intValue }
            if let s = value as? String, let i = Int(s) { return i }
        }
        return nil
    }

    func uint64(_ keys: String...) -> UInt64? {
        for key in keys {
            guard let value = raw[key] else { continue }
            if let n = value as? NSNumber, n.int64Value >= 0 { return UInt64(n.int64Value) }
            if let s = value as? String, let u = UInt64(s) { return u }
        }
        return nil
    }

    func string(_ keys: String...) -> String? {
        for key in keys {
            guard let value = raw[key] else { continue }
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
        }
        return nil
    }

    /// Accepts all three shapes a sender might use: CGPoint's own Codable form,
    /// which is the two-element array [x, y]; a nested {"x":…, "y":…}; and flat
    /// originX / originY (or x / y) keys.
    func point(nested: String, flatX: String, flatY: String, shortX: String, shortY: String) -> CGPoint? {
        if let pair = raw[nested] as? [Any], pair.count == 2 {
            let inner = PayloadFields(json: ["x": pair[0], "y": pair[1]])
            if let x = inner.double("x"), let y = inner.double("y") { return CGPoint(x: x, y: y) }
        }
        if let nestedValue = raw[nested] as? [String: Any] {
            let inner = PayloadFields(json: nestedValue)
            if let x = inner.double("x"), let y = inner.double("y") { return CGPoint(x: x, y: y) }
        }
        if let x = double(flatX, shortX), let y = double(flatY, shortY) { return CGPoint(x: x, y: y) }
        return nil
    }
}

// MARK: - Building a config from a real completion

extension CelebrationConfig {

    /// The shipping path. BangerKit's TaskCompletionPayload is the one thing both
    /// the widget's App Intent and `bangerctl done` post, so both produce the same
    /// celebration for the same task on the same day — its `seed` is what makes the
    /// offscreen renderer able to reproduce what the user saw.
    ///
    /// Tier and intensity are derived here rather than sent, because escalation is
    /// a property of the celebration and not of the task list.
    @MainActor
    init(completion payload: TaskCompletionPayload) {
        let tier = CelebrationConfig.inferTier(taskIndex: payload.taskIndex,
                                               taskCount: payload.taskCount,
                                               remaining: payload.remaining,
                                               streakDays: payload.streakDays)
        self.init(
            intensity: CelebrationConfig.inferIntensity(tier: tier,
                                                        taskIndex: payload.taskIndex,
                                                        taskCount: payload.taskCount,
                                                        streakDays: payload.streakDays),
            tier: tier,
            // The widget cannot know where on screen it was dropped, so the burst
            // fires from where the widget normally sits: the top right corner.
            origin: ScreenGeometry.widgetHomeGlobalTopLeft,
            seed: payload.seed,
            taskIndex: payload.taskIndex,
            taskCount: payload.taskCount,
            remaining: payload.remaining,
            streakDays: payload.streakDays,
            source: payload.source
        )
    }

    /// Build from a loose debugCelebrate payload.
    ///
    /// `origin` comes out in GLOBAL top-left coordinates; the presenter converts
    /// it into the overlay window's space once it knows which screen to use.
    /// Anything the sender omits is derived deterministically — no clock, no
    /// unseeded randomness, so the same payload always produces the same frames.
    @MainActor
    init(payload fields: PayloadFields) {
        // Bounded before anything arithmetic touches them. These come off a
        // distributed notification or a banger:// URL, so any local process picks the
        // numbers, and `taskCount - taskIndex - 1` on Int.min is a trap rather than a
        // wrong answer. A real day has single digits in these; 100000 is not a limit
        // anyone can reach by using the app.
        let taskIndex = min(max(fields.int("taskIndex") ?? 0, 0), 100_000)
        let taskCount = min(max(1, fields.int("taskCount") ?? 1), 100_000)
        let remaining = min(max(fields.int("remaining") ?? max(0, taskCount - taskIndex - 1), 0), 100_000)
        let streakDays = min(max(fields.int("streakDays") ?? 0, 0), 100_000)
        let source = fields.string("source") ?? "me"

        let tier: CelebrationTier = fields.string("tier").flatMap(CelebrationTier.init(rawValue:))
            ?? CelebrationConfig.inferTier(taskIndex: taskIndex,
                                           taskCount: taskCount,
                                           remaining: remaining,
                                           streakDays: streakDays)

        let intensity = fields.double("intensity")
            ?? CelebrationConfig.inferIntensity(tier: tier,
                                                taskIndex: taskIndex,
                                                taskCount: taskCount,
                                                streakDays: streakDays)

        let seed = fields.uint64("seed") ?? CelebrationConfig.derivedSeed(
            taskID: fields.string("taskId", "id", "taskID") ?? "",
            taskIndex: taskIndex,
            taskCount: taskCount,
            streakDays: streakDays,
            source: source
        )

        let origin = fields.point(nested: "origin",
                                  flatX: "originX", flatY: "originY",
                                  shortX: "x", shortY: "y")
            ?? ScreenGeometry.widgetHomeGlobalTopLeft

        self.init(intensity: bangerClamp(intensity, 0, 1),
                  tier: tier,
                  origin: origin,
                  seed: seed,
                  taskIndex: taskIndex,
                  taskCount: taskCount,
                  remaining: remaining,
                  streakDays: streakDays,
                  source: source)
    }

    /// A complete CelebrationConfig as JSON decodes exactly; a partial one falls
    /// back to the lenient path so a one-line shell trigger stays one line.
    @MainActor
    init?(debugJSON data: Data) {
        if let exact = try? JSONDecoder().decode(CelebrationConfig.self, from: data) {
            self = exact
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any], !dictionary.isEmpty else { return nil }
        self.init(payload: PayloadFields(json: dictionary))
    }

    /// banger://celebrate?tier=streak&intensity=1&x=2400&y=140
    /// banger://celebrate?json=%7B...%7D
    @MainActor
    init?(debugURL url: URL) {
        guard url.scheme?.lowercased() == "banger" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var values: [String: Any] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            if item.name == "json", let data = value.data(using: .utf8),
               let config = CelebrationConfig(debugJSON: data) {
                self = config
                return
            }
            values[item.name] = value
        }
        guard !values.isEmpty else { return nil }
        self.init(payload: PayloadFields(json: values))
    }

    // MARK: Derivations

    /// Fallback escalation, used only when the sender did not specify a tier.
    static func inferTier(taskIndex: Int, taskCount: Int, remaining: Int, streakDays: Int) -> CelebrationTier {
        if remaining <= 0 && streakDays > 0 { return .streak }
        if remaining <= 0 { return .finalTask }
        // Double(taskIndex) + 1, not Double(taskIndex + 1): the addition in Int traps
        // at Int.max and these numbers can arrive from another process.
        let progress = (Double(taskIndex) + 1) / Double(max(1, taskCount))
        return progress >= 0.6 ? .building : .standard
    }

    static func inferIntensity(tier: CelebrationTier, taskIndex: Int, taskCount: Int, streakDays: Int) -> Double {
        let progress = (Double(taskIndex) + 1) / Double(max(1, taskCount))
        let base: Double
        switch tier {
        case .standard:  base = 0.38
        case .building:  base = 0.62
        case .finalTask: base = 0.86
        case .streak:    base = 0.94 + min(0.06, Double(streakDays) * 0.01)
        }
        return bangerClamp(base + progress * 0.08, 0, 1)
    }

    /// FNV-1a. Swift's own Hasher is randomly seeded per process, which would
    /// make the same completion render differently on every launch.
    static func derivedSeed(taskID: String, taskIndex: Int, taskCount: Int,
                            streakDays: Int, source: String) -> UInt64 {
        let key = "\(taskID)|\(taskIndex)|\(taskCount)|\(streakDays)|\(source)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
