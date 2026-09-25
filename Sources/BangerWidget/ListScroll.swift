//  ListScroll.swift — a list longer than the widget, and the arrows that scroll it.
//
//  A widget cannot scroll. There is no ScrollView in one, no drag and no wheel: the
//  system draws a picture of the view, and the only things in that picture that
//  answer the pointer are buttons and toggles that run an App Intent. So the scroll
//  is built out of those.
//
//   - Every row sits in one stack. A window of it is in view; the rows either side
//     are still drawn, invisible and untouchable (RowPlan), so a row always has
//     somewhere to slide in from.
//   - Under the list, two arrows. A tap runs ScrollListIntent, which remembers the
//     new window in widget-scroll.json beside tasks.json. WidgetKit reloads the
//     widget itself the moment a button's intent returns.
//   - The reloaded entry moves the stack. Across an entry change WidgetKit animates
//     offsets and opacity — the same built-ins ReorderMotion's pop is made of — so
//     the rows slide together, the ones leaving fade out past the edge of the
//     window, and the ones arriving fade in from the other side. It reads as a
//     scroll because it is one, a page at a time.
//
//  A tap moves nearly a page: the row that was at the bottom ends up at the top, so
//  the eye keeps its place. The resting place is a detent (RowPlan.detent), so
//  scrolling back always stops on the view the widget rests in — open tasks first,
//  done ones just above them.
//
//  THE SCROLL LETS GO. Five minutes after the last tap the list slides back to its
//  resting place, by an entry dated to that instant (the same way the streak flame
//  goes cold on time). A list left scrolled hides the tasks at the top of it, and
//  the list staying visible is the entire mechanism.
//
//  The file is the widget's own. It holds a day key, a position and a time — no task
//  text — and nothing else reads it. It sits beside tasks.json because that is the
//  one folder the sandboxed extension can write (see CelebrationLedger), and the
//  agent's folder watch lets it pass: nothing about tasks.json moves.

import AppIntents
import Foundation
import SwiftUI
import BangerKit

enum ListScroll {

    static let fileName = "widget-scroll.json"

    /// How long a scroll holds before the list goes back to its resting place.
    static let hold: TimeInterval = 5 * 60

    /// Where the list has been scrolled to, and until when.
    struct Position: Equatable {
        var offset: Int
        var until: Date
    }

    private struct Memory: Codable {
        var dayKey: String
        var offset: Int
        /// Seconds since 1970, when the arrow was tapped.
        var at: Double
    }

    private static var url: URL {
        TaskStore.shared.containerURL.appendingPathComponent(fileName, isDirectory: false)
    }

    /// A real one is about 70 bytes.
    private static let maxBytes = 1024

    /// Today's scroll, if the list is still holding one. Nil means rest: no file, a
    /// file from another day, or a hold that has run out.
    static func current(dayKey: String, now: Date = Date()) -> Position? {
        guard let data = readSmallFile(),
              let memory = try? JSONDecoder().decode(Memory.self, from: data),
              memory.dayKey == dayKey else { return nil }
        let tapped = Date(timeIntervalSince1970: memory.at)
        // A tap from the future — the clock was set back — must not hold the list any
        // longer than a tap made now would.
        guard tapped <= now.addingTimeInterval(60) else { return nil }
        let until = tapped.addingTimeInterval(hold)
        return until > now ? Position(offset: memory.offset, until: until) : nil
    }

    /// The file's bytes, only if it is a small regular file. Every timeline reads it,
    /// and anything on the machine can write this folder: a FIFO would block the read
    /// forever and a symlink to /dev/zero would read until the extension is killed —
    /// either way the widget would stop updating. So no following links, no blocking
    /// open, and the type and size are checked on the open descriptor, not the path.
    private static func readSmallFile() -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maxBytes else { return nil }
        return try? handle.read(upToCount: maxBytes)
    }

    /// Remembers where the list was scrolled to. Nil is the resting place, which is
    /// remembered by forgetting.
    static func remember(offset: Int?, dayKey: String, now: Date = Date()) {
        guard let offset else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let memory = Memory(dayKey: dayKey, offset: offset, at: now.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(memory) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// What an arrow under the list does.
///
/// Like the checkbox, this must never steal focus: openAppWhenRun is false, it
/// returns a bare .result() and it never touches NSWorkspace.
struct ScrollListIntent: AppIntent {

    static let title: LocalizedStringResource = "Scroll Task List"
    static let description = IntentDescription("Scrolls Banger's widget to another part of today's list.")

    /// A widget control, not a user-facing action: keep it out of Shortcuts and Spotlight.
    static let isDiscoverable: Bool = false
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// The first row to put in view, as an index into the display order; absent for
    /// the resting place. A position rather than "up" or "down", so a double click
    /// inside one reload lands once instead of skipping a page the user never saw.
    @Parameter(title: "Offset") var offset: Int?
    /// The day the arrow was drawn on. A scroll never outlives its list.
    @Parameter(title: "Day") var dayKey: String

    init() {}

    init(offset: Int?, dayKey: String) {
        self.offset = offset
        self.dayKey = dayKey
    }

    /// No reloadTimelines here, on purpose. WidgetKit rebuilds the widget's timeline
    /// by itself as soon as a button's intent returns. Asking as well only adds a
    /// second, identical rebuild: two timelines per tap, where one does it.
    func perform() async throws -> some IntentResult {
        ListScroll.remember(offset: offset, dayKey: dayKey)
        return .result()
    }
}

/// How the window travels.
enum ScrollMotion {

    /// Smooth, with the faintest settle: a scroll, not the pop ReorderMotion throws.
    /// When a check-off moves the rows and the window together, the pop's spring
    /// drives both (see BangerWidgetView), so the two never disagree mid-flight.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2)
                     : .spring(response: 0.42, dampingFraction: 0.86)
    }

    /// How far past the window's top and bottom a row may still draw. Enough for a
    /// check-off on the first or last row in view — its shock ring reaches about
    /// seven points past the row — and short of what sits either side of the
    /// window: the progress bar above, the arrows eight points below. A row
    /// scrolling out is cut in that gap instead of crossing either.
    static func bleed(_ metrics: WidgetMetrics) -> (above: CGFloat, below: CGFloat) {
        (above: metrics.roomyHeader ? 10 : 7, below: 7)
    }
}

/// A frame part of the way through a scroll. Set only by the offscreen capture
/// (WidgetCapture), which has no widget host to animate the move; live this is nil and WidgetKit
/// interpolates between the two entries itself.
struct CaptureScroll: Equatable {
    /// Where the window was before the tap.
    var from: Int
    /// 0 at the tap, 1 settled.
    var progress: Double
}
