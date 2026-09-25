//  BangerDate.swift — what day it is, and the two date formats the file uses.
//
//  "date"        -> "yyyy-MM-dd", the Banger day (see below)
//  "completedAt" -> ISO 8601 in UTC, e.g. "2026-09-21T14:22:10Z"
//
//  THE DAY DOES NOT TURN AT MIDNIGHT.
//
//  A Banger day runs from 02:00 to 02:00 in a fixed named time zone, America/Chicago by
//  default. The day is labelled with the calendar date it STARTED on, so an instant at
//  01:00 on the 22nd is still "2026-09-21".
//
//  That is the whole point of the two-hour offset. Finishing the last thing on the list at
//  00:40 should clear the day that is ending and extend the streak — not open a new day
//  with one task on it, and not break a streak that was never broken. Midnight is in the
//  middle of the evening for anyone who works late; 2am is not in the middle of anything.
//
//  The zone is NAMED, never a fixed UTC offset, so daylight saving is the operating
//  system's problem rather than ours. Both transitions were checked:
//
//    * Spring forward. 02:00 CST does not exist — the clock jumps 01:59:59 CST ->
//      03:00:00 CDT. `nextBoundary` uses `.nextTime`, which lands on the jump instant, so
//      the day turns exactly once, at the moment the clock moves. Nothing is skipped and
//      nothing is doubled. (That day is still 24 hours long in real time, because 02:00
//      CST and 03:00 CDT are the same absolute instant.)
//    * Fall back. The US moves the clock back at 02:00 CDT to 01:00 CST, so 01:00–01:59
//      happens TWICE and 02:00 happens once. The boundary is therefore unambiguous. Both
//      passes of 1am carry the label of the day that is ending, which is what the rule
//      above wants. That day is 25 hours long.
//
//  Deliberately avoids DateFormatter so nothing here needs locale wrangling or a shared
//  mutable formatter.

import Foundation

public enum BangerDate {

    // MARK: - The day boundary

    /// Where "what day is it?" is decided. Resolved once per process.
    ///
    /// Defaults are 02:00 `America/Chicago`. Two overrides, in this order:
    ///
    ///   1. the environment — `BANGER_ROLLOVER_HOUR`, `BANGER_ROLLOVER_TZ`. This reaches
    ///      command-line tools and tests. It does NOT reach the app or the widget,
    ///      which macOS launches without your shell environment;
    ///   2. `<container>/config.json`, e.g.
    ///      `{ "rolloverHour": 4, "timeZone": "Europe/London" }`. This one does reach all
    ///      three processes, because all three already read that folder.
    ///
    /// Anything missing, malformed or naming a zone that does not exist falls back to the
    /// default rather than throwing. A to-do list must not fail to know what day it is.
    public enum Rollover {

        public static let defaultHour = 2
        public static let defaultTimeZoneIdentifier = "America/Chicago"

        public static var hour: Int { resolved.hour }
        public static var timeZone: TimeZone { resolved.timeZone }
        /// A Gregorian calendar pinned to the rollover zone. This, not `.current`, is what
        /// every day-string question in the app is asked through.
        public static var calendar: Calendar { resolved.calendar }
        /// "default", "environment", "config.json" or "config.json+environment" —
        /// reported by `bangerctl path --json` so a surprising boundary is diagnosable.
        public static var source: String { resolved.source }

        struct Settings: Sendable {
            let hour: Int
            let timeZone: TimeZone
            let calendar: Calendar
            let source: String
        }

        static let resolved: Settings = load()

        static func load() -> Settings {
            var hour = defaultHour
            var zone = TimeZone(identifier: defaultTimeZoneIdentifier) ?? .current
            var fromConfig = false
            var fromEnvironment = false

            // Deliberately does NOT call BangerContainer.resolve(): that creates the
            // directory, and TaskStore's own initialiser is already on that path. This is
            // pure path arithmetic, and the same folder resolve() lands on.
            let container = BangerContainer.folderURL
            let configURL = container.appendingPathComponent("config.json", isDirectory: false)
            if let data = try? Data(contentsOf: configURL),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let value = object["rolloverHour"] as? Int, (0...23).contains(value) {
                    hour = value
                    fromConfig = true
                }
                if let identifier = object["timeZone"] as? String,
                   let parsed = TimeZone(identifier: identifier) {
                    zone = parsed
                    fromConfig = true
                }
            }

            let environment = ProcessInfo.processInfo.environment
            if let raw = environment["BANGER_ROLLOVER_HOUR"],
               let value = Int(raw), (0...23).contains(value) {
                hour = value
                fromEnvironment = true
            }
            if let identifier = environment["BANGER_ROLLOVER_TZ"],
               let parsed = TimeZone(identifier: identifier) {
                zone = parsed
                fromEnvironment = true
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            calendar.locale = Locale(identifier: "en_US_POSIX")

            let source: String
            switch (fromConfig, fromEnvironment) {
            case (true, true):   source = "config.json+environment"
            case (true, false):  source = "config.json"
            case (false, true):  source = "environment"
            case (false, false): source = "default"
            }
            return Settings(hour: hour, timeZone: zone, calendar: calendar, source: source)
        }

        /// The first instant at which `BangerDate.today()` will return a different string.
        ///
        /// `.nextTime` is what handles the spring-forward morning, where the hour being
        /// matched does not exist: it returns the next instant after the missing one, which
        /// is the jump itself. The loop underneath is a belt-and-braces guard — if a zone
        /// ever produced a "next 2am" that still belongs to the current day, we would
        /// otherwise schedule a timer that fires and changes nothing, forever.
        public static func nextBoundary(after now: Date = Date(),
                                        calendar: Calendar = Rollover.calendar,
                                        hour: Int = Rollover.hour) -> Date {
            var match = DateComponents()
            match.hour = hour
            match.minute = 0
            match.second = 0

            let label = BangerDate.dayString(now, calendar: calendar, rolloverHour: hour)
            var candidate = now
            for _ in 0..<4 {
                guard let next = calendar.nextDate(after: candidate,
                                                   matching: match,
                                                   matchingPolicy: .nextTime,
                                                   repeatedTimePolicy: .first,
                                                   direction: .forward) else { break }
                candidate = next
                if BangerDate.dayString(candidate, calendar: calendar, rolloverHour: hour) != label {
                    return candidate
                }
            }
            // Nothing sane came back. A day from now is always a different day.
            return now.addingTimeInterval(24 * 60 * 60)
        }
    }

    // MARK: - Day strings

    /// The Banger day an instant falls in, formatted "yyyy-MM-dd".
    ///
    /// Wall-clock arithmetic on purpose, not "subtract two hours from the instant". On the
    /// fall-back date 01:30 occurs at two different absolute instants and both must land on
    /// the day that is ending; asking the calendar for the hour and stepping the DATE back
    /// gets that right for free, where subtracting a duration does not.
    public static func dayString(_ date: Date = Date(),
                                 calendar: Calendar = Rollover.calendar,
                                 rolloverHour: Int = Rollover.hour) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard (parts.hour ?? 0) < rolloverHour else {
            return format(year: parts.year, month: parts.month, day: parts.day)
        }
        // Before the boundary: this belongs to yesterday. Step the date back from NOON, so
        // a 23- or 25-hour day cannot move us two days or none.
        var noon = DateComponents()
        noon.year = parts.year
        noon.month = parts.month
        noon.day = parts.day
        noon.hour = 12
        guard let anchor = calendar.date(from: noon),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: anchor) else {
            return format(year: parts.year, month: parts.month, day: parts.day)
        }
        let back = calendar.dateComponents([.year, .month, .day], from: yesterday)
        return format(year: back.year, month: back.month, day: back.day)
    }

    /// Today's Banger day.
    public static func today(calendar: Calendar = Rollover.calendar) -> String {
        dayString(Date(), calendar: calendar)
    }

    private static func format(year: Int?, month: Int?, day: Int?) -> String {
        String(format: "%04d-%02d-%02d", year ?? 0, month ?? 0, day ?? 0)
    }

    /// True when `string` is "yyyy-MM-dd" and names a day that exists on the Gregorian
    /// calendar. "2026-02-31" and "2026-02-29" are rejected; "2028-02-29" is not.
    public static func isValidDayString(_ string: String) -> Bool {
        components(ofDayString: string) != nil
    }

    /// (year, month, day) parsed out of a "yyyy-MM-dd" string, or nil when the string is
    /// malformed or the date does not exist.
    public static func components(ofDayString string: String) -> (year: Int, month: Int, day: Int)? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year >= 1, (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        return (year, month, day)
    }

    /// Plain proleptic-Gregorian arithmetic, so validating a date string never has to ask
    /// a Calendar (which would happily normalise Feb 31 into Mar 3).
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        default: return 31
        }
    }

    /// The instant a "yyyy-MM-dd" Banger day begins — the rollover hour on that date, in
    /// the rollover zone. On a spring-forward date, where that hour does not exist, this is
    /// the instant the clock jumps.
    public static func date(fromDayString string: String,
                            calendar: Calendar = Rollover.calendar,
                            rolloverHour: Int = Rollover.hour) -> Date? {
        guard let parts = components(ofDayString: string) else { return nil }
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        components.hour = rolloverHour
        if let exact = calendar.date(from: components) { return exact }
        // The hour does not exist on this date. Search forward from midnight instead.
        components.hour = 0
        guard let midnight = calendar.date(from: components) else { return nil }
        var match = DateComponents()
        match.hour = rolloverHour
        match.minute = 0
        match.second = 0
        return calendar.nextDate(after: midnight, matching: match,
                                 matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first,
                                 direction: .forward)
    }

    /// Whole days from `from` to `to`, both "yyyy-MM-dd". Negative if `to` is earlier.
    ///
    /// Anchored at noon rather than at the boundary: a 23- or 25-hour DST day would
    /// otherwise round a one-day gap to zero or two.
    public static func dayGap(from: String, to: String, calendar: Calendar = Rollover.calendar) -> Int? {
        guard let a = noon(ofDayString: from, calendar: calendar),
              let b = noon(ofDayString: to, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    private static func noon(ofDayString string: String, calendar: Calendar) -> Date? {
        guard let parts = components(ofDayString: string) else { return nil }
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        components.hour = 12
        return calendar.date(from: components)
    }

    /// "yyyyMMdd'T'HHmmss'Z'" in UTC — a file-name-safe instant for the "moved aside"
    /// copies the store keeps (history.corrupt-…, tasks.empty-…). No colons, sorts by time.
    public static func fileStamp(_ date: Date = Date()) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let p = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    // MARK: - Timestamps

    private static let iso = Date.ISO8601FormatStyle()
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// "2026-09-21T14:22:10Z"
    public static func timestampString(_ date: Date) -> String {
        iso.format(date)
    }

    /// Parses an ISO 8601 timestamp, with or without fractional seconds.
    public static func parseTimestamp(_ string: String) -> Date? {
        if let date = try? iso.parse(string) { return date }
        if let date = try? isoFractional.parse(string) { return date }
        return nil
    }
}
