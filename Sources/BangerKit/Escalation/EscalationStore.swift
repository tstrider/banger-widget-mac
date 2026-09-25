//  EscalationStore.swift — the seam between the task document and the engine.
//
//  `TaskStore` itself is not changed here. This file only adds an extension that runs
//  one coordinated read-modify-write to update the
//  escalation ledger, which lives in `TaskDocument.extra["escalation"]`.
//
//  Call order on the app side:
//
//      BangerNotification.observeTaskCompleted { payload in
//          let decision = try? TaskStore.shared.escalate(for: payload, origin: checkboxPoint)
//          presenter.play(decision.config, plan: decision.plan)
//      }
//
//  `escalate` both decides and records, inside the same coordinated write, so two
//  completions arriving at once cannot both read "no recent completions" and both come
//  out at full volume.

import CoreGraphics
import Foundation

public extension TaskStore {

    /// Reads the ledger without changing anything.
    func escalationLedger() throws -> EscalationLedger {
        EscalationLedger.read(from: try load())
    }

    /// The decision for a completion, WITHOUT recording it. For previews, replays and
    /// `bangerctl --dry-run`. Two calls in a row return the same answer.
    func previewEscalation(for payload: TaskCompletionPayload,
                           origin: CGPoint,
                           reduceMotion: Bool = false,
                           now: Date = Date()) throws -> EscalationDecision {
        let ledger = try escalationLedger()
        let context = EscalationContext.make(payload: payload, ledger: ledger,
                                             origin: origin, reduceMotion: reduceMotion, now: now)
        return EscalationEngine.decide(context)
    }

    /// Decide AND record, atomically.
    ///
    /// The record is what makes the fatigue model and the farm guard work across
    /// processes: the widget extension checks a box, the agent app celebrates, and both
    /// see the same ledger because it is in the same coordinated file.
    @discardableResult
    func escalate(for payload: TaskCompletionPayload,
                  origin: CGPoint,
                  reduceMotion: Bool = false,
                  now: Date = Date()) throws -> EscalationDecision {
        try mutate { document in
            let ledger = EscalationLedger.read(from: document)
            let context = EscalationContext.make(payload: payload, ledger: ledger,
                                                 origin: origin, reduceMotion: reduceMotion,
                                                 now: now)
            let decision = EscalationEngine.decide(context)

            var updated = ledger
            updated.record(taskID: payload.taskID,
                           day: document.date,
                           tier: decision.tier,
                           streakDays: payload.streakDays,
                           at: now)
            updated.write(into: &document)
            return decision
        }
    }
}

// MARK: - Direct construction, for callers without a store

public extension EscalationEngine {

    /// For the renderer and for tests: decide straight from a payload and a ledger,
    /// touching no files.
    static func decide(payload: TaskCompletionPayload,
                       ledger: EscalationLedger = EscalationLedger(),
                       origin: CGPoint,
                       reduceMotion: Bool = false,
                       now: Date = Date()) -> EscalationDecision {
        decide(EscalationContext.make(payload: payload, ledger: ledger, origin: origin,
                                      reduceMotion: reduceMotion, now: now))
    }
}
