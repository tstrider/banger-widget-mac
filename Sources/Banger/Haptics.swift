//  Haptics.swift — the trackpad thump.
//
//  WHAT IS KNOWN AND WHAT IS NOT, stated up front because the rest of this file
//  depends on the difference.
//
//  KNOWN:
//    * `NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime:)`
//      returns in microseconds and never throws, including on a Mac with NO Force
//      Touch trackpad. With no AppleMultitouchDevice in the IORegistry there is no
//      actuator for the call to reach, so it is a silent no-op and degrades
//      correctly: nothing to guard, nothing to catch, nothing to stall on.
//    * The call therefore cannot be on the critical path for the first frame: the
//      haptic goes out BEFORE the overlay's frame zero is drawn.
//
//  NOT KNOWABLE FROM CODE, and so not asserted:
//    * Which of `.generic` / `.alignment` / `.levelChange` reads as a thump rather
//      than a tick, and whether two pulses 12 ms apart fuse into one heavier hit.
//      There is no read-back channel from the actuator. What this file does instead
//      is make the choice a single named constant with an environment override, so
//      the question is answered by feel in thirty seconds on a machine that has a
//      trackpad:
//
//          BANGER_HAPTIC_PATTERN=generic   open -a Banger
//          BANGER_HAPTIC_PATTERN=alignment open -a Banger
//          BANGER_HAPTIC_PATTERN=levelChange open -a Banger   # the default
//          BANGER_HAPTIC_FUSION_MS=12                          # try 0, 12, 30, 90
//
//      The default is `.levelChange` because it is the only one of the three that
//      Apple documents as a two-stage event (the detent you feel in a slider),
//      which is the heaviest single thing the API exposes. That is a reason, not a
//      measurement, and it is labelled as such.
//
//  TIMING RULE: the first pulse is dispatched synchronously on the same call stack
//  that builds the overlay window, before anything is drawn. Never scheduled,
//  never dispatched async, never on a timer. Late is unrecoverable; a few
//  milliseconds early reads as the click.

import AppKit
import BangerKit
import Foundation
import IOKit

@MainActor
enum BangerHaptics {

    // MARK: - Tuning

    /// Which AppKit pattern one pulse maps to. See the header: chosen by argument,
    /// overridable by environment, trivially A/B-able on real hardware.
    static let pattern: NSHapticFeedbackManager.FeedbackPattern = {
        switch ProcessInfo.processInfo.environment["BANGER_HAPTIC_PATTERN"]?.lowercased() {
        case "generic":   return .generic
        case "alignment": return .alignment
        default:          return .levelChange
        }
    }()

    /// Spacing between the pulses inside one fused hit, seconds.
    static let fusionGap: Double = {
        if let raw = ProcessInfo.processInfo.environment["BANGER_HAPTIC_FUSION_MS"],
           let ms = Double(raw), ms >= 0, ms <= 400 {
            return ms / 1000
        }
        return HapticPlan.fusionGap
    }()

    /// Turned off wholesale by `BANGER_HAPTICS=0`, for recording sessions.
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["BANGER_HAPTICS"] != "0"

    // MARK: - Hardware

    /// True when this Mac has something that can actually actuate.
    ///
    /// Not used as a gate — `perform` is already a safe no-op without hardware, and
    /// gating on a probe would add a failure mode where the probe is wrong and the
    /// thump silently stops. It exists so diagnostics can say which case they are
    /// measuring, and so a future settings pane can tell the truth.
    static let hasActuator: Bool = probeActuator()

    private static func probeActuator() -> Bool {
        // A built-in or paired Force Touch trackpad shows up as an
        // AppleMultitouchDevice advertising actuation. Magic Trackpad 2 and the
        // built-in trackpads both do; a mouse and a desktop Mac do not.
        if serviceExists("AppleMultitouchDevice", requiringTrueProperty: "ActuationSupported") {
            return true
        }
        // Newer stacks expose the actuator on its own node.
        if serviceExists("AppleHIDHapticDevice", requiringTrueProperty: nil) { return true }
        return false
    }

    private static func serviceExists(_ className: String,
                                      requiringTrueProperty property: String?) -> Bool {
        guard let matching = IOServiceMatching(className) else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }

        var found = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if let property {
                let value = IORegistryEntryCreateCFProperty(service, property as CFString,
                                                            kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool
                if value == true { found = true }
            } else {
                found = true
            }
            IOObjectRelease(service)
            if found { break }
        }
        return found
    }

    // MARK: - Instrumentation

    /// Called immediately after every physical `perform`, with the pulse index and
    /// the monotonic timestamp of the call. A trace harness installs a hook
    /// here rather than re-implementing the scheduling, so what it measures is
    /// what actually ships.
    nonisolated(unsafe) static var onPerform: ((Int, UInt64) -> Void)?

    private static var pending: [DispatchWorkItem] = []
    private static var pulseIndex = 0

    // MARK: - Firing

    /// Fire the whole plan for a completion.
    ///
    /// The pulse at offset 0 happens inside this call, synchronously. Everything
    /// later is dispatched on the main queue; those pulses are decoration, and a
    /// millisecond of jitter on them is invisible.
    static func fire(config: CelebrationConfig) {
        cancel()
        guard isEnabled else { return }
        pulseIndex = 0

        for pulse in HapticPlan.pulses(for: config) {
            for index in 0..<pulse.weight.pulseCount {
                let offset = pulse.offset + Double(index) * fusionGap
                if offset <= 0 {
                    perform()
                } else {
                    schedule(after: offset)
                }
            }
        }
    }

    /// One hit, right now, with no plan behind it. Used by the hotkey demo and by
    /// the trace harness.
    static func strike(_ weight: HapticWeight = .thump) {
        guard isEnabled else { return }
        for index in 0..<weight.pulseCount {
            if index == 0 {
                perform()
            } else {
                schedule(after: Double(index) * fusionGap)
            }
        }
    }

    /// Drop anything still scheduled. Called when the celebration is skipped, so a
    /// dismissed burst cannot keep tapping at the hand after it is off screen.
    static func cancel() {
        for item in pending { item.cancel() }
        pending.removeAll(keepingCapacity: true)
    }

    // MARK: - The actual call

    private static func schedule(after delay: Double) {
        let item = DispatchWorkItem { perform() }
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private static func perform() {
        // No `try`, no error, no completion handler: AppKit's performer is a
        // fire-and-forget void call that does nothing when there is no actuator.
        // Anything wrapped around it would be theatre.
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        let index = pulseIndex
        pulseIndex += 1
        onPerform?(index, DispatchTime.now().uptimeNanoseconds)
    }
}
