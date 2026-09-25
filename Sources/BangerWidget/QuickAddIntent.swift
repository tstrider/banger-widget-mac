//  QuickAddIntent.swift — the + button, and the one interruption that is allowed.
//
//  A macOS widget has no text input. None: the system hands the widget host a
//  rendered picture and a set of intents, and there is no API that puts a caret in
//  it. So the + cannot open a field — it has to ask something that can.
//
//  It does that by posting a notification rather than by foregrounding the agent.
//  `openAppWhenRun` stays false and nothing here touches NSWorkspace, so pressing +
//  does not activate Banger, does not raise a window, and does not disturb whatever
//  is in front. The agent hears the notification and puts up QuickAdd's borderless
//  panel, which is the only thing that takes focus, and hands focus straight back
//  when it closes. That is as close to "open just the panel" as macOS allows.
//
//  The one caveat, stated plainly: this works because the agent is already running.
//  If Banger is not running, + does nothing. Banger is a login item and the
//  celebration depends on it too, so a dead agent is already a broken install, but
//  the button is not a way to start one.

import AppIntents
import Foundation

/// Kept in step by hand with the copy in Sources/Banger/QuickAdd.swift. The two
/// targets do not share a framework for this, and one string is not worth widening
/// BangerKit's surface for.
enum QuickAddSignal {
    static let plain = Notification.Name("com.bangerwidget.banger.quickAdd")
    /// App Sandbox only lets a sandboxed process post distributed notification
    /// names carrying its group prefix, and a widget extension is sandboxed. The
    /// agent listens on both and the panel is idempotent, so whichever gets
    /// through, one panel appears.
    static let groupPrefixed = Notification.Name("group.com.bangerwidget.banger.quickAdd")

    static func post() {
        let center = DistributedNotificationCenter.default()
        for name in [groupPrefixed, plain] {
            center.postNotificationName(name, object: nil, userInfo: nil,
                                        deliverImmediately: true)
        }
    }
}

struct QuickAddIntent: AppIntent {

    static let title: LocalizedStringResource = "Add a Task"
    static let description = IntentDescription("Opens Banger's quick-add panel.")

    static let isDiscoverable: Bool = false
    /// False on purpose. See the note at the top of this file.
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        QuickAddSignal.post()
        return .result()
    }
}
