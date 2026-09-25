//  ScreenGeometry.swift — the one place that knows about coordinate spaces.
//
//  Convention used across every trigger path: a CelebrationConfig arriving from
//  outside this process carries `origin` as a GLOBAL point with the origin at the
//  top-left of the primary display and y growing downward — the same space
//  CoreGraphics and every "where was the mouse / where is the checkbox" API uses.
//
//  CelebrationAPI documents `origin` as being in the overlay window's space
//  (also top-left, y down). So exactly one conversion happens, here, at present
//  time: global top-left -> window-local top-left for the screen we picked.

import AppKit

/// Clamp that also swallows NaN and infinity.
///
/// Not paranoia. `banger://celebrate?intensity=nan` parses to a real Double.nan, an
/// ordinary `min(max(...))` propagates it, and the particle counts downstream are
/// `Int((161.0 + 322.0 * t).rounded())` — `Int(Double.nan)` is a trap, not a wrong
/// number. Any local process can post that notification, so the agent has to be
/// unkillable by its own debug entry point. Finite values are unaffected.
func bangerClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    guard value.isFinite else { return lower }
    return min(max(value, lower), upper)
}

@MainActor
enum ScreenGeometry {

    /// The primary display — the one whose frame origin is (0, 0) in Cocoa space.
    static var primary: NSScreen? { NSScreen.screens.first }

    /// Cocoa global space has its origin at the bottom-left of the primary display.
    static func cocoaPoint(fromGlobalTopLeft point: CGPoint) -> CGPoint {
        guard let primary else { return point }
        return CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    /// The display the celebration belongs on. Falls back to the screen with the
    /// menu bar if the point is off every display (a monitor unplugged, or stale
    /// coordinates from a widget snapshot taken before a layout change).
    static func screen(forGlobalTopLeft point: CGPoint) -> NSScreen? {
        let cocoa = cocoaPoint(fromGlobalTopLeft: point)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) { return hit }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Global top-left point expressed inside a window that covers `screen.frame`,
    /// still top-left with y down, which is what SwiftUI's Canvas draws in.
    static func windowLocalTopLeft(fromGlobalTopLeft point: CGPoint, on screen: NSScreen) -> CGPoint {
        let cocoa = cocoaPoint(fromGlobalTopLeft: point)
        let local = CGPoint(x: cocoa.x - screen.frame.minX,
                            y: screen.frame.maxY - cocoa.y)
        return CGPoint(x: bangerClamp(local.x, 0, screen.frame.width),
                       y: bangerClamp(local.y, 0, screen.frame.height))
    }

    /// Where the widget lives: top right of the main display.
    /// Used when a trigger gives us no origin of its own.
    static var widgetHomeGlobalTopLeft: CGPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let cocoa = CGPoint(x: screen.frame.maxX - 180, y: screen.frame.maxY - 120)
        let primaryMaxY = (primary ?? screen).frame.maxY
        return CGPoint(x: cocoa.x, y: primaryMaxY - cocoa.y)
    }
}
