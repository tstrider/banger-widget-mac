//  BangerTimelineProvider.swift — what the widget is allowed to know, and when.
//
//  The whole check transition is optimistic and finishes in 300 ms without the
//  provider's help (see CheckMotion), so the provider's only job is to describe the
//  resting list. The reloaded entry, whenever it turns up, agrees pixel for pixel
//  with what the widget has already drawn, and nothing moves when it lands.

import BangerKit
import Foundation
import WidgetKit

struct BangerEntry: TimelineEntry {

    enum State {
        case list(WidgetDay)
        case empty
        case unavailable(String)
    }

    var date: Date
    var state: State
    /// Where the list has been scrolled to, as the first row in view; nil for its
    /// resting place. See ListScroll.
    var scrollOffset: Int? = nil
}

struct BangerTimelineProvider: TimelineProvider {

    /// Ceiling on self-scheduled refreshes while work is outstanding, so a task
    /// added from a shell shows up without anything calling reload. ~32/day, which
    /// leaves headroom inside the system's rough 40-70 budget.
    static let idleRefresh: TimeInterval = 45 * 60

    func placeholder(in context: Context) -> BangerEntry {
        Self.sampleEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (BangerEntry) -> Void) {
        // The timeline's own first entry, so a snapshot shows a held scroll too.
        completion(context.isPreview ? Self.sampleEntry : Self.timeline(at: Date()).entries[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BangerEntry>) -> Void) {
        completion(Self.timeline(at: Date()))
    }

    /// The timeline itself. Nothing in it depends on WidgetKit's context, so it is
    /// built here, where a test can build it too.
    static func timeline(at now: Date) -> Timeline<BangerEntry> {
        let entry = Self.entry(at: now)
        let scroll = Self.scroll(state: entry.state, at: now)
        // Two things change the picture with nothing in the file moving, so nothing
        // would reload the widget for them: the streak flame goes cold at a set time
        // of the evening, and a scrolled list slides back to rest when its hold runs
        // out. Each needs an entry of its own, dated to the instant, which WidgetKit
        // draws on time.
        var instants = [now]
        if let scroll { instants.append(scroll.until) }
        if let nudge = Self.nudgeInstant(after: now, state: entry.state) {
            instants.append(nudge)
        }
        let entries = instants.sorted().map { instant in
            BangerEntry(date: instant, state: entry.state,
                        scrollOffset: scroll.flatMap { instant < $0.until ? $0.offset : nil })
        }
        return Timeline(entries: entries,
                        policy: .after(Self.nextRefresh(after: now, state: entry.state)))
    }

    // MARK: - Reading

    private static func entry(at now: Date) -> BangerEntry {
        switch TaskBridge.loadToday() {
        case .failure(.containerUnavailable):
            return BangerEntry(date: now, state: .unavailable("The shared folder isn't available yet."))
        case .failure(.unreadable):
            return BangerEntry(date: now, state: .unavailable("Today's list couldn't be read."))
        case .success(let day):
            guard !day.tasks.isEmpty else { return BangerEntry(date: now, state: .empty) }
            return BangerEntry(date: now, state: .list(day))
        }
    }

    private static func nextRefresh(after now: Date, state: BangerEntry.State) -> Date {
        // The day boundary, not local midnight. See BangerDate.Rollover: a Banger day
        // runs 02:00 to 02:00 in a fixed named zone, so midnight is the middle of the
        // day and redrawing there would show an empty list two hours early.
        let boundary = BangerDate.Rollover.nextBoundary(after: now)

        // Nothing left to do today: the only thing that changes is the date.
        if case .list(let day) = state, day.isCleared { return boundary }
        return min(boundary, now.addingTimeInterval(idleRefresh))
    }

    /// Today's scroll, while it holds. Only a list can be scrolled.
    private static func scroll(state: BangerEntry.State, at now: Date) -> ListScroll.Position? {
        guard case .list(let day) = state else { return nil }
        return ListScroll.current(dayKey: day.dayKey, now: now)
    }

    /// When today's streak flame will go cold, if it is still hot now and has a streak
    /// to lose. Nil for a cleared list, no streak, or a nudge that has already passed.
    private static func nudgeInstant(after now: Date, state: BangerEntry.State) -> Date? {
        guard case .list(let day) = state, day.streak > 0, !day.isCleared else { return nil }
        let nudge = StreakFlame.nudgeStart(endingAt: BangerDate.Rollover.nextBoundary(after: now))
        return nudge > now ? nudge : nil
    }

    // MARK: - Gallery / placeholder content

    static let sampleEntry: BangerEntry = {
        let tasks = [
            WidgetTask(id: "s1", text: "Export authenticator codes", done: true, source: "me",
                       completedAt: Date(timeIntervalSince1970: 0)),
            WidgetTask(id: "s2", text: "Call the realtor", done: true, source: "iris",
                       completedAt: Date(timeIntervalSince1970: 0)),
            WidgetTask(id: "s3", text: "Book the van", done: false, source: "iris", completedAt: nil),
            WidgetTask(id: "s4", text: "Mix down the B-side", done: false, source: "me", completedAt: nil)
        ]
        return BangerEntry(date: Date(timeIntervalSince1970: 0),
                           state: .list(WidgetDay(dayKey: "sample", tasks: tasks, streak: 4)))
    }()
}
