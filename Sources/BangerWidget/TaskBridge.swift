//  TaskBridge.swift — the widget's only door into BangerKit.
//
//  Every other file in this target speaks WidgetTask / WidgetDay, so if BangerKit's
//  TaskStore surface moves, this file is the single place that has to move with it.
//
//  There is no App Group here on purpose. A machine with no code-signing identity
//  cannot use one at all, so BangerKit's BangerContainer
//  resolves the shared folder by probing, and the widget reaches it through the
//  home-relative temporary exception in BangerWidget.entitlements.

import Foundation
import BangerKit

// MARK: - Widget-local model

struct WidgetTask: Identifiable, Hashable, Sendable {
    var id: String
    var text: String
    var done: Bool
    var source: String
    var completedAt: Date?
    /// Display identity, set by RowPlan. Differs from `id` only for a row that rose
    /// up the list, so WidgetKit animates it as a pop instead of a slide.
    var rowKey: String? = nil

    var reorderKey: String { rowKey ?? id }
}

struct WidgetDay: Sendable {
    var dayKey: String
    var tasks: [WidgetTask]
    var streak: Int

    var doneCount: Int { tasks.reduce(0) { $0 + ($1.done ? 1 : 0) } }
    var openCount: Int { tasks.count - doneCount }
    var isCleared: Bool { !tasks.isEmpty && openCount == 0 }
    var fraction: Double { tasks.isEmpty ? 0 : Double(doneCount) / Double(tasks.count) }

    /// The id of the only task still open, when exactly one is left and the day had
    /// more than one to begin with. Drives the "last one" treatment.
    var lastOpenID: String? {
        guard tasks.count > 1, openCount == 1 else { return nil }
        return tasks.first(where: { !$0.done })?.id
    }

    /// Which row carries the "one left" treatment.
    ///
    /// Normally the only open task. During the punch window it stays on the task
    /// that just cleared the day, because the last row must not lose its lighting
    /// halfway through its own transition — the reloaded entry arrives mid-flight
    /// and would otherwise pull the rail, the ring weight and the tint out from
    /// under it.
    func highlightID(punchID: String?) -> String? {
        if let id = lastOpenID { return id }
        if let punchID, isCleared, tasks.count > 1,
           tasks.contains(where: { $0.id == punchID }) { return punchID }
        return nil
    }

    /// Most recently completed task, used to decide which row renders mid-punch.
    var mostRecentlyCompleted: WidgetTask? {
        tasks.filter { $0.done && $0.completedAt != nil }
             .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }
}

enum TaskBridgeError: Error {
    case containerUnavailable(String)
    case unreadable(String)
}

/// A check-off that could not be saved: the list is there but TaskStore could not read
/// or write it. Deliberately its own type, not a TaskBridgeError case, and deliberately
/// distinct from a stale task id, which is not an error at all (see `TaskBridge.setDone`).
struct TaskWriteError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    var detail: String

    var errorDescription: String? { "Banger couldn't save that check-off: \(detail)" }

    /// What App Intents shows, if it shows anything, when `perform()` throws this.
    var localizedStringResource: LocalizedStringResource {
        "Banger couldn't save that check-off: \(detail)"
    }
}

/// Everything the celebration needs about one check-off, captured inside the
/// coordinated mutation so it is consistent with what was actually written.
struct ToggleOutcome: Sendable {
    var task: WidgetTask
    var becameDone: Bool
    var dayKey: String
    /// BangerKit's canonical completion payload, including the deterministic seed.
    /// Built by TaskStore so a widget check-off and a `bangerctl done` produce the
    /// identical celebration for the same task on the same day.
    var payload: TaskCompletionPayload
}

// MARK: - Bridge

enum TaskBridge {

    /// The resolved shared folder, shown in the widget's error state so a wrong
    /// path is visible instead of looking like an empty list.
    static var containerPath: String {
        TaskStore.shared.containerURL.path
    }

    static func loadToday() -> Result<WidgetDay, TaskBridgeError> {
        do {
            return .success(try TaskStore.shared.load().asWidgetDay)
        } catch let error as TaskStoreError {
            if case .containerUnavailable(let detail) = error {
                return .failure(.containerUnavailable(detail))
            }
            return .failure(.unreadable(error.localizedDescription))
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
    }

    /// Sets one task's done flag and reports what happened. Returns nil when the id
    /// is no longer in today's list (an agent rewrote the file between render and tap).
    /// THROWS `TaskWriteError` when the store could not read or write the
    /// list — a real failure, which the caller must not flatten into "nothing happened".
    ///
    /// A repeat of the state the task is already in writes nothing: TaskStore.mutate
    /// skips the write, and the change notification, when the document is unchanged.
    ///
    /// A *set*, not a toggle, because the widget's Toggle has already drawn the new
    /// state optimistically and sends it along: two clicks inside one reload window
    /// must not cancel each other out. `becameDone` is therefore false on a repeat,
    /// which is also what keeps the celebration from firing twice.
    ///
    /// Deliberately not `TaskStore.setDone`: that posts the celebration itself, and the
    /// widget has to run the once-per-task-per-day ledger between the write and the
    /// post. The payload still comes from TaskStore, so nothing about it is re-derived
    /// here.
    static func setDone(_ done: Bool, taskID: String) throws -> ToggleOutcome? {
        do {
            return try mutateDone(done, taskID: taskID)
        } catch {
            throw TaskWriteError(detail: error.localizedDescription)
        }
    }

    private static func mutateDone(_ done: Bool, taskID: String) throws -> ToggleOutcome? {
        try TaskStore.shared.mutate { document -> ToggleOutcome? in
            guard let index = document.index(ofTaskWithID: taskID) else { return nil }

            let wasDone = document.tasks[index].done
            let becameDone = done && !wasDone
            document.tasks[index].done = done
            if done {
                // Keep the original completion instant on a repeat, so a stray
                // click does not move the row in the display order.
                if !wasDone { document.tasks[index].completedAt = Date() }
            } else {
                document.tasks[index].completedAt = nil
            }

            return ToggleOutcome(
                task: WidgetTask(document.tasks[index]),
                becameDone: becameDone,
                dayKey: document.date,
                payload: TaskStore.completionPayload(for: document, index: index)
            )
        }
    }
}

// MARK: - BangerKit adaptation

private extension WidgetTask {
    init(_ task: BangerTask) {
        self.init(id: task.id,
                  text: task.text,
                  done: task.done,
                  source: task.source,
                  completedAt: task.completedAt)
    }
}

private extension TaskDocument {
    var asWidgetDay: WidgetDay {
        WidgetDay(dayKey: date, tasks: tasks.map(WidgetTask.init), streak: streakDays)
    }
}
