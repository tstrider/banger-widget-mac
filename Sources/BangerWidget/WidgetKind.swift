//  WidgetKind.swift — the widget's kind string, on its own.
//
//  It lives outside BangerWidgetBundle.swift for two reasons. `Widget` is
//  main-actor isolated and the App Intents read this from a nonisolated context.
//  And BangerWidgetBundle.swift is the only file in this target carrying `@main`,
//  so the offscreen capture build can compile every other file in the directory into
//  a plain executable and render the real views offscreen. Anything shared has to sit
//  outside that one file or the capture cannot link.

enum BangerWidgetKind {
    static let checklist = "BangerChecklist"
}
