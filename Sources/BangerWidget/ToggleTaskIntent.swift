//  ToggleTaskIntent.swift — what a checkbox actually does.
//
//  It is a SetValueIntent rather than a plain AppIntent, and that is not a detail.
//  `Toggle(isOn:intent:)` only accepts a SetValueIntent, and a Toggle is the one
//  construct WidgetKit renders OPTIMISTICALLY — SwiftUI flips the displayed state
//  on the click and lets this run afterwards. With a Button the check mark would
//  wait for a file write, a notification and a timeline reload before anything
//  moved. See TaskRow.swift.
//
//  Being a *set* rather than a *toggle* also makes it idempotent: two clicks in
//  the same reload window both mean "done" instead of cancelling each other out.
//
//  The contract: this must never steal focus. openAppWhenRun is false,
//  it returns a bare .result() with no opensIntent, and it never touches
//  NSWorkspace. It writes the file, posts the completion, asks for a reload, and
//  gets out of the way. The celebration is the agent app's job, in its own process.
//  The one exception to the bare result: a write that genuinely failed throws
//  (TaskWriteError), so the failure is visible instead of passing for a success.

import AppIntents
import Foundation
import WidgetKit

struct ToggleTaskIntent: SetValueIntent {

    static let title: LocalizedStringResource = "Check Off Task"
    static let description = IntentDescription("Checks a Banger task off today's list.")

    /// A widget control, not a user-facing action: keep it out of Shortcuts and Spotlight.
    static let isDiscoverable: Bool = false
    /// The line that matters. Never foreground the agent app.
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Set by SwiftUI to the state the toggle has already drawn.
    @Parameter(title: "Done") var value: Bool
    @Parameter(title: "Task ID") var taskID: String

    init() {}

    init(taskID: String, value: Bool) {
        self.taskID = taskID
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        // Runs on every exit, the throwing one included: the reload is what puts the
        // truth back over the Toggle's optimistic state when the write did not land.
        defer { WidgetCenter.shared.reloadTimelines(ofKind: BangerWidgetKind.checklist) }

        // Two different "nothing happened"s, kept apart on purpose:
        //   * nil — that id is no longer in today's list (an agent rewrote it between
        //     render and click). Not an error; the reload shows the current list.
        //   * a throw — the list could not be read or written. That is a real failure
        //     and it leaves this intent as one, instead of reporting success.
        guard let outcome = try TaskBridge.setDone(value, taskID: taskID) else { return .result() }

        // TaskStore.mutate has already posted tasksChanged if anything changed (a repeat
        // click writes and posts nothing), so an un-check needs nothing further. A genuine first completion pays out exactly once.
        if outcome.becameDone,
           CelebrationLedger.claim(taskID: outcome.task.id, dayKey: outcome.dayKey) {
            outcome.payload.post()
        }

        return .result()
    }
}
