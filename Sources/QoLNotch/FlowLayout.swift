import SwiftUI

struct ParagraphStartKey: LayoutValueKey {
    static let defaultValue = false
}

struct GlueKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Places this word directly after the previous one, with no space.
    func glue(_ value: Bool) -> some View {
        layoutValue(key: GlueKey.self, value: value)
    }

    func paragraphStart(_ value: Bool) -> some View {
        layoutValue(key: ParagraphStartKey.self, value: value)
    }
}

/// Wraps words onto lines, with extra space before a new paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 5
    var centred = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let result = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var lineStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        func finishLine(upTo end: Int) {
            guard centred, end > lineStart else { return }
            let lineWidth = x
            let offset = max(0, (width - lineWidth) / 2)
            for i in lineStart..<end { frames[i].origin.x += offset }
        }

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let newParagraph = subview[ParagraphStartKey.self]
            var lead = index == lineStart || subview[GlueKey.self] ? 0 : spacing
            if index > lineStart, x + lead + size.width > width || newParagraph {
                finishLine(upTo: index)
                y += lineHeight + lineSpacing + (newParagraph ? lineHeight * 0.7 : 0)
                x = 0
                lineHeight = 0
                lineStart = index
                lead = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x + lead, y: y), size: size))
            x += lead + size.width
            lineHeight = max(lineHeight, size.height)
        }
        finishLine(upTo: subviews.count)
        return (frames, y + lineHeight)
    }
}
