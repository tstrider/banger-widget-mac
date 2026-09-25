//  BangerNotification.swift — the wire between "a box got checked" and "throw the party".
//
//  The payload carries everything the app needs to build a CelebrationConfig WITHOUT
//  touching tasks.json again, because the file may already have moved on by the time
//  the notification lands.
//
//  Two things to know before you observe it:
//   1. Observe with `object: nil`. We put a JSON copy of the payload in `object` as a
//      backstop, because a sandboxed poster (the widget extension) is not allowed to
//      send a userInfo dictionary over DistributedNotificationCenter. An observer that
//      registers a specific object would never match.
//   2. Every userInfo value is a String. Distributed notifications serialise through a
//      property list and strings are the only shape that never surprises us.

import Foundation

public enum BangerNotification {

    /// Posted on DistributedNotificationCenter.default() whenever a task flips to done.
    /// THE canonical name. Observe this one.
    public static let taskCompleted = Notification.Name("com.bangerwidget.banger.taskCompleted")

    /// Posted whenever tasks.json changes at all (add / remove / undone / clear / rollover).
    /// The app uses this to call WidgetCenter.reloadAllTimelines(); no payload.
    public static let tasksChanged = Notification.Name("com.bangerwidget.banger.tasksChanged")

    /// App Sandbox restricts a sandboxed process to distributed notification names that
    /// carry its app-group or team prefix. The widget extension is sandboxed, so every
    /// post goes out under BOTH names and `observeTaskCompleted` listens on both,
    /// de-duplicating by seed. Whichever one survives the sandbox, the party happens once.
    public static let taskCompletedGroupPrefixed =
        Notification.Name("group.com.bangerwidget.banger.taskCompleted")
    public static let tasksChangedGroupPrefixed =
        Notification.Name("group.com.bangerwidget.banger.tasksChanged")

    /// Non-interactive trigger, for tuning and for screen recording. Carries a
    /// CelebrationConfig as JSON in userInfo["config"] or in the notification object.
    /// Nothing in the shipping path posts this; it exists so a one-line shell command
    /// can fire any tier on demand.
    public static let debugCelebrate = Notification.Name("com.bangerwidget.banger.debugCelebrate")
    public static let debugCelebrateGroupPrefixed =
        Notification.Name("group.com.bangerwidget.banger.debugCelebrate")

    /// CLOCK_UPTIME_RAW nanoseconds at the instant the completion was posted, carried in
    /// userInfo and in the object JSON. Every process on this machine reads the same
    /// clock, so an observer can subtract and get a true one-way transport time without
    /// any clock-sync handwaving. Nothing in the shipping path reads it; it exists so
    /// delivery latency can be measured.
    public static let postedAtKey = "postedAtNs"

    public enum Key {
        public static let taskID = "taskId"
        public static let taskText = "taskText"
        public static let taskIndex = "taskIndex"
        public static let taskCount = "taskCount"
        public static let remaining = "remaining"
        public static let streakDays = "streakDays"
        public static let source = "source"
        public static let fullyCleared = "fullyCleared"
        public static let date = "date"
        public static let seed = "seed"
    }

    /// Convenience observer. Handles both notification names, both the userInfo and the
    /// object-JSON payload form, and fires the handler once per completion.
    ///
    /// Always observes with `object: nil` — the payload JSON rides in the notification's
    /// `object`, so an observer registered against a specific object would never match.
    ///
    /// Keep the returned tokens alive; releasing them removes the observers.
    @discardableResult
    public static func observeTaskCompleted(
        queue: OperationQueue? = .main,
        handler: @escaping @Sendable (TaskCompletionPayload) -> Void
    ) -> [NSObjectProtocol] {
        let gate = CompletionGate()
        return [taskCompleted, taskCompletedGroupPrefixed].map { name in
            DistributedNotificationCenter.default().addObserver(
                forName: name, object: nil, queue: queue
            ) { note in
                guard let payload = TaskCompletionPayload(notification: note),
                      gate.shouldDeliver(payload) else { return }
                handler(payload)
            }
        }
    }

    /// Convenience observer for "the list changed at all" — the signal the app turns into
    /// `WidgetCenter.reloadAllTimelines()` and the one a sandboxed widget-side process can
    /// use to know it should re-read.
    ///
    /// The handler is given the CLOCK_UPTIME_RAW instant the post went out, when the
    /// sender stamped it (every TaskStore write does). Subtracting it from
    /// `BangerClock.uptimeNanos` inside the handler is a true one-way transport time: both
    /// processes are reading the same system clock, so nothing has to be synchronised.
    /// It is nil only for a post from an older build or from something that is not us.
    ///
    /// Keep the returned tokens alive; releasing them removes the observers.
    @discardableResult
    public static func observeTasksChanged(
        queue: OperationQueue? = .main,
        handler: @escaping @Sendable (UInt64?) -> Void
    ) -> [NSObjectProtocol] {
        [tasksChanged, tasksChangedGroupPrefixed].map { name in
            DistributedNotificationCenter.default().addObserver(
                forName: name, object: nil, queue: queue
            ) { note in
                handler(postedAtNanos(inChangeNotification: note))
            }
        }
    }

    /// The uptime stamp `TaskStore.postTasksChanged` puts in the notification's object.
    /// A bare decimal string, because a sandboxed poster cannot attach a userInfo
    /// dictionary and a plain string is the one payload shape that always survives.
    public static func postedAtNanos(inChangeNotification note: Notification) -> UInt64? {
        if let raw = note.object as? String, let value = UInt64(raw) { return value }
        if let raw = note.userInfo?[postedAtKey] as? String { return UInt64(raw) }
        return nil
    }

    /// Suppresses the second arrival of the same completion when both notification names
    /// get through. The seed is deterministic per (day, task, index), so a repeat inside
    /// the window is a duplicate delivery, not a second completion.
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastSeed: UInt64?
        private var lastAt: Date = .distantPast
        private let window: TimeInterval = 2

        func shouldDeliver(_ payload: TaskCompletionPayload) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            if payload.seed == lastSeed, now.timeIntervalSince(lastAt) < window { return false }
            lastSeed = payload.seed
            lastAt = now
            return true
        }
    }
}

/// Everything the celebration needs, snapshotted at the moment of completion.
public struct TaskCompletionPayload: Sendable, Equatable, Codable {

    public var taskID: String
    public var taskText: String
    /// 0-based index of the completed task among today's tasks, in file order.
    public var taskIndex: Int
    /// Total tasks today.
    public var taskCount: Int
    /// Tasks still open after this one.
    public var remaining: Int
    /// Consecutive fully-cleared days before today.
    public var streakDays: Int
    public var source: String
    /// True when this completion emptied the list.
    public var fullyCleared: Bool
    /// The document's day, "yyyy-MM-dd".
    public var date: String
    /// Stable per-completion seed. Same task on the same day always replays identically,
    /// which is what lets bangerrender reproduce a live celebration frame for frame.
    public var seed: UInt64

    public init(taskID: String,
                taskText: String,
                taskIndex: Int,
                taskCount: Int,
                remaining: Int,
                streakDays: Int,
                source: String,
                fullyCleared: Bool,
                date: String,
                seed: UInt64) {
        self.taskID = taskID
        self.taskText = taskText
        self.taskIndex = taskIndex
        self.taskCount = taskCount
        self.remaining = remaining
        self.streakDays = streakDays
        self.source = source
        self.fullyCleared = fullyCleared
        self.date = date
        self.seed = seed
    }

    /// FNV-1a over "date|id|index". Deterministic, no clock, no Foundation hashing
    /// (Swift's Hasher is seeded per process and would not reproduce).
    public static func seed(date: String, taskID: String, taskIndex: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(date)|\(taskID)|\(taskIndex)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash == 0 ? 0x9E37_79B9_7F4A_7C15 : hash
    }
}

// MARK: - Transport

public extension TaskCompletionPayload {

    var userInfo: [String: String] {
        [
            BangerNotification.Key.taskID: taskID,
            BangerNotification.Key.taskText: taskText,
            BangerNotification.Key.taskIndex: String(taskIndex),
            BangerNotification.Key.taskCount: String(taskCount),
            BangerNotification.Key.remaining: String(remaining),
            BangerNotification.Key.streakDays: String(streakDays),
            BangerNotification.Key.source: source,
            BangerNotification.Key.fullyCleared: fullyCleared ? "1" : "0",
            BangerNotification.Key.date: date,
            BangerNotification.Key.seed: String(seed),
        ]
    }

    /// Compact JSON, used as the notification's `object` so a sandboxed poster still
    /// gets the context across.
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TaskCompletionPayload.self, from: data)
        else { return nil }
        self = decoded
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        func string(_ key: String) -> String? {
            if let value = userInfo[key] as? String { return value }
            if let value = userInfo[key] as? NSNumber { return value.stringValue }
            return nil
        }
        guard let taskID = string(BangerNotification.Key.taskID) else { return nil }
        let index = Int(string(BangerNotification.Key.taskIndex) ?? "") ?? 0
        let date = string(BangerNotification.Key.date) ?? BangerDate.today()
        self.init(
            taskID: taskID,
            taskText: string(BangerNotification.Key.taskText) ?? "",
            taskIndex: index,
            taskCount: Int(string(BangerNotification.Key.taskCount) ?? "") ?? 1,
            remaining: Int(string(BangerNotification.Key.remaining) ?? "") ?? 0,
            streakDays: Int(string(BangerNotification.Key.streakDays) ?? "") ?? 0,
            source: string(BangerNotification.Key.source) ?? BangerSource.me,
            fullyCleared: (string(BangerNotification.Key.fullyCleared) ?? "0") == "1",
            date: date,
            seed: UInt64(string(BangerNotification.Key.seed) ?? "")
                ?? TaskCompletionPayload.seed(date: date, taskID: taskID, taskIndex: index)
        )
    }

    /// userInfo first, then the JSON in `object`.
    init?(notification: Notification) {
        if let payload = TaskCompletionPayload(userInfo: notification.userInfo) {
            self = payload
            return
        }
        if let raw = notification.object as? String, let payload = TaskCompletionPayload(jsonString: raw) {
            self = payload
            return
        }
        return nil
    }

    /// Posts under both names. A sandboxed poster only gets the group-prefixed one out,
    /// and a sandboxed poster's userInfo is dropped — which is why the payload also rides
    /// in `object` as JSON.
    func post(center: DistributedNotificationCenter = .default()) {
        let stamp = BangerClock.uptimeNanos
        // Spliced into the object JSON rather than added to the struct: TaskCompletionPayload
        // is decoded with JSONDecoder, which ignores keys it does not know, so an older
        // reader is unaffected and the wire shape stays the documented one.
        var object = jsonString
        if object.hasPrefix("{") {
            object = "{\"\(BangerNotification.postedAtKey)\":\(stamp)," + object.dropFirst()
        }
        var info = userInfo
        info[BangerNotification.postedAtKey] = String(stamp)
        for name in [BangerNotification.taskCompleted, BangerNotification.taskCompletedGroupPrefixed] {
            center.postNotificationName(name, object: object, userInfo: info, deliverImmediately: true)
        }
    }

    /// The post stamp, from userInfo or from the object JSON. nil when the poster was an
    /// older build.
    static func postedAtNanos(in notification: Notification) -> UInt64? {
        if let raw = notification.userInfo?[BangerNotification.postedAtKey] as? String,
           let value = UInt64(raw) { return value }
        if let raw = notification.userInfo?[BangerNotification.postedAtKey] as? NSNumber {
            return raw.uint64Value
        }
        guard let object = notification.object as? String,
              let range = object.range(of: "\"\(BangerNotification.postedAtKey)\":")
        else { return nil }
        let digits = object[range.upperBound...].prefix { $0.isNumber }
        return UInt64(digits)
    }
}

/// One clock, readable from every process, that does not move when the wall clock does.
public enum BangerClock {
    /// Nanoseconds since boot, excluding sleep. System-wide, so two processes can
    /// subtract each other's readings.
    public static var uptimeNanos: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    public static func millis(since start: UInt64) -> Double {
        Double(uptimeNanos &- start) / 1_000_000
    }
}
