//  TaskStore.swift — the only thing that touches tasks.json.
//
//  Three processes write to this file: the app, the widget extension's App Intent, and a
//  shell process from an AI agent. Every read-modify-write is serialised by THREE things, in this
//  order, and the order never varies (that is what stops it deadlocking):
//
//    1. an NSLock, in-process;
//    2. flock(2) on a sibling lock file, cross-process — the one that is actually load
//       bearing. NSFileCoordinator only serialises processes that opt in, and gives no
//       observable guarantee. flock is held by the kernel and is released automatically
//       when the holder dies, INCLUDING on SIGKILL, so a writer shot between open and
//       rename cannot wedge the file for anyone else;
//    3. NSFileCoordinator, because the system expects it and a file presenter (Finder,
//       a text editor, Spotlight) will still be asked to flush before we read.
//
//  Every write goes out as write-to-temp → fsync → rename, so a reader never sees a
//  partial file and a crash never leaves a zero-length one. A half-written tasks.json is
//  a project-level failure.
//
//  THE DAY ROLLOVER IS A THREE-STEP TRANSACTION, and the order is the whole design:
//
//    1. journal — the day that is ending is written, whole and fsynced, to
//       archive/pending/<day>.json. If this fails the call throws and tasks.json is
//       not touched, so the old day is still exactly where it was;
//    2. replace — tasks.json becomes the new, empty day. Only now is the reset
//       irreversible, and the old day is already on disk twice over;
//    3. fold — history.json gets the day (upsert by date, so a retry never makes a second
//       entry), then the journal file moves to archive/<day>.json and stays there. A
//       history.json that cannot be read is moved aside to history.corrupt-<stamp>.json,
//       never overwritten.
//
//  A process killed anywhere in there leaves either the old tasks.json (step 1 is simply
//  redone) or a pending journal (step 3 is redone by the next load or write). Steps 1–2
//  run inside the tasks.json coordinator; step 3 runs after it has been released but
//  while the flock is still held, because nesting a second NSFileCoordinator for a
//  different file on the same thread is how you deadlock NSFileCoordinator.

import Foundation
import CryptoKit

public enum TaskStoreError: Error, LocalizedError {
    case containerUnavailable(String)
    case coordination(String)
    case decode(String)
    case encode(String)
    case taskNotFound(String)
    /// Parsed as JSON but breaks a rule the list depends on: duplicate or blank ids, a day
    /// that does not exist, an absurd streak, a size limit. See `validationProblem`.
    case invalidDocument(String)
    /// tasks.json is there and is zero bytes. Not the same thing as "no file yet".
    case emptyFile(String)
    /// The day that is ending could not be preserved, so the new day was NOT started.
    case archive(String)

    public var errorDescription: String? {
        switch self {
        case .containerUnavailable(let detail):
            return "Cannot reach the Banger container: \(detail)"
        case .coordination(let detail):
            return "File coordination failed: \(detail)"
        case .decode(let detail):
            return "tasks.json is not readable: \(detail)"
        case .encode(let detail):
            return "Could not encode tasks.json: \(detail)"
        case .taskNotFound(let selector):
            return "No task matching \"\(selector)\""
        case .invalidDocument(let detail):
            return "Not a valid task list: \(detail)"
        case .emptyFile(let detail):
            return "tasks.json is empty: \(detail)"
        case .archive(let detail):
            return "Could not archive the previous day: \(detail)"
        }
    }
}

/// What one `mutateReportingChange` call actually did.
public struct TaskMutation<Value> {
    /// Whatever the body returned.
    public var value: Value
    /// False when the body left the document exactly as it found it and no rollover was
    /// due. Then nothing was written and no change notification went out.
    public var changed: Bool
    /// The day this call rolled into the archive, when it did.
    public var archivedDay: String?
    /// Non-nil when history.json could not be brought up to date. The day is NOT lost —
    /// it is in archive/pending and the next load or write retries the fold — but the
    /// caller should say so rather than report an unqualified success.
    public var historyProblem: String?
}

extension TaskMutation: Sendable where Value: Sendable {}

public final class TaskStore: @unchecked Sendable {

    public static let shared = TaskStore()

    /// Where the container came from, for diagnostics.
    public let container: BangerContainer.Resolution
    public let tasksURL: URL
    public let historyURL: URL
    /// archive/<day>.json — one immutable file per day that ended with tasks on it.
    public let archiveURL: URL
    /// archive/pending/<day>.json — the rollover journal. Only exists between "the old day
    /// is safe" and "history.json has it"; normally empty and removed.
    public let pendingRolloverURL: URL
    /// The flock(2) file. Never contains data; only its kernel lock matters.
    public let lockURL: URL
    /// Written by the WIDGET EXTENSION only, when it reads the list AND the opt-in marker
    /// below exists. Proof that the sandboxed extension really can reach the shared file,
    /// and the only externally observable signal of when the widget last re-read it. See
    /// `readReceipt()`.
    public let readReceiptURL: URL
    /// `touch` this file to turn the widget read receipt on; delete it to turn it off.
    /// Off by default: every widget read would otherwise hash the list and fsync a file.
    public let receiptsEnabledURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private let crossProcessLock: InterProcessLock
    private let calendar: Calendar
    private let postsNotifications: Bool

    /// Guards `historyProblemStorage`. Separate from `lock` so reading it never waits on I/O.
    private let stateLock = NSLock()
    private var historyProblemStorage: String?

    /// How long a writer waits for the cross-process lock before giving up on it and
    /// falling through to coordination alone. Generous: the critical section is a
    /// sub-millisecond read-modify-write, so hitting this means something is genuinely
    /// stuck, and stalling forever would be worse than a degraded write.
    private let lockTimeout: TimeInterval = 5.0
    /// Readers wait far less. A read is safe without the lock anyway (writes land by
    /// rename, so a reader sees one whole version or another), and the widget's timeline
    /// read is on the latency path.
    private let readLockTimeout: TimeInterval = 0.25
    /// A zero-byte tasks.json younger than this is assumed to be a shell redirect that is
    /// still writing (`> tasks.json` truncates first), so nobody touches it. Older than
    /// this it is abandoned, and the write path moves it aside and starts a fresh day.
    private let emptyFileGrace: TimeInterval = 5.0

    public init(container: BangerContainer.Resolution = BangerContainer.resolve(),
                fileManager: FileManager = .default,
                calendar: Calendar = BangerDate.Rollover.calendar,
                postsNotifications: Bool = true) {
        self.container = container
        self.fileManager = fileManager
        self.calendar = calendar
        // A throwaway container (BANGER_CONTAINER) must not make the real, running app
        // celebrate or reload the real widget. Distributed notifications are machine-wide,
        // so a scratch `bangerctl done` would otherwise fire the real overlay and sound.
        // BANGER_NOTIFY=1 turns them back on for anyone who genuinely wants that.
        let scratchContainer = container.source == .override
            && ProcessInfo.processInfo.environment["BANGER_NOTIFY"] != "1"
        self.postsNotifications = postsNotifications && !scratchContainer
        self.tasksURL = container.url.appendingPathComponent("tasks.json", isDirectory: false)
        self.historyURL = container.url.appendingPathComponent("history.json", isDirectory: false)
        self.archiveURL = container.url.appendingPathComponent("archive", isDirectory: true)
        self.pendingRolloverURL = archiveURL.appendingPathComponent("pending", isDirectory: true)
        self.lockURL = container.url.appendingPathComponent(".tasks.lock", isDirectory: false)
        self.readReceiptURL = container.url.appendingPathComponent("widget-read-receipt.json",
                                                                  isDirectory: false)
        self.receiptsEnabledURL = container.url.appendingPathComponent("widget-receipts-enabled",
                                                                      isDirectory: false)
        self.crossProcessLock = InterProcessLock(path: lockURL.path)
    }

    /// The resolved container path, for `bangerctl path` and diagnostics.
    public var containerURL: URL { container.url }

    /// Non-nil only when the container is genuinely broken.
    ///
    /// ~/Library/Application Support/Banger is the shipping architecture, not a
    /// degraded mode: it is the one folder the widget can reach, through the
    /// home-relative temporary exception in BangerWidget.entitlements, so every process
    /// uses it (BangerContainer says why nothing else may).
    public var containerWarning: String? {
        guard let problem = container.creationErrorDescription else { return nil }
        return "cannot use \(container.url.path): \(problem)"
    }

    /// Why the last attempt to fold a rolled-over day into history.json failed, or nil
    /// when the last attempt succeeded (or there was nothing to fold). The day itself is
    /// safe in archive/pending either way; this is what a caller shows the user.
    public var lastHistoryProblem: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return historyProblemStorage
    }

    private func setHistoryProblem(_ problem: String?) {
        stateLock.lock()
        historyProblemStorage = problem
        stateLock.unlock()
    }

    /// True while a rolled-over day is journaled but not yet in history.json. One stat;
    /// cheap enough for every load.
    public var hasPendingRollover: Bool {
        fileManager.fileExists(atPath: pendingRolloverURL.path)
    }

    /// The days waiting in the journal, oldest first.
    public func pendingRolloverDays() -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: pendingRolloverURL.path)
        else { return [] }
        return names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    /// Whether the widget extension will leave a read receipt. See `receiptsEnabledURL`.
    public var widgetReceiptsEnabled: Bool {
        fileManager.fileExists(atPath: receiptsEnabledURL.path)
    }

    // MARK: - Coding

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Pretty and stable: an agent edits this file by hand from a shell.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: - Public API

    /// Reads the document, rolling it over to today first if it is stale, and finishing
    /// any rollover a killed process left half done. A missing file yields a fresh empty
    /// day rather than an error; a zero-byte one is recovered only once it is clearly
    /// abandoned (see `emptyFileGrace`), and throws until then.
    ///
    /// Only takes the write path when there is something to do, so the widget reading the
    /// list every refresh does not rewrite the file underneath everyone.
    ///
    /// Throws `.archive` when the day that ended could not be preserved: in that case
    /// nothing was changed. A rollover whose history.json update failed still succeeds —
    /// the day is safe in archive/pending — and says so through `lastHistoryProblem`.
    /// Use `reconcileDay()` for the strict version.
    public func load() throws -> TaskDocument {
        let current: TaskDocument
        do {
            current = try peek()
        } catch TaskStoreError.emptyFile(_) {
            // Only the write path, holding the exclusive lock, may decide it is abandoned.
            return try mutate { $0 }
        }
        guard current.date != BangerDate.today(calendar: calendar) || hasPendingRollover else {
            return current
        }
        return try mutate { $0 }
    }

    /// `load()`, but it also throws when a rolled-over day is still waiting to reach
    /// history.json. For a scheduler that must only mark a rollover handled once every
    /// step of it has landed, and retry otherwise.
    @discardableResult
    public func reconcileDay() throws -> TaskDocument {
        let document = try load()
        if hasPendingRollover {
            let days = pendingRolloverDays().joined(separator: ", ")
            throw TaskStoreError.archive(
                "\(days.isEmpty ? "a rolled-over day" : days) is safe in "
                + "\(pendingRolloverURL.path) but history.json was not updated"
                + (lastHistoryProblem.map { ": \($0)" } ?? ""))
        }
        return document
    }

    /// Retries folding journaled days into history.json. Throws if that fails. Returns
    /// how many days were folded.
    @discardableResult
    public func foldPendingHistory() throws -> Int {
        try withLock {
            try withWriteSerialisation {
                do {
                    let count = try foldPendingRollovers()
                    setHistoryProblem(nil)
                    return count
                } catch {
                    setHistoryProblem(error.localizedDescription)
                    throw error
                }
            }
        }
    }

    /// Reads without rolling over or writing. For diagnostics; normal callers want `load()`.
    public func peek() throws -> TaskDocument {
        let read: (document: TaskDocument, bytes: Data?) = try withLock {
            var result: Result<(document: TaskDocument, bytes: Data?), Error>?
            try coordinateRead { url in
                result = Result { try self.readDocument(at: url) }
            }
            guard let result else {
                throw TaskStoreError.coordination("read of \(tasksURL.path) never ran")
            }
            return try result.get()
        }
        // After every lock is released: a diagnostic must never sit on the read path's
        // critical section, and it is opt-in so a normal widget read writes nothing at all.
        if let bytes = read.bytes, TaskStore.isWidgetExtension, widgetReceiptsEnabled {
            writeReadReceipt(for: read.document, bytes: bytes)
        }
        return read.document
    }

    /// Writes `document` as the whole of tasks.json. Validated like an import, except
    /// that a future date is allowed (the next rollover archives it). A previous day
    /// still sitting in tasks.json is journaled first, exactly as a rollover would.
    public func save(_ document: TaskDocument) throws {
        _ = try replaceDocument(document, futureDates: .allow)
    }

    /// Coordinated read-modify-write in one hop. The closure sees today's document
    /// (rolled over if needed) and whatever it leaves behind is what gets written.
    ///
    /// When the closure changes nothing and no rollover was due, nothing is written and
    /// no change notification is posted. `mutateReportingChange` says which happened.
    @discardableResult
    public func mutate<T>(_ body: (inout TaskDocument) throws -> T) throws -> T {
        try mutateReportingChange(body).value
    }

    /// `mutate`, reporting whether anything was written, what was archived, and whether
    /// history.json is behind.
    public func mutateReportingChange<T>(_ body: (inout TaskDocument) throws -> T) throws -> TaskMutation<T> {
        var changed = false
        var archivedDay: String?
        var historyProblem: String?
        let value: T = try withLock {
            try withWriteSerialisation {
                var result: Result<T, Error>?
                try coordinateWriting(tasksURL) { url in
                    do {
                        var recovered = false
                        var document = try self.readDocumentForWrite(at: url, recovered: &recovered)
                        let original = document
                        let rolled = self.rollOverIfNeeded(&document)
                        let value = try body(&document)
                        if rolled || recovered || document != original {
                            // Encode and validate first: if the new document cannot be
                            // written, nothing — journal included — should move.
                            let bytes = try self.encodeForDisk(document, validate: true)
                            if rolled, !original.tasks.isEmpty {
                                // Step 1. The rename below is the irreversible moment;
                                // the day that is ending goes to disk on its own first.
                                try self.journal(original)
                                archivedDay = original.date
                                Self.faultPoint("afterJournal")
                            }
                            // Step 2.
                            try Self.atomicallyReplace(url, with: bytes)
                            changed = true
                            if archivedDay != nil { Self.faultPoint("afterTasksReplace") }
                        }
                        result = .success(value)
                    } catch {
                        result = .failure(error)
                    }
                }
                guard let result else {
                    throw TaskStoreError.coordination("write of \(tasksURL.path) never ran")
                }
                // Step 3, and the retry of any earlier step 3 that died. Still under the
                // flock, but after the tasks.json coordinator has been let go.
                historyProblem = foldIfPending()
                return try result.get()
            }
        }
        if changed {
            postTasksChanged()
            sweepOnceInBackground()
        }
        return TaskMutation(value: value, changed: changed, archivedDay: archivedDay,
                            historyProblem: historyProblem)
    }

    /// Replaces tasks.json wholesale with bytes that came from somewhere else, taking the
    /// same lock every other writer takes and refusing anything that is not a valid
    /// TaskDocument.
    ///
    /// This exists for exactly one reason. The obvious way for a shell script to write the
    /// whole list is `echo '{...}' > tasks.json`, and that is genuinely unsafe: a redirect
    /// truncates the file in place and a reader in the gap sees an empty or half-written
    /// document. So an agent gets a primitive that is as easy to use and is not a trap:
    /// `bangerctl set-json < file`.
    ///
    /// Refused, with tasks.json left exactly as it was: anything over
    /// `TaskDocumentLimits.maxDocumentBytes`, anything that is not a task document, and
    /// anything that fails `validationProblem` — including a date after today's Banger
    /// day, which the very next read would otherwise roll straight into history. A
    /// previous day still in tasks.json is journaled before it is replaced; a tasks.json
    /// that cannot be parsed is moved aside to tasks.corrupt-<stamp>.json, not destroyed.
    ///
    /// Returns the document that was written.
    @discardableResult
    public func replaceAll(withJSON data: Data) throws -> TaskDocument {
        guard data.count <= TaskDocumentLimits.maxDocumentBytes else {
            throw TaskStoreError.invalidDocument(
                "set-json was handed \(data.count) bytes; the limit is "
                + "\(TaskDocumentLimits.maxDocumentBytes). tasks.json was not changed.")
        }
        let incoming: TaskDocument
        do {
            incoming = try JSONDecoder().decode(TaskDocument.self, from: data)
        } catch {
            throw TaskStoreError.decode("the JSON handed to set-json is not a task document: "
                                        + error.localizedDescription)
        }
        return try replaceDocument(incoming,
                                   futureDates: .reject(today: BangerDate.today(calendar: calendar)))
    }

    private func replaceDocument(_ incoming: TaskDocument,
                                 futureDates: TaskDocument.FutureDatePolicy) throws -> TaskDocument {
        if let problem = incoming.validationProblem(futureDates: futureDates) {
            throw TaskStoreError.invalidDocument("\(problem). tasks.json was not changed.")
        }
        var changed = false
        try withLock {
            try withWriteSerialisation {
                var thrown: Error?
                try coordinateWriting(tasksURL) { url in
                    do {
                        let bytes = try self.encodeForDisk(incoming, validate: true)
                        guard try self.keepWhatIsAbout(toBeReplacedBy: incoming, at: url) else { return }
                        try Self.atomicallyReplace(url, with: bytes)
                        changed = true
                    } catch {
                        thrown = error
                    }
                }
                _ = foldIfPending()
                if let thrown { throw thrown }
            }
        }
        if changed {
            postTasksChanged()
            sweepOnceInBackground()
        }
        return incoming
    }

    /// Before a wholesale replace: journal a previous day that never got rolled over, and
    /// move an unparseable file aside. Returns false when the file already holds exactly
    /// `incoming`, so there is nothing to write.
    private func keepWhatIsAbout(toBeReplacedBy incoming: TaskDocument, at url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // We cannot see what is there, so we cannot promise to keep it. Refuse.
            throw TaskStoreError.decode("\(url.path): \(error.localizedDescription) "
                                        + "— the file is there and could not be read")
        }
        guard !data.isEmpty else { return true }   // nothing in it to keep
        if let current = try? JSONDecoder().decode(TaskDocument.self, from: data),
           current.validationProblem() == nil {
            if current == incoming { return false }
            if current.date != BangerDate.today(calendar: calendar), !current.tasks.isEmpty {
                try journal(current)
            }
            return true
        }
        try preserveAside(url, in: container.url, stem: "tasks.corrupt")
        return true
    }

    // MARK: - Task operations

    /// Appends a task and returns it.
    @discardableResult
    public func add(text: String, source: String = BangerSource.me) throws -> BangerTask {
        try mutate { document in
            var task = BangerTask(text: text, source: source)
            let existing = Set(document.tasks.map(\.id))
            while existing.contains(task.id) { task.id = BangerTask.newID() }
            document.tasks.append(task)
            return task
        }
    }

    /// Sets a task's done flag. Returns the completion payload when the task went
    /// false -> true (and posts the celebration notification), nil otherwise.
    ///
    /// A set, not a toggle, and idempotent like the widget's: asking for the state the
    /// task is already in changes nothing — in particular a repeated `done` keeps the
    /// original `completedAt` — and writes nothing.
    @discardableResult
    public func setDone(_ done: Bool, matching selector: TaskSelector) throws -> TaskCompletionPayload? {
        let payload: TaskCompletionPayload? = try mutate { document in
            guard let index = document.resolveIndex(selector) else {
                throw TaskStoreError.taskNotFound(Self.describe(selector))
            }
            guard document.tasks[index].done != done else { return nil }
            document.tasks[index].done = done
            document.tasks[index].completedAt = done ? Date() : nil
            guard done else { return nil }
            return Self.completionPayload(for: document, index: index)
        }
        if let payload, postsNotifications { payload.post() }
        return payload
    }

    @discardableResult
    public func remove(matching selector: TaskSelector) throws -> BangerTask {
        try mutate { document in
            guard let index = document.resolveIndex(selector) else {
                throw TaskStoreError.taskNotFound(Self.describe(selector))
            }
            return document.tasks.remove(at: index)
        }
    }

    /// Empties today's list. Streak state is untouched. Returns how many were removed.
    @discardableResult
    public func clearToday() throws -> Int {
        try mutate { document in
            let count = document.tasks.count
            document.tasks.removeAll()
            return count
        }
    }

    /// Builds the payload for an already-completed task without changing anything.
    /// The app can use this to replay a celebration.
    public func completionPayload(forTaskWithID id: String) throws -> TaskCompletionPayload? {
        let document = try load()
        guard let index = document.index(ofTaskWithID: id) else { return nil }
        return Self.completionPayload(for: document, index: index)
    }

    public static func completionPayload(for document: TaskDocument, index: Int) -> TaskCompletionPayload {
        let task = document.tasks[index]
        return TaskCompletionPayload(
            taskID: task.id,
            taskText: task.text,
            taskIndex: index,
            taskCount: document.tasks.count,
            remaining: document.openCount,
            streakDays: document.streakDays,
            source: task.source,
            fullyCleared: document.isFullyCleared,
            date: document.date,
            seed: TaskCompletionPayload.seed(date: document.date, taskID: task.id, taskIndex: index)
        )
    }

    // MARK: - Rollover

    /// If the document is not today's, start a fresh empty day and carry streak state
    /// forward. Returns whether it rolled; the caller still holds the old day and
    /// decides whether it is worth archiving (a day with nothing on it is not).
    ///
    /// A day that had tasks and ended with all of them done extends the streak; a day
    /// that had tasks and did not ends it. A day with no tasks on it at all is not a
    /// failure to clear, so it leaves the streak alone.
    private func rollOverIfNeeded(_ document: inout TaskDocument) -> Bool {
        let today = BangerDate.today(calendar: calendar)
        guard document.date != today else { return false }

        let previous = document
        var fresh = TaskDocument(date: today,
                                 tasks: [],
                                 streakDays: previous.streakDays,
                                 lastClearedDate: previous.lastClearedDate,
                                 extra: previous.extra)

        if !previous.tasks.isEmpty {
            if previous.isFullyCleared {
                // tasks.json is hand-editable on purpose, so a streak of Int.max is
                // reachable. Saturate rather than trap: a crash here would take out
                // the app, the widget and the CLI at once, every time the file opened.
                fresh.streakDays = previous.streakDays < Int.max ? previous.streakDays + 1 : Int.max
                fresh.lastClearedDate = previous.date
            } else {
                fresh.streakDays = 0
            }
        }

        document = fresh
        return true
    }

    /// Step 1: archive/pending/<day>.json, whole and fsynced. Throws `.archive` on any
    /// failure, and the caller must then not replace tasks.json.
    ///
    /// Must run with the write serialisation held. It deliberately takes no coordinator
    /// of its own: it runs inside the tasks.json one, and only TaskStore writers — all
    /// behind the same flock — ever write these files.
    private func journal(_ day: TaskDocument) throws {
        do {
            let bytes = try encodeForDisk(day, validate: false)
            try fileManager.createDirectory(at: pendingRolloverURL, withIntermediateDirectories: true)
            let target = pendingRolloverURL.appendingPathComponent("\(day.date).json", isDirectory: false)
            if let existing = try? Data(contentsOf: target) {
                if existing == bytes { return }
                // A different version of the same day is already waiting — set-json put
                // an old day back, say. Keep that one beside the archive, not over it.
                try preserveAside(target, in: archiveURL, stem: "\(day.date).superseded")
            }
            try Self.atomicallyReplace(target, with: bytes)
        } catch {
            throw TaskStoreError.archive(
                "\(day.date) could not be written to \(pendingRolloverURL.path) "
                + "(\(error.localizedDescription)); tasks.json was left as it was")
        }
    }

    /// Runs step 3 when a journal is waiting, records the outcome in
    /// `lastHistoryProblem`, and returns the problem (nil on success or nothing to do).
    /// Never throws: by the time it runs the day is already safe on disk.
    private func foldIfPending() -> String? {
        guard hasPendingRollover else {
            setHistoryProblem(nil)
            return nil
        }
        do {
            try foldPendingRollovers()
            setHistoryProblem(nil)
            return nil
        } catch {
            let problem = "history.json was not updated (\(error.localizedDescription)); "
                + "the day is safe in \(pendingRolloverURL.path) and will be retried"
            setHistoryProblem(problem)
            return problem
        }
    }

    /// Step 3: every journaled day into history.json, then into archive/<day>.json.
    ///
    /// Must be called with the write serialisation held and NO NSFileCoordinator open on
    /// this thread. Idempotent: history is an upsert by date, and a journal file whose
    /// twin is already in the archive is simply dropped.
    @discardableResult
    private func foldPendingRollovers() throws -> Int {
        let directory = pendingRolloverURL
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)

        // Anything dot-prefixed is a temp file from a journal write that died before its
        // rename. Every journal write happens behind the flock we hold, so none is live.
        for name in names where name.hasPrefix(".") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }

        var days: [(url: URL, bytes: Data, document: TaskDocument)] = []
        for name in names.sorted() where !name.hasPrefix(".") && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let bytes = try Data(contentsOf: url)
            guard let document = try? JSONDecoder().decode(TaskDocument.self, from: bytes) else {
                // Cannot be folded. Keep it where a human will find it, and move on.
                try preserveAside(url, in: archiveURL,
                                  stem: "\(String(name.dropLast(".json".count))).unreadable")
                continue
            }
            days.append((url, bytes, document))
        }

        if !days.isEmpty {
            try coordinateWriting(historyURL) { url in
                var history = try self.readHistoryPreservingCorrupt(at: url)
                for day in days {
                    // Replacing rather than appending keeps this idempotent when a retry,
                    // or two processes noticing the same stale day, fold it twice.
                    history.days.removeAll { $0.date == day.document.date }
                    history.days.append(day.document)
                }
                history.days.sort { $0.date < $1.date }
                var data: Data
                do {
                    data = try self.encoder.encode(history)
                } catch {
                    throw TaskStoreError.encode("history.json: \(error.localizedDescription)")
                }
                data.append(0x0A)
                try Self.atomicallyReplace(url, with: data)
            }
            Self.faultPoint("afterHistoryWrite")
            for day in days { try fileIntoArchive(day.url, bytes: day.bytes) }
        }

        // Only succeeds once the directory is empty, which is exactly when `load()`
        // should stop taking the write path to look at it.
        _ = rmdir(directory.path)
        return days.count
    }

    /// The history to fold into. Absent -> empty. Present but unreadable or unparseable
    /// (including a directory squatting on the name) -> moved aside to
    /// history.corrupt-<stamp>.json first, never overwritten.
    private func readHistoryPreservingCorrupt(at url: URL) throws -> TaskHistory {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let isDanglingLink = !exists
            && (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard exists || isDanglingLink else { return TaskHistory() }
        if exists, !isDirectory.boolValue,
           let data = try? Data(contentsOf: url), !data.isEmpty,
           let history = try? JSONDecoder().decode(TaskHistory.self, from: data) {
            return history
        }
        try preserveAside(url, in: container.url, stem: "history.corrupt")
        return TaskHistory()
    }

    /// pending/<day>.json -> archive/<day>.json. A different archive for the same day is
    /// kept as <day>.superseded-<stamp>.json rather than replaced.
    private func fileIntoArchive(_ source: URL, bytes: Data) throws {
        let target = archiveURL.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        if let existing = try? Data(contentsOf: target) {
            if existing == bytes {
                try fileManager.removeItem(at: source)
                return
            }
            try preserveAside(target, in: archiveURL,
                              stem: "\(target.deletingPathExtension().lastPathComponent).superseded")
        }
        guard rename(source.path, target.path) == 0 else {
            throw TaskStoreError.coordination(
                "rename \(source.path) -> \(target.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Renames `url` to <directory>/<stem>-<UTC stamp>[-n].json and returns where it went.
    @discardableResult
    private func preserveAside(_ url: URL, in directory: URL, stem: String) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "\(stem)-\(BangerDate.fileStamp())"
        var candidate = directory.appendingPathComponent("\(base).json", isDirectory: false)
        var attempt = 1
        while fileManager.fileExists(atPath: candidate.path)
                || (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            candidate = directory.appendingPathComponent("\(base)-\(attempt).json", isDirectory: false)
            attempt += 1
        }
        guard rename(url.path, candidate.path) == 0 else {
            throw TaskStoreError.coordination(
                "could not move \(url.path) aside to \(candidate.path): \(String(cString: strerror(errno)))")
        }
        return candidate
    }

    // MARK: - Coordinated file access

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func coordinateRead(_ body: (URL) throws -> Void) throws {
        try ensureContainer()
        // A shared lock, and we proceed without it if a writer is being slow: reads are
        // safe regardless, because every write lands by rename.
        let held = crossProcessLock.acquire(exclusive: false, timeout: readLockTimeout)
        defer { if held { crossProcessLock.release() } }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(readingItemAt: tasksURL,
                               options: .withoutChanges,
                               error: &coordinationError) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let coordinationError { throw TaskStoreError.coordination(coordinationError.localizedDescription) }
        if let thrown { throw thrown }
    }

    /// THE serialisation point for writers. Everything inside is a critical section that
    /// no other process on this machine is inside.
    ///
    /// BANGER_BENCH_NO_LOCK removes the serialisation so a stress test can show the
    /// failures it prevents. Nothing but that test ever sets it.
    ///   1 = no flock, NSFileCoordinator still in place
    ///   2 = neither: a bare read-modify-write, which is what most people would write
    private func withWriteSerialisation<T>(_ body: () throws -> T) throws -> T {
        try ensureContainer()
        guard Self.serialisationLevel == 0 else { return try body() }
        guard crossProcessLock.acquire(exclusive: true, timeout: lockTimeout) else {
            throw TaskStoreError.coordination(
                "could not take \(lockURL.path) within \(Int(lockTimeout * 1000)) ms — "
                + "another writer is wedged")
        }
        defer { crossProcessLock.release() }
        return try body()
    }

    /// 0 = everything on (the only value any shipping build ever sees).
    static let serialisationLevel =
        Int(ProcessInfo.processInfo.environment["BANGER_BENCH_NO_LOCK"] ?? "0") ?? 0

    /// "" for every shipping build. A stress test sets it to "midWrite" or
    /// "beforeRename" to kill a writer at an exact point inside `atomicallyReplace`.
    static let dieAt = ProcessInfo.processInfo.environment["BANGER_BENCH_DIE_AT"] ?? ""

    /// Kill points between the rollover's steps, for the crash tests. Compiled in only
    /// when BANGER_FAULT_INJECTION is defined, which no target in project.yml does: a
    /// test harness builds these sources itself with `-D BANGER_FAULT_INJECTION` and sets
    /// BANGER_FAULT_AT to afterJournal, afterTasksReplace or afterHistoryWrite.
    #if BANGER_FAULT_INJECTION
    static func faultPoint(_ name: String) {
        if ProcessInfo.processInfo.environment["BANGER_FAULT_AT"] == name { kill(getpid(), SIGKILL) }
    }
    #else
    @inline(__always) static func faultPoint(_ name: String) {}
    #endif

    /// Write coordination on one file. `.forMerging` takes the write lock and asks any
    /// presenter to flush first, which is what makes it safe to read the current contents
    /// inside the block. Never call this while another coordinator is open on this thread.
    private func coordinateWriting(_ target: URL, _ body: (URL) throws -> Void) throws {
        if Self.serialisationLevel >= 2 {
            try body(target)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var thrown: Error?
        coordinator.coordinate(writingItemAt: target,
                               options: .forMerging,
                               error: &coordinationError) { url in
            do { try body(url) } catch { thrown = error }
        }
        if let coordinationError { throw TaskStoreError.coordination(coordinationError.localizedDescription) }
        if let thrown { throw thrown }
    }

    private func ensureContainer() throws {
        if let problem = container.creationErrorDescription {
            throw TaskStoreError.containerUnavailable("\(container.url.path): \(problem)")
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: container.url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw TaskStoreError.containerUnavailable("\(container.url.path) is not a directory")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: container.url, withIntermediateDirectories: true)
        } catch {
            throw TaskStoreError.containerUnavailable("\(container.url.path): \(error.localizedDescription)")
        }
    }

    /// The one read of tasks.json, shared by every path, and the validation boundary for
    /// persisted documents. Returns the bytes too (nil when there was no file) so the
    /// widget's opt-in receipt can hash exactly what was decoded.
    private func readDocument(at url: URL) throws -> (document: TaskDocument, bytes: Data?) {
        // "No file yet" and "a file I cannot read" are NOT the same answer, and
        // collapsing them is how a list gets deleted. `mutate` writes back whatever
        // this returns, so answering "empty day" to an EACCES or an EIO would put an
        // empty day on disk over the real one. Absent -> fresh day. Present and
        // unreadable -> throw, exactly like a parse failure.
        guard fileManager.fileExists(atPath: url.path) else {
            return (TaskDocument(date: BangerDate.today(calendar: calendar)), nil)
        }
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > TaskDocumentLimits.maxDocumentBytes {
            throw TaskStoreError.invalidDocument("\(url.path) is \(size) bytes; the limit is "
                                                 + "\(TaskDocumentLimits.maxDocumentBytes) — fix or move that file by hand")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TaskStoreError.decode("\(url.path): \(error.localizedDescription) "
                                        + "— the file is there and could not be read")
        }
        // Zero bytes is not "no file". Every writer here lands by rename, so an empty
        // tasks.json is someone's `> tasks.json` in flight, or the wreck of one. Either
        // way it is not ours to treat as an empty day, or the next add would silently
        // replace it. See `readDocumentForWrite` for the recovery.
        guard !data.isEmpty else {
            throw TaskStoreError.emptyFile("\(url.path) is 0 bytes — if nothing is writing it, "
                                           + "the next write moves it aside and starts a fresh day")
        }
        let document: TaskDocument
        do {
            document = try JSONDecoder().decode(TaskDocument.self, from: data)
        } catch {
            // Refuse rather than "recover" by starting fresh: silently discarding the
            // list is worse than a wedged tool, and the file is hand-editable.
            throw TaskStoreError.decode("\(url.path): \(error.localizedDescription) "
                                        + "— fix or move that file by hand")
        }
        if let problem = document.validationProblem(futureDates: .allow) {
            throw TaskStoreError.invalidDocument("\(url.path): \(problem) — fix or move that file by hand")
        }
        return (document, data)
    }

    /// `readDocument` for the write path, which alone may recover a zero-byte file.
    ///
    /// The policy, chosen as the safest of the options: a zero-byte tasks.json younger
    /// than `emptyFileGrace` throws (a redirect may be mid-write, and renaming it away
    /// would send that writer's bytes into the aside file). Older than that, it is moved
    /// aside to tasks.empty-<stamp>.json — kept, not deleted — and the day starts fresh.
    /// Nothing with content is ever
    /// replaced this way.
    private func readDocumentForWrite(at url: URL, recovered: inout Bool) throws -> TaskDocument {
        do {
            return try readDocument(at: url).document
        } catch TaskStoreError.emptyFile(let detail) {
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard let modified, Date().timeIntervalSince(modified) >= emptyFileGrace else {
                throw TaskStoreError.emptyFile(detail)
            }
            try preserveAside(url, in: container.url, stem: "tasks.empty")
            recovered = true
            return TaskDocument(date: BangerDate.today(calendar: calendar))
        }
    }

    /// Encodes a document the way it lands on disk, and proves the bytes parse back before
    /// anything is allowed to replace a good file. `validate` applies the domain rules too;
    /// it is off only for archive copies of a day that was already validated when read.
    private func encodeForDisk(_ document: TaskDocument, validate: Bool) throws -> Data {
        if validate, let problem = document.validationProblem(futureDates: .allow) {
            throw TaskStoreError.invalidDocument(problem)
        }
        var data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw TaskStoreError.encode(error.localizedDescription)
        }
        data.append(0x0A) // trailing newline: an agent opens this in a text editor

        // Last gate before the bytes leave the process. Encoding valid JSON is the
        // encoder's job, but this file is the product's single point of failure, so we
        // prove the bytes parse before we let them replace a good file.
        guard data.count > 2, data.first == UInt8(ascii: "{") else {
            throw TaskStoreError.encode("refusing to write \(data.count) bytes that are not a JSON object")
        }
        do {
            _ = try JSONDecoder().decode(TaskDocument.self, from: data)
        } catch {
            throw TaskStoreError.encode("encoded tasks.json does not parse back: \(error.localizedDescription)")
        }
        return data
    }

    /// write-to-temp → fsync → rename. Three properties we need and `Data.write(.atomic)`
    /// does not give us all of:
    ///
    ///  * a reader only ever sees one whole version, because rename(2) is atomic;
    ///  * the bytes are on the disk before the rename, so a panic or a power cut cannot
    ///    leave a present-but-empty tasks.json;
    ///  * the temp file's name is ours, so a writer killed between the write and the
    ///    rename leaves a droppings file we can recognise and sweep instead of an opaque
    ///    `.dat.nosync…` that accumulates forever.
    private static func atomicallyReplace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let template = directory
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).XXXXXX").path
        var bytes = Array(template.utf8CString)

        let fd = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            mkstemp(buffer.baseAddress!)
        }
        guard fd >= 0 else {
            throw TaskStoreError.coordination("mkstemp in \(directory.path): \(String(cString: strerror(errno)))")
        }
        let temporaryPath = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                                   as: UTF8.self)

        func abandon(_ message: String) -> TaskStoreError {
            close(fd)
            unlink(temporaryPath)
            return TaskStoreError.coordination("writing \(url.path): \(message)")
        }

        var written = 0
        let halfway = data.count / 2
        let dieHalfway = Self.dieAt == "midWrite"
        let result: Int32? = data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            while written < data.count {
                // BENCH ONLY: stop at the halfway mark so the kill below happens with a
                // genuinely half-written temp file. Without this the first write(2) takes
                // the whole buffer and there is no halfway moment to die at.
                var chunk = data.count - written
                if dieHalfway && written < halfway { chunk = halfway - written }
                let n = write(fd, base.advanced(by: written), chunk)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if n == 0 { return EIO }
                written += n
                // BENCH ONLY: die with half the bytes in the temp file and nothing
                // fsynced, which is the worst moment there is.
                if dieHalfway && written >= halfway { kill(getpid(), SIGKILL) }
            }
            return nil
        }
        if let result { throw abandon(String(cString: strerror(result))) }

        // BENCH ONLY. A stress test sets this to make the process die at an exact point
        // inside the write, because an external SIGKILL fired at a random instant
        // essentially never lands here: the critical section is well under a
        // millisecond. A kill test that never hits the window it is testing is not a
        // test, so the window is hit on purpose.
        //
        // SIGKILL, not exit(): the point is to prove the KERNEL releases the flock and
        // that no cleanup code of ours gets to run. Nothing but the test sets this.
        if Self.dieAt == "beforeRename" { close(fd); kill(getpid(), SIGKILL) }

        // fsync(2), deliberately NOT F_FULLFSYNC. fsync orders the data ahead of the
        // rename, which is what stops a crash leaving a present-but-empty tasks.json.
        // F_FULLFSYNC additionally flushes the drive's own cache and costs over ten times
        // as much as fsync, on the celebration's latency path, to insure a to-do list
        // against a power cut in the last millisecond. Not worth it here.
        guard fsync(fd) == 0 else {
            throw abandon("fsync: \(String(cString: strerror(errno)))")
        }
        // The file the world will see should be readable by the world, not 0600.
        _ = fchmod(fd, 0o644)
        close(fd)

        guard rename(temporaryPath, url.path) == 0 else {
            unlink(temporaryPath)
            throw TaskStoreError.coordination("rename onto \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Removes temp files left behind by a writer that died between mkstemp and rename —
    /// tasks.json's, history.json's, the receipt's, and the rollover journal's. Only
    /// touches files older than `age`, so with the default it can never race a live
    /// writer. Returns how many it removed.
    @discardableResult
    public func sweepAbandonedWrites(olderThan age: TimeInterval = 60) -> Int {
        let containerPrefixes = [tasksURL, historyURL, readReceiptURL]
            .map { ".\($0.lastPathComponent).tmp." }
        var removed = 0
        func sweep(_ directory: URL, matches: (String) -> Bool) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where matches(name) {
                let candidate = directory.appendingPathComponent(name, isDirectory: false)
                let attributes = try? fileManager.attributesOfItem(atPath: candidate.path)
                let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
                guard Date().timeIntervalSince(modified) > age else { continue }
                if (try? fileManager.removeItem(at: candidate)) != nil { removed += 1 }
            }
        }
        sweep(container.url) { name in containerPrefixes.contains { name.hasPrefix($0) } }
        for directory in [archiveURL, pendingRolloverURL] {
            sweep(directory) { $0.hasPrefix(".") && $0.contains(".json.tmp.") }
        }
        return removed
    }

    private func postTasksChanged() {
        guard postsNotifications else { return }
        // The post carries the CLOCK_UPTIME_RAW instant it went out, as a bare string in
        // `object`. Two reasons it is the object and not userInfo: a sandboxed poster (the
        // widget extension) is not allowed to attach a userInfo dictionary, and every
        // process on this machine reads the same uptime clock, so a receiver can subtract
        // and get a true one-way transport time with no clock-sync argument.
        let stamp = String(BangerClock.uptimeNanos)
        let center = DistributedNotificationCenter.default()
        for name in [BangerNotification.tasksChanged, BangerNotification.tasksChangedGroupPrefixed] {
            center.postNotificationName(name, object: stamp, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Runs `sweepAbandonedWrites` once in this process's life, on a background queue,
    /// after the first successful write.
    ///
    /// A writer that is SIGKILLed between mkstemp and rename leaves a `.tasks.json.tmp.*`
    /// file behind. Nothing is broken by one, but on a machine that runs for months that
    /// is litter that only ever grows. Sweeping inside the write would put a directory
    /// listing on the celebration's latency path, which is the one place in this project
    /// that cannot afford it — so it happens once, later, off-thread, and its failure is
    /// ignored.
    private func sweepOnceInBackground() {
        Self.sweepGate.lock()
        let alreadyDone = Self.didSweep
        Self.didSweep = true
        Self.sweepGate.unlock()
        guard !alreadyDone else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            _ = self?.sweepAbandonedWrites()
        }
    }

    private static let sweepGate = NSLock()
    nonisolated(unsafe) private static var didSweep = false

    private static func describe(_ selector: TaskSelector) -> String {
        switch selector {
        case .id(let id): return id
        case .position(let position): return String(position)
        case .idOrPosition(let raw): return raw
        }
    }
}

// MARK: - The widget read receipt

/// Written by the widget extension, and by nothing else, every time it reads tasks.json —
/// but ONLY while `<container>/widget-receipts-enabled` exists. It is a diagnostic, and
/// hashing the list and fsyncing a file on every widget refresh (in the folder the app's
/// file watcher is watching) is not something normal use should pay for. Turn it on with
/// `touch <container>/widget-receipts-enabled`; `bangerctl receipt` says so when it is off.
///
/// This exists because "the entitlement is present" is not evidence. A sandboxed
/// extension either reaches ~/Library/Application Support/Banger or it does not, and the
/// only honest way to know is to make the extension leave a note in that folder saying
/// what it just read. `bangerctl receipt` prints it; `digest` is a SHA-256 of the exact
/// bytes the extension decoded, so it can be checked against the file on disk.
public struct WidgetReadReceipt: Codable, Sendable, Equatable {
    /// ISO 8601, when the extension read the file.
    public var at: String
    /// CLOCK_UPTIME_RAW nanoseconds — comparable with any other process on this machine,
    /// which is what makes an intent-to-widget-redraw latency measurable.
    public var atUptimeNs: UInt64
    public var pid: Int32
    /// The reading process's bundle. Ends in .appex when it really is the widget.
    public var bundlePath: String
    public var bundleIdentifier: String
    public var processName: String
    /// True when NSHomeDirectory() has been redirected into a sandbox container, i.e. the
    /// reader is genuinely sandboxed and still got to the shared file.
    public var sandboxed: Bool
    public var sandboxHome: String
    public var realHome: String
    public var tasksPath: String
    public var bytes: Int
    public var digestSHA256: String
    public var date: String
    public var taskCount: Int
    public var openCount: Int
    /// The first task's text, verbatim. A nonce put in the file by a test shows up
    /// here, which is the whole point: it proves the read, not the permission.
    public var firstTaskText: String

    public var isAppExtension: Bool { bundlePath.hasSuffix(".appex") }
}

public extension TaskStore {

    /// True when this process is a macOS app extension — the widget.
    static var isWidgetExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// The last note the widget extension left, or nil if it has never read the file.
    func readReceipt() -> WidgetReadReceipt? {
        guard let data = try? Data(contentsOf: readReceiptURL), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WidgetReadReceipt.self, from: data)
    }

    /// Deletes the receipt, so the next one is unambiguously new. Used by tests.
    func clearReadReceipt() {
        try? FileManager.default.removeItem(at: readReceiptURL)
    }

    internal func writeReadReceipt(for document: TaskDocument, bytes data: Data) {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sandboxHome = NSHomeDirectory()
        let realHome = BangerContainer.realHomeDirectory.path
        let receipt = WidgetReadReceipt(
            at: BangerDate.timestampString(Date()),
            atUptimeNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            pid: getpid(),
            bundlePath: Bundle.main.bundleURL.path,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            processName: ProcessInfo.processInfo.processName,
            sandboxed: sandboxHome != realHome,
            sandboxHome: sandboxHome,
            realHome: realHome,
            tasksPath: tasksURL.path,
            bytes: data.count,
            digestSHA256: digest,
            date: document.date,
            taskCount: document.tasks.count,
            openCount: document.openCount,
            firstTaskText: document.tasks.first?.text ?? ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(receipt) else { return }
        // Called by `peek()` after every lock and coordinator has been released: it is a
        // different file, it is written by one process, and nothing blocks on it. If it fails, it fails silently
        // — a diagnostic must never be able to break the thing it is diagnosing.
        try? Self.atomicallyReplace(readReceiptURL, with: encoded)
    }
}

// MARK: - Cross-process lock

/// flock(2) on a sibling file.
///
/// Why not rely on NSFileCoordinator alone: coordination is cooperative between processes
/// that all use it, it has no timeout we control, and — the part that matters — there is
/// no way to observe from outside whether it actually held. flock is a kernel lock on an
/// open file description. Two processes cannot both hold it exclusively, the kernel drops
/// it when the holder exits *however* it exits (including SIGKILL, including a panic), and
/// a stale lock file left on disk is harmless because the lock lives in the kernel, not in
/// the file's contents.
///
/// One descriptor per store, kept open for the process's life. Locking is not reentrant,
/// which is fine: TaskStore's own NSLock already forbids nesting.
final class InterProcessLock: @unchecked Sendable {

    private let path: String
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1

    init(path: String) { self.path = path }

    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Bookkeeping for the slow path, so the waiter timing out and the kernel handing the
    /// lock over cannot both happen and leave the lock held by nobody.
    private final class Handoff: @unchecked Sendable {
        let mutex = NSLock()
        var handedOff = false
        var abandoned = false
    }

    /// Blocks until the lock is ours or `timeout` elapses. Returns false on timeout and on
    /// any error opening the lock file — the caller decides whether that is fatal.
    ///
    /// Two paths. The fast one is a non-blocking flock, which is what an uncontended write
    /// takes and costs nothing. The slow one hands the wait to the kernel with a BLOCKING
    /// flock on a background thread.
    ///
    /// That second part is not a detail. The obvious implementation — retry LOCK_NB in a
    /// loop with a backoff — is a thundering herd: every waiter wakes on its own timer and
    /// races, so under a storm one unlucky writer can lose thousands of races in a row and
    /// time out while everybody else makes progress. A blocking flock puts waiters on the
    /// kernel's queue instead, and the timeout is kept by waiting on a semaphore rather
    /// than by polling.
    func acquire(exclusive: Bool, timeout: TimeInterval) -> Bool {
        stateLock.lock()
        if descriptor < 0 {
            descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        }
        let fd = descriptor
        stateLock.unlock()
        guard fd >= 0 else { return false }

        let operation = exclusive ? LOCK_EX : LOCK_SH
        if flock(fd, operation | LOCK_NB) == 0 { return true }
        if errno != EWOULDBLOCK { return false }

        let handoff = Handoff()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let acquired = flock(fd, operation) == 0
            handoff.mutex.lock()
            var releaseImmediately = false
            if acquired {
                if handoff.abandoned { releaseImmediately = true } else { handoff.handedOff = true }
            }
            handoff.mutex.unlock()
            // Nobody is waiting for it any more, so give it straight back rather than
            // holding a lock no caller believes it owns.
            if releaseImmediately { _ = flock(fd, LOCK_UN) }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + max(0, timeout)) == .success {
            handoff.mutex.lock()
            defer { handoff.mutex.unlock() }
            return handoff.handedOff
        }
        // Timed out — unless the handover landed in the instant before we gave up, which
        // this mutex is what settles.
        handoff.mutex.lock()
        defer { handoff.mutex.unlock() }
        if handoff.handedOff { return true }
        handoff.abandoned = true
        return false
    }

    func release() {
        stateLock.lock()
        let fd = descriptor
        stateLock.unlock()
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
    }
}
