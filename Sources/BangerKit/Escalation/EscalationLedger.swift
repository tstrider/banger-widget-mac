//  EscalationLedger.swift — the escalation engine's own state, inside the task document.
//
//  WHERE IT LIVES AND WHY
//
//  `TaskDocument` keeps unknown top-level JSON keys in `extra` and writes them back out
//  verbatim (Model/TaskDocument.swift). `TaskStore.rollOverIfNeeded` carries `extra`
//  across a day boundary untouched. So a single key — "escalation" — gives this engine
//  durable, cross-day, cross-process state without adding a file, a database, or any
//  change to Store/.
//
//  Because `extra` survives rollover wholesale, the ledger has to expire its OWN per-day
//  fields. It stamps the day it belongs to; `forDay(_:)` returns a ledger whose per-day
//  counters are reset when the day has turned over, while the cross-day facts
//  (`lastActiveDate`, `bestStreak`, `daysCelebrated`) carry forward. That is the whole
//  trick and it is why no Store change is needed.
//
//  NOT FARMABLE
//
//  Three separate routes are closed:
//
//    1. `fires[taskID]` counts how many times each task has paid out today. Uncheck and
//       recheck the same box and the engine caps the tier at `standard` and drops the
//       intensity to about a third. The count never decreases within a day, so
//       unchecking cannot reset it.
//    2. `endingFired` records that today already had its ending. Re-clearing the list —
//       uncheck the last task, check it again — cannot buy a second finale.
//    3. `streakDays` itself is not written here at all. It lives in `TaskDocument` and
//       only moves at a day rollover, driven by whether the PREVIOUS day ended cleared.
//       Nothing inside a day can move it, which is the property that makes a streak
//       worth having.
//
//  Timestamps are stored as ISO 8601 strings, like `completedAt`, so the file stays
//  hand-editable and an agent's shell script does not have to understand it.

import Foundation

// MARK: - Ledger

public struct EscalationLedger: Equatable, Sendable {

    public static let documentKey = "escalation"
    public static let currentVersion = 1

    public var version: Int
    /// The day the per-day fields below belong to, "yyyy-MM-dd".
    public var day: String
    /// taskID -> how many times it has paid out today.
    public var fires: [String: Int]
    /// Today already had its finale.
    public var endingFired: Bool
    /// Timestamps of today's completions, newest last, capped at 16.
    public var recentCompletions: [Date]
    /// How many completions happened today, including repeats.
    public var completionsToday: Int

    // Cross-day facts. These survive `forDay`.

    /// The last day that had any completion at all, "yyyy-MM-dd". Drives the comeback.
    public var lastActiveDate: String?
    /// The longest streak ever reached, for the record. Never used to scale anything.
    public var bestStreak: Int
    /// How many distinct days have fired at least one celebration.
    public var daysCelebrated: Int

    public init(version: Int = EscalationLedger.currentVersion,
                day: String = BangerDate.today(),
                fires: [String: Int] = [:],
                endingFired: Bool = false,
                recentCompletions: [Date] = [],
                completionsToday: Int = 0,
                lastActiveDate: String? = nil,
                bestStreak: Int = 0,
                daysCelebrated: Int = 0) {
        self.version = version
        self.day = day
        self.fires = fires
        self.endingFired = endingFired
        self.recentCompletions = recentCompletions
        self.completionsToday = completionsToday
        self.lastActiveDate = lastActiveDate
        self.bestStreak = bestStreak
        self.daysCelebrated = daysCelebrated
    }

    public func fireCount(forTaskID id: String) -> Int { fires[id] ?? 0 }

    /// This ledger as it applies to `day`. Per-day counters reset on a new day; the
    /// cross-day facts carry forward untouched.
    public func forDay(_ today: String) -> EscalationLedger {
        guard day != today else { return self }
        return EscalationLedger(
            version: EscalationLedger.currentVersion,
            day: today,
            fires: [:],
            endingFired: false,
            recentCompletions: [],
            completionsToday: 0,
            lastActiveDate: lastActiveDate,
            bestStreak: bestStreak,
            daysCelebrated: daysCelebrated
        )
    }

    /// Writes down that a celebration just happened. Call this AFTER `decide`, with the
    /// tier it produced, so the next completion sees an accurate picture.
    ///
    /// Monotonic within a day: nothing here can be walked back by unchecking a box.
    public mutating func record(taskID: String,
                                day today: String,
                                tier: CelebrationTier,
                                streakDays: Int,
                                at when: Date) {
        self = forDay(today)
        if lastActiveDate != today {
            daysCelebrated += 1
        }
        fires[taskID] = fireCount(forTaskID: taskID) + 1
        completionsToday += 1
        recentCompletions.append(when)
        if recentCompletions.count > 16 {
            recentCompletions.removeFirst(recentCompletions.count - 16)
        }
        if tier == .finalTask || tier == .streak { endingFired = true }
        lastActiveDate = today
        bestStreak = max(bestStreak, streakDays + (tier == .streak || tier == .finalTask ? 1 : 0))
        version = EscalationLedger.currentVersion
    }
}

// MARK: - JSON bridging, through TaskDocument.extra

public extension EscalationLedger {

    init(json: JSONValue?) {
        guard let object = json?.objectValue else { self = EscalationLedger(); return }
        let stamps = (object["recent"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
            .compactMap { BangerDate.parseTimestamp($0) }
        var fires: [String: Int] = [:]
        for (key, value) in object["fires"]?.objectValue ?? [:] {
            if let count = value.intValue, count > 0 { fires[key] = count }
        }
        self = EscalationLedger(
            version: object["version"]?.intValue ?? EscalationLedger.currentVersion,
            day: object["day"]?.stringValue ?? BangerDate.today(),
            fires: fires,
            endingFired: object["endingFired"]?.boolValue ?? false,
            recentCompletions: stamps,
            completionsToday: object["completionsToday"]?.intValue ?? 0,
            lastActiveDate: object["lastActiveDate"]?.stringValue,
            bestStreak: object["bestStreak"]?.intValue ?? 0,
            daysCelebrated: object["daysCelebrated"]?.intValue ?? 0
        )
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "version": .int(version),
            "day": .string(day),
            "fires": .object(fires.mapValues { .int($0) }),
            "endingFired": .bool(endingFired),
            "completionsToday": .int(completionsToday),
            "bestStreak": .int(bestStreak),
            "daysCelebrated": .int(daysCelebrated),
            "recent": .array(recentCompletions.map { .string(BangerDate.timestampString($0)) }),
        ]
        if let lastActiveDate { object["lastActiveDate"] = .string(lastActiveDate) }
        return .object(object)
    }

    /// Reads the ledger out of a task document, already rolled to the document's day.
    static func read(from document: TaskDocument) -> EscalationLedger {
        EscalationLedger(json: document.extra[EscalationLedger.documentKey]).forDay(document.date)
    }

    /// Writes the ledger back into a task document's overflow bag.
    func write(into document: inout TaskDocument) {
        document.extra[EscalationLedger.documentKey] = json
    }
}
