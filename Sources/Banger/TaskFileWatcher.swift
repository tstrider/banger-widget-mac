//  TaskFileWatcher.swift — the app notices completions by watching the file.
//
//  WHY THIS EXISTS, and it is the most important comment in the app.
//
//  A widget App Intent posting a DistributedNotificationCenter notification for the app
//  to act on is not enough on its own: the widget extension is sandboxed — macOS requires
//  a widget extension to be sandboxed or the widget host will not load it — and App
//  Sandbox refuses to let a sandboxed process post a distributed notification whose name
//  does not carry its app-group or team-identifier prefix. A build with no code-signing
//  identity and no usable app group has neither.
//
//  Relying on the notification alone, ticking a box in the widget would write the
//  completion to tasks.json correctly and produce silence, while the same completion
//  through bangerctl — an ordinary, unsandboxed process — would celebrate.
//
//  So the app does not wait to be told. It is NOT sandboxed, the file is already the
//  single source of truth that three writers share, and a completion is a state change
//  in that file. Watching it removes the inter-process dependency altogether rather than
//  working around it.
//
//  The notification path is kept, because when it does work (bangerctl, the app itself)
//  it is a few milliseconds faster and it carries its context in the payload. The two
//  paths are de-duplicated by completion seed, so whichever arrives first wins and the
//  second is dropped — a task never celebrates twice.
//
//  TWO KINDS OF NEWS. A scan reports "these tasks just became done" (the celebration) and,
//  separately, "the document changed at all" (an add, a removal, an uncheck, an edit, a
//  rollover). The second is what keeps the widget honest when the notification path is
//  lost: the widget extension cannot post one, so without it an add or uncheck from the
//  widget or a hand edit would wait on WidgetKit's own schedule.
//
//  NOISE. The directory watch fires for every file in the folder — the widget's read
//  receipt, its celebration ledger, history.json, the lock file, the store's temp files.
//  None of those are the list. Before reading anything, a scan stats tasks.json and
//  compares (device, inode, size, mtime, ctime) with the last version it read: if nothing
//  about the file moved, the event was somebody else's and the scan stops there, with no
//  read, no lock and no coordination.
//
//  CONCURRENCY. The dispatch sources, the settle timer and every scan run on
//  `StorageQueue.shared`, a serial queue, and nowhere else. A scan reads through TaskStore,
//  and a TaskStore read is not the 1 ms it usually is when something else holds the file:
//  it queues on the store's in-process NSLock (a quick-add write can hold that for the
//  five-second write-lock timeout), then waits up to 250 ms for the shared flock, then
//  enters synchronous NSFileCoordinator. None of that may happen on the main thread, which
//  drives the celebration's animation and the quick-add field. What reaches the main actor
//  is an immutable `TaskFileScan` value, in the order the scans ran, and the only work
//  there is the callback. The engine's state is confined to the queue rather than
//  statically isolated, which is why it is `@unchecked Sendable`: neither
//  `DispatchSourceFileSystemObject` nor `DispatchWorkItem` is `Sendable`, and a queue is
//  the thing that actually serialises it.

import Foundation
import BangerKit

// MARK: - The storage queue

/// Where every piece of the agent app's task-file I/O runs, one at a time: the watcher's
/// scans, the rollover scheduler's reconcile and quick-add's write.
///
/// Serial on purpose. TaskStore already serialises in-process on an NSLock, so two threads
/// would only queue on that lock instead; on one queue the order is explicit, a burst is
/// a line of work rather than a pile of blocked threads, and none of it is ever the main
/// thread. `.userInitiated` because a completion's scan is on the celebration's latency
/// path.
enum StorageQueue {
    static let shared = DispatchQueue(label: "com.bangerwidget.banger.storage", qos: .userInitiated)
}

// MARK: - What a scan found

/// One scan's result, handed to the main actor as a value.
struct TaskFileScan: Sendable {
    /// The document as read.
    let document: TaskDocument
    /// Tasks that just flipped from open to done, in file order.
    let completed: [BangerTask]
    /// True when the document differs from the last one this watcher read.
    let changed: Bool
}

// MARK: - Watcher

/// Watches tasks.json and reports tasks that have newly become done, and any change at all.
///
/// Uses a vnode source on the file plus a directory source on its parent, because the
/// store replaces the file atomically (write-temp-then-rename). A rename swaps the inode,
/// which kills a vnode watch on the old one — so the directory watch is what survives the
/// swap and re-arms the file watch. Watching only the file would work exactly once.
@MainActor
final class TaskFileWatcher {

    /// Called with the tasks that just flipped from open to done, in file order, plus the
    /// document they came from. Taken at init and never reassigned.
    private let onCompletions: (_ completed: [BangerTask], _ document: TaskDocument) -> Void

    /// Called after `onCompletions` whenever the document changed in any way. Coalescing is
    /// the receiver's business; this fires at most once per scan.
    private let onDocumentChanged: (_ document: TaskDocument) -> Void

    private let engine: TaskFileWatchEngine

    /// Set by `stop()`. A result already on its way to the main queue is dropped after it.
    private var stopped = true

    init(store: TaskStore = .shared,
         queue: DispatchQueue = StorageQueue.shared,
         onDocumentChanged: @escaping (_ document: TaskDocument) -> Void = { _ in },
         onCompletions: @escaping (_ completed: [BangerTask], _ document: TaskDocument) -> Void) {
        self.onCompletions = onCompletions
        self.onDocumentChanged = onDocumentChanged
        self.engine = TaskFileWatchEngine(store: store, queue: queue)
    }

    func start() {
        guard stopped else { return }
        stopped = false
        engine.start { [weak self] scan in
            // On the storage queue. The main queue is FIFO and so is the storage queue, so
            // results arrive here in the order the scans ran.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(scan) }
            }
        }
    }

    func stop() {
        stopped = true
        engine.stop()
    }

    private func apply(_ scan: TaskFileScan) {
        guard !stopped else { return }
        // Celebration first: it is the latency-critical half.
        if !scan.completed.isEmpty { onCompletions(scan.completed, scan.document) }
        if scan.changed { onDocumentChanged(scan.document) }
    }
}

// MARK: - File identity

/// Enough of stat(2) to tell "tasks.json is a different file or has different bytes" from
/// "something else in the folder changed".
struct TaskFileStamp: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
    }
    let identity: Identity
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    /// ctime moves on a rename onto the path and on a chmod, neither of which touches mtime.
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ st: stat) {
        identity = Identity(device: Int64(st.st_dev), inode: UInt64(st.st_ino))
        size = Int64(st.st_size)
        modifiedSeconds = Int(st.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(st.st_mtimespec.tv_nsec)
        changedSeconds = Int(st.st_ctimespec.tv_sec)
        changedNanoseconds = Int(st.st_ctimespec.tv_nsec)
    }

    /// nil when there is no file at `path` (or it cannot be stat'ed at all).
    static func read(path: String) -> TaskFileStamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return TaskFileStamp(st)
    }

    static func read(fd: Int32) -> TaskFileStamp? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return TaskFileStamp(st)
    }
}

// MARK: - Engine

/// The part of the watcher that lives on the storage queue. Every stored property below is
/// read and written only on `queue`; that confinement, not the type system, is what makes
/// the `@unchecked Sendable` true.
final class TaskFileWatchEngine: @unchecked Sendable {

    private let store: TaskStore
    private let queue: DispatchQueue

    /// A rename produces several events in a few milliseconds. Coalesce them so one
    /// completion is one read, not five. Armed by the FIRST event and not pushed back by
    /// later ones, so a steady trickle of events cannot postpone a scan indefinitely.
    private let settle: TimeInterval = 0.012

    /// A scan that fails (coordination error, a file caught mid-hand-edit) is retried on
    /// these delays and then left for the next event. Nine seconds in all.
    private let scanRetryDelays: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2, 5]

    /// The directory could not be opened, or went away: retry opening it, backing off to
    /// this ceiling and staying there. One open(2) every half-minute costs nothing.
    private let maximumDirectoryRetryDelay: TimeInterval = 30

    private var deliver: (@Sendable (TaskFileScan) -> Void)?
    private var stopped = true

    private var fileSource: (any DispatchSourceFileSystemObject)?
    /// The inode the file source is watching. The file watch is re-armed only when the
    /// inode at the path is a different one.
    private var watchedFile: TaskFileStamp.Identity?

    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var dirRetry: DispatchWorkItem?
    private var dirFailures = 0

    private var pendingScan: DispatchWorkItem?
    private var forceNextScan = false
    private var scanRetry: DispatchWorkItem?
    private var scanFailures = 0
    /// Set when the retries ran out; the stamp of the file that kept failing. Events that
    /// leave the file exactly as it was are then noise rather than a reason to fail again.
    private var abandonedStamp: TaskFileStamp??

    /// False until the first successful read, which is the baseline and never a
    /// celebration: whatever is already done when the app launches does not fire a burst
    /// of celebrations at login.
    private var seeded = false
    private var lastStamp: TaskFileStamp?
    private var lastDocument: TaskDocument?
    /// Ids seen as done in `lastDocument`.
    private var doneIDs: Set<String> = []

    init(store: TaskStore, queue: DispatchQueue) {
        self.store = store
        self.queue = queue
    }

    func start(deliver: @escaping @Sendable (TaskFileScan) -> Void) {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            self.deliver = deliver
            seeded = false
            lastStamp = nil
            lastDocument = nil
            doneIDs = []
            scanFailures = 0
            abandonedStamp = nil
            dirFailures = 0
            armDirectory()
            forceNextScan = true
            runScan()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            deliver = nil
            pendingScan?.cancel(); pendingScan = nil
            scanRetry?.cancel(); scanRetry = nil
            dirRetry?.cancel(); dirRetry = nil
            cancelFileWatch()
            dirSource?.cancel(); dirSource = nil
        }
    }

    // MARK: Watching

    private func armFile() {
        cancelFileWatch()
        guard !stopped else { return }

        let fd = open(store.tasksURL.path, O_EVTONLY)
        guard fd >= 0 else { return }   // no file yet; the directory watch will catch it

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            // The inode we are watching has gone. Drop the watch; the scan re-arms onto
            // whatever replaced it, if anything has.
            if !src.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.cancelFileWatch()
            }
            self.scheduleScan()
        }
        src.setCancelHandler { close(fd) }
        // The identity of what was actually opened, not of what a stat a moment ago saw.
        watchedFile = TaskFileStamp.read(fd: fd)?.identity
        src.resume()
        fileSource = src
    }

    private func cancelFileWatch() {
        fileSource?.cancel()
        fileSource = nil
        watchedFile = nil
    }

    private func armDirectory() {
        dirRetry?.cancel(); dirRetry = nil
        dirSource?.cancel(); dirSource = nil
        guard !stopped else { return }

        let dir = store.tasksURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there and could not be made (unmounted, permissions). Try again later;
            // nothing else will ever re-arm it.
            let delay = min(0.25 * pow(2, Double(min(dirFailures, 16))), maximumDirectoryRetryDelay)
            dirFailures += 1
            NSLog("Banger: cannot watch %@ (%@); retrying in %.1fs",
                  dir.path, String(cString: strerror(errno)), delay)
            let retry = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.armDirectory()
            }
            dirRetry = retry
            queue.asyncAfter(deadline: .now() + delay, execute: retry)
            return
        }

        let recovering = dirFailures > 0
        dirFailures = 0

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // .write covers entries being created, renamed and removed, which is how the
            // atomic replace shows up. .attrib catches a permission fix on the folder.
            // The other three mean the folder itself went away.
            eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if !src.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                // Our descriptor now points at a folder that is somewhere else, or at
                // nothing. Watch whatever is at the path now, and read it: anything could
                // have changed in the gap.
                self.cancelFileWatch()
                self.armDirectory()
                self.scheduleScan(force: true)
                return
            }
            self.scheduleScan()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src

        // Events were missed while there was no watch.
        if recovering { scheduleScan(force: true) }
    }

    // MARK: Scanning

    private func scheduleScan(force: Bool = false) {
        guard !stopped else { return }
        if force { forceNextScan = true }
        // Already one on the way: this event joins it. A scan running right now is on this
        // same queue, so an event during it lands here afterwards and books exactly one
        // rerun — never more than one pending.
        guard pendingScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScan = nil
            self.runScan()
        }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }

    private func runScan() {
        guard !stopped else { return }
        scanRetry?.cancel(); scanRetry = nil
        let force = forceNextScan
        forceNextScan = false

        let stamp = TaskFileStamp.read(path: store.tasksURL.path)

        // Re-arm the file watch only when the path now names a different file.
        if stamp?.identity != watchedFile {
            if stamp == nil { cancelFileWatch() } else { armFile() }
        }

        if !force && seeded && scanFailures == 0 && stamp == lastStamp {
            return   // the receipt, a ledger, history, the lock or a temp file — not the list
        }
        if let abandonedStamp {
            if !force && abandonedStamp == stamp { return }
            // A different file, or a deliberate retry: it gets a fresh set of attempts.
            self.abandonedStamp = nil
            scanFailures = 0
        }

        // The stamp is taken BEFORE the read, so the bytes read are at least as new as the
        // stamp recorded for them. The other order could record a newer stamp for older
        // bytes and then skip the event that carried the change.
        let document: TaskDocument
        do {
            document = try store.peek()
        } catch {
            scanFailed(stamp: stamp, error: error)
            return
        }
        let recovered = scanFailures > 0
        scanFailures = 0
        lastStamp = stamp

        guard seeded else {
            seeded = true
            lastDocument = document
            doneIDs = Set(document.tasks.filter(\.done).map(\.id))
            // A baseline, never a celebration. If earlier reads failed, the widget may be
            // showing something stale, so say it changed.
            if recovered { deliver?(TaskFileScan(document: document, completed: [], changed: true)) }
            return
        }

        let previousDate = lastDocument?.date ?? document.date
        let nowDone = document.tasks.filter(\.done)
        let fresh: [BangerTask]
        if document.date == previousDate {
            fresh = nowDone.filter { !doneIDs.contains($0.id) }
        } else if document.date > previousDate {
            // A later day. The rollover emptied the list, so anything done in this document
            // was done on this day — including a completion that landed in the same
            // coalesced scan as the rollover. Guarded by the completion time, so a task carried into a new day
            // by a hand edit with its old tick still on it cannot replay an old reward.
            fresh = nowDone.filter { task in
                guard let at = task.completedAt else { return false }
                return BangerDate.dayString(at) == document.date
            }
        } else {
            // The date went backwards (a hand edit, a clock correction). Nothing in it is
            // news; take it as the new baseline.
            fresh = []
        }

        // Unchecking must make a task eligible to celebrate again only if the user
        // genuinely re-completes it later; drop ids that are no longer done so the set
        // does not grow without bound across a day.
        doneIDs = Set(nowDone.map(\.id))

        let changed = document != lastDocument
        lastDocument = document
        guard changed || !fresh.isEmpty else { return }
        deliver?(TaskFileScan(document: document, completed: fresh, changed: changed))
    }

    private func scanFailed(stamp: TaskFileStamp?, error: Error) {
        guard scanFailures < scanRetryDelays.count else {
            // Out of retries. Left alone until the file changes again.
            NSLog("Banger: tasks.json still unreadable after %d retries, waiting for it to change: %@",
                  scanFailures, error.localizedDescription)
            abandonedStamp = .some(stamp)
            return
        }
        let delay = scanRetryDelays[scanFailures]
        scanFailures += 1
        if scanFailures == 1 {
            NSLog("Banger: could not read tasks.json, retrying: %@", error.localizedDescription)
        }
        let retry = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.forceNextScan = true
            self.runScan()
        }
        scanRetry = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
    }
}
