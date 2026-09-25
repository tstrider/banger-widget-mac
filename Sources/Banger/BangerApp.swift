//  BangerApp.swift — process entry point.
//
//  Deliberately not a SwiftUI `App`. A SwiftUI scene graph wants to own a window,
//  and this process must never have one. We build NSApplication by hand, pin the
//  activation policy to .accessory (no Dock tile, no menu bar, never becomes the
//  active app on its own) and hand control to the delegate.

import AppKit

@main
enum BangerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Set before run() so the process never flashes a Dock tile at launch.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
