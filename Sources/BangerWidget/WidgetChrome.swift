//  WidgetChrome.swift — ink, metrics, the container, and which rows survive.
//
//  Context this is designed for, and it is an unusual one: the widget sits in the
//  top right of a pure black desktop with nothing above or beside it. There is no
//  surrounding UI to borrow structure from, and no competing colour. So:
//
//   - No card. A rounded rectangle with a hairline all the way round is an iOS
//     list cell that has been dropped on a desktop. Instead the container is lit
//     from above: the edge is bright along the top and gone by halfway down, which
//     is how every other object on a Mac is lit.
//   - One accent for what is still open. Progress is the one place allowed a full
//     colour ramp — teal to gold — because it is the payoff, and it should look it.
//     Completed work is deliberately quieter than the thing you have not done yet.
//   - Weight, not colour, carries the hierarchy. macOS desaturates desktop widgets
//     whenever another app has focus, and the user can turn the background off
//     entirely. Both strip the accent, so nothing may depend on it to be readable.

import SwiftUI
import WidgetKit
import BangerKit

// MARK: - Ink

/// Three components, so a colour can be interpolated. `Color` is opaque and will
/// not give its own back on macOS without going through NSColor conversions that
/// are not safe to do inside a widget's render pass.
struct InkRGB {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

struct WidgetInk {
    var accent: Color
    var primary: Color
    var body: Color
    var dim: Color
    var faint: Color
    var hairline: Color
    var ring: Color
    /// What a filled checkbox draws its tick in. Near-black against the accent,
    /// but never pure black, which crushes on an OLED-ish desktop.
    var onAccent: Color
    /// How far every white is lifted when the container background is off.
    var lift: Double

    /// The accent and the strike colour as components, because the commit
    /// interpolates between them in RGB and `Color` will not hand its own back.
    var accentRGB: InkRGB
    /// What a checkbox looks like on the frame it is struck: gold-white, from the
    /// celebration palette's second entry. It exists because a commit that is only
    /// a brightness ramp on one accent hue is one-dimensional, and one dimension
    /// is the first thing that stops registering. See CheckMotion.
    var strikeRGB: InkRGB

    /// The one non-accent colour in the widget: the gold the shattered ring's
    /// hot pieces come off as. It is on screen for about seven frames a day, and
    /// it is there so that the commit is not a single hue getting brighter.
    var spark: Color

    /// The streak flame's heat, beyond teal and gold: ember orange, the progress bar's
    /// hot pink, and the lighter orange the ember tier's number is set in. `cold` is the
    /// icy blue an at-risk flame goes, and `onFire` is the type colour on the legend
    /// tier's solid fire capsule. See StreakFlame.
    var ember: Color
    var hot: Color
    var emberText: Color
    var cold: Color
    var onFire: Color

    /// The progress bar's own ramp, left to right: teal, blue, pink, gold. The day
    /// heats up as it fills, and the last stretch is the celebration's gold. In
    /// vibrant mode it is a white ramp instead, so the shape survives the system
    /// stripping colour.
    var progressRGB: [InkRGB]

    /// The ramp as a gradient, for the bar.
    var progressGradient: Gradient {
        Gradient(colors: progressRGB.map { Color(red: $0.r, green: $0.g, blue: $0.b) })
    }

    /// The ramp's colour `t` of the way along, for the glow at the fill's tip.
    func progressColor(at t: Double) -> Color {
        let stops = progressRGB
        guard stops.count > 1 else { return accent }
        let x = min(1, max(0, t)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x))
        let f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.r + (b.r - a.r) * f,
                     green: a.g + (b.g - a.g) * f,
                     blue: a.b + (b.b - a.b) * f)
    }

    /// A white at a given opacity, on the same ladder as the named inks above.
    func white(_ value: Double) -> Color { .white.opacity(min(1, value + lift)) }

    /// The accent, `h` of the way toward the strike colour. h = 0 is the resting
    /// teal a finished checkbox keeps; h = 1 is the frame of impact.
    func struck(_ h: Double) -> Color {
        let t = min(1, max(0, h))
        return Color(red: accentRGB.r + (strikeRGB.r - accentRGB.r) * t,
                     green: accentRGB.g + (strikeRGB.g - accentRGB.g) * t,
                     blue: accentRGB.b + (strikeRGB.b - accentRGB.b) * t)
    }

    static func make(mode: WidgetRenderingMode, hasBackground: Bool) -> WidgetInk {
        let fullColor = (mode == .fullColor)
        let lift: Double = hasBackground ? 0 : 0.06
        func white(_ value: Double) -> Color { .white.opacity(min(1, value + lift)) }
        return WidgetInk(
            accent: fullColor ? BangerPalette.accent : white(0.94),
            primary: white(0.97),
            body: white(0.80),
            dim: white(0.44),
            faint: white(0.26),
            hairline: white(0.11),
            ring: white(0.33),
            onAccent: fullColor ? Color(red: 0.02, green: 0.07, blue: 0.07) : .black,
            lift: lift,
            // In vibrant / accented rendering modes the system strips colour, so
            // the strike has to be a value difference instead of a hue one.
            accentRGB: fullColor ? InkRGB(0.05, 0.85, 0.75) : InkRGB(0.94, 0.94, 0.94),
            // Warm, near-white: a struck disc has to read as hot metal, not as a
            // highlighter, and the path from teal to a saturated gold goes through
            // lime — which looks like a bug. The GOLD lives in the shards instead,
            // where it is small, fast and unmistakably a different material.
            strikeRGB: fullColor ? InkRGB(1.00, 0.96, 0.84) : InkRGB(1.00, 1.00, 1.00),
            spark: fullColor ? Color(red: 1.00, green: 0.78, blue: 0.12) : white(0.92),
            // In vibrant mode these fall back to whites on the same ladder, so the tiers
            // still step up in size, fill and glow when the system strips the colour.
            ember: fullColor ? Color(red: 1.00, green: 0.50, blue: 0.16) : white(0.80),
            hot: fullColor ? Color(red: 1.00, green: 0.30, blue: 0.55) : white(0.62),
            emberText: fullColor ? Color(red: 1.00, green: 0.74, blue: 0.48) : white(0.90),
            cold: fullColor ? Color(red: 0.55, green: 0.82, blue: 1.00) : white(0.85),
            onFire: fullColor ? Color(red: 0.24, green: 0.03, blue: 0.08) : .black,
            progressRGB: fullColor
                ? [InkRGB(0.05, 0.85, 0.75),   // accent teal
                   InkRGB(0.30, 0.62, 1.00),   // electric blue
                   InkRGB(1.00, 0.30, 0.55),   // hot pink
                   InkRGB(1.00, 0.78, 0.12)]   // celebration gold
                : [InkRGB(0.70, 0.70, 0.70), InkRGB(1.00, 1.00, 1.00)]
        )
    }
}

// MARK: - Metrics

struct WidgetMetrics {
    var padding: CGFloat
    var maxRows: Int
    var countSize: CGFloat
    var rowTextSize: CGFloat
    var rowSpacing: CGFloat
    var boxDiameter: CGFloat
    /// The large family gets a little more air under the header.
    var roomyHeader: Bool
    var showsHint: Bool
    var showsLastOneLabel: Bool
    var showsBothPills: Bool

    /// One row, in every state: open, mid-commit and done are all this tall, which is
    /// what lets the list scroll by whole rows.
    var rowHeight: CGFloat { boxDiameter + 7 }
    /// From one row's top to the next one's.
    var rowPitch: CGFloat { rowHeight + rowSpacing }

    static func forFamily(_ family: WidgetFamily) -> WidgetMetrics {
        switch family {
        case .systemSmall:
            return .init(padding: 12, maxRows: 4, countSize: 21, rowTextSize: 11.5,
                         rowSpacing: 1.5, boxDiameter: 15, roomyHeader: false,
                         showsHint: false, showsLastOneLabel: false, showsBothPills: false)
        case .systemLarge:
            return .init(padding: 17, maxRows: 9, countSize: 24, rowTextSize: 13,
                         rowSpacing: 2.5, boxDiameter: 18, roomyHeader: true,
                         showsHint: true, showsLastOneLabel: true, showsBothPills: true)
        default:
            return .init(padding: 14, maxRows: 4, countSize: 20, rowTextSize: 12.5,
                         rowSpacing: 1.5, boxDiameter: 16, roomyHeader: false,
                         showsHint: false, showsLastOneLabel: true, showsBothPills: true)
        }
    }

    /// The real point size the widget host gives each family on macOS. Used only by
    /// the offscreen capture, so a rendered frame is the widget at its true size
    /// rather than a blown-up mock-up.
    static func pointSize(for family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: return CGSize(width: 170, height: 170)
        case .systemLarge: return CGSize(width: 364, height: 364)
        default:           return CGSize(width: 364, height: 170)
        }
    }
}

// MARK: - Container

/// Near-black, with one cold glow off the top right — the corner it lives in.
/// Only drawn in full colour: the system strips this in vibrant mode and when the
/// user turns the background off, which is why nothing in front depends on it.
struct BangerContainerBackground: View {

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            Color.black
            if renderingMode == .fullColor {
                LinearGradient(colors: [Color.white.opacity(0.055),
                                        Color.white.opacity(0.010),
                                        .clear],
                               startPoint: .top, endPoint: .bottom)
                // One cold glow off the corner it lives in. Small on purpose: a
                // wash big enough to tint the whole card turns the widget green
                // and steals the accent from the two places that have earned it.
                RadialGradient(colors: [BangerPalette.accent.opacity(0.11), .clear],
                               center: UnitPoint(x: 1.0, y: -0.06),
                               startRadius: 0, endRadius: 130)
            }
        }
    }
}

// MARK: - What the card as a whole is doing

/// The commit, as the card sees it. One value, built once in BangerWidgetView from
/// the entry and the row's optimistic signal together, so the wash, the edge and
/// the header can never disagree about which frame they are on.
struct CardCommitState: Equatable {
    /// Every task is done — optimistically on the commit frame, and still true
    /// after the reload lands.
    var cleared: Bool = false
    /// The one brightness curve. 0 at rest.
    var heat: Double = 0
    /// The one amber curve. 0 at rest.
    var gold: Double = 0
    /// 0…1 round the perimeter.
    var sweep: Double = 0
    /// Where the commit came from, in the card's unit space.
    var impact: UnitPoint = UnitPoint(x: 0.10, y: 0.85)
    /// How big an event this is. An ordinary task is a third of the day closing:
    /// the escalation is in the reach of the bloom and in whether the perimeter
    /// lights at all, not in a different effect.
    var reach: Double = 1.0
}

/// The card getting hit.
///
/// THE LIMIT THIS IS DESIGNED AGAINST, stated plainly because it shapes every
/// number in it: a widget's drawing is clipped to its container shape. There is no
/// overlay window, no negative padding, no shadow it controls and no way to put a
/// single pixel outside the card. So the commit is not a thing that happens to one
/// row but a thing that happens to the whole card, blooming from the checkbox that
/// was clicked and reaching every edge. The thing that does cross the boundary is
/// the agent app's celebration overlay, fired by the same click, in another process.
///
/// It is also the reason the card ends BRIGHTER: a cleared day keeps a low
/// permanent wash, which nothing in the open state has.
struct CommitBloom: View {

    var state: CardCommitState
    var ink: WidgetInk

    var body: some View {
        let impact = state.impact
        let rest = state.cleared ? 0.055 : 0.0
        let level = (rest + 0.30 * state.heat) * state.reach
        // The bloom does not arrive the accent colour. It arrives STRUCK and cools
        // to the accent across the amber window, the same way the disc does, which
        // is why the second hue is a real share of the card's colour for 200 ms
        // rather than a brief garnish on a teal flash. The accent is held back
        // while the gold is up, so the two are a sequence and not a muddle.
        let cool = 1 - 0.58 * state.gold

        return ZStack {
            RadialGradient(colors: [ink.accent.opacity(level * cool),
                                    ink.accent.opacity(level * cool * 0.42),
                                    .clear],
                           center: impact, startRadius: 0, endRadius: 430 * state.reach)
            RadialGradient(colors: [ink.spark.opacity(0.36 * state.gold * state.reach),
                                    ink.spark.opacity(0.13 * state.gold * state.reach),
                                    .clear],
                           center: impact, startRadius: 0, endRadius: 400 * state.reach)
        }
        .allowsHitTesting(false)
    }
}

/// Lit from above rather than outlined, and — on a cleared day — lit all the way
/// round.
///
/// A full-strength hairline all the way round is the single thing that makes a
/// desktop widget read as a transplanted phone card, so the resting open state is
/// a top edge that fades out by halfway. A FINISHED day is a different object and
/// is allowed a different outline: the whole perimeter lights, permanently, and it
/// is the brightest continuous line in the widget.
///
/// On the commit frame a band of gold sets off round that perimeter and completes
/// one lap in 240 ms. It is the largest single thing the commit moves — the edge is
/// the outermost pixel a widget owns — and it dies exactly as it arrives home, so
/// it leaves the permanent accent edge behind rather than freezing somewhere.
struct ContainerEdgeLight: View {
    var ink: WidgetInk
    var state: CardCommitState = CardCommitState()

    var body: some View {
        ZStack {
            ContainerRelativeShape()
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.155), location: 0.0),
                            .init(color: .white.opacity(0.055), location: 0.22),
                            .init(color: .white.opacity(0.012), location: 0.55),
                            .init(color: .white.opacity(0.022), location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)

            if state.cleared {
                ContainerRelativeShape()
                    .strokeBorder(ink.accent.opacity(0.46 + 0.34 * state.heat),
                                  lineWidth: 1.7 + 2.0 * state.heat)
                    .shadow(color: ink.accent.opacity(0.30 * state.heat), radius: 8 * state.heat)

                ContainerRelativeShape()
                    .strokeBorder(
                        AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: .clear, location: 0.74),
                                .init(color: ink.spark.opacity(0.30), location: 0.88),
                                .init(color: ink.spark.opacity(0.95), location: 0.975),
                                .init(color: .white.opacity(0.95), location: 1.00)
                            ],
                            center: .center,
                            angle: .degrees(-90 + 360 * state.sweep)),
                        lineWidth: 2.2 + 2.8 * state.heat)
                    .opacity(state.gold)
            }
        }
    }
}

// MARK: - Which rows are in view

/// The list as the widget draws it: every task in display order, and the stretch of
/// it that is in view.
///
/// When the list fits, all of it is in view and nothing else here applies. When it
/// does not, the list scrolls (ListScroll.swift says how, since a widget has no scroll
/// view): the last line goes to the arrows and the rest is a window onto the list.
///
/// Where the window RESTS: every open task earns
/// its slot first — an unreachable checkbox is a dead widget — and completed tasks
/// fill what is left, most recent first. Done tasks sit at the top of the display
/// order, so that is simply: scrolled past the done tasks, but never past the end.
struct RowPlan {
    /// The rows to draw. Each carries the identity it is drawn with; see
    /// ReorderMotion.key. When the list scrolls this reaches past the window on
    /// both sides, drawn but invisible, so a row has somewhere to slide in from.
    var rows: [WidgetTask]
    /// Every row's identity, in display order, including rows too far from the
    /// window to draw. It changes when the order does and not when the window
    /// moves, so it is what tells a reorder from a scroll.
    var orderKeys: [String]
    /// Where `rows` starts in the whole display order.
    var firstIndex = 0
    /// The first row in view, as an index into the whole display order.
    var offset = 0
    /// How many rows are in view at once.
    var visibleCount: Int
    var total: Int
    var doneCount = 0
    /// Where the window sits when nobody has scrolled it.
    var restingOffset = 0

    /// The list is longer than the widget, so it scrolls and has arrows.
    var scrolls: Bool { total > visibleCount }
    var maxOffset: Int { max(0, total - visibleCount) }
    var aboveCount: Int { offset }
    var belowCount: Int { max(0, total - offset - visibleCount) }
    /// Everything above the window is finished work. True at rest, which is why the
    /// up arrow can say "done": at rest it is the way back to what got done today.
    var aboveIsAllDone: Bool { offset <= doneCount }

    /// Whether the row at `index` in `rows` is in view, with the window at `start`
    /// (by default, where it is).
    func isInView(_ index: Int, windowAt start: Int? = nil) -> Bool {
        let position = firstIndex + index
        let top = start ?? offset
        return position >= top && position < top + visibleCount
    }

    /// Where the arrows go: nearly a page, so the row that was at the bottom ends up
    /// at the top and the eye keeps its place. Nil when there is nowhere to go.
    var upTarget: Int? {
        offset > 0 ? detent(max(0, offset - step)) : nil
    }

    var downTarget: Int? {
        offset < maxOffset ? detent(min(maxOffset, offset + step)) : nil
    }

    private var step: Int { max(1, visibleCount - 1) }

    /// The resting place is a detent: a scroll that would cross it stops on it, so
    /// the view the widget rests in is always one tap away, from either side.
    private func detent(_ target: Int) -> Int {
        let crosses = (offset < restingOffset && target > restingOffset)
            || (offset > restingOffset && target < restingOffset)
        return crosses ? restingOffset : target
    }

    /// Display order: done tasks rise to the top in the order they were checked
    /// off, and open tasks follow in the file's order. So checking 1 then 3 of
    /// 1-2-3 reads 1-3-2. Only the picture moves; the file keeps its order.
    ///
    /// `scrolledTo` is where the user last put the window (ListScroll); nil means
    /// the resting place. It is clamped, so a list that got shorter since the tap
    /// cannot scroll past its own end.
    static func make(_ tasks: [WidgetTask], maxRows: Int, scrolledTo requested: Int? = nil) -> RowPlan {
        let ordered = displayOrder(tasks)
        let keys = ordered.map(\.reorderKey)
        guard tasks.count > maxRows, maxRows > 1 else {
            return RowPlan(rows: ordered, orderKeys: keys,
                           visibleCount: ordered.count, total: ordered.count)
        }
        let visible = maxRows - 1  // the last line goes to the arrows
        let done = tasks.reduce(0) { $0 + ($1.done ? 1 : 0) }
        let maxOffset = tasks.count - visible
        let resting = min(done, maxOffset)
        let offset = min(max(0, requested ?? resting), maxOffset)
        // Draw only what the next picture can slide in: one arrow's reach either side
        // of the window, and the resting window too, which is where the five-minute
        // release goes. Every invisible row is a whole toggle drawn in both states, so
        // when the way back to rest is longer than a few pages it is not drawn, and
        // that one release pops instead of sliding.
        let reach = visible - 1
        var first = max(0, offset - reach)
        var end = min(ordered.count, offset + visible + reach)
        let withRest = (min(first, resting), max(end, resting + visible))
        if withRest.1 - withRest.0 <= 5 * visible {
            (first, end) = withRest
        }
        return RowPlan(rows: Array(ordered[first..<end]), orderKeys: keys,
                       firstIndex: first, offset: offset,
                       visibleCount: visible, total: ordered.count, doneCount: done,
                       restingOffset: resting)
    }

    /// Done first, oldest completion on top; open after, in file order. The sort is
    /// stable, so ties (or a done task with no timestamp) keep the file's order.
    static func displayOrder(_ tasks: [WidgetTask]) -> [WidgetTask] {
        let done = tasks.enumerated()
            .filter { $0.element.done }
            .sorted {
                let a = $0.element.completedAt ?? .distantPast
                let b = $1.element.completedAt ?? .distantPast
                return a != b ? a < b : $0.offset < $1.offset
            }
            .map(\.element)
        return (done + tasks.filter { !$0.done }).map { task in
            var keyed = task
            keyed.rowKey = ReorderMotion.key(for: task, in: tasks)
            return keyed
        }
    }
}
