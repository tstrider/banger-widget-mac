//  EscalationContext.swift — everything the engine is allowed to look at.
//
//  The engine is a PURE function of this struct. Every clock read, every file read and
//  every calendar question happens on the way IN, in `EscalationContext.make(...)`, so
//  that `EscalationEngine.decide(_:)` is reproducible: the same context always produces
//  the same config, the same plan and the same seed, in this process or in a renderer
//  six months from now.
//
//  That is not pedantry. The offscreen renderer is only useful if it reproduces the
//  frames the user actually saw, and the config is upstream of the frames.

import CoreGraphics
import Foundation

public struct EscalationContext: Equatable, Sendable {

    // MARK: Where the checkbox was

    /// Overlay-window coordinates, origin top-left, points.
    public var origin: CGPoint

    // MARK: The set

    /// 0-based position of the completed task in today's list.
    public var taskIndex: Int
    /// How many tasks today's list holds.
    public var taskCount: Int
    /// How many are still open AFTER this completion.
    public var remaining: Int
    /// Who put the task on the list: "me", "iris", ...
    public var source: String

    // MARK: The streak

    /// Consecutive fully-cleared days BEFORE today. Moves only at a day rollover, so it
    /// cannot be farmed inside a single day.
    public var streakDays: Int
    /// Whole days since the last day that had any completion on it at all.
    /// 0 = they have already completed something today. 1 = yesterday. >= 2 = a gap.
    public var daysSinceLastActivity: Int
    /// True when this is the first completion of today.
    public var isFirstCompletionToday: Bool

    // MARK: The farm guard

    /// How many times THIS task has already been completed today. A box that gets
    /// unchecked and rechecked must not pay out again.
    public var priorCompletionsOfThisTask: Int
    /// True when today's list has already been cleared once and celebrated as an ending.
    public var endingAlreadyFired: Bool

    // MARK: Recent history (the noise guard)

    /// Seconds ago, for each of the recent completions, most recent first.
    /// Supplied by the caller — the engine never asks what time it is.
    public var secondsSinceRecentCompletions: [Double]

    // MARK: Time of day

    /// Minutes since local midnight, 0..<1440.
    public var minuteOfDay: Int

    // MARK: Accessibility

    public var reduceMotion: Bool

    // MARK: Determinism

    /// Stable per-completion seed. Normally `TaskCompletionPayload.seed`.
    public var seed: UInt64

    public init(origin: CGPoint = .zero,
                taskIndex: Int = 0,
                taskCount: Int = 1,
                remaining: Int = 0,
                source: String = BangerSource.me,
                streakDays: Int = 0,
                daysSinceLastActivity: Int = 0,
                isFirstCompletionToday: Bool = true,
                priorCompletionsOfThisTask: Int = 0,
                endingAlreadyFired: Bool = false,
                secondsSinceRecentCompletions: [Double] = [],
                minuteOfDay: Int = 12 * 60,
                reduceMotion: Bool = false,
                seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.origin = origin
        self.taskIndex = taskIndex
        self.taskCount = max(1, taskCount)
        self.remaining = max(0, remaining)
        self.source = source
        self.streakDays = max(0, streakDays)
        self.daysSinceLastActivity = max(0, daysSinceLastActivity)
        self.isFirstCompletionToday = isFirstCompletionToday
        self.priorCompletionsOfThisTask = max(0, priorCompletionsOfThisTask)
        self.endingAlreadyFired = endingAlreadyFired
        self.secondsSinceRecentCompletions = secondsSinceRecentCompletions
        self.minuteOfDay = min(max(minuteOfDay, 0), 1439)
        self.reduceMotion = reduceMotion
        self.seed = seed
    }
}

// MARK: - Derived facts

public extension EscalationContext {

    /// How far through today's list this completion lands, 0 < p <= 1.
    var setProgress: Double {
        let done = Double(taskCount - remaining)
        return min(1, max(0, done / Double(taskCount)))
    }

    /// This completion emptied the list.
    var clearsTheSet: Bool { remaining == 0 }

    /// The end is in sight but not reached. Keyed on what is LEFT, never on the index:
    /// a three-task day and a twelve-task day both get exactly two of these.
    var isClosing: Bool { !clearsTheSet && remaining <= 2 && taskCount >= 3 }

    /// The first task of a day that follows a gap. Starting again after missing is the
    /// single hardest moment in any habit, and almost nothing rewards it.
    var isComeback: Bool { isFirstCompletionToday && daysSinceLastActivity >= 2 }

    /// A live streak that this completion would extend.
    var hasLiveStreak: Bool { streakDays >= 1 }

    /// This is a re-check of a box that already paid out today.
    var isRepeat: Bool { priorCompletionsOfThisTask > 0 }

    /// 22:00–06:59. Loud is antisocial at 1 a.m.; the celebration still happens, quieter.
    var isQuietHours: Bool { minuteOfDay >= 22 * 60 || minuteOfDay < 7 * 60 }

    /// Attention fatigue. A leaky bucket: every recent completion deposits 1.0 and the
    /// bucket drains with an 18-second time constant.
    ///
    /// Five boxes in ten seconds gives roughly 3.6, which the engine turns into about a
    /// third of normal loudness for the fifth one. That is the whole point: the fifth
    /// must not be five times the first, or the user turns the thing off in a week.
    var fatigue: Double {
        let tau = 18.0
        var total = 0.0
        for dt in secondsSinceRecentCompletions where dt >= 0 {
            total += exp(-dt / tau)
        }
        return total
    }
}

// MARK: - Building a context from the live world

public extension EscalationContext {

    /// The one place a clock is read. Everything downstream is pure.
    ///
    /// `ledger` holds the per-day state the engine owns (see `EscalationLedger`);
    /// `payload` is what `TaskStore` published when the box was checked.
    static func make(payload: TaskCompletionPayload,
                     ledger: EscalationLedger,
                     origin: CGPoint,
                     reduceMotion: Bool = false,
                     now: Date = Date(),
                     calendar: Calendar = .current) -> EscalationContext {

        let today = payload.date
        let day = ledger.forDay(today)

        let minute: Int = {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            return (parts.hour ?? 12) * 60 + (parts.minute ?? 0)
        }()

        let gap: Int = {
            guard let last = day.lastActiveDate else { return 0 }
            if last == today { return 0 }
            // Deliberately NOT `calendar`: that one is the machine's, and it is here
            // for `minuteOfDay` (quiet hours are about local wall-clock time). Day
            // gaps are counted in the rollover zone, so they agree with the labels.
            return max(0, BangerDate.dayGap(from: last, to: today,
                                            calendar: BangerDate.Rollover.calendar) ?? 0)
        }()

        let recent = day.recentCompletions
            .map { now.timeIntervalSince($0) }
            .filter { $0 >= 0 && $0 < 180 }
            .sorted()

        return EscalationContext(
            origin: origin,
            taskIndex: payload.taskIndex,
            taskCount: payload.taskCount,
            remaining: payload.remaining,
            source: payload.source,
            streakDays: payload.streakDays,
            daysSinceLastActivity: gap,
            isFirstCompletionToday: day.completionsToday == 0,
            priorCompletionsOfThisTask: day.fireCount(forTaskID: payload.taskID),
            endingAlreadyFired: day.endingFired,
            secondsSinceRecentCompletions: recent,
            minuteOfDay: minute,
            reduceMotion: reduceMotion,
            seed: payload.seed
        )
    }
}
