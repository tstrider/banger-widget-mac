//  StreakFlame.swift — the streak pill: how hot the flame is, and when it goes cold.
//
//  Three jobs, and nothing else:
//
//   - HEAT. The longer the streak, the bigger and hotter the flame. Six tiers, each a
//     step up in size, colour and glow, drawn from the same palette as the progress
//     bar (teal, then ember orange, hot pink, and the celebration's gold). A widget
//     cannot animate, so every bit of the reward is in the resting picture.
//   - AT RISK. Late in the day, with a streak on the line and the list not cleared,
//     the flame goes cold: hollow, icy blue, dashed outline, a faint frost glow. It
//     reads as "going out", not as "off". It comes back the
//     moment the list clears — on the commit frame, because the header reads the
//     row's optimistic commit. An empty list never nags; it has no pill to nag with.
//   - 9,999. The number is capped for display, grouped, and drawn in monospaced
//     digits, so the pill's width only changes when the digit count does.
//
//  THE STREAK ITSELF IS NOT COUNTED HERE. `streak` is TaskDocument.streakDays:
//  consecutive fully-cleared days BEFORE today. It only moves at the day rollover,
//  on purpose, so tasks added late in the evening cannot take back a number that
//  already went up. Clearing today makes the flame hot again; the digit moves at 2am.
//
//  Everything that decides anything is a pure function on `StreakFlame`, so it can be
//  checked without a widget host.

import SwiftUI
import BangerKit

// MARK: - The rules

enum StreakFlame {

    /// How long before the day boundary the flame starts to go cold, if the list is not
    /// cleared. The boundary is BangerDate.Rollover's (02:00 America/Chicago by
    /// default), so this puts the nudge at 20:00 — early enough to do something about
    /// it, late enough that an unfinished list is a real risk rather than a normal
    /// afternoon. Measured in real time, so on the one fall-back night a year the nudge
    /// lands at 21:00 wall clock instead; nobody is harmed by an hour's grace.
    static let nudgeLead: TimeInterval = 6 * 60 * 60

    /// The largest number the pill spells out. Anything above it reads "9,999+".
    static let displayCap = 9_999

    /// The instant the flame goes cold, for the day that ends at `boundary`.
    static func nudgeStart(endingAt boundary: Date) -> Date {
        boundary.addingTimeInterval(-nudgeLead)
    }

    /// True when the pill should show the cold, at-risk flame.
    ///
    /// `cleared` is the header's own cleared flag, which includes the row's optimistic
    /// commit, so the flame is hot again on the same frame the last box is ticked.
    static func isAtRisk(streak: Int,
                         taskCount: Int,
                         cleared: Bool,
                         now: Date,
                         nextBoundary: Date) -> Bool {
        guard streak > 0, taskCount > 0, !cleared else { return false }
        return now >= nudgeStart(endingAt: nextBoundary)
    }

    /// "7", "1,234", "9,999", "9,999+". Grouped the way the user's locale groups.
    static func label(for streak: Int, locale: Locale = .current) -> String {
        let shown = min(max(streak, 0), displayCap)
        let text = shown.formatted(.number.locale(locale))
        return streak > displayCap ? text + "+" : text
    }

    enum Tier: Int, CaseIterable, Comparable {
        /// 1–2 days. The resting teal the pill has always had.
        case spark
        /// 3–6. It has caught: ember orange.
        case ember
        /// 7–29. A week in: orange licking up into gold, over a pink base.
        case blaze
        /// 30–99. A month: hot pink capsule, white number.
        case inferno
        /// 100–364. Gold-rimmed, white-hot tip.
        case supernova
        /// 365+. A year. The pill stops being a tint and becomes a solid bar of fire.
        case legend

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    static func tier(for streak: Int) -> Tier {
        switch streak {
        case ..<3:     return .spark
        case 3..<7:    return .ember
        case 7..<30:   return .blaze
        case 30..<100: return .inferno
        case 100..<365: return .supernova
        default:       return .legend
        }
    }
}

// MARK: - The pill

struct StreakPill: View {

    var streak: Int
    var atRisk: Bool
    var ink: WidgetInk
    /// The small family has 146 points of header for everything; the pill gives up a
    /// little size there. From 1,000 days on, "of N" gives way to it (see headline).
    var compact: Bool = false

    private var tier: StreakFlame.Tier { StreakFlame.tier(for: streak) }

    var body: some View {
        HStack(spacing: compact ? 1.5 : 2.5) {
            flame
            Text(StreakFlame.label(for: streak))
                .font(.system(size: compact ? 9.5 : 10.5, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(numberStyle)
                .contentTransition(.numericText(value: Double(min(streak, StreakFlame.displayCap))))
                .lineLimit(1)
        }
        .padding(.leading, compact ? 4 : 5.5)
        .padding(.trailing, compact ? 4 : 6.5)
        .padding(.vertical, 2.5)
        .background(capsuleFill)
        .overlay(capsuleEdge)
        .fixedSize()
        .shadow(color: atRisk ? ink.cold.opacity(0.45) : glow.opacity(glowOpacity),
                radius: atRisk ? 3 : glowRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(atRisk
            ? "\(streak) day streak, at risk — clear today's list to keep it"
            : "\(streak) day streak"))
    }

    // MARK: Flame

    /// The flame's point size. It grows a little through the first three tiers, then
    /// takes a clear jump at 30, 100 and 365, on every family, so the flame itself
    /// shows the milestone and not only the capsule's colour. It never changes with the
    /// at-risk state, so going cold never moves the header by a pixel.
    private var flameSize: CGFloat {
        let sizes: [CGFloat] = compact
            ? [8.0, 8.5, 9.0, 10.5, 12.0, 13.5]
            : [8.5, 9.0, 9.5, 11.5, 13.5, 15.5]
        return sizes[tier.rawValue]
    }

    @ViewBuilder private var flame: some View {
        // Reserve the filled flame's box, so the hollow cold one is the same size.
        let symbol = Image(systemName: atRisk ? "flame" : "flame.fill")
            .font(.system(size: flameSize, weight: atRisk ? .semibold : .bold))

        if atRisk {
            symbol.foregroundStyle(ink.cold)
        } else {
            switch tier {
            case .spark:
                symbol.foregroundStyle(ink.accent)
            case .ember:
                symbol.foregroundStyle(LinearGradient(colors: [ink.ember, ink.spark],
                                                      startPoint: .bottom, endPoint: .top))
            case .blaze, .inferno:
                symbol.foregroundStyle(LinearGradient(colors: [ink.hot, ink.ember, ink.spark],
                                                      startPoint: .bottom, endPoint: .top))
                    .shadow(color: ink.ember.opacity(0.9), radius: 1.5)
            case .supernova:
                // Gold going white at the tip, over a pink capsule: the flame is the
                // hottest thing in the pill, where on the tiers below it matched it.
                symbol.foregroundStyle(LinearGradient(colors: [ink.spark, ink.white(1.0)],
                                                      startPoint: .bottom, endPoint: .top))
                    .shadow(color: ink.spark.opacity(1.0), radius: 2.5)
            case .legend:
                // On a solid fire-coloured capsule a coloured flame disappears, so the
                // year-long flame is WHITE-hot with a gold halo — the brightest mark
                // anywhere in the widget.
                symbol.foregroundStyle(LinearGradient(colors: [ink.struck(1), ink.white(1.0)],
                                                      startPoint: .bottom, endPoint: .top))
                    .shadow(color: ink.hot.opacity(0.9), radius: 1.2)
                    .shadow(color: ink.spark.opacity(1.0), radius: 3)
            }
        }
    }

    // MARK: Number

    private var numberStyle: AnyShapeStyle {
        if atRisk { return AnyShapeStyle(ink.cold) }
        switch tier {
        case .spark: return AnyShapeStyle(ink.accent)
        case .ember: return AnyShapeStyle(ink.emberText)
        case .blaze: return AnyShapeStyle(ink.white(0.95))
        case .inferno, .supernova: return AnyShapeStyle(ink.white(1.0))
        case .legend: return AnyShapeStyle(ink.onFire)
        }
    }

    // MARK: Capsule

    @ViewBuilder private var capsuleFill: some View {
        if atRisk {
            Capsule().fill(ink.cold.opacity(0.12))
        } else {
            switch tier {
            case .spark:
                Capsule().fill(ink.accent.opacity(0.14))
            case .ember:
                Capsule().fill(ink.ember.opacity(0.15))
            case .blaze:
                Capsule().fill(LinearGradient(colors: [ink.hot.opacity(0.20), ink.ember.opacity(0.20)],
                                              startPoint: .leading, endPoint: .trailing))
            case .inferno:
                Capsule().fill(LinearGradient(colors: [ink.hot.opacity(0.42), ink.ember.opacity(0.34)],
                                              startPoint: .leading, endPoint: .trailing))
            case .supernova:
                Capsule().fill(LinearGradient(colors: [ink.hot.opacity(0.92), ink.hot.opacity(0.70)],
                                              startPoint: .leading, endPoint: .trailing))
                    .overlay(gloss(0.22))
            case .legend:
                Capsule().fill(LinearGradient(colors: [ink.hot, ink.ember, ink.spark],
                                              startPoint: .leading, endPoint: .trailing))
                    .overlay(gloss(0.34))
            }
        }
    }

    @ViewBuilder private var capsuleEdge: some View {
        if atRisk {
            // Dashed: the outline itself looks like it is coming apart. Full strength
            // and thicker than the hot tiers' edges, so the one state whose job is to
            // pull the eye is not the quietest thing in the header.
            Capsule().strokeBorder(ink.cold,
                                   style: StrokeStyle(lineWidth: 1.2, dash: [2.4, 1.6]))
        } else {
            switch tier {
            case .spark:
                Capsule().strokeBorder(ink.accent.opacity(0.28), lineWidth: 0.75)
            case .ember:
                Capsule().strokeBorder(ink.ember.opacity(0.40), lineWidth: 0.8)
            case .blaze:
                Capsule().strokeBorder(LinearGradient(colors: [ink.hot.opacity(0.55), ink.ember.opacity(0.60)],
                                                      startPoint: .leading, endPoint: .trailing),
                                       lineWidth: 0.85)
            case .inferno:
                Capsule().strokeBorder(LinearGradient(colors: [ink.hot.opacity(0.85), ink.ember.opacity(0.85)],
                                                      startPoint: .leading, endPoint: .trailing),
                                       lineWidth: 0.95)
            case .supernova:
                Capsule().strokeBorder(ink.spark.opacity(0.95), lineWidth: 1.1)
            case .legend:
                Capsule().strokeBorder(ink.white(0.85), lineWidth: 0.9)
            }
        }
    }

    /// The progress bar's gloss: a lit top half, so a filled capsule reads as a
    /// glowing tube rather than flat paint.
    private func gloss(_ strength: Double) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(strength), .white.opacity(0.0)],
                                 startPoint: .top, endPoint: .center))
            .blendMode(.plusLighter)
    }

    // MARK: Glow

    private var glow: Color {
        switch tier {
        case .spark: return ink.accent
        case .ember: return ink.ember
        case .blaze, .inferno: return ink.hot
        case .supernova, .legend: return ink.spark
        }
    }

    private var glowOpacity: Double {
        [0.0, 0.30, 0.40, 0.55, 0.65, 0.80][tier.rawValue]
    }

    private var glowRadius: CGFloat {
        [0, 3, 4, 5, 6, 7][tier.rawValue]
    }
}
