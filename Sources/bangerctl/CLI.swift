//  CLI.swift — bangerctl. How an AI agent and the user write to the list from a shell.
//
//  No dependencies, no ArgumentParser. `done` goes through the exact same TaskStore call
//  the widget's App Intent uses, notification and all, which makes `bangerctl done 1` the
//  fastest way to fire a real celebration.

import Foundation
import AppKit
import CoreGraphics

// MARK: - Exit codes

enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 2
}

// MARK: - Output

enum Output {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
    static func error(_ text: String) {
        FileHandle.standardError.write(Data(("bangerctl: " + text + "\n").utf8))
    }
    /// Raw stderr, no prefix. Usage text on a failure path belongs here, not on stdout.
    static func errorLine(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// MARK: - Argument parsing

struct ParsedArguments {
    var command: String
    var positionals: [String] = []
    var flags: [String: String] = [:]
    var booleanFlags: Set<String> = []

    var wantsJSON: Bool { booleanFlags.contains("json") }

    /// All positionals joined, so `bangerctl add call the realtor` works unquoted.
    var joinedPositionals: String {
        positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ArgumentError: Error, LocalizedError {
    case noCommand
    case unknownFlag(String)
    case flagNeedsValue(String)

    var errorDescription: String? {
        switch self {
        case .noCommand: return "no command given"
        case .unknownFlag(let flag): return "unknown option \(flag)"
        case .flagNeedsValue(let flag): return "\(flag) needs a value"
        }
    }
}

/// Flags that carry a value. Everything else long-form is a boolean.
private let valueFlags: Set<String> = [
    "source",
    // Diagnostics. See the DIAGNOSTICS block in `usage`.
    "prefix", "count", "barrier", "seconds", "n", "tier", "seed", "intensity", "pid", "settle",
    "origin-x", "origin-y",
]
private let booleanFlagNames: Set<String> = ["json", "help", "quiet", "no-wait"]

func parseArguments(_ arguments: [String]) throws -> ParsedArguments {
    let remaining = arguments
    guard !remaining.isEmpty else { throw ArgumentError.noCommand }

    var command: String?
    var positionals: [String] = []
    var flags: [String: String] = [:]
    var booleans: Set<String> = []
    var literalsOnly = false

    var index = 0
    while index < remaining.count {
        let argument = remaining[index]
        index += 1

        if literalsOnly {
            if command == nil { command = argument } else { positionals.append(argument) }
            continue
        }
        if argument == "--" { literalsOnly = true; continue }

        if argument == "-h" {
            booleans.insert("help"); continue
        }
        if argument.hasPrefix("--") {
            let body = String(argument.dropFirst(2))
            let name: String
            var inlineValue: String?
            if let equals = body.firstIndex(of: "=") {
                name = String(body[body.startIndex..<equals])
                inlineValue = String(body[body.index(after: equals)...])
            } else {
                name = body
            }
            if valueFlags.contains(name) {
                if let inlineValue {
                    flags[name] = inlineValue
                } else {
                    guard index < remaining.count else { throw ArgumentError.flagNeedsValue(argument) }
                    flags[name] = remaining[index]
                    index += 1
                }
            } else if booleanFlagNames.contains(name) {
                booleans.insert(name)
            } else {
                throw ArgumentError.unknownFlag(argument)
            }
            continue
        }

        if command == nil { command = argument } else { positionals.append(argument) }
    }

    guard let command else {
        if booleans.contains("help") {
            return ParsedArguments(command: "help", positionals: [], flags: [:], booleanFlags: booleans)
        }
        throw ArgumentError.noCommand
    }
    return ParsedArguments(command: command, positionals: positionals,
                           flags: flags, booleanFlags: booleans)
}

// MARK: - JSON output shapes

struct ListOutput: Encodable {
    struct Row: Encodable {
        var index: Int
        var id: String
        var text: String
        var done: Bool
        var source: String
        var completedAt: String?
    }
    var date: String
    var streakDays: Int
    var lastClearedDate: String?
    var open: Int
    var done: Int
    var fullyCleared: Bool
    var tasks: [Row]

    init(_ document: TaskDocument) {
        date = document.date
        streakDays = document.streakDays
        lastClearedDate = document.lastClearedDate
        open = document.openCount
        done = document.doneCount
        fullyCleared = document.isFullyCleared
        tasks = document.tasks.enumerated().map { offset, task in
            Row(index: offset + 1,
                id: task.id,
                text: task.text,
                done: task.done,
                source: task.source,
                completedAt: task.completedAt.map(BangerDate.timestampString))
        }
    }
}

struct AddOutput: Encodable {
    var ok = true
    var index: Int
    var id: String
    var text: String
    var source: String
}

struct DoneOutput: Encodable {
    var ok = true
    var celebrated: Bool
    var payload: TaskCompletionPayload?
    var message: String
}

struct SimpleOutput: Encodable {
    var ok = true
    var message: String
    var count: Int?
}

struct StreakOutput: Encodable {
    var date: String
    var streakDays: Int
    var projectedStreakDays: Int
    var lastClearedDate: String?
    var open: Int
    var done: Int
    var fullyCleared: Bool
}

struct PathOutput: Encodable {
    var container: String
    var tasks: String
    var history: String
    /// One immutable file per rolled-over day, and the journal of days not yet in history.
    var archive: String
    var pendingRolloverDays: [String]
    var historyProblem: String?
    /// Whether the widget extension leaves a read receipt (`touch` the marker to enable).
    var widgetReceiptsEnabled: Bool
    var widgetReceiptsMarker: String
    var source: String
    var isFallback: Bool
    var existedBeforeResolution: Bool
    var creationError: String?
    /// Any tasks.json left where an older build could have written one. Nothing reads
    /// them. Empty is the only healthy answer; anything here is a list somebody filled
    /// in that the widget never showed.
    var strayLists: [String]
    /// The day boundary in force. A list that looks like it cleared at the wrong time
    /// is almost always one of these three being different from what you assumed.
    var rolloverHour: Int
    var rolloverTimeZone: String
    var rolloverSetBy: String
    var today: String
    var nextRollover: String
}

// MARK: - The commands

enum BangerCTL {

    static let usage = """
    bangerctl — the Banger checklist, from a shell.

    USAGE
      bangerctl add <text...> [--source <who>]   add a task (default source: me)
      bangerctl list [--json]                    today's list
      bangerctl done <id|index>                  check it off — fires the celebration
      bangerctl undone <id|index>                uncheck it
      bangerctl rm <id|index>                    delete it
      bangerctl clear                            empty today's list (streak untouched)
      bangerctl streak [--json]                  streak and today's progress
      bangerctl set-json < file.json             replace the whole list, safely (validated:
                                                 unique non-blank ids, a real date no later
                                                 than today, sane streak; refused input
                                                 leaves tasks.json untouched)
      bangerctl path [--json]                    where tasks.json actually resolved to
      bangerctl help

    NOTES
      <index> is the 1-based position shown by `list`. An exact id always wins over a
      positional match. Every command takes --json.

    DIAGNOSTICS
      These exist for tools/dataflow_bench.sh and for measuring latency. They are safe to
      run but they are not part of daily use.

      bangerctl receipt [--json]              what the widget extension last read, and when.
                                              Off by default; enable with:
                                                touch <container>/widget-receipts-enabled
                                              (`bangerctl path` prints <container>)
      bangerctl sweep                         remove temp files left by a killed writer
      bangerctl celebrate [--tier T] [--seed N] [--intensity F]
                          [--origin-x PX] [--origin-y PX]
                                              fire the overlay without touching the list.
                                              --origin-* are GLOBAL top-left points; omit
                                              them and the burst starts at the widget's
                                              home corner. tools/record_live.sh passes them
                                              so the offscreen render can be pinned to the
                                              same origin the live overlay used.
      bangerctl listen --seconds S [--json]   print completions as they arrive, with the
                                              one-way transport time in ms
      bangerctl latency [--n N] [--json]      measure intent -> overlay on screen, and
                                              intent -> widget re-read, in ms
      bangerctl bench-write --prefix P --count N [--barrier F] [--json]
      bangerctl bench-done <id> [--barrier F] [--json]
      bangerctl bench-read --seconds S [--barrier F] [--json]
      bangerctl bench-churn --prefix P [--seconds S] [--barrier F]

      --barrier F makes the process announce itself (F.ready.<pid>) and then spin until F
      exists, so N processes can be released into the same microsecond.
    """

    static func run(_ rawArguments: [String]) -> Int32 {
        let parsed: ParsedArguments
        do {
            parsed = try parseArguments(rawArguments)
        } catch {
            Output.error(error.localizedDescription)
            Output.errorLine(usage)
            return ExitCode.usage.rawValue
        }

        if parsed.booleanFlags.contains("help") || parsed.command == "help" {
            Output.line(usage)
            return ExitCode.ok.rawValue
        }

        let store = TaskStore.shared
        // Never let the fallback container be a silent surprise: if the widget cannot see
        // this file, say so on every run that is not machine-parsed.
        if let warning = store.containerWarning, !parsed.wantsJSON, parsed.command != "path" {
            Output.error(warning)
        }
        do {
            defer { if parsed.command != "path" { warnAboutHistory(store) } }
            switch parsed.command {
            case "add":       return try add(parsed, store)
            case "list", "ls": return try list(parsed, store)
            case "done":      return try setDone(parsed, store, done: true)
            case "undone":    return try setDone(parsed, store, done: false)
            case "rm", "remove", "delete": return try remove(parsed, store)
            case "clear":     return try clear(parsed, store)
            case "streak":    return try streak(parsed, store)
            case "path":      return try path(parsed, store)
            case "set-json":  return try setJSON(parsed, store)
            case "receipt":   return try receipt(parsed, store)
            case "sweep":     return sweep(parsed, store)
            case "celebrate": return celebrate(parsed)
            case "listen":    return listen(parsed)
            case "latency":   return try latency(parsed, store)
            case "bench-write": return try benchWrite(parsed, store)
            case "bench-done":  return try benchDone(parsed, store)
            case "bench-read":  return benchRead(parsed, store)
            case "bench-churn": return benchChurn(parsed, store)
            default:
                Output.error("unknown command \"\(parsed.command)\"")
                Output.errorLine(usage)
                return ExitCode.usage.rawValue
            }
        } catch let error as TaskStoreError {
            Output.error(error.localizedDescription)
            return ExitCode.failure.rawValue
        } catch {
            Output.error(error.localizedDescription)
            return ExitCode.failure.rawValue
        }
    }

    /// A rollover that archived the old day but could not update history.json still
    /// succeeds — the day is safe in archive/pending and the next run retries — but it
    /// is not an unqualified success, so say so. stderr, so --json output stays clean.
    private static func warnAboutHistory(_ store: TaskStore) {
        guard let problem = store.lastHistoryProblem else { return }
        Output.error("warning: \(problem)")
    }

    // MARK: add

    private static func add(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let text = arguments.joinedPositionals
        guard !text.isEmpty else {
            Output.error("add needs some text, e.g. bangerctl add \"Call the realtor\"")
            return ExitCode.usage.rawValue
        }
        let source = arguments.flags["source"] ?? BangerSource.me
        let task = try store.add(text: text, source: source)
        let document = try store.peek()
        let index = (document.index(ofTaskWithID: task.id) ?? document.tasks.count - 1) + 1

        if arguments.wantsJSON {
            try Output.json(AddOutput(index: index, id: task.id, text: task.text, source: task.source))
        } else {
            Output.line("Added #\(index) [\(task.id)] \"\(task.text)\" (\(task.source)).")
        }
        return ExitCode.ok.rawValue
    }

    // MARK: list

    private static func list(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let document = try store.load()
        if arguments.wantsJSON {
            try Output.json(ListOutput(document))
            return ExitCode.ok.rawValue
        }

        var header = document.date
        if document.tasks.isEmpty {
            header += "  ·  nothing on the list"
        } else {
            header += "  ·  \(document.doneCount) of \(document.tasks.count) done"
        }
        if document.streakDays > 0 {
            header += "  ·  streak \(document.streakDays)"
        }
        Output.line(header)

        guard !document.tasks.isEmpty else { return ExitCode.ok.rawValue }

        let indexWidth = String(document.tasks.count).count
        let textWidth = min(52, document.tasks.map(\.text.count).max() ?? 0)
        let sourceWidth = document.tasks.map(\.source.count).max() ?? 0
        for (offset, task) in document.tasks.enumerated() {
            let number = String(offset + 1).leftPadded(to: indexWidth)
            let box = task.done ? "[x]" : "[ ]"
            let text = task.text.rightPadded(to: textWidth)
            let source = task.source.rightPadded(to: sourceWidth)
            Output.line("  \(number)  \(box) \(text)   \(source)   \(task.id)")
        }
        return ExitCode.ok.rawValue
    }

    // MARK: done / undone

    private static func setDone(_ arguments: ParsedArguments, _ store: TaskStore, done: Bool) throws -> Int32 {
        let raw = arguments.joinedPositionals
        guard !raw.isEmpty else {
            Output.error("\(done ? "done" : "undone") needs an id or a list number")
            return ExitCode.usage.rawValue
        }

        // Capture the text before the call so the message reads well either way.
        let before = try store.load()
        let target = before.resolve(.idOrPosition(raw))

        let payload = try store.setDone(done, matching: .idOrPosition(raw))
        let after = try store.peek()
        let text = payload?.taskText ?? target?.text ?? raw

        let message: String
        if done {
            if let payload {
                if payload.fullyCleared {
                    let tomorrow = payload.streakDays + 1
                    message = "BANGER. \"\(text)\" cleared the day — streak goes to \(tomorrow) tomorrow."
                } else {
                    message = "Banger. \"\(text)\" — \(payload.remaining) left today."
                }
            } else {
                message = "\"\(text)\" was already done. Nothing fired."
            }
        } else {
            message = "Reopened \"\(text)\". \(after.openCount) left today."
        }

        if arguments.wantsJSON {
            try Output.json(DoneOutput(celebrated: payload != nil, payload: payload, message: message))
        } else {
            Output.line(message)
        }

        // Give the distributed notification a moment to leave the process before we exit,
        // otherwise a fast `bangerctl done 1` can outrun its own celebration.
        if payload != nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        return ExitCode.ok.rawValue
    }

    // MARK: rm

    private static func remove(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let raw = arguments.joinedPositionals
        guard !raw.isEmpty else {
            Output.error("rm needs an id or a list number")
            return ExitCode.usage.rawValue
        }
        let removed = try store.remove(matching: .idOrPosition(raw))
        let message = "Removed \"\(removed.text)\"."
        if arguments.wantsJSON {
            try Output.json(SimpleOutput(message: message, count: 1))
        } else {
            Output.line(message)
        }
        return ExitCode.ok.rawValue
    }

    // MARK: clear

    private static func clear(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let count = try store.clearToday()
        let message = count == 0 ? "Nothing to clear." : "Cleared \(count) task\(count == 1 ? "" : "s") off today."
        if arguments.wantsJSON {
            try Output.json(SimpleOutput(message: message, count: count))
        } else {
            Output.line(message)
        }
        return ExitCode.ok.rawValue
    }

    // MARK: streak

    private static func streak(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let document = try store.load()
        if arguments.wantsJSON {
            try Output.json(StreakOutput(date: document.date,
                                         streakDays: document.streakDays,
                                         projectedStreakDays: document.projectedStreakDays,
                                         lastClearedDate: document.lastClearedDate,
                                         open: document.openCount,
                                         done: document.doneCount,
                                         fullyCleared: document.isFullyCleared))
            return ExitCode.ok.rawValue
        }
        Output.line("Streak: \(document.streakDays) day\(document.streakDays == 1 ? "" : "s").")
        Output.line("Last full clear: \(document.lastClearedDate ?? "never").")
        if document.tasks.isEmpty {
            Output.line("Today: nothing on the list.")
        } else {
            Output.line("Today: \(document.doneCount) of \(document.tasks.count) done.")
            if document.isFullyCleared {
                Output.line("Ends today cleared — that makes it \(document.projectedStreakDays) tomorrow.")
            }
        }
        return ExitCode.ok.rawValue
    }

    // MARK: set-json

    /// The safe version of `echo '{...}' > tasks.json`.
    ///
    /// A shell redirect truncates the file in place, so any reader inside the gap gets an
    /// empty or half-written document. This takes the same cross-process lock every
    /// other writer takes, validates the bytes parse as a task document before anything
    /// is replaced, and lands them with an atomic rename. Nothing ever sees a partial file.
    private static func setJSON(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            Output.error("set-json reads the new tasks.json from standard input, "
                         + "e.g. bangerctl set-json < today.json")
            return ExitCode.usage.rawValue
        }
        let document = try store.replaceAll(withJSON: data)
        if arguments.wantsJSON {
            try Output.json(ListOutput(document))
        } else {
            Output.line("Replaced today's list: \(document.date), \(document.tasks.count) "
                        + "task\(document.tasks.count == 1 ? "" : "s"), "
                        + "\(document.doneCount) done.")
        }
        return ExitCode.ok.rawValue
    }

    // MARK: path

    private static func path(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let resolution = store.container
        let strays = BangerContainer.strayLists()
        if arguments.wantsJSON {
            try Output.json(PathOutput(container: resolution.url.path,
                                       tasks: store.tasksURL.path,
                                       history: store.historyURL.path,
                                       archive: store.archiveURL.path,
                                       pendingRolloverDays: store.pendingRolloverDays(),
                                       historyProblem: store.lastHistoryProblem,
                                       widgetReceiptsEnabled: store.widgetReceiptsEnabled,
                                       widgetReceiptsMarker: store.receiptsEnabledURL.path,
                                       source: resolution.source.rawValue,
                                       isFallback: resolution.isFallback,
                                       existedBeforeResolution: resolution.existedBeforeResolution,
                                       creationError: resolution.creationErrorDescription,
                                       strayLists: strays.map(\.path),
                                       rolloverHour: BangerDate.Rollover.hour,
                                       rolloverTimeZone: BangerDate.Rollover.timeZone.identifier,
                                       rolloverSetBy: BangerDate.Rollover.source,
                                       today: BangerDate.today(),
                                       nextRollover: BangerDate.timestampString(
                                           BangerDate.Rollover.nextBoundary())))
            return ExitCode.ok.rawValue
        }
        Output.line("container    \(resolution.url.path)")
        Output.line("tasks        \(store.tasksURL.path)")
        Output.line("history      \(store.historyURL.path)")
        Output.line("archive      \(store.archiveURL.path)")
        let pending = store.pendingRolloverDays()
        if !pending.isEmpty {
            Output.line("NOT IN HISTORY YET  \(pending.joined(separator: ", ")) "
                        + "(safe in \(store.pendingRolloverURL.path); the next load retries)")
        }
        Output.line("receipts     \(store.widgetReceiptsEnabled ? "on" : "off")  "
                    + "(\(store.widgetReceiptsEnabled ? "rm" : "touch") \(store.receiptsEnabledURL.path))")
        Output.line("resolved by  \(resolution.source.rawValue)")
        Output.line("pre-existed  \(resolution.existedBeforeResolution)")
        Output.line("day starts   \(String(format: "%02d", BangerDate.Rollover.hour)):00 "
                    + "\(BangerDate.Rollover.timeZone.identifier) (set by \(BangerDate.Rollover.source))")
        Output.line("today is     \(BangerDate.today())")
        Output.line("next turn    \(BangerDate.timestampString(BangerDate.Rollover.nextBoundary()))")
        for stray in strays {
            Output.line("STRAY LIST   \(stray.path) — a second list nothing reads. "
                        + "Do not use it; tell the user it is there.")
        }
        if let problem = resolution.creationErrorDescription {
            Output.line("PROBLEM      \(problem)")
        }
        return ExitCode.ok.rawValue
    }
}

// MARK: - Diagnostics: the barrier

/// Lets N processes be released into the same instant.
///
/// Spawning N shells and hoping they collide is not a concurrency test — process startup
/// is tens of milliseconds and they arrive one after another. So each bench process
/// announces itself by creating `<barrier>.ready.<pid>`, then busy-waits on `<barrier>`
/// appearing. The driving script waits until N ready files exist and then creates it, which
/// puts every writer inside the same microsecond with all of its warm-up already paid for.
enum Barrier {

    static func waitFor(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        let ready = "\(path).ready.\(getpid())"
        FileManager.default.createFile(atPath: ready, contents: Data())
        // Busy-wait, not a poll with sleep: the release has to be sharp.
        while !FileManager.default.fileExists(atPath: path) {
            usleep(200)
        }
    }
}

// MARK: - Diagnostics: output shapes

struct BenchWriteOutput: Encodable {
    var ok: Bool
    var prefix: String
    var attempted: Int
    var succeeded: Int
    var failed: Int
    var firstError: String?
    var elapsedMs: Double
    var meanMsPerWrite: Double
    var maxMsPerWrite: Double
    var ids: [String]
}

struct BenchDoneOutput: Encodable {
    var ok: Bool
    var id: String
    var celebrated: Bool
    var elapsedMs: Double
    var error: String?
}

struct BenchReadOutput: Encodable {
    var ok: Bool
    var reads: Int
    var parseFailures: Int
    var emptyReads: Int
    var missingFile: Int
    var ioErrors: Int
    var distinctVersions: Int
    var elapsedMs: Double
    var meanMsPerRead: Double
    var maxMsPerRead: Double
    var firstFailureDetail: String?
}

struct LatencySample: Encodable {
    var trial: Int
    var mutateMs: Double
    var postToOverlayMs: Double
    var intentToOverlayMs: Double
    var intentToWidgetReadMs: Double?
}

struct LatencyOutput: Encodable {
    var ok: Bool
    var bangerRunning: Bool
    var trials: Int
    var intentToOverlayMs: Stats
    var postToOverlayMs: Stats
    var mutateMs: Stats
    var intentToWidgetReadMs: Stats?
    var widgetReceiptSeen: Bool
    var note: String
    var samples: [LatencySample]

    struct Stats: Encodable {
        var n: Int
        var min: Double
        var median: Double
        var mean: Double
        var stdDev: Double
        var p90: Double
        var p99: Double
        var max: Double
        /// 2 ms buckets, so the shape of the distribution is in the artefact and not just
        /// three summary numbers. A median with no spread behind it is an assertion.
        var histogram2ms: [String: Int]

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            n = sorted.count
            min = sorted.first!
            max = sorted.last!
            let average = sorted.reduce(0, +) / Double(sorted.count)
            mean = average
            let variance = sorted.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(sorted.count)
            stdDev = variance.squareRoot()
            median = sorted[sorted.count / 2]
            p90 = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            p99 = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            var buckets: [String: Int] = [:]
            for value in sorted {
                let low = Int(value / 2) * 2
                buckets["\(low)-\(low + 2)", default: 0] += 1
            }
            histogram2ms = buckets
        }
    }
}

// MARK: - Diagnostics: the overlay, watched from outside

/// Watches the window server for the celebration overlay appearing.
///
/// The honest alternative would be to instrument the app, but then the number would be
/// the app's opinion of itself. This is an unrelated process asking the window server
/// "is there a Banger window at the screen-saver level on screen yet", which is as close
/// to "did the user see it" as anything outside a camera gets. The overlay window is
/// created fresh for every celebration and closed at teardown, so a window number that
/// was not in the baseline is unambiguously this celebration's.
///
/// Caveat, stated rather than buried: this is the moment the window becomes on-screen,
/// which is up to one display refresh (8.3 ms at 120 Hz) before its first composited
/// frame is actually lit.
enum OverlayWatcher {

    static let screenSaverLevel = 1000

    static func bangerPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.bangerwidget.Banger")
            .first?.processIdentifier
    }

    static func overlayWindowNumbers(pid: pid_t) -> Set<Int> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var found: Set<Int> = []
        for window in raw {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == screenSaverLevel,
                  let number = window[kCGWindowNumber as String] as? Int
            else { continue }
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            if alpha <= 0 { continue }
            found.insert(number)
        }
        return found
    }

    /// Spins until a window number outside `baseline` shows up, or the deadline passes.
    /// Returns the uptime nanoseconds at which it was first seen.
    static func awaitNewOverlay(pid: pid_t, baseline: Set<Int>, timeout: TimeInterval) -> UInt64? {
        let deadline = BangerClock.uptimeNanos &+ UInt64(timeout * 1_000_000_000)
        while BangerClock.uptimeNanos < deadline {
            let now = overlayWindowNumbers(pid: pid)
            if !now.subtracting(baseline).isEmpty { return BangerClock.uptimeNanos }
        }
        return nil
    }

    static func awaitClear(pid: pid_t, baseline: Set<Int>, timeout: TimeInterval) {
        let deadline = BangerClock.uptimeNanos &+ UInt64(timeout * 1_000_000_000)
        while BangerClock.uptimeNanos < deadline {
            if overlayWindowNumbers(pid: pid).subtracting(baseline).isEmpty { return }
            usleep(5_000)
        }
    }
}

// MARK: - Diagnostics: the commands

extension BangerCTL {

    // MARK: receipt

    static func receipt(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let enableHint = "widget read receipts are off by default; enable with: "
            + "touch \(store.receiptsEnabledURL.path)"
        guard let receipt = store.readReceipt() else {
            let why = store.widgetReceiptsEnabled
                ? "the widget extension has not read \(store.tasksURL.path) since receipts were enabled "
                    + "(no \(store.readReceiptURL.lastPathComponent))"
                : "no \(store.readReceiptURL.lastPathComponent) — \(enableHint)"
            if arguments.wantsJSON {
                try Output.json(SimpleOutput(ok: false, message: why, count: 0))
            } else {
                Output.error(why)
            }
            return ExitCode.failure.rawValue
        }
        if !store.widgetReceiptsEnabled, !arguments.wantsJSON {
            Output.error("this receipt is old: \(enableHint)")
        }
        if arguments.wantsJSON {
            try Output.json(receipt)
            return ExitCode.ok.rawValue
        }
        Output.line("read at      \(receipt.at)")
        Output.line("by pid       \(receipt.pid)  (\(receipt.processName))")
        Output.line("bundle       \(receipt.bundlePath)")
        Output.line("is .appex    \(receipt.isAppExtension)")
        Output.line("sandboxed    \(receipt.sandboxed)")
        Output.line("sandbox home \(receipt.sandboxHome)")
        Output.line("real home    \(receipt.realHome)")
        Output.line("read file    \(receipt.tasksPath)")
        Output.line("bytes        \(receipt.bytes)")
        Output.line("sha256       \(receipt.digestSHA256)")
        Output.line("day          \(receipt.date)  \(receipt.taskCount) tasks, \(receipt.openCount) open")
        Output.line("first task   \"\(receipt.firstTaskText)\"")
        return ExitCode.ok.rawValue
    }

    // MARK: sweep

    static func sweep(_ arguments: ParsedArguments, _ store: TaskStore) -> Int32 {
        let removed = store.sweepAbandonedWrites(olderThan: 0)
        if arguments.wantsJSON {
            try? Output.json(SimpleOutput(message: "swept", count: removed))
        } else {
            Output.line("Removed \(removed) abandoned temp file\(removed == 1 ? "" : "s").")
        }
        return ExitCode.ok.rawValue
    }

    // MARK: celebrate

    /// Fires the overlay without touching the list, for screen recording.
    static func celebrate(_ arguments: ParsedArguments) -> Int32 {
        let tier = arguments.flags["tier"] ?? "finalTask"
        let seed = arguments.flags["seed"] ?? "424242"
        let intensity = arguments.flags["intensity"] ?? "1.0"
        var info: [String: String] = [
            "tier": tier,
            "intensity": intensity,
            "seed": seed,
            "taskIndex": "5",
            "taskCount": "6",
            "remaining": "0",
            "streakDays": "0",
            "source": "me",
        ]
        // Pinning the origin is what makes the live-vs-offscreen comparison exact.
        // Without these the app falls back to ScreenGeometry.widgetHomeGlobalTopLeft,
        // which depends on the attached display and so cannot be reproduced offscreen
        // from the command line alone.
        if let x = arguments.flags["origin-x"] { info["originX"] = x }
        if let y = arguments.flags["origin-y"] { info["originY"] = y }
        let center = DistributedNotificationCenter.default()
        for name in [BangerNotification.debugCelebrate,
                     BangerNotification.debugCelebrateGroupPrefixed] {
            center.postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
        }
        if !arguments.booleanFlags.contains("quiet") {
            Output.line("Fired \(tier) (seed \(seed)).")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        return ExitCode.ok.rawValue
    }

    // MARK: listen

    static func listen(_ arguments: ParsedArguments) -> Int32 {
        let seconds = Double(arguments.flags["seconds"] ?? "5") ?? 5
        let wantsJSON = arguments.wantsJSON
        let center = DistributedNotificationCenter.default()
        var tokens: [NSObjectProtocol] = []
        for name in [BangerNotification.taskCompleted,
                     BangerNotification.taskCompletedGroupPrefixed] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let arrived = BangerClock.uptimeNanos
                guard let payload = TaskCompletionPayload(notification: note) else { return }
                let posted = TaskCompletionPayload.postedAtNanos(in: note)
                let transport = posted.map { Double(arrived &- $0) / 1_000_000 }
                if wantsJSON {
                    let line = "{\"id\":\"\(payload.taskID)\",\"seed\":\(payload.seed),"
                        + "\"name\":\"\(note.name.rawValue)\","
                        + "\"arrivedNs\":\(arrived),"
                        + "\"transportMs\":\(transport.map { String(format: "%.3f", $0) } ?? "null")}"
                    Output.line(line)
                } else {
                    let ms = transport.map { String(format: "%.2f ms", $0) } ?? "unstamped"
                    Output.line("\(payload.taskID)  \"\(payload.taskText)\"  \(ms)  via \(note.name.rawValue)")
                }
            })
        }
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        for token in tokens { center.removeObserver(token) }
        return ExitCode.ok.rawValue
    }

    // MARK: latency

    static func latency(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        // 200 by default. A single median is not evidence. At ~2 s a trial this is
        // about seven minutes, which is the price of a distribution.
        let trials = Int(arguments.flags["n"] ?? "200") ?? 200
        let settle = Double(arguments.flags["settle"] ?? "0.35") ?? 0.35

        guard let pid = OverlayWatcher.bangerPID() else {
            let note = "Banger.app is not running, so there is no overlay to time. "
                + "Start it with `open -a /Applications/Banger.app` and run this again."
            if arguments.wantsJSON {
                try Output.json(LatencyOutput(ok: false, bangerRunning: false, trials: 0,
                                              intentToOverlayMs: LatencyOutput.Stats([0])!,
                                              postToOverlayMs: LatencyOutput.Stats([0])!,
                                              mutateMs: LatencyOutput.Stats([0])!,
                                              intentToWidgetReadMs: nil,
                                              widgetReceiptSeen: false,
                                              note: note, samples: []))
            } else {
                Output.error(note)
            }
            return ExitCode.failure.rawValue
        }

        var samples: [LatencySample] = []
        for trial in 1...max(1, trials) {
            let task = try store.add(text: "latency probe \(trial) \(BangerClock.uptimeNanos)",
                                     source: "bench")
            // Let the add's own tasksChanged settle so it cannot be mistaken for ours.
            usleep(UInt32(settle * 1_000_000))
            store.clearReadReceipt()
            let receiptBefore = store.readReceipt()?.atUptimeNs

            let baseline = OverlayWatcher.overlayWindowNumbers(pid: pid)

            // ---- this is exactly what ToggleTaskIntent.perform does, and nothing else ----
            let intentStart = BangerClock.uptimeNanos
            let payload = try store.setDone(true, matching: .id(task.id))
            let afterPost = BangerClock.uptimeNanos
            // -----------------------------------------------------------------------------

            guard payload != nil else { continue }
            guard let shown = OverlayWatcher.awaitNewOverlay(pid: pid, baseline: baseline,
                                                             timeout: 3.0) else {
                Output.error("trial \(trial): no overlay window appeared within 3 s")
                continue
            }

            var widgetMs: Double?
            // The widget re-read is on the widget host's schedule, not ours; give it a
            // second and take it if it lands.
            let receiptDeadline = BangerClock.uptimeNanos &+ 1_500_000_000
            while BangerClock.uptimeNanos < receiptDeadline {
                if let receipt = store.readReceipt(), receipt.atUptimeNs != receiptBefore,
                   receipt.atUptimeNs > intentStart {
                    widgetMs = Double(receipt.atUptimeNs &- intentStart) / 1_000_000
                    break
                }
                usleep(10_000)
            }

            samples.append(LatencySample(
                trial: trial,
                mutateMs: Double(afterPost &- intentStart) / 1_000_000,
                postToOverlayMs: Double(shown &- afterPost) / 1_000_000,
                intentToOverlayMs: Double(shown &- intentStart) / 1_000_000,
                intentToWidgetReadMs: widgetMs))

            OverlayWatcher.awaitClear(pid: pid, baseline: baseline, timeout: 4.0)
            _ = try? store.remove(matching: .id(task.id))
        }

        let widgetValues = samples.compactMap(\.intentToWidgetReadMs)
        let output = LatencyOutput(
            ok: !samples.isEmpty,
            bangerRunning: true,
            trials: samples.count,
            intentToOverlayMs: LatencyOutput.Stats(samples.map(\.intentToOverlayMs)) ?? LatencyOutput.Stats([0])!,
            postToOverlayMs: LatencyOutput.Stats(samples.map(\.postToOverlayMs)) ?? LatencyOutput.Stats([0])!,
            mutateMs: LatencyOutput.Stats(samples.map(\.mutateMs)) ?? LatencyOutput.Stats([0])!,
            intentToWidgetReadMs: LatencyOutput.Stats(widgetValues),
            widgetReceiptSeen: !widgetValues.isEmpty,
            note: "intentToOverlayMs = file write + distributed notification + the app "
                + "building and ordering in the overlay window, measured from a third "
                + "process via CGWindowList. It is the moment the window goes on screen, "
                + "up to one refresh before its first lit frame.",
            samples: samples)

        if arguments.wantsJSON {
            try Output.json(output)
        } else {
            Output.line(String(format: "intent -> overlay on screen   median %.1f  p90 %.1f  p99 %.1f  max %.1f  sd %.1f ms  (n=%d)",
                               output.intentToOverlayMs.median, output.intentToOverlayMs.p90,
                               output.intentToOverlayMs.p99, output.intentToOverlayMs.max,
                               output.intentToOverlayMs.stdDev, output.intentToOverlayMs.n))
            Output.line(String(format: "  of which file write          median %.1f ms",
                               output.mutateMs.median))
            Output.line(String(format: "  of which notify + present    median %.1f ms",
                               output.postToOverlayMs.median))
            if let widget = output.intentToWidgetReadMs {
                Output.line(String(format: "intent -> widget re-read      median %.1f ms   max %.1f ms   (n=%d)",
                                   widget.median, widget.max, widget.n))
            } else if !store.widgetReceiptsEnabled {
                Output.line("intent -> widget re-read      not measured: receipts are off "
                            + "(touch \(store.receiptsEnabledURL.path))")
            } else {
                Output.line("intent -> widget re-read      not observed (widget not on the desktop?)")
            }
        }
        return output.ok ? ExitCode.ok.rawValue : ExitCode.failure.rawValue
    }

    // MARK: bench-write

    static func benchWrite(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let prefix = arguments.flags["prefix"] ?? "w\(getpid())"
        let count = Int(arguments.flags["count"] ?? "50") ?? 50
        Barrier.waitFor(arguments.flags["barrier"])

        var ids: [String] = []
        var failed = 0
        var firstError: String?
        var worst = 0.0
        let started = BangerClock.uptimeNanos
        for index in 0..<count {
            let began = BangerClock.uptimeNanos
            do {
                let task = try store.add(text: "\(prefix)-\(String(format: "%04d", index))",
                                         source: "bench")
                ids.append(task.id)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
            worst = max(worst, BangerClock.millis(since: began))
        }
        let elapsed = BangerClock.millis(since: started)
        let output = BenchWriteOutput(ok: failed == 0,
                                      prefix: prefix,
                                      attempted: count,
                                      succeeded: ids.count,
                                      failed: failed,
                                      firstError: firstError,
                                      elapsedMs: elapsed,
                                      meanMsPerWrite: count == 0 ? 0 : elapsed / Double(count),
                                      maxMsPerWrite: worst,
                                      ids: ids)
        try Output.json(output)
        return output.ok ? ExitCode.ok.rawValue : ExitCode.failure.rawValue
    }

    // MARK: bench-done

    static func benchDone(_ arguments: ParsedArguments, _ store: TaskStore) throws -> Int32 {
        let raw = arguments.joinedPositionals
        Barrier.waitFor(arguments.flags["barrier"])
        let began = BangerClock.uptimeNanos
        do {
            let payload = try store.setDone(true, matching: .idOrPosition(raw))
            try Output.json(BenchDoneOutput(ok: true, id: raw,
                                            celebrated: payload != nil,
                                            elapsedMs: BangerClock.millis(since: began),
                                            error: nil))
            return ExitCode.ok.rawValue
        } catch {
            try Output.json(BenchDoneOutput(ok: false, id: raw, celebrated: false,
                                            elapsedMs: BangerClock.millis(since: began),
                                            error: error.localizedDescription))
            return ExitCode.failure.rawValue
        }
    }

    // MARK: bench-read

    /// Reads the raw bytes, not through TaskStore: the point is to prove that whatever a
    /// naive reader (an agent's shell, a text editor, `cat`) sees is always a whole, parseable
    /// document, even while several processes are replacing it.
    static func benchRead(_ arguments: ParsedArguments, _ store: TaskStore) -> Int32 {
        let seconds = Double(arguments.flags["seconds"] ?? "5") ?? 5
        Barrier.waitFor(arguments.flags["barrier"])

        var reads = 0, parseFailures = 0, emptyReads = 0, missing = 0, ioErrors = 0
        var versions: Set<Int> = []
        var worst = 0.0
        var firstFailure: String?
        let started = BangerClock.uptimeNanos
        let deadline = started &+ UInt64(seconds * 1_000_000_000)

        while BangerClock.uptimeNanos < deadline {
            let began = BangerClock.uptimeNanos
            reads += 1
            guard let data = try? Data(contentsOf: store.tasksURL) else {
                if FileManager.default.fileExists(atPath: store.tasksURL.path) {
                    ioErrors += 1
                } else {
                    missing += 1
                }
                continue
            }
            if data.isEmpty {
                emptyReads += 1
                if firstFailure == nil { firstFailure = "zero-length file" }
                continue
            }
            do {
                let document = try JSONDecoder().decode(TaskDocument.self, from: data)
                versions.insert(document.tasks.count)
            } catch {
                parseFailures += 1
                if firstFailure == nil {
                    let head = String(decoding: data.prefix(120), as: UTF8.self)
                    firstFailure = "\(error.localizedDescription) — first 120 bytes: \(head)"
                }
            }
            worst = max(worst, BangerClock.millis(since: began))
        }

        let elapsed = BangerClock.millis(since: started)
        let output = BenchReadOutput(ok: parseFailures == 0 && emptyReads == 0 && ioErrors == 0,
                                     reads: reads,
                                     parseFailures: parseFailures,
                                     emptyReads: emptyReads,
                                     missingFile: missing,
                                     ioErrors: ioErrors,
                                     distinctVersions: versions.count,
                                     elapsedMs: elapsed,
                                     meanMsPerRead: reads == 0 ? 0 : elapsed / Double(reads),
                                     maxMsPerRead: worst,
                                     firstFailureDetail: firstFailure)
        try? Output.json(output)
        return output.ok ? ExitCode.ok.rawValue : ExitCode.failure.rawValue
    }

    // MARK: bench-churn

    /// Writes forever. Exists to be SIGKILLed at an arbitrary instant, which with any
    /// luck is between the temp write and the rename.
    static func benchChurn(_ arguments: ParsedArguments, _ store: TaskStore) -> Int32 {
        let prefix = arguments.flags["prefix"] ?? "churn\(getpid())"
        let seconds = Double(arguments.flags["seconds"] ?? "30") ?? 30
        Barrier.waitFor(arguments.flags["barrier"])
        let deadline = BangerClock.uptimeNanos &+ UInt64(seconds * 1_000_000_000)
        var attempted = 0, wrote = 0
        var firstError = ""
        while BangerClock.uptimeNanos < deadline {
            attempted += 1
            do {
                _ = try store.add(text: "\(prefix)-\(attempted)", source: "bench")
                wrote += 1
            } catch {
                // Counted, not swallowed: "wrote" must mean landed, or a
                // reported-versus-present comparison measures nothing.
                if firstError.isEmpty {
                    firstError = error.localizedDescription
                        .replacingOccurrences(of: "\"", with: "'")
                }
            }
        }
        Output.line("{\"ok\":\(firstError.isEmpty),\"attempted\":\(attempted),\"wrote\":\(wrote),"
                    + "\"failed\":\(attempted - wrote),\"firstError\":\"\(firstError)\"}")
        return ExitCode.ok.rawValue
    }
}

// MARK: - Small string helpers

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
