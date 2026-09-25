//  ImpactFlashLayer.swift — the scale punch and the flash: the half of "feel"
//  that you can see. The other half is the trackpad, in Sources/Banger/Haptics.swift.
//
//  WHAT IT DRAWS, and why it is allowed to
//  ---------------------------------------
//  The completed row lives in the widget, in another process, and the overlay
//  cannot scale someone else's pixels. So this layer draws the row's LIGHT: an
//  additive field, shaped like the list, registered on the checkbox. Composited
//  over the real widget it reads as the row swelling and flashing; on black it
//  reads as the list itself. Because it is additive only, at rest it contributes
//  exactly nothing — which satisfies "one frame after settle the desktop is
//  pixel-identical" without anything having to fade out.
//
//  THE MODEL, in three sentences
//  ----------------------------
//  A pulse of light is emitted at the checkbox at t=0. It travels outward at
//  2400 pt/s, decays in time with tau = 55 ms and in space with 1/(1+d/290), it
//  COOLS from white through accent teal into gold as it goes, and it is only
//  visible where a row is there to catch it.
//  Then, at 335 ms, after a gap in which the screen is nearly empty, the checkbox
//  EMITS AGAIN: a second, faster pulse along the row in the second hue, and an
//  expanding SHELL — a gold front with a long wake and a periwinkle lip that
//  crosses 560 pt in 175 ms and leaves the frame. Its radius only ever grows.
//
//  THE ORDER, which is the point
//  -----------------------------
//     t = 0 ms    white specular at the checkbox, at FULL, on the trigger frame.
//                 The tick is already drawn. Nothing eases in: light has no mass.
//     t = 0 ms    the pulse starts travelling outward.
//     t = 19 ms   the rows above and below switch on — each one whole, at its own
//                 arrival time. They do not move and they are never swept.
//     t = 38 ms   the checkbox spring peaks. The box has answered.
//     t = 67 ms   the row spring peaks; the far end of the row is now lit.
//     t = 58 ms   the flash is already at 50 %, while the scale is still climbing.
//     t ~ 120 ms  the light is majority GOLD: the teal has cooled out of it.
//     t = 188 ms  the flash is at 10 %; the row is still ~4 % oversize.
//     t = 300 ms  the gap: the screen is nearly still.
//     t = 335 ms  the second emission. The box relights and the shell forms.
//     t ~ 383 ms  the second beat peaks.
//     t = 335…485 ms  the lit radius grows monotonically; it never contracts.
//     t = 589 ms  the shell has tapered to zero. No pixel is changed by this layer
//                 after it, and nothing of it is parked.
//
//  (The timings can be read off the `telemetry` this layer publishes.)
//
//  Purity: the only state is `elapsed` and two springs integrated at the contract's
//  fixed timestep. No clock, no Double.random.

import CoreGraphics
import Foundation
import SwiftUI

public struct ImpactFlashLayer: CelebrationLayer {

    private let profile: FeelProfile
    private let origin: CGPoint

    private(set) var row: StruckSpring
    private(set) var box: StruckSpring
    private(set) var elapsed: Double = 0

    public init(config: CelebrationConfig, reduceMotion: Bool = false) {
        let profile = FeelProfile(config: config, reduceMotion: reduceMotion)
        self.profile = profile
        self.origin = config.origin
        self.row = StruckSpring(peakTime: profile.rowPeakTime,
                                damping: profile.rowDamping,
                                overshoot: profile.rowOvershoot)
        self.box = StruckSpring(peakTime: profile.boxPeakTime,
                                damping: profile.boxDamping,
                                overshoot: profile.boxOvershoot)
    }

    // MARK: - Simulation

    public mutating func step(dt: Double) {
        elapsed += dt
        row.step(dt: dt)
        box.step(dt: dt)
    }

    /// Done when there is no light left to draw, and not before the last scheduled
    /// beat has decayed away. Deliberately a brightness test rather than a
    /// spring-at-rest test: the spring's amplitude trails off asymptotically and
    /// would hold the overlay window open for another 400 ms after the last visible
    /// pixel. Nothing is on screen, so nothing is running.
    public var isFinished: Bool {
        guard elapsed > 0.05 else { return false }
        guard elapsed > lastBeatAt + 0.02 else { return false }
        return peakLight < visibilityFloor
            && boxLight < visibilityFloor
            && beatLevel(at: 0) < visibilityFloor
            && shells.isEmpty
    }

    private var lastBeatAt: Double {
        max(profile.secondBeatAt, profile.thirdBeatAt ?? 0)
    }

    /// Below this the additive contribution, multiplied through `flashAmplitude`,
    /// is under 1/255 — it cannot change an 8-bit pixel, so there is nothing left
    /// to draw and nothing left to clean up.
    private var visibilityFloor: Double { 0.010 }

    // MARK: - The outbound pulse

    /// Brightness at a point `distance` points from the checkbox.
    ///
    /// Three terms, and only the first exists for a row that was not struck:
    ///   * the travelling pulse, which cannot light a point it has not reached yet
    ///     — that gate is what makes the list light up outward from the click
    ///     instead of switching on as one slab;
    ///   * `residual`, the struck row's own glow, driven by how hard it is still
    ///     ringing and by how far the bounce has compressed it. Both come straight
    ///     out of the spring. Kept deliberately SMALL so it does not fill in the
    ///     gap that the second beat lands in;
    ///   * a 1/(1+d/D) spread, because energy covering more area covers it thinner.
    private func pulse(at distance: Double, residual: Double = 0) -> Double {
        let arrival = distance / profile.wavefrontSpeed
        let travel = elapsed - arrival
        // 1 us of slack. At 2400 pt/s a real arrival is milliseconds away, so this
        // changes nothing for the normal path; it exists so that Reduce Motion,
        // which sets the speed to "instant", lights the whole list on frame zero
        // instead of losing it to a rounding error.
        guard travel >= -1e-6 else { return 0 }
        let level = exp(-max(0, travel) / profile.flashTau) + residual
        return min(1, level) / (1 + distance / profile.falloffDistance)
    }

    /// The struck row's own light: still-ringing plus bounce compression.
    private var residual: Double {
        row.ringingAmplitude * profile.ringingGain + row.compression * profile.reboundGain
    }

    // MARK: - The second emission

    /// The second beat, at `distance` points from the checkbox.
    ///
    /// THIS RUNS OUTWARD. A front that converges back on the checkbox reads as the
    /// animation retracting: nothing in the physical world implodes after a burst.
    ///
    /// So the checkbox simply emits a second time. Same mechanism as t = 0, same
    /// arrival gate, faster front (the medium is already excited), entirely in the
    /// second hue. The box is lit FIRST and the far end LAST, as it was at the
    /// strike; what distinguishes the two events is colour, speed and the shell,
    /// not direction — and direction is the one thing that must never reverse.
    private func beatLevel(at distance: Double) -> Double {
        var out = emission(distance: distance,
                           launch: profile.secondBeatAt,
                           gain: profile.secondBeatGain)
        if let third = profile.thirdBeatAt {
            out += emission(distance: distance, launch: third, gain: profile.thirdBeatGain)
        }
        return out
    }

    private func emission(distance: Double, launch: Double, gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        let arrival = distance / profile.secondBeatSpeed
        let t = elapsed - (launch + arrival)
        let level = bangerArrival(t, rise: profile.secondBeatRise,
                                  tau: profile.secondBeatTau)
        return level * gain / (1 + distance / (profile.falloffDistance * 1.7))
    }

    // MARK: - The shell

    /// Where the expanding front is, how bright it is, and how deep its wake is.
    ///
    /// The radius is a pure function of time since emission and only ever increases.
    /// The brightness is the emission envelope THINNED BY THE SPREAD: the same
    /// energy over a wake four times deeper is four times dimmer, which is why the
    /// shell leaves the frame by fading rather than by being switched off. Nothing
    /// here is deleted while it is still visible.
    struct ShellState: Equatable, Sendable {
        var radius: Double
        var tail: Double
        var level: Double
        /// 0 at emission, 1 when the front has spent itself.
        var progress: Double
    }

    private var shellLifetime: Double { profile.shellExpand * 1.60 }

    private func shell(launch: Double, gain: Double) -> ShellState? {
        guard gain > 0, profile.shellGain > 0 else { return nil }
        let t = elapsed - launch
        guard t > -profile.secondBeatRise, t < shellLifetime else { return nil }

        let u = feelClamp(t / profile.shellExpand, 0, 1)
        let reach = profile.shellEndRadius - profile.shellStartRadius
        // Past full expansion the front keeps drifting outward at the speed it had
        // when it got there, rather than stopping. A front that halts in mid-air is
        // the same lie as matter that vanishes in mid-air.
        let coast = max(0, t - profile.shellExpand) * (reach * 0.16 / profile.shellExpand)
        let radius = profile.shellStartRadius + reach * bangerExpansion(u) + coast
        let tail = profile.shellTail + radius * profile.shellTailGrow

        let env = bangerArrival(t, rise: profile.secondBeatRise,
                                tau: profile.secondBeatTau * 1.12)
        let spread = profile.shellTail / max(tail, 1)
        // FORMATION. A front does not exist until it has left the thing that
        // emitted it, and without this term the shell's brightest instant is a
        // 24 pt disc sitting on the checkbox — a white blob, not an emission. It
        // also puts the peak of the beat where the AREA is, which is where the
        // beat's energy has to come from.
        let form = feelClamp(radius / profile.shellFormRadius, 0, 1)
        let level = env * spread * form * gain * profile.shellGain
            * bangerTerminalTaper(t, lifetime: shellLifetime, fraction: 0.45)
        guard level > 0.0015 else { return nil }
        return ShellState(radius: radius, tail: tail, level: level, progress: u)
    }

    private var shells: [ShellState] {
        var out: [ShellState] = []
        if let s = shell(launch: profile.secondBeatAt, gain: 1) { out.append(s) }
        if let third = profile.thirdBeatAt,
           let s = shell(launch: third, gain: profile.thirdBeatGain / max(profile.secondBeatGain, 1e-6)) {
            out.append(s)
        }
        return out
    }

    /// The white core at the point of contact. Gone in two frames.
    private var specular: Double {
        profile.reduceMotion ? 0 : bangerStrikeDecay(elapsed, tau: profile.specularTau)
    }

    private var boxLight: Double {
        bangerStrikeDecay(elapsed, tau: profile.boxTau)
    }

    /// Total light at the strike point. Line widths read off this.
    private var peakLight: Double { pulse(at: 0, residual: residual) }

    // MARK: - Colour

    /// How far the light at a given point has cooled out of the accent and into the
    /// second hue, 0…1.
    ///
    /// Two things drive it and they are both physical rather than scheduled: TIME
    /// since the strike (energy at a point loses its hottest components first) and
    /// DISTANCE from it (the far end of the row is lit by light that has already
    /// spread). That is what gives the first 200 ms a second hue without a second
    /// timer, and it is why the row is not one colour across its length on any
    /// frame after the first.
    private func coolness(at distance: Double) -> Double {
        // The hue boundary TRAVELS WITH THE FRONT. A point is teal while the energy
        // is on it and turns gold 42 ms after the front has passed, over a 20 ms
        // band. So on any single frame the row is teal at the leading edge and gold
        // behind it, with a crisp moving seam between the two — two hues on screen
        // at once, on different pixels, on every frame from 20 ms onward.
        //
        // Two things are load-bearing about doing it this way. (1) Cooling by
        // wall-clock alone puts teal and gold on the SAME pixels and this draw path
        // is additive, so they sum toward white instead of resolving back into hue.
        // (2) A WIDE crossfade smears the sweep across too many intermediate hues.
        // A 20 ms seam is about 48 pt of a 300 pt row: the intermediate limes are
        // real and visible, but too small a share to read as a hue family of their
        // own. The 42 ms lag is what keeps the ACCENT leading rather than the gold:
        // it is the dial for how much of the light is teal versus gold.
        let arrival = distance / profile.wavefrontSpeed
        let since = elapsed - arrival
        let u = feelClamp((since - 0.042) / 0.020, 0, 1)
        let smooth = u * u * (3 - 2 * u)
        return smooth * profile.coolGain
    }

    /// The colour of the light at a point, given how lit it is and how much of that
    /// light is the inbound beat rather than the strike.
    ///
    /// The beat is 100 % `secondary`, unconditionally. That is the whole reason it
    /// exists: it gives the event a second dimension rather than a second helping.
    private func tint(distance: Double, lit: Double, beat: Double) -> FeelTint {
        let strike = max(0, lit - beat)
        let total = max(strike + beat, 1e-9)
        var colour = profile.primary.hueMixed(profile.secondary, coolness(at: distance))
        colour = colour.hueMixed(profile.secondary, beat / total)
        // White is confined to the front itself: hotExponent 5 means a point at
        // half the front's brightness carries 3 % of the white a point at the front
        // carries, so the row body stays saturated rather than washing out.
        let hot = pow(feelClamp(strike, 0, 1), profile.hotExponent) * profile.hotGain
        return colour.lifted(hot)
    }

    // MARK: - Draw

    public func draw(in context: inout GraphicsContext, size: CGSize) {
        guard elapsed >= 0 else { return }
        let live = shells
        guard peakLight > visibilityFloor
                || boxLight > visibilityFloor
                || beatLevel(at: 0) > visibilityFloor
                || beatLevel(at: profile.rowSpan) > visibilityFloor
                || !live.isEmpty else { return }

        drawSpill(in: context)
        drawShells(live, in: context)
        drawNeighbours(in: context)
        drawStruckRow(in: context)
        drawBox(in: context)
    }

    // MARK: The expanding shell

    /// The second beat's front, drawn as a wake in the second hue with a narrow
    /// leading band in the third.
    ///
    /// WHY THIS IS THE BIGGEST THING ON SCREEN AFTER 335 ms, and why it has to be.
    /// Motion energy is mean |ΔY| over the whole frame, so it scales with lit AREA.
    /// A 34 pt-tall row of light, even at 100 % white, cannot come close to the
    /// energy of the confetti field that makes the first peak. There is no
    /// brightness that gets a row there; only area does. At its widest this front is
    /// ~340 000 pt² of moving light at an opacity that peaks around 0.4 — which is
    /// why the frame's mean luma stays low while the motion energy is high. It is
    /// a lift, not a white-out.
    ///
    /// Two stacked radial gradients rather than one:
    ///   * the WAKE, in `secondary`, filling from the origin out to the front and
    ///     brightest at the front;
    ///   * the FRONT, a narrow band in `tertiary` right at the radius.
    /// Two gradients because a single one has to interpolate gold → periwinkle in
    /// RGB, which passes through a desaturated grey that this additive path then
    /// stacks toward white — the exact failure documented on `FeelTint.hueMixed`.
    /// Kept apart, each hue stays itself, and where they overlap the very front goes
    /// pale, which is what the hottest part of a front should do anyway.
    private func drawShells(_ states: [ShellState], in context: GraphicsContext) {
        guard !states.isEmpty else { return }
        var ctx = context
        ctx.blendMode = .plusLighter

        for s in states {
            let outer = s.radius + s.tail * profile.shellLead
            guard outer > 1 else { continue }
            let rect = CGRect(x: origin.x - outer, y: origin.y - outer,
                              width: outer * 2, height: outer * 2)
            let front = feelClamp(s.radius / outer, 0.03, 0.995)
            let inner = feelClamp((s.radius - s.tail) / outer, 0, front - 0.03)
            // The WAKE crests BEHIND the front and is nearly spent by the time it
            // reaches it. That is what leaves room for the third hue: the two
            // gradients must not be bright on the same pixels, because this path is
            // additive and gold + periwinkle at equal weight sums to a nearly grey
            // blue. Separated, the front keeps its own hue, #738CFF.
            let crest = feelClamp((s.radius - s.tail * 0.34) / outer,
                                  inner + 0.005, front - 0.012)
            let lip = feelClamp((s.radius - s.tail * 0.13) / outer,
                                crest + 0.004, front - 0.004)

            // The wake is the SECOND HUE end to end rather than cooling out of teal.
            // A teal-to-gold crossing band inside a shell this large — however
            // narrow, even rotated through the hue circle — makes lime a major share
            // of the celebration's colour. So the shell gets exactly one colour and
            // the crossing happens at the lip, once.
            func stop(_ tint: FeelTint, _ a: Double, _ loc: Double) -> Gradient.Stop {
                .init(color: Color(.sRGB, red: tint.r, green: tint.g, blue: tint.b,
                                   opacity: min(1, a)),
                      location: feelClamp(loc, 0, 1))
            }
            let w = profile.secondary
            let mid = feelClamp((s.radius - s.tail * 0.66) / outer,
                                inner + 0.004, crest - 0.004)
            ctx.fill(Path(ellipseIn: rect),
                     with: .radialGradient(Gradient(stops: [
                        stop(w, s.level * 0.20, 0),
                        stop(w, s.level * 0.34, inner),
                        stop(w, s.level * 0.90, mid),
                        stop(w, s.level * 1.00, crest),
                        stop(w, s.level * 0.46, lip),
                        stop(w, s.level * 0.20, front),
                        stop(w, 0, 1),
                     ]), center: origin, startRadius: 0, endRadius: outer))

            let t = profile.tertiary
            func peri(_ a: Double) -> Color {
                Color(.sRGB, red: t.r, green: t.g, blue: t.b, opacity: min(1, a))
            }
            ctx.fill(Path(ellipseIn: rect),
                     with: .radialGradient(Gradient(stops: [
                        .init(color: peri(0), location: 0),
                        .init(color: peri(0), location: crest),
                        .init(color: peri(s.level * 0.14), location: lip),
                        .init(color: peri(s.level * 0.58), location: front),
                        .init(color: peri(0), location: 1),
                     ]), center: origin, startRadius: 0, endRadius: outer))
        }
    }

    /// What the strike throws onto everything around it.
    ///
    /// The radius does not animate: a growing radius makes a concentric ring too
    /// faint to see. The propagating ring belongs to `Layers/ShockwaveLayer`, which
    /// draws it at an amplitude you can see. So this is simply a light SOURCE:
    /// fixed radius, on the same clock as the flash, and it cools into the second
    /// hue with everything else. Peak opacity 0.22 in a 235 pt disc — enough to
    /// read as a light, nowhere near a full-screen white flash.
    private func drawSpill(in context: GraphicsContext) {
        // Its own, faster clock. See FeelProfile.spillTau.
        let strike = bangerStrikeDecay(elapsed, tau: profile.spillTau)
            + residual * 0.5
        let beat = beatLevel(at: 0)
        let level = min(1.0, strike) + beat
        guard level > 0.004 else { return }
        var ctx = context
        ctx.blendMode = .plusLighter

        let r = profile.spillRadius
        let a = min(1.0, level) * profile.spillAmplitude
        // Half the white lift the row's own front carries. The spill is a large,
        // low-alpha disc; whitening it whitens a lot of pixels and turns an
        // additive specular lift into a colour swap. Keep the white on the front.
        let core = tint(distance: 0, lit: min(1, level), beat: beat)
            .mixed(profile.primary.hueMixed(profile.secondary, coolness(at: 0)), 0.45)
        let edge = profile.primary.hueMixed(profile.secondary,
                                            feelClamp(coolness(at: 60) + beat * 2, 0, 1))
        let gradient = Gradient(stops: [
            .init(color: Color(.sRGB, red: core.r, green: core.g, blue: core.b, opacity: a),
                  location: 0),
            .init(color: Color(.sRGB, red: edge.r, green: edge.g, blue: edge.b,
                               opacity: a * 0.42), location: 0.34),
            .init(color: Color(.sRGB, red: edge.r, green: edge.g, blue: edge.b,
                               opacity: a * 0.09), location: 0.68),
            .init(color: Color(.sRGB, red: edge.r, green: edge.g, blue: edge.b, opacity: 0),
                  location: 1),
        ])
        ctx.fill(Path(ellipseIn: CGRect(x: origin.x - r, y: origin.y - r,
                                        width: r * 2, height: r * 2)),
                 with: .radialGradient(gradient, center: origin,
                                       startRadius: 0, endRadius: r))
    }

    // MARK: Geometry

    private var rowRect: CGRect {
        CGRect(x: origin.x - profile.rowLead,
               y: origin.y - profile.rowHeight / 2,
               width: profile.rowWidth,
               height: profile.rowHeight)
    }

    // MARK: The struck row

    private func drawStruckRow(in context: GraphicsContext) {
        let stretch = profile.anisotropy * row.normalisedVelocity
        let scale = 1 + row.displacement

        var ctx = context
        ctx.blendMode = .plusLighter
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale * (1 - 0.45 * stretch), y: scale * (1 + stretch))
        ctx.translateBy(x: -origin.x, y: -origin.y)

        let rect = rowRect

        // Bloom: outset copies at low opacity, biggest first. Additive stacking
        // gives the falloff for free and stays deterministic — no blur filter, so
        // the offscreen render and the live Canvas cannot diverge.
        let glow = residual
        for step in [(-26.0, 0.075), (-15.0, 0.115), (-7.5, 0.160), (-2.5, 0.215)] {
            let r = rect.insetBy(dx: step.0, dy: step.0)
            ctx.fill(Path(roundedRect: r, cornerRadius: profile.rowCorner - step.0 * 0.8),
                     with: shading(for: r, amplitude: step.1, residual: glow))
        }

        let body = Path(roundedRect: rect, cornerRadius: profile.rowCorner)
        ctx.fill(body, with: shading(for: rect, amplitude: 0.78, residual: glow))

        // The rim is where the wavefront is most legible: a crisp edge that
        // brightens as the energy passes it and thins as it leaves.
        ctx.stroke(body, with: shading(for: rect, amplitude: 1, residual: glow),
                   lineWidth: 1.3 + 2.6 * peakLight)
    }

    // MARK: The rest of the list

    /// The neighbouring rows.
    ///
    /// There is no gradient on a neighbour. A left-to-right gradient sampled from
    /// the travelling pulse slides its bright zone across every row in the list at
    /// once, which reads as a blur filter over the whole list and makes static rows
    /// look dragged sideways.
    ///
    /// Instead each one has a single arrival time (its own vertical distance /
    /// wavefront speed), switches on WHOLE at that moment, and decays on its own
    /// clock. Per-element, not a camera effect. And they do not move by one pixel:
    /// the user's surrounding content should never move. Only the struck row moves.
    private func drawNeighbours(in context: GraphicsContext) {
        var ctx = context
        ctx.blendMode = .plusLighter
        let rect = rowRect

        for (index, dy) in profile.neighbourOffsets.enumerated() {
            let gain = index < profile.neighbourGains.count ? profile.neighbourGains[index] : 0
            guard gain > 0 else { continue }
            let d = abs(dy)
            let lit = (pulse(at: d) + beatLevel(at: d)) * gain
            guard lit > 0.0015 else { continue }
            let beat = beatLevel(at: d) * gain
            let colour = tint(distance: d, lit: lit, beat: beat)
            let r = rect.offsetBy(dx: 0, dy: dy)
            let path = Path(roundedRect: r, cornerRadius: profile.rowCorner)
            ctx.fill(path, with: .color(Color(.sRGB, red: colour.r, green: colour.g,
                                              blue: colour.b,
                                              opacity: lit * profile.flashAmplitude * 0.78)))
            ctx.stroke(path, with: .color(Color(.sRGB, red: colour.r, green: colour.g,
                                                blue: colour.b,
                                                opacity: min(1, lit * profile.flashAmplitude * 2.1))),
                       lineWidth: 1.3)
        }
    }

    /// One linear gradient standing in for "how lit is this row at each x".
    /// Sampling the closed-form pulse at 26 points across the row is cheaper than
    /// 26 separate fills and smoother than either.
    ///
    /// Only the STRUCK row gets this. It is the one element entitled to a
    /// horizontal sweep, because it is the one element the energy actually crosses.
    private func shading(for rect: CGRect,
                         amplitude: Double, residual: Double) -> GraphicsContext.Shading {
        let steps = 26
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(steps + 1)
        for k in 0...steps {
            let u = Double(k) / Double(steps)
            let x = rect.minX + u * rect.width
            let d = abs(x - origin.x)
            let strike = pulse(at: d, residual: residual)
            let beat = beatLevel(at: d)
            let lit = min(1, strike + beat)
            let colour = tint(distance: d, lit: lit, beat: beat)
            stops.append(.init(color: Color(.sRGB, red: colour.r, green: colour.g,
                                            blue: colour.b,
                                            opacity: lit * profile.flashAmplitude * amplitude),
                               location: u))
        }
        return .linearGradient(Gradient(stops: stops),
                               startPoint: CGPoint(x: rect.minX, y: rect.midY),
                               endPoint: CGPoint(x: rect.maxX, y: rect.midY),
                               options: [])
    }

    // MARK: Checkbox

    private func drawBox(in context: GraphicsContext) {
        let stretch = profile.anisotropy * 1.3 * box.normalisedVelocity
        let scale = 1 + box.displacement

        var ctx = context
        ctx.blendMode = .plusLighter
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale * (1 - 0.45 * stretch), y: scale * (1 + stretch))
        ctx.translateBy(x: -origin.x, y: -origin.y)

        let light = boxLight
        let spec = specular
        let beat = beatLevel(at: 0)
        let half = profile.boxSize / 2
        let rect = CGRect(x: origin.x - half, y: origin.y - half,
                          width: profile.boxSize, height: profile.boxSize)
        let path = Path(roundedRect: rect, cornerRadius: profile.boxCorner)

        // Specular: the struck point. White, at full on frame zero, gone in two
        // frames. This is the thing that changes on the exact frame of the click.
        if spec > 0.004 {
            let radius = profile.boxSize * (0.9 + 2.4 * (1 - spec))
            let bloom = Gradient(stops: [
                .init(color: .white.opacity(0.85 * spec), location: 0),
                .init(color: Color(.sRGB, red: 0.55, green: 1, blue: 0.96,
                                   opacity: 0.34 * spec), location: 0.40),
                .init(color: .white.opacity(0), location: 1),
            ])
            ctx.fill(Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius,
                                            width: radius * 2, height: radius * 2)),
                     with: .radialGradient(bloom, center: origin,
                                           startRadius: 0, endRadius: radius))
        }

        // The second beat lands HERE, last, in the second hue — a gold (or, on a
        // streak, pink) bloom on the checkbox, which is where the eye already is.
        if beat > 0.004 {
            let s = profile.secondary
            let radius = profile.boxSize * (2.6 - 1.1 * feelClamp(beat / 0.4, 0, 1))
            let bloom = Gradient(stops: [
                .init(color: Color(.sRGB, red: s.r, green: s.g, blue: s.b,
                                   opacity: min(0.78, beat * 1.45)), location: 0),
                .init(color: Color(.sRGB, red: s.r, green: s.g, blue: s.b,
                                   opacity: min(0.32, beat * 0.58)), location: 0.42),
                .init(color: Color(.sRGB, red: s.r, green: s.g, blue: s.b, opacity: 0),
                      location: 1),
            ])
            ctx.fill(Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius,
                                            width: radius * 2, height: radius * 2)),
                     with: .radialGradient(bloom, center: origin,
                                           startRadius: 0, endRadius: radius))
        }

        let boxTint = tint(distance: 0, lit: min(1, light + beat), beat: beat)
        ctx.fill(path, with: .color(Color(.sRGB,
                                          red: boxTint.r + 0.75 * spec,
                                          green: boxTint.g + 0.15 * spec,
                                          blue: boxTint.b + 0.25 * spec,
                                          opacity: min(1, light * 0.66 + beat * 0.70))))
        let rim = boxTint.lifted(0.42)
        ctx.stroke(path, with: .color(Color(.sRGB, red: rim.r, green: rim.g, blue: rim.b,
                                            opacity: min(1, light * 0.88 + beat * 1.1))),
                   lineWidth: 1.7 + 1.9 * spec)

        // The tick. Drawn complete on frame zero — the state changed the instant they
        // clicked, and an animated stroke-on would be the overlay pretending to
        // decide something it already knows.
        var tick = Path()
        let s = profile.boxSize
        tick.move(to: CGPoint(x: origin.x - s * 0.26, y: origin.y + s * 0.02))
        tick.addLine(to: CGPoint(x: origin.x - s * 0.07, y: origin.y + s * 0.21))
        tick.addLine(to: CGPoint(x: origin.x + s * 0.28, y: origin.y - s * 0.22))
        ctx.stroke(tick,
                   with: .color(.white.opacity(min(1, light * 0.82 + spec * 0.30 + beat * 0.55))),
                   style: StrokeStyle(lineWidth: 2.9, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Telemetry

/// The layer's internal state, published so that the timing can be checked
/// frame by frame. Nothing in the draw path reads it.
extension ImpactFlashLayer {

    public struct Telemetry: Equatable, Sendable {
        public var time: Double
        /// 1 + displacement. The number the row is actually drawn at.
        public var rowScale: Double
        public var boxScale: Double
        /// Vertical stretch factor applied on top of rowScale.
        public var rowStretch: Double
        /// Accent light at the strike point, 0…1.
        public var flash: Double
        /// White specular at the strike point, 0…1.
        public var specular: Double
        /// How hard the row is still ringing, 1 at the strike, 0 at rest.
        public var ringing: Double
        /// Bounce compression past rest, 0…1.
        public var compression: Double
        /// The inbound second beat at the checkbox, as a fraction of the strike.
        public var beat: Double
        /// The second beat at the far end of the row. It LAGS `beat` by the
        /// travel time, which shows the direction of the second emission.
        public var beatFar: Double
        /// Radius of the expanding front in points, 0 when no shell is alive. It
        /// only ever grows.
        public var shellRadius: Double
        /// Peak opacity of that front.
        public var shellLevel: Double
        /// 0 = pure accent teal, 1 = pure secondary hue, at the checkbox.
        public var coolness: Double
    }

    public var telemetry: Telemetry {
        Telemetry(time: elapsed,
                  rowScale: 1 + row.displacement,
                  boxScale: 1 + box.displacement,
                  rowStretch: 1 + profile.anisotropy * row.normalisedVelocity,
                  flash: peakLight,
                  specular: specular,
                  ringing: row.ringingAmplitude,
                  compression: row.compression,
                  beat: beatLevel(at: 0),
                  beatFar: beatLevel(at: profile.rowSpan),
                  shellRadius: shells.first?.radius ?? 0,
                  shellLevel: shells.first?.level ?? 0,
                  coolness: coolness(at: 0))
    }
}
