//  TriggerBridge.swift — the distributed notifications the agent listens on, and
//  the widget reload that keeps it current.
//
//  Suspension behaviour is .deliverImmediately on purpose. A background agent is
//  never the active application, and the default coalescing behaviour will queue
//  notifications for an inactive process — which would mean the confetti arrives
//  some time after the click, or not at all.
//
//  Every name is observed twice, plain and group-prefixed, because App Sandbox only
//  lets the widget extension post names carrying its group prefix while a shell or
//  `bangerctl` posts the plain one. BangerKit posts under both and de-duplicates the
//  completion by seed, so whichever gets through, the party happens exactly once.

import AppKit
import WidgetKit
import BangerKit

@MainActor
final class TriggerBridge {

    private var tokens: [NSObjectProtocol] = []

    /// The path that actually works from the widget. See TaskFileWatcher for why the
    /// notification alone is not enough: a sandboxed widget extension cannot post one
    /// without an app-group or team prefix, and this project has neither.
    ///
    /// Built in `start()` rather than here, because the watcher takes its completion
    /// handler at init and keeps it immutable — there is no callback to reassign later.
    private var watcher: TaskFileWatcher?

    /// Fires the day over at 02:00 in the rollover zone. The store's own rollover is
    /// lazy — it happens on the next read or write — which is correct but means an
    /// idle overnight machine shows yesterday's list until something touches the file.
    /// See DayRolloverScheduler.
    private var rollover: DayRolloverScheduler?

    func start() {
        guard tokens.isEmpty else { return }

        tokens += BangerNotification.observeTaskCompleted { payload in
            Task { @MainActor in
                TriggerBridge.celebrateOnce(CelebrationConfig(completion: payload),
                                            seed: payload.seed, taskID: payload.taskID)
                WidgetReloader.shared.schedule()
            }
        }

        // The file watcher. This is what makes ticking a box in the widget do anything,
        // and what refreshes the widget after an add, uncheck or edit it cannot announce.
        let watcher = TaskFileWatcher(onDocumentChanged: { _ in
            WidgetReloader.shared.schedule()
        }, onCompletions: { (tasks: [BangerTask], document: TaskDocument) in
            for task in tasks {
                // Built from the document the watcher just read, not from a second
                // `load()`. Same numbers, same seed — `completionPayload(for:index:)`
                // is a pure function of (document, index) — but one decode instead of
                // two per completion on the latency path, and no chance of `load()`
                // rolling the day over underneath us and losing the completion it was
                // called to celebrate.
                guard let index = document.index(ofTaskWithID: task.id) else { continue }
                let payload = TaskStore.completionPayload(for: document, index: index)
                TriggerBridge.celebrateOnce(CelebrationConfig(completion: payload),
                                            seed: payload.seed, taskID: task.id)
            }
            // No reload here: a completion is a document change, and that callback
            // follows this one with the reload.
        })
        self.watcher = watcher
        watcher.start()

        let rollover = DayRolloverScheduler {
            // The list is empty and the streak has moved. The widget is the only thing
            // that shows either, and it will not notice on its own.
            WidgetReloader.shared.schedule()
        }
        self.rollover = rollover
        rollover.start()

        tokens += observe(BangerNotification.debugCelebrate,
                          BangerNotification.debugCelebrateGroupPrefixed) { note in
            // The config may arrive as a JSON string in userInfo["config"] or
            // ["json"], as the notification object, or as loose userInfo keys.
            let json = (note.userInfo?["config"] as? String)
                ?? (note.userInfo?["json"] as? String)
                ?? (note.object as? String)
            let fields = Self.flatten(note.userInfo)
            Task { @MainActor in
                var config: CelebrationConfig?
                if let json, let data = json.data(using: .utf8) {
                    config = CelebrationConfig(debugJSON: data)
                }
                if config == nil, !fields.isEmpty {
                    config = CelebrationConfig(payload: PayloadFields(json: fields))
                }
                guard let config else { return }
                CelebrationPresenter.shared.celebrate(config)
            }
        }

        tokens += observe(BangerNotification.tasksChanged,
                          BangerNotification.tasksChangedGroupPrefixed) { _ in
            // Delivered on .main (see `observe`), so no Task per notification: a burst of
            // writes is a burst of these, and each only needs to ask for the one reload.
            MainActor.assumeIsolated { WidgetReloader.shared.schedule() }
        }
    }

    /// Both trigger paths can see the same completion. Whichever arrives first fires;
    /// the other is dropped. Keyed on the completion seed, which BangerKit derives
    /// deterministically from (date, task id, index), so the two paths agree on it.
    private static var celebrated: [UInt64: Date] = [:]

    @MainActor
    static func celebrateOnce(_ config: CelebrationConfig, seed: UInt64, taskID: String) {
        let now = Date()
        celebrated = celebrated.filter { now.timeIntervalSince($0.value) < 4 }
        if celebrated[seed] != nil { return }
        celebrated[seed] = now
        CelebrationPresenter.shared.celebrate(config)
    }

    func stop() {
        rollover?.stop()
        rollover = nil
        watcher?.stop()
        watcher = nil
        let center = DistributedNotificationCenter.default()
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    // MARK: - Observing

    /// Observers run on the main queue but are not statically isolated, so each
    /// handler takes only Sendable values out of the notification before hopping
    /// to the main actor.
    private func observe(_ names: Notification.Name...,
                         using handler: @escaping @Sendable (Notification) -> Void) -> [NSObjectProtocol] {
        names.map { name in
            DistributedNotificationCenter.default().addObserver(
                forName: name,
                object: nil,
                queue: .main,
                using: handler
            )
        }
    }

    // MARK: - Payload snapshot

    /// A distributed notification's userInfo is plist types and is not Sendable.
    /// Flatten it to `[String: String]` synchronously, on whatever thread delivered
    /// it, so the main-actor hop carries a value we own.
    nonisolated private static func flatten(_ userInfo: [AnyHashable: Any]?) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in userInfo ?? [:] {
            guard let key = key as? String else { continue }
            switch value {
            case let s as String:   out[key] = s
            case let n as NSNumber: out[key] = n.stringValue
            case let nested as [String: Any]:
                // e.g. origin: { x: 2400, y: 140 } -> originX / originY
                for (innerKey, innerValue) in nested {
                    let composed = key + innerKey.prefix(1).uppercased() + innerKey.dropFirst()
                    if let s = innerValue as? String { out[composed] = s }
                    else if let n = innerValue as? NSNumber { out[composed] = n.stringValue }
                }
            case let pair as [Any] where pair.count == 2:
                // CGPoint's own Codable form: origin: [2400, 140] -> originX / originY
                for (innerKey, innerValue) in zip(["X", "Y"], pair) {
                    if let s = innerValue as? String { out[key + innerKey] = s }
                    else if let n = innerValue as? NSNumber { out[key + innerKey] = n.stringValue }
                }
            default: continue
            }
        }
        return out
    }
}

/// Widget refresh is not instant on its own. Every task
/// change the agent hears about ends with a reload, coalesced so a burst of
/// completions costs one reload instead of five.
///
/// Every app-side reload goes through here. The same change is usually heard two or
/// three ways at once (the file watcher, the tasksChanged notification, the completion
/// notification), so each of those only asks; the first ask opens a short window and
/// everything inside it rides on the one reload at its end. The window is not pushed
/// back by later asks, so a steady stream of changes still reloads every 250 ms rather
/// than never.
@MainActor
final class WidgetReloader {

    static let shared = WidgetReloader()
    private var pending: DispatchWorkItem?
    private let window: TimeInterval = 0.25

    private init() {}

    func schedule() {
        guard pending == nil else { return }
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                WidgetReloader.shared.pending = nil
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: item)
    }

    /// Reload now, for a change the user is looking at the widget to see (quick-add). Takes
    /// any pending reload with it rather than doing a second one moments later.
    func reloadNow() {
        pending?.cancel()
        pending = nil
        WidgetCenter.shared.reloadAllTimelines()
    }
}
