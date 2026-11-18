import SwiftUI

/// The island's own look: white on black in one system face, like the notch it grows from.
/// The theme supplies only the accent and the glow; the script keeps its theme in full.
struct IslandPalette {
    var text = Color.white
    var accent = Color.white
    var glow = Color.blue
    /// The island's own colour, for text that sits on top of the accent.
    var onAccent = Color.black

    init() {}

    init(_ theme: Theme) {
        accent = theme.readableAccent
        glow = theme.glowColour.color
    }

    /// Quieter text: labels, hints, inactive icons.
    var secondary: Color { text.opacity(0.62) }
    /// Faint surfaces behind widgets and chips.
    var fill: Color { text.opacity(0.1) }
    /// Corner radius for tiles that sit against the island's edge: the island's own radius minus the margin (concentric).
    var tileRadius: CGFloat = 14
    /// A surface that sits on a tile: a step lighter, so depth reads on black.
    var raised: Color { text.opacity(0.16) }
    /// A 1-pixel edge that takes its colour from whatever is behind it: brighter at the top, where light would catch.
    var hairline: LinearGradient {
        LinearGradient(colors: [text.opacity(0.16), text.opacity(0.05)], startPoint: .top, endPoint: .bottom)
    }
    /// The radius for something inset by `padding` inside a tile.
    func inner(_ padding: CGFloat) -> CGFloat { max(4, tileRadius - padding) }
    /// Outer radius minus padding, kept within a sensible range. Pure, for tests.
    static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat { min(22, max(8, outer - padding)) }

    /// One type scale for every tab: 10 and 11 for captions, 13 for text, larger sizes for numbers.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let snapped: CGFloat = size < 10.5 ? 10 : size < 12 ? 11 : size < 16 ? 13 : size
        return .system(size: snapped, weight: weight)
    }

    /// A colour as drawn on black: lifted just enough to read.
    static func readable(_ colour: RGBA) -> Color { colour.liftedForBlack().color }
}

extension View {
    /// The standard tile: fill, concentric radius, hairline edge.
    func islandTile(_ look: IslandPalette, radius: CGFloat? = nil, fill: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? look.tileRadius, style: .continuous)
        return background(shape.fill(fill ?? look.fill))
            .overlay(shape.strokeBorder(look.hairline, lineWidth: 0.5))
    }

    /// Fades a scrolling row out at its ends instead of cutting it off.
    func fadedEdges(_ axis: Axis = .horizontal, length: CGFloat = 14) -> some View {
        mask {
            if axis == .horizontal {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: length)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: length)
                }
            } else {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: length)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: length)
                }
            }
        }
    }
}

private struct IslandPaletteKey: EnvironmentKey {
    static let defaultValue = IslandPalette()
}

extension EnvironmentValues {
    var islandPalette: IslandPalette {
        get { self[IslandPaletteKey.self] }
        set { self[IslandPaletteKey.self] = newValue }
    }
}

/// Small pill button used across the island's tabs.
struct IslandChipStyle: ButtonStyle {
    /// Prominent chips take the theme's highlight colour.
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, prominent: prominent)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.islandPalette) private var look

        var body: some View {
            let colour = prominent ? look.accent : look.text
            configuration.label
                .font(look.font(11.5, .semibold))
                .foregroundStyle(colour)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(colour.opacity(configuration.isPressed ? 0.32 : (prominent ? 0.2 : 0.12))))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(IslandMotion.quick, value: configuration.isPressed)
        }
    }
}

/// A soft panel, like a widget, that groups one piece of a tab.
struct IslandCard<Content: View>: View {
    @Environment(\.islandPalette) private var look
    var padding: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .islandTile(look)
    }
}

/// An icon, a line and a hint: what a tab shows before it has anything of its own.
struct IslandNotice: View {
    @Environment(\.islandPalette) private var look
    let icon: String
    let title: String
    let detail: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(look.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(look.fill))
                    .overlay(Circle().strokeBorder(look.hairline, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(look.font(13, .semibold)).foregroundStyle(look.text)
                    Text(detail).font(look.font(11)).foregroundStyle(look.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let button {
                        Button(button, action: action).buttonStyle(IslandChipStyle(prominent: true)).padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
