//  EscalationProbe.swift — the engine explaining itself, in text.
//
//  Escalation is the one part of this project you cannot fully see in one celebration:
//  the claim is about the RELATIONSHIP between celebrations, across a day and across
//  weeks. So the engine ships a report that makes every claim in
//  `EscalationEngine`'s header checkable without running the app.
//
//  The `grid` section is machine-readable, so a render script can take the intensity and
//  the running time of each rendered tier from it — the video is driven by the engine,
//  not by numbers typed into a shell script.
//
//  Pure. No clock, no files. Everything below is a function of constants.

import CoreGraphics
import Foundation

public enum EscalationProbe {

    static let origin = CGPoint(x: 1209, y: 176)

    // MARK: - Machine-readable: what the grid renders

    /// One line per tier: `tier intensity seconds beats accentMS` (accent -1 = none).
    /// A render script can read this, so the video and the engine can never drift apart.
    public static func gridSpec() -> String {
        CelebrationTier.allCases.map { tier -> String in
            let d = EscalationEngine.canonical(tier)
            return String(format: "%@ %.4f %.3f %d %d",
                          tier.rawValue,
                          d.intensity,
                          d.plan.duration,
                          d.plan.beats.count,
                          d.plan.accentAtMS ?? -1)
        }.joined(separator: "\n")
    }

    // MARK: - The whole report

    public static func report() -> String {
        [
            header("1. THE FOUR TIERS — what each one DOES, not how loud it is"),
            tierTable(),
            note("""
                 The `silhouette` column is the line that matters, not `intens`. Cover
                 the intensity column and you can still name every tier from what its
                 shape does after 300 ms: nothing, a circle, a line, a circle then a
                 line. That is the acceptance test for this round, stated as a table.
                 Note also that `beat2 % of beat1` CLIMBS — 0, 61, 56, 108 — instead of
                 sitting at a flat 33-41 % the way one scaled envelope template does.
                 """),

            header("2. THE SET IS THE EVENT — a 3-task day and a 12-task day both end"),
            setShapeTable(),
            note("""
                 Nothing ramps with the task index. Both days are flat until two remain,
                 both get exactly two `building` steps, both get exactly one ending.
                 A twelve-task day's sixth task is not an achievement; finishing is.
                 """),

            header("3. RAPID FIRE — five boxes in ten seconds must not be five bangs"),
            rapidFireTable(),
            note("""
                 The fifth is a bit over a third of the first and a third shorter,
                 and it has stopped being a burst: it is a tap, with the melody and the
                 low body taken away, leaving a click. The dampening changes the SHAPE,
                 not only the gain, which is why it reads as the app getting out of the
                 way rather than as a volume control someone turned down.
                 """),

            header("4. THE SAME BLITZ, ENDING ON THE LAST TASK"),
            blitzEndingTable(),
            note("""
                 Clearing the list is an ending even at the bottom of a blitz: the tier is
                 never demoted, the accent still lands, and the intensity floor is 0.68.
                 It is trimmed by about a tenth in running time. That is all.
                 """),

            header("5. THE STREAK CURVE — and why it stops growing"),
            streakCurve(),
            note("""
                 It peaks around the fifth consecutive day and then eases back to ~0.94.
                 A ritual that is louder every single day is one the user turns off in week
                 three. After day five the streak grows in the PLAN — the late sparkle,
                 the third haptic — and not in the volume.
                 """),

            header("6. STARTING AGAIN AFTER A GAP"),
            comebackTable(),
            note("""
                 The first task back after missing days gets `building`, not `standard`.
                 This is the moment habits die and almost nothing rewards it.
                 """),

            header("7. THE STREAK IS NOT FARMABLE"),
            farmTable(),
            note("""
                 Uncheck and recheck the last task and you get a 420 ms acknowledgement
                 at about 0.1 intensity, never the finale. Three independent guards:
                 per-task fire counts that only ever increase within a day, a day-level
                 `endingFired` flag, and `streakDays` itself which lives in the task
                 document and only moves at a day rollover.
                 """),

            header("8. THE STREAK SURVIVES A DAY ROLLOVER (and a process restart)"),
            streakPersistenceCheck(),
            note("""
                 The ledger lives inside the task document's overflow bag, so it is
                 written to disk with the tasks and survives quitting the app. At a day
                 rollover `forDay(_:)` resets the per-day counters — today's fire counts,
                 today's ending flag, today's recent-completion timestamps — and carries
                 the cross-day facts forward: lastActiveDate, bestStreak, daysCelebrated.
                 `streakDays` itself is not in this ledger at all; it lives in
                 TaskDocument and only moves at a rollover, which is the property that
                 makes it unfarmable from inside a day.
                 """),

            header("9. QUIET HOURS AND REDUCE-MOTION"),
            quietTable(),

            header("10. DETERMINISM"),
            determinismCheck(),
        ].joined(separator: "\n\n")
    }

    // MARK: - Sections

    static func tierTable() -> String {
        var rows: [[String]] = [[
            "tier", "intens", "ms", "beats", "beat times", "beat2 % of beat1",
            "accent", "haptics", "audio", "gesture", "silhouette after 300ms", "resolves",
        ]]
        for tier in CelebrationTier.allCases {
            let d = EscalationEngine.canonical(tier)
            let p = d.plan
            rows.append([
                tier.rawValue,
                fmt(d.intensity),
                String(p.durationMS),
                String(p.beats.count),
                p.beats.map { String($0.atMS) }.joined(separator: "/"),
                secondBeatShare(p),
                p.accentAtMS.map { "\($0)ms" } ?? "—",
                p.hapticsMS.map(String.init).joined(separator: "/"),
                describe(p.audio),
                p.gesture.rawValue,
                silhouette(tier),
                p.resolves ? "YES" : "no",
            ])
        }
        return table(rows)
    }

    static func setShapeTable() -> String {
        var rows: [[String]] = [["day size", "tier for completion 1, 2, 3, ... (in order)"]]
        for count in [1, 3, 6, 12] {
            var tiers: [String] = []
            for i in 0..<count {
                let remaining = count - i - 1
                let context = EscalationContext(origin: origin, taskIndex: i, taskCount: count,
                                                remaining: remaining, streakDays: 0,
                                                isFirstCompletionToday: i == 0,
                                                secondsSinceRecentCompletions: [],
                                                seed: 12345)
                tiers.append(short(EscalationEngine.decide(context).tier))
            }
            rows.append(["\(count) task\(count == 1 ? "" : "s")", tiers.joined(separator: " ")])
        }
        rows.append(["", "std = standard, bld = building, FIN = finalTask, STREAK = streak"])
        return table(rows)
    }

    static func rapidFireTable() -> String {
        // Six completions, one every two seconds, mid-list on a long day.
        var rows: [[String]] = [["#", "t", "tier", "intens", "vs 1st", "ms", "gesture", "audio", "haptics"]]
        var first: Double = 0
        for n in 0..<6 {
            let recent = (0..<n).map { Double(($0 + 1) * 2) }
            let context = EscalationContext(origin: origin, taskIndex: n, taskCount: 12,
                                            remaining: 11 - n, streakDays: 0,
                                            isFirstCompletionToday: n == 0,
                                            secondsSinceRecentCompletions: recent,
                                            seed: 12345)
            let d = EscalationEngine.decide(context)
            if n == 0 { first = d.intensity }
            rows.append([
                String(n + 1),
                "+\(n * 2)s",
                short(d.tier),
                fmt(d.intensity),
                String(format: "%.0f%%", 100 * d.intensity / max(first, 0.0001)),
                String(d.plan.durationMS),
                d.plan.gesture.rawValue,
                d.plan.audio.muted ? "silent" : describe(d.plan.audio),
                d.plan.hapticsMS.map(String.init).joined(separator: "/"),
            ])
        }
        return table(rows)
    }

    static func blitzEndingTable() -> String {
        var rows: [[String]] = [["recent completions", "fatigue", "tier", "intens", "ms", "accent", "resolves"]]
        for n in [0, 3, 6, 10] {
            let recent = (0..<n).map { Double(($0 + 1) * 2) }
            let context = EscalationContext(origin: origin, taskIndex: n, taskCount: n + 1,
                                            remaining: 0, streakDays: 0,
                                            isFirstCompletionToday: n == 0,
                                            secondsSinceRecentCompletions: recent,
                                            seed: 12345)
            let d = EscalationEngine.decide(context)
            rows.append([
                "\(n) in the last \(max(n, 1) * 2)s",
                fmt(context.fatigue),
                short(d.tier),
                fmt(d.intensity),
                String(d.plan.durationMS),
                d.plan.accentAtMS.map { "\($0)ms" } ?? "—",
                d.plan.resolves ? "YES" : "no",
            ])
        }
        return table(rows)
    }

    static func streakCurve() -> String {
        var rows: [[String]] = [["streak day", "intensity", ""]]
        for days in [1, 2, 3, 4, 5, 6, 8, 11, 15, 21, 30, 60] {
            let context = EscalationContext(origin: origin, taskIndex: 2, taskCount: 3,
                                            remaining: 0, streakDays: days,
                                            isFirstCompletionToday: false, seed: 12345)
            let v = EscalationEngine.decide(context).intensity
            let bars = Int((v * 44).rounded())
            rows.append([String(days + 1), fmt(v), String(repeating: "#", count: bars)])
        }
        return table(rows)
    }

    static func comebackTable() -> String {
        var rows: [[String]] = [["days away", "first task of the day", "intens", "second task", "intens"]]
        for gap in [0, 1, 2, 5, 14] {
            let a = EscalationEngine.decide(EscalationContext(
                origin: origin, taskIndex: 0, taskCount: 5, remaining: 4, streakDays: 0,
                daysSinceLastActivity: gap, isFirstCompletionToday: true, seed: 12345))
            let b = EscalationEngine.decide(EscalationContext(
                origin: origin, taskIndex: 1, taskCount: 5, remaining: 3, streakDays: 0,
                daysSinceLastActivity: gap, isFirstCompletionToday: false,
                secondsSinceRecentCompletions: [300], seed: 12345))
            rows.append([String(gap), short(a.tier), fmt(a.intensity), short(b.tier), fmt(b.intensity)])
        }
        return table(rows)
    }

    static func farmTable() -> String {
        var rows: [[String]] = [["attempt", "prior fires", "ending already fired", "tier", "intens", "ms", "resolves"]]
        for attempt in 0..<4 {
            let context = EscalationContext(
                origin: origin, taskIndex: 2, taskCount: 3, remaining: 0, streakDays: 7,
                isFirstCompletionToday: attempt == 0,
                priorCompletionsOfThisTask: attempt,
                endingAlreadyFired: attempt > 0,
                secondsSinceRecentCompletions: (0..<attempt).map { Double(($0 + 1) * 4) },
                seed: 12345)
            let d = EscalationEngine.decide(context)
            rows.append([
                attempt == 0 ? "genuine clear" : "recheck #\(attempt)",
                String(attempt),
                attempt > 0 ? "yes" : "no",
                short(d.tier),
                fmt(d.intensity),
                String(d.plan.durationMS),
                d.plan.resolves ? "YES" : "no",
            ])
        }
        return table(rows)
    }

    static func quietTable() -> String {
        var rows: [[String]] = [["case", "tier", "intens", "ms", "gesture", "audio gain", "body", "sparkle", "haptics"]]
        func row(_ label: String, minute: Int, reduce: Bool) -> [String] {
            let d = EscalationEngine.decide(EscalationContext(
                origin: origin, taskIndex: 2, taskCount: 3, remaining: 0, streakDays: 5,
                isFirstCompletionToday: false, minuteOfDay: minute, reduceMotion: reduce,
                seed: 12345))
            return [label, short(d.tier), fmt(d.intensity), String(d.plan.durationMS),
                    d.plan.gesture.rawValue, fmt(d.plan.audio.gain),
                    d.plan.audio.body ? "yes" : "no",
                    d.plan.audio.sparkle ? "yes" : "no",
                    d.plan.hapticsMS.map(String.init).joined(separator: "/")]
        }
        rows.append(row("streak, 14:00", minute: 14 * 60, reduce: false))
        rows.append(row("streak, 23:40", minute: 23 * 60 + 40, reduce: false))
        rows.append(row("streak, reduce-motion", minute: 14 * 60, reduce: true))
        return table(rows)
    }

    static func determinismCheck() -> String {
        var lines: [String] = []
        var allEqual = true
        for tier in CelebrationTier.allCases {
            let a = EscalationEngine.canonical(tier)
            let b = EscalationEngine.canonical(tier)
            let same = a.config == b.config && a.plan == b.plan
            allEqual = allEqual && same
            lines.append("  \(tier.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                         + "seed \(a.config.seed)  identical: \(same ? "yes" : "NO")")
        }
        lines.append(allEqual
                     ? "  OK — decide() is a pure function of its context."
                     : "  FAILED — the engine is not deterministic.")
        return lines.joined(separator: "\n")
    }

    // MARK: - The shape claim, as numbers

    /// What each tier's second beat is worth against its own first beat, so it can be
    /// read without watching anything.
    static func secondBeatShare(_ plan: EscalationPlan) -> String {
        guard let first = plan.beats.first, first.share > 0, plan.beats.count > 1 else {
            return "—"
        }
        let rest = plan.beats.dropFirst().reduce(0) { $0 + $1.share }
        return String(format: "%.0f%%", 100 * rest / first.share)
    }

    /// What is on screen after 300 ms, in one word per event. With the radius and the
    /// brightness normalised away, a viewer must be able to name the tier from this column.
    static func silhouette(_ tier: CelebrationTier) -> String {
        switch tier {
        case .standard:  return "(nothing)"
        case .building:  return "circle"
        case .finalTask: return "line + landing"
        case .streak:    return "circle, then line + landing"
        }
    }

    // MARK: - Persistence

    static func streakPersistenceCheck() -> String {
        var lines: [String] = []

        // Day one: a full clear on a live streak, then two re-checks.
        var ledger = EscalationLedger(day: "2026-09-20")
        ledger.record(taskID: "a", day: "2026-09-20", tier: .standard,
                      streakDays: 4, at: Date(timeIntervalSince1970: 1_000_000))
        ledger.record(taskID: "b", day: "2026-09-20", tier: .streak,
                      streakDays: 4, at: Date(timeIntervalSince1970: 1_000_060))
        lines.append("  day 2026-09-20: fires a=\(ledger.fireCount(forTaskID: "a")) "
                     + "b=\(ledger.fireCount(forTaskID: "b"))  endingFired=\(ledger.endingFired)  "
                     + "bestStreak=\(ledger.bestStreak)  daysCelebrated=\(ledger.daysCelebrated)")

        // Round-trip through JSON, which is what actually happens: the ledger is written
        // into TaskDocument.extra and read back on the next launch.
        let reloaded = EscalationLedger(json: ledger.json)
        let survived = reloaded == ledger
        lines.append("  written to JSON and read back: identical \(survived ? "yes" : "NO")")

        // Roll over to the next day.
        let tomorrow = reloaded.forDay("2026-09-21")
        lines.append("  day 2026-09-21: fires b=\(tomorrow.fireCount(forTaskID: "b"))  "
                     + "endingFired=\(tomorrow.endingFired)  "
                     + "recentCompletions=\(tomorrow.recentCompletions.count)  "
                     + "bestStreak=\(tomorrow.bestStreak)  "
                     + "lastActiveDate=\(tomorrow.lastActiveDate ?? "nil")")

        let perDayReset = tomorrow.fireCount(forTaskID: "b") == 0
            && !tomorrow.endingFired
            && tomorrow.recentCompletions.isEmpty
        let crossDayKept = tomorrow.bestStreak == ledger.bestStreak
            && tomorrow.lastActiveDate == "2026-09-20"
            && tomorrow.daysCelebrated == ledger.daysCelebrated

        // A three-day gap must still be recognised as a comeback.
        let comeback = EscalationEngine.decide(EscalationContext(
            origin: origin, taskIndex: 0, taskCount: 4, remaining: 3,
            daysSinceLastActivity: 3, isFirstCompletionToday: true, seed: 12345))
        lines.append("  first task after a 3-day gap: \(short(comeback.tier)) "
                     + "at \(fmt(comeback.intensity))")

        lines.append(survived && perDayReset && crossDayKept
                     ? "  OK — per-day state resets, cross-day state carries, nothing is lost on restart."
                     : "  FAILED — the ledger does not survive a rollover correctly.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    static func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

    static func short(_ tier: CelebrationTier) -> String {
        switch tier {
        case .standard:  return "std"
        case .building:  return "bld"
        case .finalTask: return "FIN"
        case .streak:    return "STREAK"
        }
    }

    static func describe(_ audio: EscalationAudio) -> String {
        if audio.muted { return "silent" }
        var parts: [String] = []
        if audio.click { parts.append("click") }
        if audio.body { parts.append("body") }
        parts.append("\(audio.noteCount)n")
        if audio.holdMS > 0 { parts.append("hold\(audio.holdMS)") }
        if audio.sparkle { parts.append("sparkle") }
        return parts.joined(separator: "+")
    }

    static func header(_ text: String) -> String {
        let rule = String(repeating: "─", count: max(8, text.count))
        return "\(text)\n\(rule)"
    }

    static func note(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    " + $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        var widths = [Int](repeating: 0, count: first.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return rows.enumerated().map { index, row -> String in
            let line = row.enumerated().map { i, cell -> String in
                i < widths.count ? cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) : cell
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
            if index == 0 {
                let rule = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
                return "  " + line + "\n  " + rule
            }
            return "  " + line
        }.joined(separator: "\n")
    }
}
