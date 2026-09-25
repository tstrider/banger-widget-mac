//  BangerWidgetView.swift — the checklist as it sits in the top right of a black desktop.
//
//  Resting design, which matters as much as the transition: it is alone against
//  pure black with nothing above or beside it, so it has to supply its own
//  structure. It does that with light rather than with an outline (see
//  ContainerEdgeLight), with one heavy number and everything else quiet, and with
//  the accent spent on exactly two things — how far today has got, and what is
//  still open. Finished work is deliberately dimmer than unfinished work.
//
//  THE LEDGER LANDS ON THE COMMIT, NOT AFTER IT.
//
//  A widget's counter normally cannot move until a reloaded timeline entry arrives,
//  because the entry is the only thing that knows the new count. That is one round
//  trip — a file write, a notification, a reload, a re-render — behind the check
//  stroke. The number is the payload, so it must not trail the animation.
//
//  So the count does not come from the entry while a row is mid-commit. The row
//  publishes its own optimistic commit upward as a SwiftUI preference
//  (RowCommitKey), and the header is drawn in an `overlayPreferenceValue` that
//  reads it — which resolves inside the same render pass, so the counter flips, the
//  fourth segment fills and the CLEARED chip arrives on the SAME FRAME the stroke
//  completes. A hidden copy of the header stays in the layout flow to reserve the
//  space, and the + button stays in the flow copy so it is still clickable; the
//  overlay ignores hit testing entirely.
//
//  When the reload does land, the entry agrees with what is already drawn, the row
//  stops publishing, and nothing moves. The reload is invisible, which is the point.
//
//  The progress bar is segmented, one segment per task. On a list of four that is
//  legible at a glance from across a room, and it makes "one left" a shape rather
//  than a sentence.

import AppIntents
import SwiftUI
import WidgetKit
import BangerKit

struct BangerWidgetView: View {

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsContainerBackground

    let entry: BangerEntry

    /// Everything below is set only by the offscreen capture, which has no widget
    /// host to read the environment from and drives the clock itself. Live, both of
    /// these are nil and SwiftUI is in charge.
    var familyOverride: WidgetFamily? = nil
    var captureTaskID: String? = nil
    var capturePhase: CheckPhase? = nil
    var captureScroll: CaptureScroll? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ink: WidgetInk { .make(mode: renderingMode, hasBackground: showsContainerBackground) }
    private var metrics: WidgetMetrics { .forFamily(familyOverride ?? family) }
    /// The small family's header has 146 points for the count, a pill and the + button,
    /// so everything in that one row gives up a little there.
    private var isSmall: Bool { (familyOverride ?? family) == .systemSmall }

    var body: some View {
        // Both of these sit OUTSIDE the padding, so they own the whole card rather
        // than the text block — which is the point. The commit reaches the card's
        // own boundary, which is as far out as a widget is physically allowed to draw.
        content
            .padding(metrics.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: Self.cardSpace)
            .backgroundPreferenceValue(RowCommitKey.self) { signal in
                GeometryReader { proxy in
                    CommitBloom(state: cardState(signal, size: proxy.size), ink: ink)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .overlayPreferenceValue(RowCommitKey.self) { signal in
                if showsContainerBackground {
                    ContainerEdgeLight(ink: ink, state: cardState(signal))
                        .allowsHitTesting(false)
                }
            }
    }

    /// What the card as a whole is doing: cleared or not, and where the three
    /// curves are. Built from the entry and the row's optimistic commit together,
    /// so it is correct before the reload and identical after it.
    /// The card's own coordinate space, so a row can say where it is without
    /// knowing anything about the card.
    static let cardSpace = "banger.card"

    private func cardState(_ signal: RowCommitSignal?, size: CGSize? = nil) -> CardCommitState {
        guard case .list(let day) = entry.state, !day.tasks.isEmpty else {
            return CardCommitState()
        }
        let extra = (signal?.committed == true) ? 1 : 0
        let doneCount = min(day.tasks.count, day.doneCount + extra)
        let cleared = doneCount == day.tasks.count

        // Where the click landed, resolved from the row's own bounds rather than
        // guessed, so an ordinary task in the middle of the list blooms from the
        // middle of the list.
        var impact = UnitPoint(x: 0.10, y: 0.85)
        if let size, size.width > 0, size.height > 0, let point = signal?.impact {
            impact = UnitPoint(x: point.x / size.width, y: point.y / size.height)
        }

        return CardCommitState(cleared: cleared,
                               heat: signal?.heat ?? 0,
                               gold: signal?.gold ?? 0,
                               sweep: signal?.sweep ?? 0,
                               impact: impact,
                               // Closing the day is the big one. An ordinary task
                               // gets the same shape at a third of the reach —
                               // escalation, not a different effect.
                               reach: cleared ? 1.0 : 0.34)
    }

    @ViewBuilder private var content: some View {
        switch entry.state {
        case .list(let day): list(day)
        case .empty: emptyState
        case .unavailable(let detail): unavailableState(detail)
        }
    }

    // MARK: List

    private func list(_ day: WidgetDay) -> some View {
        let plan = RowPlan.make(day.tasks, maxRows: metrics.maxRows, scrolledTo: entry.scrollOffset)
        let highlightID = day.lastOpenID
        // The row that closes the day. Before the click it is the only one left;
        // after the reload `lastOpenID` is nil, so it becomes the most recently
        // completed row of a cleared day — the same row, still stamped. Keying the
        // stamp on `isLastOpen` would have deleted it the moment the entry landed.
        let closingID: String? = day.lastOpenID
            ?? (day.isCleared && day.tasks.count > 1 ? day.mostRecentlyCompleted?.id : nil)

        return VStack(alignment: .leading, spacing: 0) {
            // Layout only. The live one is in the overlay below, where it can read
            // the row's optimistic commit and land on the same frame as the stroke.
            ledger(day, signal: nil, layer: .flow)

            Spacer().frame(height: metrics.roomyHeader ? 13 : 9)

            rows(plan, highlightID: highlightID, closingID: closingID)

            if plan.scrolls {
                Spacer().frame(height: 8)
                scrollArrows(plan, dayKey: day.dayKey)
            }

            Spacer(minLength: 0)
        }
        .overlayPreferenceValue(RowCommitKey.self) { signal in
            VStack(alignment: .leading, spacing: 0) {
                ledger(day, signal: signal, layer: .live)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    /// The rows: one stack behind a window (see ListScroll.swift). When the list fits,
    /// the window is the whole stack and every modifier below is a no-op — one view
    /// either way, so a list that grows past the widget keeps its rows' identity
    /// instead of being swapped out wholesale.
    private func rows(_ plan: RowPlan, highlightID: String?, closingID: String?) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            ForEach(Array(plan.rows.enumerated()), id: \.element.reorderKey) { index, task in
                let inView = plan.isInView(index)
                TaskRowView(task: task,
                            isLastOpen: task.id == highlightID,
                            closesDay: task.id == closingID,
                            metrics: metrics,
                            ink: ink,
                            phase: task.id == captureTaskID ? capturePhase : nil)
                    // Either side of the window: drawn, so it has somewhere to slide
                    // in from, but not seen, not clickable and not read out.
                    .opacity(rowVisibility(plan, index, inView: inView))
                    .allowsHitTesting(inView)
                    .accessibilityHidden(!inView)
                    .transition(ReorderMotion.transition(reduceMotion: reduceMotion))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .offset(y: -CGFloat(windowTop(plan) - Double(plan.firstIndex)) * metrics.rowPitch)
        // Checked rows rise to the top on the reload; this is how they travel. It sits
        // INSIDE the scroll's own animation on purpose: a check-off can move the rows
        // and the window at once, and then the pop's spring has to drive both, or the
        // rows wobble between two curves.
        .animation(ReorderMotion.animation(reduceMotion: reduceMotion), value: plan.orderKeys)
        .animation(ScrollMotion.animation(reduceMotion: reduceMotion), value: plan.offset)
        .frame(height: plan.scrolls
                   ? CGFloat(plan.visibleCount) * metrics.rowPitch - metrics.rowSpacing
                   : nil,
               alignment: .top)
        .mask {
            // Wide open sideways, where the pop slides in from and the shock ring
            // reaches; only a few points past the window's top and bottom. A list that
            // fits is not cut at all.
            let bleed = plan.scrolls ? ScrollMotion.bleed(metrics) : (above: 400, below: 400)
            Rectangle()
                .padding(.top, -bleed.above)
                .padding(.bottom, -bleed.below)
                .padding(.horizontal, -metrics.padding)
        }
    }

    /// Where the window's top edge is, in rows. Whole, except part of the way through
    /// a scroll the capture tool is replaying.
    private func windowTop(_ plan: RowPlan) -> Double {
        guard let captureScroll else { return Double(plan.offset) }
        return Double(captureScroll.from)
            + Double(plan.offset - captureScroll.from) * captureScroll.progress
    }

    private func rowVisibility(_ plan: RowPlan, _ index: Int, inView: Bool) -> Double {
        let now: Double = inView ? 1 : 0
        guard let captureScroll else { return now }
        let before: Double = plan.isInView(index, windowAt: captureScroll.from) ? 1 : 0
        return before + (now - before) * captureScroll.progress
    }

    /// The way to the rest of a list that is longer than the widget: up on the left,
    /// down on the right, each only while there is somewhere to go.
    private func scrollArrows(_ plan: RowPlan, dayKey: String) -> some View {
        let up = plan.aboveIsAllDone ? "\(plan.aboveCount) done" : "\(plan.aboveCount) above"
        let down = "\(plan.belowCount) more"
        // The small family has 146 points for both. If the words do not fit beside
        // each other, the numbers and the arrows still do.
        return ViewThatFits(in: .horizontal) {
            scrollArrowRow(plan, dayKey: dayKey, up: up, down: down)
            scrollArrowRow(plan, dayKey: dayKey, up: "\(plan.aboveCount)", down: "\(plan.belowCount)")
        }
    }

    private func scrollArrowRow(_ plan: RowPlan, dayKey: String, up: String, down: String) -> some View {
        HStack(spacing: 0) {
            if let target = plan.upTarget {
                scrollArrow(plan, dayKey: dayKey, to: target, title: up, pointsUp: true)
                    .accessibilityLabel(Text(plan.aboveIsAllDone ? "Show \(plan.aboveCount) done"
                                                                 : "Show \(plan.aboveCount) above"))
            }
            Spacer(minLength: 8)
            if let target = plan.downTarget {
                scrollArrow(plan, dayKey: dayKey, to: target, title: down, pointsUp: false)
                    .accessibilityLabel(Text("Show \(plan.belowCount) more"))
            }
        }
        // Flush with the checkboxes on the left and the rows' own end on the right.
        .padding(.leading, 14.5)
        .padding(.trailing, 6)
    }

    /// Dressed like the + button, because it is the same kind of thing: a door, not
    /// a task. The chevron leads on the way up and trails on the way down.
    private func scrollArrow(_ plan: RowPlan, dayKey: String, to target: Int,
                             title: String, pointsUp isUp: Bool) -> some View {
        let chevron = Image(systemName: isUp ? "chevron.up" : "chevron.down")
            .font(.system(size: 7.5, weight: .heavy))
        return Button(intent: ScrollListIntent(offset: target == plan.restingOffset ? nil : target,
                                               dayKey: dayKey)) {
            HStack(spacing: 3.5) {
                if isUp { chevron }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                if !isUp { chevron }
            }
            .foregroundStyle(ink.dim)
            // A little tighter on the small family, so "1 done" and "6 more" still fit
            // side by side in its 146 points.
            .padding(.horizontal, isSmall ? 5.5 : 7)
            // The large family has room to spare under the list; the other two have
            // exactly one line for it.
            .padding(.vertical, metrics.roomyHeader ? 3 : 1)
            .background(Capsule().fill(ink.white(0.07)))
            .overlay(Capsule().strokeBorder(ink.hairline, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Which half of the header a copy is responsible for drawing.
    private enum LedgerLayer {
        /// In the layout flow: reserves the space, and owns the + button so it stays
        /// clickable. Everything that carries the count is hidden.
        case flow
        /// Drawn in the preference overlay: owns everything that carries the count.
        case live
    }

    private func ledger(_ day: WidgetDay, signal: RowCommitSignal?, layer: LedgerLayer) -> some View {
        let extra = (signal?.committed == true) ? 1 : 0
        let doneCount = min(day.tasks.count, day.doneCount + extra)
        let cleared = !day.tasks.isEmpty && doneCount == day.tasks.count
        // The ONE brightness curve, straight off the row. Nothing in the header has
        // a decay of its own to resolve on a different frame.
        let heat = signal?.heat ?? 0
        let gold = signal?.gold ?? 0
        let railShoot = signal?.railShoot ?? 0
        let fraction = day.tasks.isEmpty ? 0 : Double(doneCount) / Double(day.tasks.count)

        return VStack(alignment: .leading, spacing: 0) {
            headline(day, doneCount: doneCount, cleared: cleared,
                     heat: heat, gold: gold, layer: layer)
            Spacer().frame(height: 7)
            ProgressLadder(fraction: fraction,
                           segments: day.tasks.count,
                           landingIndex: extra == 1 ? day.doneCount : nil,
                           heat: heat,
                           gold: gold,
                           shoot: railShoot,
                           merged: cleared,
                           ink: ink)
                .shadow(color: ink.accent.opacity(cleared ? 0.40 + 0.38 * heat : 0.14 * heat),
                        radius: 5 + 6 * heat)
                .shadow(color: ink.spark.opacity(0.55 * gold), radius: 9 * gold)
                .hidden(layer == .flow)
        }
    }

    private func headline(_ day: WidgetDay,
                          doneCount: Int,
                          cleared: Bool,
                          heat: Double,
                          gold: Double,
                          layer: LedgerLayer) -> some View {
        // Nothing in the row can shrink, so on the small family a big streak pill (its
        // flame grows with the tier) or CLEARED beside "147 of 148" is wider than the
        // card. Then "of N" gives way: the progress rail below still shows the total.
        ViewThatFits(in: .horizontal) {
            headlineRow(day, doneCount: doneCount, cleared: cleared,
                        heat: heat, gold: gold, layer: layer, showsTotal: true)
            headlineRow(day, doneCount: doneCount, cleared: cleared,
                        heat: heat, gold: gold, layer: layer, showsTotal: false)
        }
    }

    private func headlineRow(_ day: WidgetDay,
                             doneCount: Int,
                             cleared: Bool,
                             heat: Double,
                             gold: Double,
                             layer: LedgerLayer,
                             showsTotal: Bool) -> some View {
        let countsAreLive = (layer == .live)

        return HStack(alignment: .firstTextBaseline, spacing: isSmall ? 3.5 : 5) {
            Text("\(doneCount)")
                .font(.system(size: metrics.countSize, weight: .heavy, design: .rounded))
                // White, not `ink.struck(heat)`: that is the accent teal once the
                // heat is gone, a colour with two thirds of white's luma, so
                // incrementing the number would make it darker. On a cleared day
                // it is pure white, one step LARGER, and carries a glow. The number
                // is the payload; the payload ends brighter.
                .foregroundStyle(cleared ? ink.white(1.0) : ink.primary)
                .contentTransition(.numericText(value: Double(doneCount)))
                // Never wrap or squeeze the count: the pills beside it are sized so
                // the row fits, and a "1" over a "2" is worse than anything they show.
                .lineLimit(1)
                .fixedSize()
                .scaleEffect((cleared ? 1.06 : 1.0) + 0.13 * heat, anchor: .bottomLeading)
                .shadow(color: ink.accent.opacity(cleared ? 0.38 + 0.34 * heat : 0.50 * heat),
                        radius: cleared ? 7 + 9 * heat : 7 * heat)
                .shadow(color: ink.spark.opacity(0.70 * gold), radius: 13 * gold)
                .hidden(!countsAreLive)

            if showsTotal {
                Text("of \(day.tasks.count)")
                    .font(.system(size: metrics.countSize * 0.60, weight: .semibold, design: .rounded))
                    .foregroundStyle(cleared ? ink.white(0.62) : ink.dim)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden(!countsAreLive)
            }

            Spacer(minLength: 4)

            if cleared { clearedPill(heat: heat, gold: gold).hidden(!countsAreLive) }
            if day.streak > 0, !cleared || metrics.showsBothPills {
                StreakPill(streak: day.streak,
                           atRisk: StreakFlame.isAtRisk(
                               streak: day.streak,
                               taskCount: day.tasks.count,
                               cleared: cleared,
                               now: entry.date,
                               nextBoundary: BangerDate.Rollover.nextBoundary(after: entry.date)),
                           ink: ink,
                           compact: isSmall)
                    .hidden(!countsAreLive)
            }
            quickAddButton.hidden(countsAreLive)
        }
    }

    private func clearedPill(heat: Double, gold: Double) -> some View {
        // Arrives whole, on one frame, at full size, and settles DOWN out of an
        // overshoot. A chip that scales up from nothing is a fade with a shape.
        // White type on a filled capsule, not teal type on a tint: this pill is one
        // of the reasons the header ends up with more light in it than it started.
        Text("CLEARED")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(isSmall ? 0.8 : 1.6)
            .foregroundStyle(ink.white(0.98))
            .padding(.horizontal, isSmall ? 5 : 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(ink.accent.opacity(0.34 + 0.30 * heat)))
            .overlay(Capsule().strokeBorder(ink.accent.opacity(0.66 + 0.30 * heat), lineWidth: 0.9))
            .overlay(Capsule().strokeBorder(ink.spark.opacity(0.80 * gold), lineWidth: 1.2))
            .fixedSize()
            .scaleEffect(1 + 0.13 * heat, anchor: .trailing)
            .shadow(color: ink.accent.opacity(0.24 + 0.36 * heat), radius: 4 + 7 * heat)
    }

    /// A widget cannot take text input — macOS gives it none. This is the door to
    /// the one thing that can: QuickAdd's borderless panel, opened by notification
    /// so that nothing has to be brought to the front to get a text field.
    private var quickAddButton: some View {
        Button(intent: QuickAddIntent()) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(ink.dim)
                .frame(width: 18, height: 18)
                .background(Circle().fill(ink.white(0.07)))
                .overlay(Circle().strokeBorder(ink.hairline, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add a task"))
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                quickAddButton
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing on today's list")
                        .font(.system(size: metrics.rowTextSize + 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.body)
                    Text("Hit + , or ⌃⌥⌘N from anywhere.")
                        .font(.system(size: metrics.rowTextSize - 1.5, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.faint)
                        .lineLimit(2)
                }
            }
            if metrics.showsHint {
                Spacer().frame(height: 12)
                Text("bangerctl add \"…\"")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.faint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink.hairline.opacity(0.7)))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Unavailable

    private func unavailableState(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink.dim)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Can't reach the list")
                        .font(.system(size: metrics.rowTextSize + 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.body)
                    Text(detail)
                        .font(.system(size: metrics.rowTextSize - 1.5, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.faint)
                        .lineLimit(2)
                    Text(TaskBridge.containerPath)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(ink.faint)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Conditional hiding

private extension View {
    /// `.hidden()` keeps the space and drops the drawing AND the hit testing, which
    /// is exactly what the two header copies need from each other.
    @ViewBuilder func hidden(_ shouldHide: Bool) -> some View {
        if shouldHide { self.hidden() } else { self }
    }
}

// MARK: - Progress

/// One segment per task, so the day has a shape rather than a percentage.
///
/// AND — the part that is not an animation — when the last one is checked the
/// ladder stops being segments. The gaps shut and the bar thickens into a single
/// continuous capsule, on the commit frame, permanently. A cleared day does not
/// look like a full progress bar; it looks like a different object.
///
/// That is here because a commit whose only mechanism is a glow fading out is
/// one-dimensional, and a glow is the first thing a person stops seeing. This one
/// is structural: it is still visibly different on the fifteenth firing and on the
/// five-hundredth, because it is not an effect, it is the shape of a finished day.
struct ProgressLadder: View {

    var fraction: Double
    var segments: Int
    /// The segment that has just been completed, if the commit is live.
    var landingIndex: Int?
    /// The one brightness curve, shared with the row and the counter.
    var heat: Double
    /// The one amber curve.
    var gold: Double
    /// How far the gold head has run along the merged rail, 0…1.
    var shoot: Double
    /// True once every task is done: draw one bar, not a row of parts.
    var merged: Bool
    var ink: WidgetInk

    /// Fixed, so the merge changes the bar without moving a single row.
    private let slotHeight: CGFloat = 5.2

    var body: some View {
        Group {
            if merged { mergedBar } else { ladder }
        }
        .frame(height: slotHeight)
    }

    /// It OVERSHOOTS: the rail punches to 1.6x its resting
    /// thickness on the commit frame and decelerates back over eighteen frames,
    /// while a white head runs the full width of the card in 150 ms and dies where
    /// it arrives. The overshoot is in the scale, not the brightness, so the
    /// resolve stays monotone.
    ///
    /// A finished day wears the whole ramp, teal to gold, end to end.
    private var mergedBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(gradient: ink.progressGradient,
                                              startPoint: .leading, endPoint: .trailing))
                gloss
                Capsule().fill(ink.white(0.55)).opacity(0.6 * heat)
                // The head: a hot white tip running along a bar that is already lit.
                Capsule()
                    .fill(LinearGradient(colors: [.clear, ink.white(0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * shoot)
                    .opacity(0.95 * gold)
            }
            .frame(height: slotHeight)
        }
        .frame(height: slotHeight)
        .shadow(color: ink.progressColor(at: 1).opacity(0.45), radius: 5)
        .scaleEffect(y: 1 + 0.60 * heat, anchor: .center)
    }

    /// A bright top half, so the fill reads as a lit tube rather than flat paint.
    private var gloss: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.0)],
                                 startPoint: .top, endPoint: .center))
            .blendMode(.plusLighter)
    }

    /// The segments. One gradient runs under the WHOLE bar and each segment shows
    /// its own slice of it, so the colour says how far through the day you are:
    /// the first task is teal, the last one is gold. The segment you are on next
    /// wears a faint outline in the colour it will turn, so even 0 of 3 has
    /// somewhere to point.
    private var ladder: some View {
        let count = max(1, min(segments, 12))
        let filled = fraction * Double(count)
        let spacing: CGFloat = 3
        let nextIndex = Int(filled.rounded(.down))
        let tip = ink.progressColor(at: fraction)

        return GeometryReader { geometry in
            let segmentWidth = max(0, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            ZStack(alignment: .leading) {
                // Track.
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { index in
                        let isNext = (index == nextIndex && nextIndex < count)
                        Capsule()
                            .fill(ink.white(0.075))
                            .overlay {
                                if isNext {
                                    Capsule().strokeBorder(
                                        ink.progressColor(at: (Double(index) + 0.5) / Double(count)).opacity(0.55),
                                        lineWidth: 0.8)
                                }
                            }
                    }
                }

                // Fill: one gradient, cut into the segments that are done.
                ZStack {
                    LinearGradient(gradient: ink.progressGradient,
                                   startPoint: .leading, endPoint: .trailing)
                    gloss
                }
                .frame(width: geometry.size.width)
                .mask(alignment: .leading) {
                    HStack(spacing: spacing) {
                        ForEach(0..<count, id: \.self) { index in
                            let level = min(1, max(0, filled - Double(index)))
                            Capsule()
                                .frame(width: segmentWidth * level)
                                .frame(width: segmentWidth, alignment: .leading)
                                .scaleEffect(y: index == landingIndex ? 1 + 0.45 * heat : 1,
                                             anchor: .center)
                        }
                    }
                }
                .shadow(color: tip.opacity(fraction > 0 ? 0.55 : 0), radius: 4)

                // The landing segment's gold flash.
                if let landing = landingIndex, landing < count {
                    let level = min(1, max(0, filled - Double(landing)))
                    Capsule()
                        .fill(ink.spark)
                        .frame(width: segmentWidth * level, height: slotHeight)
                        .scaleEffect(y: 1 + 0.45 * heat, anchor: .center)
                        .opacity(0.92 * gold)
                        .offset(x: CGFloat(landing) * (segmentWidth + spacing))
                }
            }
        }
        .frame(height: slotHeight)
    }
}
