//  DayRolloverScheduler.swift — something that actually fires at the day boundary.
//
//  WHY THIS EXISTS.
//
//  Rollover in `TaskStore` is lazy: it happens the first time anything reads or writes the
//  file after the day has turned. That is correct and it stays — it is what makes the
//  boundary safe when three processes hit it at once, and it is the backstop if everything
//  here fails. But lazy alone is not enough for a list that lives on the desktop:
//
//    * nothing reads the file while the machine is idle overnight, so at 09:00 the widget
//      is still showing yesterday until something happens to touch it;
//    * the widget's own refresh is on the system's budget, roughly 40-70 a day, and macOS
//      decides when — so "it will catch up on its own" can mean an hour;
//    * a completion at 01:50 and a completion at 02:10 belong to different days, and the
//      second must not be counted against the first day's clear.
//
//  So the agent app holds a timer on the boundary and pokes the store when it passes.
//
//  SURVIVING SLEEP, which is the part that is easy to get wrong.
//
//  `DispatchTime` / `.now() + interval` counts mach uptime, and mach uptime DOES NOT
//  ADVANCE while the Mac is asleep. A timer armed at 23:00 for three hours' time would fire
//  at 02:00 plus however long the machine spent asleep — which for an overnight sleep is
//  the following morning, or never. `wallDeadline` counts the wall clock instead, so the
//  deadline stays where it was put and has already passed by the time the machine wakes.
//
//  Three further belts on top of that one brace, because this is a thing that fails
//  silently and is noticed a day later:
//
//    1. the deadline is capped at an hour, so the timer re-checks periodically instead of
//       trusting a single armed shot twelve hours out;
//    2. wake, system-clock change and time-zone change all re-check immediately and re-arm.
//       Travelling, or a clock correction after a long sleep, moves the boundary;
//    3. the check itself is cheap and idempotent — it compares the day string it last saw
//       with the day string now, and only touches the file when they differ. A spurious
//       fire costs one string comparison.
//
//  RECONCILING, which is what makes it more than a timer.
//
//  "The day string it last saw" means the day it last saw SUCCESSFULLY ON DISK, not the
//  day the clock said. Two consequences:
//
//    * at launch there is no such day yet, so the first check always reconciles the file:
//      an app that was not running across 02:00 finds yesterday's list still in tasks.json
//      and rolls it now, instead of leaving it for the next boundary or for the widget to
//      trip over;
//    * a rollover that fails (a wedged writer, a coordination error) does not count as
//      seen. It is retried on a short bounded backoff, and after that the hourly re-check
//      and the wake observer keep trying, so a transient failure recovers without anybody
//      touching anything.
//
//  The file work itself runs on StorageQueue, never here on the main actor: a rollover is
//  a coordinated write that can wait seconds on another process, and the main thread is
//  the one drawing the celebration.

import AppKit
import BangerKit

@MainActor
final class DayRolloverScheduler {

    /// Called after the store has been rolled over to the new day. Used to refresh the
    /// widget, which is otherwise still drawing yesterday's list.
    private let onRollover: () -> Void

    private let store: TaskStore
    private let io: DispatchQueue

    /// Never sleep longer than this in one hop, however far away the boundary is.
    private let maximumSleep: TimeInterval = 60 * 60

    /// A second past the boundary, so a clock that is a hair early cannot fire us while the
    /// day that is ending is still the current one and then have to fire again.
    private let overshoot: TimeInterval = 1

    /// After a failed reconcile. Bounded: once these run out the hourly timer and the wake
    /// observer are the retry, which is plenty for a fault that outlived six minutes.
    private let retryDelays: [TimeInterval] = [2, 5, 15, 60, 300]

    private var timer: DispatchSourceTimer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// The Banger day the file was last confirmed to be on — read or rolled without error.
    /// Empty until the startup reconcile succeeds, which is what makes launching the app
    /// reconcile a stale file rather than assume it is current.
    private var reconciledDay = ""

    /// A reconcile is on the storage queue. Checks that arrive meanwhile book one rerun.
    private var inFlight = false
    private var rerunRequested = false

    private var failures = 0
    private var retry: DispatchWorkItem?
    /// The day a failure already told the widget about, so a run of retries is one reload.
    private var failureReportedDay = ""

    /// Set by `stop()`. A handler already in flight must not re-arm after it.
    private var stopped = false

    init(store: TaskStore = .shared,
         queue: DispatchQueue = StorageQueue.shared,
         onRollover: @escaping () -> Void) {
        self.store = store
        self.io = queue
        self.onRollover = onRollover
    }

    func start() {
        guard timer == nil else { return }
        stopped = false

        // Waking, and any jump in the clock or the zone, moves the boundary.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        observe(NotificationCenter.default, NSNotification.Name.NSSystemClockDidChange)
        observe(NotificationCenter.default, NSNotification.Name.NSSystemTimeZoneDidChange)

        // Reconcile whatever is on disk now, then arm for the next boundary.
        recheck()
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        retry?.cancel()
        retry = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// Re-check and re-arm now. Called on wake and on a clock change; also useful directly.
    func recheck() {
        guard !stopped else { return }
        checkForRollover()
        schedule()
    }

    // MARK: - Internals

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.recheck()
            }
        }
        observers.append((center, token))
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard !stopped else { return }

        let now = Date()
        let boundary = BangerDate.Rollover.nextBoundary(after: now)
        let untilBoundary = boundary.timeIntervalSince(now) + overshoot
        let delay = max(1, min(untilBoundary, maximumSleep))

        let source = DispatchSource.makeTimerSource(queue: .main)
        // wallDeadline, NOT deadline. See the note at the top of this file.
        source.schedule(wallDeadline: .now() + delay, leeway: .seconds(1))
        source.setEventHandler {
            MainActor.assumeIsolated { [weak self] in
                guard let self, !self.stopped else { return }
                self.checkForRollover()
                self.schedule()
            }
        }
        source.resume()
        timer = source
    }

    /// Cheap when nothing has happened: one string comparison and no file access.
    private func checkForRollover() {
        guard !stopped else { return }
        let today = BangerDate.today()
        guard today != reconciledDay else { return }
        guard !inFlight else { rerunRequested = true; return }
        inFlight = true
        retry?.cancel()
        retry = nil

        // `load()` is the store's own rollover: it archives the day that ended, empties the
        // list and moves the streak. The peek first is what lets us tell "rolled it" from
        // "it was already today's" without a second opinion, and it is the only read when
        // nothing needs doing.
        let store = self.store
        io.async {
            let outcome = Result<Bool, Error> {
                guard try store.peek().date != today else { return false }
                _ = try store.load()
                return true
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    self?.finish(today: today, outcome: outcome)
                }
            }
        }
    }

    private func finish(today: String, outcome: Result<Bool, Error>) {
        inFlight = false
        guard !stopped else { return }

        switch outcome {
        case .success(let rolled):
            // A boundary we were awake for, even if the widget or the CLI got to the file
            // first: the widget is still drawing yesterday until it is told.
            let crossed = !reconciledDay.isEmpty && reconciledDay != today
            let hadReportedFailure = failureReportedDay == today
            reconciledDay = today
            failures = 0
            failureReportedDay = ""
            if rolled || crossed || hadReportedFailure { onRollover() }

        case .failure(let error):
            // Logged rather than swallowed, and not fatal: the lazy path in TaskStore rolls
            // the day over the next time anything touches the file. The widget is told
            // once per failing day, so its own next read can do exactly that.
            NSLog("Banger: day rollover to %@ could not be written: %@",
                  today, error.localizedDescription)
            if failureReportedDay != today {
                failureReportedDay = today
                failures = 0   // a new day's failure gets the whole backoff again
                onRollover()
            }
            scheduleRetry()
        }

        if rerunRequested {
            rerunRequested = false
            checkForRollover()
        }
    }

    private func scheduleRetry() {
        guard failures < retryDelays.count, !stopped else { return }
        let delay = retryDelays[failures]
        failures += 1
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { [weak self] in
                guard let self, !self.stopped else { return }
                self.retry = nil
                self.checkForRollover()
            }
        }
        retry?.cancel()
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
