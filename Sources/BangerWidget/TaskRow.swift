//  TaskRow.swift — the thing the user actually touches.
//
//  The row is a `Toggle(isOn:intent:)` backed by a SetValueIntent, not a
//  `Button(intent:)`. That is the whole trick and it is worth being explicit about:
//  a Button in a widget repaints only when a reloaded timeline entry arrives, so
//  the check mark appears one round trip after the click — a write to tasks.json,
//  a notification, a reload, a re-render. A Toggle bound to a SetValueIntent is the
//  one construct WidgetKit renders OPTIMISTICALLY: SwiftUI flips
//  `configuration.isOn` immediately, on the click, and the intent catches up
//  afterwards. Nothing else in the widget API gives frame-one feedback.
//
//  The row does not keep that head start to itself. It publishes the state of its
//  own commit upwards as a SwiftUI preference, and the header draws the counter,
//  the progress ladder and the CLEARED chip from that — on the same frame, not one
//  beat later. See BangerWidgetView.
//
//  The row is the toggle, not just the circle — everywhere except the words. On a
//  desktop widget sitting alone in a corner there is no crowding to protect
//  against, and a row-sized target means the row can answer the click as a unit
//  rather than watching a circle change beside it. The text itself is the one
//  exception: tapping it opens the whole task in a card (PeekTaskIntent), because
//  a row is one line and a long task ends in "…". That target is laid over the
//  text's own frame, published by the text, so it covers the words and nothing
//  else: the circle, the rail, the gap between circle and words and the empty end
//  of the row all still check the task off.
//
//  Layout is fixed across states on purpose: same font, same heights whether a task
//  is open or done. Nothing reads as a commit if the text reflows underneath it.

import AppIntents
import SwiftUI
import WidgetKit
import BangerKit

/// Explicit clock position. Set only by the offscreen capture, which drives the
/// transition itself; live this is nil and SwiftUI animates.
struct CheckPhase: Equatable {
    /// Seconds since the click.
    var time: Double
}

// MARK: - What the row tells the rest of the widget

/// The row's own commit, published upward so the header lands on the same frame.
///
/// It carries the whole clock, not just a flag, because the commit is not
/// confined to the row: the counter, the ladder, the card's wash and the
/// band running round the card's perimeter are all multiples of these same three
/// curves. Publishing the curves rather than the time is what makes it impossible
/// for any of them to resolve on a different frame from the thing that caused it.
struct RowCommitSignal: Equatable {
    var taskID: String
    /// Seconds since the click — used only to pick the most advanced row if two
    /// ever animate at once.
    var time: Double
    /// True from the FIRST frame after the click. The counter adds this.
    var committed: Bool
    /// The one brightness curve.
    var heat: Double
    /// The one amber curve. Alive for 235 ms.
    var gold: Double
    /// 0…1 round the container's perimeter.
    var sweep: Double
    /// How far the rail's gold head has run.
    var railShoot: Double
    /// The centre of the checkbox that was clicked, in the card's own coordinate
    /// space. The bloom has to start where the click landed — a commit that blooms
    /// from the wrong row is worse than one that does not bloom — and a widget
    /// cannot ask for a frame after the fact, so the row hands it up with
    /// everything else, on the same frame, through the same preference.
    var impact: CGPoint? = nil
}

struct RowCommitKey: PreferenceKey {
    static let defaultValue: RowCommitSignal? = nil
    static func reduce(value: inout RowCommitSignal?, nextValue: () -> RowCommitSignal?) {
        guard let next = nextValue() else { return }
        if let current = value, current.time >= next.time { return }
        value = next
    }
}

// MARK: - Row

struct TaskRowView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let task: WidgetTask
    let isLastOpen: Bool
    /// This is the row that closes the day: either the only one still open, or —
    /// after the reload — the most recently completed row of a cleared day. It is
    /// deliberately NOT `isLastOpen`, which goes false the moment the entry
    /// reloads and would take the closing stamp away with it.
    let closesDay: Bool
    let metrics: WidgetMetrics
    let ink: WidgetInk
    var phase: CheckPhase? = nil

    var body: some View {
        Toggle(isOn: task.done,
               intent: ToggleTaskIntent(taskID: task.id, value: !task.done)) {
            Text(task.text)
        }
        .toggleStyle(TaskRowToggleStyle(task: task,
                                        isLastOpen: isLastOpen,
                                        closesDay: closesDay,
                                        metrics: metrics,
                                        ink: ink,
                                        phase: phase,
                                        reduceMotion: reduceMotion))
        .accessibilityLabel(Text(task.text))
        .accessibilityValue(Text(task.done ? "Done" : "Not done"))
        // Laid OVER the toggle as a sibling rather than nested inside its style, so
        // the two are separate controls and the topmost one under the pointer wins:
        // the words peek, everything else toggles. Full row height, so the target is
        // not a 16-point strip; the text's own width, so it never reaches the circle.
        .overlayPreferenceValue(RowTextBoundsKey.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    let text = geometry[anchor]
                    Button(intent: PeekTaskIntent(taskID: task.id)) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: text.width, height: geometry.size.height)
                    .position(x: text.midX, y: geometry.size.height / 2)
                    .accessibilityLabel(Text("Show full text"))
                    .accessibilityValue(Text(task.text))
                }
            }
        }
    }
}

/// Where the row's text sits, so the peek target can be laid over exactly the words.
/// The first value wins: WidgetKit also lays out the toggle's other state, and its
/// text is in the same place because the row never reflows between states.
struct RowTextBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if value == nil { value = nextValue() }
    }
}

struct TaskRowToggleStyle: ToggleStyle {

    let task: WidgetTask
    let isLastOpen: Bool
    let closesDay: Bool
    let metrics: WidgetMetrics
    let ink: WidgetInk
    var phase: CheckPhase?
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        // configuration.isOn is the OPTIMISTIC value: true on the click, before the
        // intent has written anything. The whole transition reads from here.
        let progress: Double = {
            if let phase { return CheckMotion.progress(fromTime: phase.time) }
            return configuration.isOn ? 1 : 0
        }()

        return RowCommitBody(progress: progress,
                             taskID: task.id,
                             taskIsDone: task.done,
                             text: task.text,
                             isLastOpen: isLastOpen,
                             closesDay: closesDay,
                             metrics: metrics,
                             ink: ink)
            // A LINEAR animation, so `progress` is elapsed time over the duration
            // and every curve in CheckMotion can be authored in seconds. Reduce
            // Motion takes the same two resting states with nothing in between.
            .animation(reduceMotion ? nil : CheckMotion.commitAnimation,
                       value: configuration.isOn)
    }
}

// MARK: - The row

/// The entire row, as one Animatable unit driven by elapsed time.
///
/// It has to be Animatable rather than a stack of plain modifiers because the
/// mapping from the clock to what you see is non-linear and, for the shatter,
/// not expressible as a from/to at all. Animating the endpoints of ordinary
/// modifiers would interpolate 1.0 to 1.0 and produce no motion.
struct RowCommitBody: View, Animatable {

    var progress: Double
    var taskID: String
    var taskIsDone: Bool
    var text: String
    var isLastOpen: Bool
    var closesDay: Bool
    var metrics: WidgetMetrics
    var ink: WidgetInk

    // `nonisolated`: SwiftUI infers @MainActor for a View, but Animatable is not
    // isolated and the render pass touches animatableData off the main actor.
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let time = CheckMotion.time(fromProgress: progress)
        let v = CommitVisuals(time: time, isLastOpen: isLastOpen)
        let rowHeight = metrics.rowHeight

        HStack(spacing: 0) {
            rail(v, rowHeight: rowHeight)
            Spacer().frame(width: 7)
            checkbox(v)
            Spacer().frame(width: 8)
            label(v)
            Spacer(minLength: 4)
            if closesDay, metrics.showsLastOneLabel {
                badgeSlot(v)
            }
        }
        .frame(height: rowHeight)
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ink.accent.opacity(v.rowWash))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(ink.accent.opacity(v.rowStroke), lineWidth: 0.9)
                }
        }
        .scaleEffect(v.rowScale, anchor: .leading)
        // The head start, handed to the header. Published only while this row is
        // ahead of the entry; once the reload catches up the header reads the
        // entry instead and nothing changes on screen.
        // Published from a GeometryReader in the row's own background, so the
        // signal carries where the row IS as well as what it is doing. An Anchor
        // resolved inside backgroundPreferenceValue lands in the wrong space; a
        // named coordinate space is unambiguous.
        .background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named(BangerWidgetView.cardSpace))
                Color.clear.preference(
                    key: RowCommitKey.self,
                    value: signal(v, time: time,
                                  impact: CGPoint(x: frame.minX + Self.checkboxInset(metrics),
                                                  y: frame.midY)))
            }
        }
    }

    /// Distance from the row's leading edge to the centre of its checkbox. The
    /// same three constants the HStack above is built from, named once so the
    /// bloom cannot drift away from the thing that caused it.
    static func checkboxInset(_ metrics: WidgetMetrics) -> CGFloat {
        5 + 2.5 + 7 + metrics.boxDiameter / 2
    }

    private func signal(_ v: CommitVisuals, time: Double, impact: CGPoint) -> RowCommitSignal? {
        // Only while the row is actually mid-flight. A row at rest publishes
        // nothing: WidgetKit pre-renders a Toggle's other state (isOn = true) so
        // it can swap on the click, and a resting "on" copy of an open task would
        // otherwise leak its +1 into the header — the counter would read 1 of 3
        // with nothing done. Every curve is zero at progress 1 anyway, so this
        // costs nothing.
        guard progress > 0, progress < 1 else { return nil }
        return RowCommitSignal(taskID: taskID,
                               time: time,
                               committed: v.committed && !taskIsDone,
                               heat: v.heat,
                               gold: v.gold,
                               sweep: v.sweep,
                               railShoot: v.railShoot,
                               impact: impact)
    }

    // MARK: Rail

    /// The row's own instant answer, on the leading edge where the eye already is.
    private func rail(_ v: CommitVisuals, rowHeight: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(ink.accent)
            .frame(width: 2.5, height: rowHeight * 0.72 * v.railExtent)
            .opacity(v.railOpacity)
            .frame(width: 2.5, height: rowHeight, alignment: .center)
    }

    // MARK: Box

    private func checkbox(_ v: CommitVisuals) -> some View {
        let d = metrics.boxDiameter
        let baseWidth: Double = isLastOpen ? 1.9 : 1.5
        // Three of the seven shards come off as gold sparks; the rest keep the
        // ring's own colour, so the shatter reads as the ring coming apart rather
        // than as sparks arriving from somewhere else.
        let ringColor = isLastOpen ? ink.accent : ink.ring

        let shardWidth = baseWidth * (1 + 0.26 * v.shardThrow)

        return ZStack {
            // The ring is SUBSTITUTED, not cross-faded. Up to the click it is an
            // ordinary stroked circle — the resting checkbox must not look like a
            // thing that is already coming apart. On the commit frame the circle
            // is gone and seven pieces of it are already in flight.
            if v.shardThrow <= 0 {
                Circle()
                    .strokeBorder(ringColor, lineWidth: baseWidth)
            } else {
                ShatterRing(throwAmount: v.shardThrow, span: v.shardSpan,
                            lineWidth: shardWidth, phase: 0, stride: 2)
                    .stroke(ringColor.opacity(v.shardOpacity),
                            style: StrokeStyle(lineWidth: shardWidth, lineCap: .round))
                // Every other piece comes off hot. Gold against black is the one
                // colour in the widget that is not the accent, and it exists for
                // exactly seven frames a day.
                ShatterRing(throwAmount: v.shardThrow, span: v.shardSpan,
                            lineWidth: shardWidth, phase: 1, stride: 2)
                    .stroke(ink.spark.opacity(v.shardOpacity),
                            style: StrokeStyle(lineWidth: shardWidth, lineCap: .round))
            }

            // Arrives struck, cools to the accent. Hue is the dimension here, not
            // opacity: the disc is fully opaque from the frame it exists.
            Circle()
                .fill(ink.struck(v.discHeat))
                .scaleEffect(v.discScale)
                .opacity(v.discOpacity)

            // The hot edge. Gold against a white-hot core is what struck metal
            // looks like, and it is the one large non-teal shape in the commit.
            // It leaves by THINNING to nothing rather than by fading, so the
            // checkbox is never a partly transparent thing.
            Circle()
                .strokeBorder(ink.spark, lineWidth: d * 0.12 * v.discHeat)
                .scaleEffect(v.discScale)
                .opacity(v.discOpacity)

            TickShape()
                .trim(from: 0, to: v.tickTrim)
                .stroke(ink.onAccent,
                        style: StrokeStyle(lineWidth: d * 0.135,
                                           lineCap: .round, lineJoin: .round))
                .opacity(v.tickOpacity)

            // THE SHOCK. The one thing in the transition that leaves the box: a
            // thin gold ring that expands to nearly three times the checkbox and
            // thins to nothing over the whole amber window. It is drawn last and
            // outside the fixed slot on purpose — `.frame` sizes a view, it does
            // not clip it — so the ring crosses the row it was fired from.
            //
            // A widget's drawing is clipped to its container shape, so this is
            // literally as far as anything here is permitted to travel. The thing
            // that does cross the card's edge is the agent app's celebration
            // overlay, in another process.
            Circle()
                .strokeBorder(ink.spark.opacity(0.40 * v.gold),
                              lineWidth: max(0.01, d * 0.055 * v.shockWidth))
                .scaleEffect(v.shockScale)
        }
        .frame(width: d, height: d)
        .scaleEffect(v.boxScale)
        // A fixed slot, so nothing in the row moves when the box pops.
        .frame(width: d, height: d)
    }

    // MARK: Text

    private func label(_ v: CommitVisuals) -> some View {
        Text(text)
            .font(.system(size: metrics.rowTextSize,
                          weight: v.textIsLight ? .medium
                                                : (isLastOpen ? .semibold : .medium),
                          design: .rounded))
            .foregroundStyle(ink.white(v.textLevel))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            // Before the strike overlay, so this is the text's frame and nothing more.
            .anchorPreference(key: RowTextBoundsKey.self, value: .bounds) { $0 }
            // Drawn left to right in step with the tick, not switched on. A
            // strikethrough that simply appears is another way of cross-fading,
            // and one that draws is a growth rather than a dim.
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(ink.white(0.44))
                        .frame(width: geometry.size.width * v.strikeTrim, height: 1.3)
                        .position(x: geometry.size.width * v.strikeTrim / 2,
                                  y: geometry.size.height / 2)
                }
                .allowsHitTesting(false)
            }
    }

    /// The slot LAST ONE sits in.
    ///
    /// On the commit frame the slot SWAPS rather than going dark: an outlined pill
    /// saying what is left becomes a filled stamp saying what happened, on the same
    /// frame as everything else, and the stamp is four times brighter than the
    /// pill it replaces. The two are stacked so the row's layout cannot shift.
    private func badgeSlot(_ v: CommitVisuals) -> some View {
        // The stamp is drawn as an overlay ON the pill rather than beside it in a
        // ZStack, so it inherits the pill's exact footprint. The slot therefore
        // cannot change width when the two swap, and the filled area — which is
        // the whole point of the swap — is the full size of the outline it
        // replaces.
        lastOneBadge
            .opacity(v.badgeOpacity)
            .overlay { closedStamp(v).opacity(1 - v.badgeOpacity) }
    }

    private var lastOneBadge: some View {
        Text("LAST ONE")
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .tracking(1.3)
            .foregroundStyle(ink.accent)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(Capsule().fill(ink.accent.opacity(0.18)))
            .fixedSize()
    }

    /// What replaces LAST ONE on the commit frame.
    ///
    /// A check mark, not a word: the header already says CLEARED on this very
    /// frame, so a word here would be the same statement twice. What the slot is
    /// FOR is the light — a solid accent capsule is roughly four times the luma of
    /// the 18 %-tinted outline it replaces, which is most of why the row ends
    /// brighter than it began — and the fill covers the pill's whole footprint.
    /// Struck warm on the commit frame and cooling with the rest.
    private func closedStamp(_ v: CommitVisuals) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 8.5, weight: .black))
            .foregroundStyle(ink.onAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(ink.struck(v.discHeat)))
            .overlay(Capsule().strokeBorder(ink.spark.opacity(0.85 * v.gold), lineWidth: 1.1))
            .scaleEffect(1 + 0.14 * v.heat)
            .shadow(color: ink.accent.opacity(0.28 + 0.40 * v.heat), radius: 4 + 7 * v.heat)
    }
}

// MARK: - Tick

/// A check mark as one open path, so `.trim` can draw it on.
struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.235, y: rect.minY + h * 0.520))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.425, y: rect.minY + h * 0.710))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.775, y: rect.minY + h * 0.310))
        return path
    }
}

// MARK: - Shatter

/// The open ring, as seven arc shards that can be thrown apart.
///
/// Opacity alone is one dimension, and one dimension is what stops registering
/// first. So the ring does not dissolve. It breaks.
///
/// The resting open checkbox is drawn as an ordinary stroked `Circle` and this
/// shape is not used at all until the click, so nothing about the resting state
/// hints that the ring is going to come apart.
///
/// As `throwAmount` rises each shard independently:
///   - travels outward at its own speed, from a fixed table, so the ring comes
///     apart raggedly rather than scaling up as a unit,
///   - rotates about its own midpoint at its own rate, so pieces tumble,
///   - shortens (`span`), until it is gone geometrically rather than by fading.
///
/// Every number is a constant. There is no randomness, so two renders of the same
/// frame are identical.
struct ShatterRing: Shape {

    var throwAmount: Double
    var span: Double
    var lineWidth: Double
    /// Which shards this instance draws: indices `phase, phase+stride, …`. Two
    /// instances at stride 2 let half the shards be thrown hot.
    var phase: Int = 0
    var stride: Int = 1
    var count: Int = 7

    /// Outward speed per shard. Deliberately uneven — a ring that expands evenly
    /// is a ripple, not a break.
    private static let speeds: [Double] =
        [1.00, 0.66, 1.24, 0.82, 1.08, 0.58, 0.90]
    /// Tumble, degrees at full throw.
    private static let spins: [Double] =
        [18, -12, 26, -21, 9, -28, 14]
    /// Sideways drift along the rim, degrees at full throw, so the pieces do not
    /// stay on their own radials.
    private static let drifts: [Double] =
        [4.0, -5.6, 2.0, -3.0, 7.0, -1.6, -4.8]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let r0 = outer - lineWidth / 2
        guard r0 > 0, count > 0 else { return path }

        let step = 360.0 / Double(count)
        // Round caps stick out by half a line width; subtract their angular width
        // so that at rest the caps meet exactly and the ring is continuous.
        let capDegrees = (lineWidth / 2) / r0 * 180 / .pi
        let restSpan = max(1.0, step - 2 * capDegrees)

        var index = phase
        while index < count {
            let speed = Self.speeds[index % Self.speeds.count]
            let spin = Self.spins[index % Self.spins.count]
            let drift = Self.drifts[index % Self.drifts.count]

            // Where the shard's own centre has got to.
            let radius = r0 * (1 + throwAmount * 0.66 * speed)
            let midAngle = Double(index) * step + step / 2
                + drift * throwAmount
            let arcSpan = restSpan * max(0, span)
            guard arcSpan > 0.8 else { index += stride; continue }

            // The shard keeps its own length as it travels, so it straightens
            // relative to the (now larger) circle it sits on and tumbles by
            // `spin`. Drawn as a short arc about its own midpoint.
            let halfArc = (arcSpan / 2) * (r0 / radius)
            let rotated = midAngle + spin * throwAmount
            let a0 = (rotated - halfArc) * .pi / 180
            let a1 = (rotated + halfArc) * .pi / 180

            // Move first: addArc draws a line from the current point otherwise,
            // and seven shards joined by chords is a spirograph, not a shatter.
            path.move(to: CGPoint(x: centre.x + radius * cos(a0),
                                  y: centre.y + radius * sin(a0)))
            path.addArc(center: centre, radius: radius,
                        startAngle: .radians(a0), endAngle: .radians(a1),
                        clockwise: false)
            index += stride
        }
        return path
    }
}
