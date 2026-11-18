import SwiftUI

/// The outline of a grown notch: the top edge flares out into the screen edge with
/// small inward curves, and the bottom corners are rounded.
struct NotchShape: Shape {
    var ear: CGFloat = 10
    var radius: CGFloat = 20

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, (rect.width - ear * 2) / 2, rect.height - ear)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
                   control1: CGPoint(x: rect.minX + ear * 0.62, y: rect.minY),
                   control2: CGPoint(x: rect.minX + ear, y: rect.minY + ear * 0.38))
        p.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + ear + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: rect.maxX - ear, y: rect.minY + ear * 0.38),
                   control2: CGPoint(x: rect.maxX - ear * 0.62, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Microphone loudness, kept apart from the main model so the glow can animate
/// without redrawing the whole script.
final class VoiceLevel: ObservableObject {
    static let shared = VoiceLevel()
    @Published private(set) var value: Double = 0

    func push(_ level: Double) {
        value = level == 0 ? 0 : value * 0.55 + level * 0.45
    }
}

/// A dome of light rising from the bottom of the panel, behind the lines being read.
struct AuraView: View {
    @ObservedObject private var level = VoiceLevel.shared
    let colour: RGBA
    let strength: Double
    let listening: Bool

    var body: some View {
        // A lighter version of the colour for the bright core.
        let core = Color(.sRGB,
                         red: colour.r + (1 - colour.r) * 0.45,
                         green: colour.g + (1 - colour.g) * 0.45,
                         blue: colour.b + (1 - colour.b) * 0.45,
                         opacity: 1)
        let base = colour.color
        GeometryReader { geo in
            let width = geo.size.width * 0.56
            let height = geo.size.height * 1.25
            Ellipse()
                .fill(
                    EllipticalGradient(
                        stops: [
                            .init(color: core.opacity(0.95), location: 0),
                            .init(color: base.opacity(0.95), location: 0.35),
                            .init(color: base.opacity(0.7), location: 0.7),
                            .init(color: base.opacity(0), location: 1),
                        ],
                        center: .center
                    )
                )
                .frame(width: width, height: height)
                .scaleEffect(1 + 0.14 * level.value)
                .position(x: geo.size.width / 2, y: geo.size.height * 1.02)
                .blur(radius: 9)
                .opacity(strength * (listening ? 0.82 + 0.18 * level.value : 0.82))
                .animation(.easeOut(duration: 0.18), value: level.value)
        }
        .allowsHitTesting(false)
    }
}
