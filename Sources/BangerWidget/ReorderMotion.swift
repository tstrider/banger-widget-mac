//  ReorderMotion.swift — how a checked row gets to its new spot near the top.
//
//  The order changes when the reloaded entry lands (RowPlan.displayOrder). Across an
//  entry change WidgetKit only animates built-in things — positions, and the
//  insertion/removal transitions of views whose identity changed. A custom
//  Animatable is drawn at its end value only.
//
//  So the fun is built out of identity. A task that ROSE past open rows gets a new
//  identity once it is done. WidgetKit sees the old row leave and a new one arrive:
//
//    - at its old spot, the row shrinks and fades away;
//    - at its new spot near the top, it POPS in: from small, from the right, on a
//      bouncy spring that overshoots and settles;
//    - the open rows it jumped over slide down to make room.
//
//  A task that did not move keeps its identity, so it never pops for nothing, and
//  the key never changes again afterwards, so it pops exactly once.

import SwiftUI

enum ReorderMotion {

    /// Bouncy on purpose: the overshoot on the pop-in is the whole joke.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25)
                     : .spring(response: 0.5, dampingFraction: 0.55)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.4, anchor: .leading)
                .combined(with: .offset(x: 34))
                .combined(with: .opacity),
            removal: .scale(scale: 0.6, anchor: .leading)
                .combined(with: .opacity))
    }

    /// The identity a row is drawn with. A done task that had an open task above it
    /// in the file when it was checked has risen past it; it gets a new key. That
    /// test does not change later — an earlier task that was open then is either
    /// still open or was completed after — so a row pops once and then rests.
    static func key(for task: WidgetTask, in tasks: [WidgetTask]) -> String {
        guard task.done, let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            return task.id
        }
        let finished = task.completedAt ?? .distantPast
        let rose = tasks[..<index].contains { earlier in
            !earlier.done || (earlier.completedAt ?? .distantPast) > finished
        }
        return rose ? task.id + "#rose" : task.id
    }
}
