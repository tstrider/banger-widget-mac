//  BangerWidgetBundle.swift — the extension entry point and the widget's shape.
//
//  Keep this file thin. It is the only file in the target carrying `@main`, and
//  the offscreen capture build compiles every OTHER file here into a plain
//  executable so it can render the real views offscreen. Anything shared has to live
//  elsewhere or the capture will not link.

import SwiftUI
import WidgetKit
import BangerKit

@main
struct BangerWidgetBundle: WidgetBundle {
    var body: some Widget {
        BangerChecklistWidget()
    }
}

struct BangerChecklistWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BangerWidgetKind.checklist, provider: BangerTimelineProvider()) { entry in
            BangerWidgetView(entry: entry)
                .containerBackground(for: .widget) { BangerContainerBackground() }
        }
        .configurationDisplayName("Banger")
        .description("Today's list, in the corner. Check one off.")
        // Large is FIRST on purpose: the picker shows the first entry, and large is the
        // size the list stays visible at (9 rows before anything has to scroll). Small and
        // medium stay supported so the user can swap without losing tasks.
        .supportedFamilies([.systemLarge, .systemMedium, .systemSmall])
        // Own the padding: the layout is tuned for a widget with nothing beside it,
        // and the system margins are sized for a crowded home screen.
        .contentMarginsDisabled()
    }
}
