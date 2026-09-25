//  CheckMotion.swift — the whole check-off transition, as arithmetic over ONE clock.
//
//  Seven things land on ONE frame — the counter, the CLEARED pill, the ladder
//  merging, the glyph swap, the strikethrough, the row lift, and the card itself —
//  and the resolve is a single monotone fall to a genuinely still frame.
//
//  1. IT ENDS BRIGHTER THAN IT STARTS. "Done" is not encoded as "less light": the
//     resting DONE state is brighter than the resting OPEN state on every element
//     the commit touches:
//
//       numeral   white 0.97, no glow   ->  white 1.00, +6 % size, permanent glow
//       label     white 0.97            ->  white 0.74
//       badge     LAST ONE              ->  a filled stamp that stays
//       ladder    3 segments, 3 pt      ->  one rail, 5.2 pt, permanently lit
//       edge      top-light only        ->  a lit accent perimeter, permanent
//       card      unlit                 ->  a low permanent accent wash
//
//     "Finished" is carried by WEIGHT and STRUCTURE, which can be brighter,
//     instead of by dimming, which cannot.
//
//  2. THE SECOND COLOUR LASTS. ONE curve, `gold`, owns the amber. It holds near
//     full for 180 ms and is gone at 235 ms, long enough to read as a colour rather
//     than a flicker, and five separate things ride it: the shattered shards, the
//     disc's struck rim, an expanding shock ring, the rail's leading edge, and the
//     band running round the card's perimeter.
//
//  3. IT REACHES THE CARD'S EDGE. THE HARD LIMIT, stated plainly: a widget's
//     drawing is clipped to its container shape. Nothing it renders can cross the
//     card's edge — there is no overlay window, no negative padding and no shadow it
//     controls. So the commit goes as far out as a widget is physically able to go:
//     to the card's own boundary. `sweep` runs a bright band around the entire
//     perimeter, `heat` blooms a wash across the whole card from the point of
//     impact, and the ring shock expands past the checkbox into the row. The thing
//     that does cross the boundary is the agent app's celebration overlay, fired by
//     the same click from a different process.
//
//  THE SHAPE, in milliseconds after the click, at 60 fps:
//
//     0    the last resting open frame.
//    17    COMMIT. One frame. The disc punches in struck, the ring shatters, a
//          shock ring leaves the box, the card blooms, the perimeter lights, AND
//          the counter reads 4 of 4, the ladder merges, the CLEARED pill is there,
//          the closing stamp is there, the text is struck. Nothing on this list
//          arrives later than anything else on it.
//    17-90   the tick stroke draws, with an elbow in it.
//    17-150  the rail's gold head runs the width of the card.
//    17-235  THE AMBER WINDOW. Shards fly and shorten, the disc's rim cools, the
//            shock ring expands out, the band completes its lap of the perimeter.
//    17-300  one monotone fall of `heat` from its maximum to zero.
//   300    REST, brighter than 0 was, and pixel-identical from here on.
//
//  Nothing after the commit frame moves upward. Every curve below either holds or
//  falls, which is what makes the resolve monotone with no direction reversals.
//
//  HOW A WIDGET CAN HAVE A CLOCK. It cannot, directly — there is no display link
//  and no timer. But `.animation(.linear(duration: d), value:)` on an `Animatable`
//  whose `animatableData` runs 0 → 1 gives exactly `progress = elapsed / d`. Time,
//  recovered from a linear animation. That is why every curve below is authored by
//  hand as keyframes in seconds rather than delegated to a spring, and why the
//  offscreen capture can evaluate the identical arithmetic at identical times. The
//  clip is the curve, not a re-creation of it. 300 ms is also comfortably inside
//  WidgetKit's ~2 s transition budget, and it costs no extra reload: the whole
//  thing is optimistic and the reloaded entry, whenever it lands, agrees with what
//  is already drawn.

import SwiftUI

// MARK: - Easing

/// Hand-authored easings. `callAsFunction` so a keyframe table reads as data.
enum Ease {
    case hold, linear, out, outSoft, outHard, inOut, inCubic, outBack

    @inline(__always)
    func callAsFunction(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        switch self {
        case .hold:    return 0
        case .linear:  return t
        case .out:     return 1 - pow(1 - t, 2.6)
        case .outSoft: return 1 - pow(1 - t, 1.7)
        case .outHard: return 1 - pow(1 - t, 4.0)
        case .inOut:   return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .inCubic: return t * t * t
        case .outBack:
            let c1 = 2.0, c3 = 3.0
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        }
    }
}

/// One keyframe: reach `v` at `t` seconds, arriving along `ease`.
typealias Keyframe = (t: Double, v: Double, ease: Ease)

/// Evaluate a keyframe table. Flat before the first key and after the last.
@inline(__always)
func track(_ time: Double, _ keys: [Keyframe]) -> Double {
    guard let first = keys.first else { return 0 }
    if time <= first.t { return first.v }
    var prev = first
    for key in keys.dropFirst() {
        if time < key.t {
            let span = key.t - prev.t
            let x = span > 0 ? (time - prev.t) / span : 1
            return prev.v + (key.v - prev.v) * key.ease(x)
        }
        prev = key
    }
    return prev.v
}

@inline(__always) private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
@inline(__always) private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: - The clock

enum CheckMotion {

    /// Everything is at rest after this, on one frame, and stays there.
    ///
    /// 300 ms, so the amber is a colour the eye actually holds rather than a
    /// flash. The commit itself is still one frame, and 300 ms is well inside a
    /// widget transition's ~2 s budget.
    static let duration: Double = 0.300

    /// The commit is the first animated frame. Nothing waits for anything.
    /// Kept as a named constant because three files assert against it.
    static let commitEpsilon: Double = 0.0005

    /// How long the second hue is on screen.
    static let amberWindow: Double = 0.245

    /// A linear animation is the only one whose animatableData IS elapsed time.
    /// Every curve in this file is authored against that clock.
    static var commitAnimation: Animation { .linear(duration: duration) }

    /// progress (0…1, what SwiftUI animates) -> seconds since the click.
    @inline(__always)
    static func time(fromProgress progress: Double) -> Double {
        clamp01(progress) * duration
    }

    @inline(__always)
    static func progress(fromTime time: Double) -> Double {
        clamp01(time / duration)
    }
}

// MARK: - The commit

/// The whole row plus everything the row tells the rest of the widget, as a pure
/// function of seconds since the click.
struct CommitVisuals {

    /// THE brightness curve. Every lit thing in the widget is a multiple of this
    /// one number. It has one maximum, no reversals and one zero.
    var heat: Double

    /// THE amber curve. Every gold thing in the widget is a multiple of this one
    /// number, and it is deliberately much slower than `heat`: the second hue has
    /// to survive long enough to be a colour the eye keeps.
    var gold: Double

    // Checkbox
    var shardThrow: Double      // 0 = the intact ring, 1 = fully thrown
    var shardSpan: Double       // arc extent of each shard, 1 -> 0
    var shardOpacity: Double
    var shockScale: Double      // the ring's shock, expanding past the box
    var shockWidth: Double
    var discScale: Double
    var discOpacity: Double
    var discHeat: Double        // 1 = struck gold-white, 0 = accent teal
    var tickTrim: Double
    var tickOpacity: Double
    var boxScale: Double

    // Text
    var strikeTrim: Double
    var textLevel: Double
    var textIsLight: Bool

    // Row
    var railExtent: Double
    var railOpacity: Double
    var rowWash: Double
    var rowStroke: Double
    var rowScale: Double
    var badgeOpacity: Double

    // Card — the furthest out a widget is allowed to reach.
    /// 0…1 round the container's perimeter, for the band that runs the edge.
    var sweep: Double
    /// How far the rail's gold head has run along the merged bar.
    var railShoot: Double

    /// True from the commit frame. The counter, the ladder and the chip read this
    /// and nothing else; there is no later landing for them to wait for.
    var committed: Bool

    /// - Parameters:
    ///   - time: seconds since the click. 0 is the resting open row,
    ///     `CheckMotion.duration` and beyond is the resting done row.
    ///   - isLastOpen: the only task left. Its resting row is already lit, so the
    ///     commit lands on a row that was promising something.
    init(time: Double, isLastOpen: Bool) {
        let t = max(0, time)

        // MARK: the one brightness curve
        //
        // Full on the first frame after the click (16.7 ms at 60 Hz, 8.3 at 120),
        // then monotonically down to exactly zero at the resting frame. Five keys,
        // each lower than the last, each eased .out so the fall decelerates. Half
        // the energy is gone inside 60 ms; the last of it slides to zero at 300.
        // Nothing else in this file is allowed to brighten anything.
        heat = track(t, [
            (0.000, 0.00, .linear),
            (0.012, 1.00, .outHard),
            (0.060, 0.52, .out),
            (0.120, 0.24, .out),
            (0.200, 0.08, .out),
            (0.300, 0.00, .outSoft)
        ])

        // MARK: the one amber curve
        //
        // Holds above 0.85 for 110 ms, above 0.5 for 190, and is gone at 235 —
        // a window the eye reads
        // as "it went gold", not as a flicker. Still monotone after the commit
        // frame, so it cannot put a reversal into the brightness.
        gold = track(t, [
            (0.000, 0.00, .hold),
            (0.012, 1.00, .linear),
            (0.130, 0.90, .linear),
            (0.195, 0.62, .outSoft),
            (0.245, 0.00, .out)
        ])

        // MARK: the one scale curve
        //
        // Also monotone after the commit frame. A single overshoot that settles;
        // no elastic undershoot, because an undershoot reads as a dropped frame
        // rather than as give. With 300 ms to settle in, it decelerates over
        // eighteen frames.
        let pop = track(t, [
            (0.000, 0.00, .linear),
            (0.012, 1.00, .outHard),
            (0.090, 0.34, .out),
            (0.180, 0.10, .out),
            (0.300, 0.00, .outSoft)
        ])

        // MARK: state — every bit of it flips on the commit frame
        //
        // Not a crossfade, which would smear the commit across several frames.
        // `committed` is what the header, the pill and the stamp read.
        committed = t >= CheckMotion.commitEpsilon
        let done = committed ? 1.0 : 0.0

        // MARK: shatter — the ring is destroyed, not dissolved
        //
        // Thrown hard and early: a third of the throw is already spent on the
        // commit frame, so the shards are in flight the instant they exist rather
        // than easing away from the rim. They travel for the full amber
        // window, because they are half of what carries the gold.
        shardThrow = track(t, [
            (0.000, 0.00, .linear),
            (0.200, 1.00, .out)
        ])
        // They shorten to nothing. A shard that shrinks to zero length has left;
        // a shard that fades to zero opacity is just another dim.
        shardSpan = track(t, [
            (0.000, 1.00, .linear),
            (0.140, 0.82, .linear),
            (0.235, 0.00, .outSoft)
        ])
        shardOpacity = track(t, [
            (0.000, 1.00, .linear),
            (0.180, 0.92, .linear),
            (0.235, 0.00, .out)
        ])

        // MARK: shock — the one thing that leaves the checkbox
        //
        // A thin gold ring that expands to nearly three times the box and thins to
        // nothing. It crosses out of the box's own slot and over the row, which is
        // as far as anything in a widget is allowed to travel.
        shockScale = track(t, [
            (0.000, 0.55, .linear),
            (0.012, 1.10, .outHard),
            (0.235, 2.20, .out)
        ])
        shockWidth = track(t, [
            (0.000, 0.00, .hold),
            (0.012, 1.00, .linear),
            (0.120, 0.46, .out),
            (0.235, 0.00, .out)
        ])

        // MARK: disc — punches in past its final size and arrives hot
        discScale = track(t, [
            (0.000, 0.30, .linear),
            (0.012, 1.100, .outHard),
            (0.090, 1.020, .out),
            (0.300, 1.000, .outSoft)
        ])
        discOpacity = done
        // Hue, not brightness: struck on the frame of impact, accent teal at the
        // end of the amber window.
        discHeat = track(t, [
            (0.000, 1.00, .hold),
            (0.012, 1.00, .linear),
            (0.120, 0.66, .linear),
            (0.235, 0.00, .out)
        ])

        // MARK: tick — a real 73 ms draw with an elbow in it.
        // Two segments at different speeds: the short leg goes first, then the
        // hand turns the corner and the long leg decelerates into its end. One
        // frame of a broken half-hook reads as a dropped frame; five with a
        // velocity change in the middle reads as a stroke.
        tickTrim = track(t, [
            (0.000, 0.00, .hold),
            (0.008, 0.00, .linear),
            (0.036, 0.42, .out),
            (0.090, 1.00, .outSoft)
        ])
        tickOpacity = done

        // MARK: box
        boxScale = 1 + 0.150 * pop

        // MARK: text — struck on the commit frame, not after it
        //
        // The weight and the level are state, so they flip with the state. The
        // level lands at 0.74: a finished line is quieter than the one you have
        // not done, without most of the card going out. The strikethrough is the
        // one thing allowed to take time, because it DRAWS: it travels left to
        // right in step with the tick, which is a growth, not a dim.
        strikeTrim = track(t, [
            (0.000, 0.00, .hold),
            (0.008, 0.00, .linear),
            (0.110, 1.00, .out)
        ])
        textLevel = committed ? CommitVisuals.doneTextLevel
                              : (isLastOpen ? 0.97 : 0.80)
        textIsLight = committed

        // MARK: rail
        let railRestOpen = isLastOpen ? 0.85 : 0.0
        let railRestDone = isLastOpen ? 0.78 : 0.55
        railOpacity = min(1, lerp(railRestOpen, railRestDone, done) + 0.20 * heat)
        let railBase = isLastOpen ? 1.0 : done
        railExtent = railBase * (1 + 0.150 * pop)

        // MARK: row fill
        let washRestOpen = isLastOpen ? 0.070 : 0.0
        let strokeRestOpen = isLastOpen ? 0.34 : 0.0
        // A finished row keeps a real fill and a real edge, so the card does not
        // go dark, but both stay under the open row's, so "still to do" is still
        // the loudest thing on the card.
        rowWash = lerp(washRestOpen, 0.052, done) + 0.150 * heat
        rowStroke = lerp(strokeRestOpen, 0.12, done) + 0.34 * heat
        rowScale = 1 + 0.024 * pop

        badgeOpacity = 1 - done

        // MARK: card
        //
        // One lap of the container's perimeter inside the amber window. The band's
        // brightness is `gold`, so it dies exactly as it arrives home and leaves
        // the permanent accent edge behind it rather than freezing somewhere.
        sweep = track(t, [
            (0.000, 0.00, .linear),
            (0.012, 0.07, .linear),
            (0.240, 1.00, .out)
        ])
        railShoot = track(t, [
            (0.000, 0.00, .hold),
            (0.012, 0.12, .linear),
            (0.150, 1.00, .out)
        ])
    }

    /// Where a finished line's text sits. Named because three files use it and
    /// because it is the single number that decides whether the card ends brighter
    /// or dimmer than it started.
    static let doneTextLevel: Double = 0.74

    static func resting(done: Bool, isLastOpen: Bool) -> CommitVisuals {
        CommitVisuals(time: done ? CheckMotion.duration : 0, isLastOpen: isLastOpen)
    }
}

// MARK: - Offscreen timeline

/// One complete check-off replayed as a function of time, for the offscreen capture.
///
/// It is trivial, and that is the point: there is nothing in the transition the
/// widget does not control, so there is nothing left for the capture to simulate.
/// There is no reload delay in it, because nothing on screen waits for the reload.
struct CheckTimeline {

    func time(at t: Double) -> Double {
        min(max(t, 0), CheckMotion.duration)
    }

    func phase(at t: Double) -> CheckPhase {
        CheckPhase(time: time(at: t))
    }
}
