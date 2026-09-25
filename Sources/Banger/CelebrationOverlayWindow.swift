//  CelebrationOverlayWindow.swift — the full-screen, click-through party window.
//
//  Level: .screenSaver (CGWindowLevelForKey(.screenSaverWindow) == 1000).
//  That sits above every level the user actually interacts with — normal (0),
//  floating (3), modal panel (8), dock (20), main menu (24), status (25),
//  pop-up menu (101) — and strictly below CGShieldingWindowLevel(), which is what
//  the lock screen, fast user switching and the real screen saver engine use.
//  So the confetti covers the whole desktop but can never draw over a locked or
//  logging-in machine. CGShieldingWindowLevel() - 1 would also clear everything
//  normal, but it is one step under the shield and leaves no room for the system
//  UI that legitimately sits between the two, so .screenSaver is the safer pick.

import AppKit

final class CelebrationOverlayWindow: NSWindow {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        // The designated initializer takes the rect in global screen coordinates,
        // so handing it the target screen's frame is what places it on that display.
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        // A hard requirement. Every click, scroll and hover goes
        // straight through to whatever the user was actually doing.
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false

        // Present on every Space and over full-screen apps, without the act of
        // showing it yanking the user out of the Space they are in.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isRestorable = false
        animationBehavior = .none
        displaysWhenScreenProfileChanges = true
        tabbingMode = .disallowed

        setFrame(screen.frame, display: false)
    }

    /// Install the SwiftUI content, sized to fill.
    func setOverlayContent(_ view: NSView) {
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        contentView = view
    }

    /// Show without ever making this window key, main, or activating the process.
    func present() {
        orderFrontRegardless()
    }

    /// Full teardown: drop the hosting view (which drops the Canvas and its GPU
    /// backing store) before the window goes away, so nothing lingers compositing.
    func tearDown() {
        orderOut(nil)
        contentView = nil
        close()
    }
}
