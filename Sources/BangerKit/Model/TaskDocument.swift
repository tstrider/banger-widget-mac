//  TaskDocument.swift — the whole of tasks.json.
//
//  {
//    "date": "2026-09-21",
//    "tasks": [ ... ],
//    "streakDays": 3,
//    "lastClearedDate": "2026-09-20"
//  }
//
//  `streakDays` means "consecutive fully-cleared days BEFORE today", which is exactly
//  what CelebrationConfig.streakDays wants. It only moves at a day rollover, never
//  mid-day, so clearing today's list does not change it until tomorrow.

import Foundation

public struct TaskDocument: Sendable, Equatable {

    /// "yyyy-MM-dd", local calendar.
    public var date: String
    public var tasks: [BangerTask]
    public var streakDays: Int
    /// The last day that ended fully cleared, "yyyy-MM-dd".
    public var lastClearedDate: String?
    /// Unknown top-level JSON keys, preserved across a round trip.
    public var extra: [String: JSONValue]

    public init(date: String = BangerDate.today(),
                tasks: [BangerTask] = [],
                streakDays: Int = 0,
                lastClearedDate: String? = nil,
                extra: [String: JSONValue] = [:]) {
        self.date = date
        self.tasks = tasks
        self.streakDays = streakDays
        self.lastClearedDate = lastClearedDate
        self.extra = extra
    }
}

// MARK: - Derived state the escalation engine needs

public extension TaskDocument {

    var doneCount: Int { tasks.lazy.filter(\.done).count }
    var openCount: Int { tasks.count - doneCount }

    /// A day counts as cleared only if it had something on it.
    var isFullyCleared: Bool { !tasks.isEmpty && openCount == 0 }

    /// 0-based position of a task among today's tasks, in file order.
    func index(ofTaskWithID id: String) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    func task(withID id: String) -> BangerTask? {
        tasks.first { $0.id == id }
    }

    /// The streak the user would be on if the day ended right now. Saturating, like the
    /// rollover itself: a hand-edited Int.max must not trap the CLI's `streak`.
    var projectedStreakDays: Int {
        guard isFullyCleared else { return 0 }
        return streakDays < Int.max ? streakDays + 1 : Int.max
    }

    /// Resolves an id, or a 1-based list position as typed by a human.
    func resolve(_ selector: TaskSelector) -> BangerTask? {
        resolveIndex(selector).map { tasks[$0] }
    }

    /// The 0-based index a selector names. Callers that go on to change the row use THIS,
    /// never "resolve the task, then look its id up again": with two rows sharing an id
    /// (only possible in a file that fails validation, but a file is hand-editable) the
    /// second lookup lands on the wrong row. A position is a position.
    func resolveIndex(_ selector: TaskSelector) -> Int? {
        switch selector {
        case .id(let id):
            return index(ofTaskWithID: id)
        case .position(let position):
            guard position >= 1, position <= tasks.count else { return nil }
            return position - 1
        case .idOrPosition(let raw):
            if let byID = index(ofTaskWithID: raw) { return byID }
            if let position = Int(raw), position >= 1, position <= tasks.count {
                return position - 1
            }
            return nil
        }
    }
}

// MARK: - Validation

/// The domain rules a task document has to meet before the store will write it, and
/// before it will trust one it read. JSON that decodes is not the same thing as a list
/// the app can act on: two rows with one id make "check off #2" tick #1, and a date of
/// "2026-02-31" makes every day-arithmetic question undefined.
///
/// Applied at one boundary, in TaskStore: `set-json` imports, every read of tasks.json,
/// and every write. It never mutates anything and it ignores unknown keys, which keep
/// round-tripping untouched.
public enum TaskDocumentLimits {
    /// Largest tasks.json / set-json input accepted. A long list is a few tens of KB.
    public static let maxDocumentBytes = 8 * 1024 * 1024
    public static let maxTasks = 5_000
    /// Characters, not bytes. A pasted paragraph is fine; a pasted novel is a mistake.
    public static let maxTaskTextLength = 20_000
    public static let maxIDLength = 128
    public static let maxSourceLength = 256
    /// ~270 years of cleared days. Anything larger was typed, not earned.
    public static let maxStreakDays = 100_000
}

public extension TaskDocument {

    /// What to do about a date later than today.
    enum FutureDatePolicy: Sendable {
        /// A persisted file: the next rollover archives it, so nothing is lost. The clock
        /// may simply have been wrong when it was written.
        case allow
        /// An import relative to `today`: almost always an agent that computed the day at
        /// midnight instead of at the 02:00 boundary. Accepting it would make the very next
        /// read roll the imported list into history and show an empty day.
        case reject(today: String)
    }

    /// nil when the document is acceptable, otherwise the first problem, phrased for a
    /// human who is about to open the file in an editor.
    func validationProblem(futureDates: FutureDatePolicy = .allow) -> String? {
        guard BangerDate.isValidDayString(date) else {
            return "\"date\" is \"\(date)\", which is not a real yyyy-MM-dd day"
        }
        if case .reject(let today) = futureDates,
           let gap = BangerDate.dayGap(from: today, to: date), gap > 0 {
            return "\"date\" is \(date), which is after today's Banger day \(today) "
                + "(the day turns at \(String(format: "%02d", BangerDate.Rollover.hour)):00 "
                + "\(BangerDate.Rollover.timeZone.identifier))"
        }
        if let lastClearedDate, !BangerDate.isValidDayString(lastClearedDate) {
            return "\"lastClearedDate\" is \"\(lastClearedDate)\", which is not a real yyyy-MM-dd day"
        }
        guard (0...TaskDocumentLimits.maxStreakDays).contains(streakDays) else {
            return "\"streakDays\" is \(streakDays); it must be 0...\(TaskDocumentLimits.maxStreakDays)"
        }
        guard tasks.count <= TaskDocumentLimits.maxTasks else {
            return "\(tasks.count) tasks; the limit is \(TaskDocumentLimits.maxTasks)"
        }
        var seen = Set<String>()
        seen.reserveCapacity(tasks.count)
        for (offset, task) in tasks.enumerated() {
            let row = "task #\(offset + 1)"
            if task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(row) has a blank \"id\""
            }
            if task.id.count > TaskDocumentLimits.maxIDLength {
                return "\(row) has an \"id\" longer than \(TaskDocumentLimits.maxIDLength) characters"
            }
            if !seen.insert(task.id).inserted {
                return "\(row) reuses the id \"\(task.id)\"; every id must be unique"
            }
            if task.text.count > TaskDocumentLimits.maxTaskTextLength {
                return "\(row) has \(task.text.count) characters of text; "
                    + "the limit is \(TaskDocumentLimits.maxTaskTextLength)"
            }
            if task.source.count > TaskDocumentLimits.maxSourceLength {
                return "\(row) has a \"source\" longer than \(TaskDocumentLimits.maxSourceLength) characters"
            }
        }
        return nil
    }
}

/// How a caller names a task. `idOrPosition` is what the CLI hands in: an exact id wins
/// over a positional match, so a task whose id happens to be "3" is still reachable.
public enum TaskSelector: Sendable, Equatable {
    case id(String)
    case position(Int)
    case idOrPosition(String)
}

// MARK: - Codable with an overflow bag

extension TaskDocument: Codable {

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum K {
        static let date = "date", tasks = "tasks"
        static let streakDays = "streakDays", lastClearedDate = "lastClearedDate"
        static let known: Set<String> = [date, tasks, streakDays, lastClearedDate]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        self.date = try container.decodeIfPresent(String.self, forKey: AnyKey(K.date)) ?? BangerDate.today()
        self.tasks = try container.decodeIfPresent([BangerTask].self, forKey: AnyKey(K.tasks)) ?? []
        self.streakDays = try container.decodeIfPresent(Int.self, forKey: AnyKey(K.streakDays)) ?? 0
        self.lastClearedDate = try container.decodeIfPresent(String.self, forKey: AnyKey(K.lastClearedDate))

        var overflow: [String: JSONValue] = [:]
        for key in container.allKeys where !K.known.contains(key.stringValue) {
            overflow[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extra = overflow
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(date, forKey: AnyKey(K.date))
        try container.encode(tasks, forKey: AnyKey(K.tasks))
        try container.encode(streakDays, forKey: AnyKey(K.streakDays))
        try container.encodeIfPresent(lastClearedDate, forKey: AnyKey(K.lastClearedDate))
        for (key, value) in extra where !K.known.contains(key) {
            try container.encode(value, forKey: AnyKey(key))
        }
    }
}

// MARK: - History

/// history.json, beside tasks.json: every day that ended with tasks on it, one entry per
/// date, oldest first. Nothing reads it yet but nothing should have to reconstruct a
/// cleared day from memory either. It is rebuilt from, and backed by, one immutable
/// archive/<day>.json per day — see the rollover notes at the top of TaskStore.swift.
public struct TaskHistory: Codable, Sendable, Equatable {
    public var days: [TaskDocument]
    public init(days: [TaskDocument] = []) { self.days = days }
}
