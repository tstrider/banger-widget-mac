//  TaskPeekCard.swift — what the peek card looks like. The behaviour is in TaskPeek.swift.
//
//  The widget's own look, off the widget: near-black, lit from above (a bright top
//  edge that is gone by halfway down, never a hairline all the way round), the same
//  rounded face at a size meant for reading rather than scanning. A done task reads
//  quieter, as it does on the row, and the small ring or disc in front of it is the
//  row's checkbox in miniature. That is all the state it shows, and it has no controls:
//  it is a place to read the words and nothing else.

import AppKit
import SwiftUI
import BangerKit

struct TaskPeekCard: View {

    /// Wide enough for about forty characters a line, which is the widget's row plus a
    /// little: a long task wraps into a short paragraph rather than a tall ribbon.
    static let maxWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 14

    private static let fontSize: CGFloat = 14
    private static let leading: CGFloat = 14
    private static let trailing: CGFloat = 16
    private static let markWidth: CGFloat = 10
    private static let markGap: CGFloat = 9

    var text: String
    var done: Bool

    /// The card hugs a short task instead of leaving a wide empty bar after it, and
    /// stops at `maxWidth`, where the text starts to wrap.
    static func width(for text: String) -> CGFloat {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let font = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        // Per line: a task with a newline in it is as wide as its longest line.
        let widest = text.components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let chrome = leading + markWidth + markGap + trailing
        // A couple of points of slack, so AppKit's measurement and SwiftUI's layout
        // cannot disagree by a hair and wrap the last word of a line that fits.
        return min(maxWidth, (widest + chrome + 3).rounded(.up))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.markGap) {
            mark
            Text(text)
                .font(.system(size: Self.fontSize, weight: .medium, design: .rounded))
                .lineSpacing(2.5)
                .foregroundStyle(Color.white.opacity(done ? 0.52 : 0.94))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, Self.leading)
        .padding(.trailing, Self.trailing)
        .padding(.vertical, 12)
        .frame(width: Self.width(for: text), alignment: .leading)
        .background { background }
        .environment(\.colorScheme, .dark)
    }

    /// The row's checkbox, small: a ring while open, the accent disc once done.
    private var mark: some View {
        ZStack {
            if done {
                Circle().fill(BangerPalette.accent.opacity(0.85))
                Image(systemName: "checkmark")
                    .font(.system(size: 5.5, weight: .black))
                    .foregroundStyle(Color(red: 0.02, green: 0.07, blue: 0.07))
            } else {
                Circle().strokeBorder(Color.white.opacity(0.33), lineWidth: 1.2)
            }
        }
        .frame(width: Self.markWidth, height: Self.markWidth)
        // Sits on the first line with its centre about where a lowercase letter's is.
        .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4.5 }
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return shape
            .fill(Color(white: 0.035))
            .overlay {
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.06),
                                                   Color.white.opacity(0.012),
                                                   .clear],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.17),
                                                           Color.white.opacity(0.045),
                                                           Color.white.opacity(0.0)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1)
            }
    }
}
