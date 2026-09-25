//  AppDelegate.swift — the background agent itself.
//
//  Owns the three trigger paths (hotkey, distributed notifications, URL scheme)
//  and nothing else. All celebration state lives in CelebrationPresenter.

import AppKit
import BangerKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let triggers = TriggerBridge()
    private let hotKey = HotKeyMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        triggers.start()

        // Carbon hot key: works from the background with no Accessibility grant.
        // Cycles the four tiers so the celebration can be felt end to end while tuning.
        hotKey.register(keyCode: HotKeyMonitor.keyB,
                        modifiers: [.control, .option, .command]) {
            CelebrationPresenter.shared.celebrateDemoCyclingTier()
        }

        // The quick-add panel. This one line is the whole wiring: QuickAdd builds
        // and prewarms its panel, reserves ⌃⌥⌘N with the window server (Carbon, so
        // no Accessibility grant), and listens for the notification the widget's +
        // posts. Without it the panel is compiled in and unreachable, and a widget
        // has no text input, so the only way to add a task would be a terminal.
        QuickAdd.shared.install()

        // Tap a task's words on the widget to read all of it. Listens for the widget's
        // peek request (a file beside tasks.json, and a notification) and puts the full
        // text in a card beside the widget. See TaskPeek.
        TaskPeek.shared.install()

        // Decode the wavs and build the audio graph now, so the first celebration of the
        // day is not the one that pays for it. Without this the first fire is audibly
        // late while AVAudioEngine starts.
        BangerSound.shared.prepare()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
        QuickAdd.shared.uninstall()
        TaskPeek.shared.uninstall()
        triggers.stop()
        CelebrationPresenter.shared.dismissImmediately()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// `open "banger://celebrate?tier=finalTask&intensity=0.9"` from a shell.
    /// Secondary to the debugCelebrate notification, which does not touch activation.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let config = CelebrationConfig(debugURL: url) else { continue }
            CelebrationPresenter.shared.celebrate(config)
        }
        // Launch Services activates us to deliver the URL. Hand focus straight back:
        // an accessory app that stays active replaces the user's menu bar.
        if NSApp.isActive { NSApp.deactivate() }
    }
}
