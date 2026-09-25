//  PeekTaskIntent.swift — tap a task's text to read the whole thing.
//
//  A row is one line and a long task ends in "…". The layout stays that way; the full
//  text is one tap away instead. A widget cannot show a popover, a tooltip or anything
//  else outside its own rectangle, so, exactly like the + (QuickAddIntent), this asks
//  the agent app to do it: the agent puts up a small card beside the widget and takes
//  it down on a click anywhere, on Escape, or on a second tap of the same text.
//
//  `openAppWhenRun` stays false and nothing here touches NSWorkspace, so the tap does
//  not activate Banger or disturb whatever is in front.
//
//  TWO ROUTES TO THE AGENT, because only one of them is known to work from here.
//
//   1. A request file, peek-request.json, beside tasks.json. This is the route that
//      is proven: the extension already writes into that folder through its
//      temporary-exception entitlement (the check-off, the celebration ledger, the
//      read receipt), and the agent is not sandboxed and watches that folder.
//   2. A distributed notification under the plain and the group-prefixed name, the
//      way the + does it. A sandboxed extension with no app group or team prefix
//      probably cannot post either; it costs nothing to try, and where it
//      does get through it is a few milliseconds sooner. userInfo is dropped for a
//      sandboxed poster, so what little it carries rides in `object`.
//
//  Each tap carries a fresh request id, and the agent acts on an id once, so the tap
//  that arrives both ways still counts as one tap — which matters, because a second
//  tap of the same task is how the card closes.
//
//  Only the task's id travels. The agent reads the text from tasks.json itself, so
//  the task's words are never in a notification or the system log.

import AppIntents
import Foundation
import BangerKit

/// Kept in step by hand with the copy in Sources/Banger/TaskPeek.swift, for the same
/// reason as QuickAddSignal: the two targets do not share a framework for this, and a
/// file name and two strings are not worth widening BangerKit's surface for.
enum TaskPeekSignal {
    static let plain = Notification.Name("com.bangerwidget.banger.peek")
    static let groupPrefixed = Notification.Name("group.com.bangerwidget.banger.peek")
    static let requestFileName = "peek-request.json"

    struct Request: Codable {
        /// Fresh per tap. The agent de-duplicates on it.
        var id: String
        var taskID: String
        /// Seconds since 1970, so the agent can ignore a request it only finds late.
        var at: Double
    }

    static func post(taskID: String) {
        let request = Request(id: UUID().uuidString, taskID: taskID,
                              at: Date().timeIntervalSince1970)

        // The file first: it is the route that is known to work. Atomic, so the agent
        // never reads half of one.
        let url = TaskStore.shared.containerURL
            .appendingPathComponent(requestFileName, isDirectory: false)
        if let data = try? JSONEncoder().encode(request) {
            try? data.write(to: url, options: .atomic)
        }

        let center = DistributedNotificationCenter.default()
        for name in [groupPrefixed, plain] {
            center.postNotificationName(name, object: "\(request.id) \(taskID)",
                                        userInfo: nil, deliverImmediately: true)
        }
    }
}

struct PeekTaskIntent: AppIntent {

    static let title: LocalizedStringResource = "Show Full Task"
    static let description = IntentDescription("Shows a Banger task's whole text beside the widget.")

    /// A widget control, not a user-facing action: keep it out of Shortcuts and Spotlight.
    static let isDiscoverable: Bool = false
    /// False on purpose. See the note at the top of this file.
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Task ID") var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        TaskPeekSignal.post(taskID: taskID)
        return .result()
    }
}
