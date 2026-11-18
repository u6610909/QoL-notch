import SwiftUI

/// The welcome: the QoL Notch wordmark writes itself stroke by stroke across the island,
/// the Q's tail flicks in with the theme's highlight, a light sweeps across, then the
/// tagline and one dot per tool come in. Built from the logo's own geometry
/// (scripts/make_logo.py), so it matches the README and the app icon.
struct WelcomeView: View {
    @Environment(\.islandPalette) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    /// Seconds the whole piece takes; the island moves on to Home a little after.
    static let length: Double = 3.4
    private static let height: CGFloat = 40

    var body: some View {
        TimelineView(.animation) { context in
            let t = reduceMotion ? Self.length : context.date.timeIntervalSince(start)
            content(t)
        }
        .onAppear { start = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Welcome to QoL Notch")
    }

    private func content(_ t: Double) -> some View {
        VStack(spacing: 9) {
            ZStack {
                // Each letter starts a moment after the last, like handwriting.
                ForEach(0..<Wordmark.letterCount, id: \.self) { index in
                    let begin = 0.2 + Double(index) * 0.12
                    Wordmark(part: .letter(index))
                        .trim(from: 0, to: ease(t, from: begin, length: 0.5))
                        .stroke(look.text, style: Wordmark.stroke(height: Self.height))
                }
                // The tail lands last, a little larger, then settles.
                let tail = ease(t, from: 1.45, length: 0.22)
                Wordmark(part: .tail)
                    .trim(from: 0, to: tail)
                    .stroke(look.accent, style: Wordmark.stroke(height: Self.height))
                    .shadow(color: look.accent.opacity(0.7 * tail), radius: 6)
                    .scaleEffect(1 + 0.25 * (1 - ease(t, from: 1.55, length: 0.35)) * (tail > 0 ? 1 : 0),
                                 anchor: UnitPoint(x: 110 / 962, y: 110 / 140))
                // A light passes over the finished word.
                let sweep = ease(t, from: 1.75, length: 0.8, curve: false)
                if sweep > 0 && sweep < 1 {
                    Wordmark(part: .all)
                        .stroke(
                            LinearGradient(stops: [
                                .init(color: .white.opacity(0), location: max(0, sweep * 1.4 - 0.3)),
                                .init(color: .white.opacity(0.85), location: min(1, sweep * 1.4 - 0.15)),
                                .init(color: .white.opacity(0), location: min(1, sweep * 1.4)),
                            ], startPoint: .leading, endPoint: .trailing),
                            style: Wordmark.stroke(height: Self.height))
                        .blendMode(.plusLighter)
                }
            }
            .aspectRatio(962 / 140, contentMode: .fit)
            .frame(height: Self.height)

            Text("Your notch, but useful.")
                .font(look.font(13, .medium))
                .foregroundStyle(look.secondary)
                .opacity(ease(t, from: 1.95, length: 0.4))
                .offset(y: 6 * (1 - ease(t, from: 1.95, length: 0.4)))

            // One dot for each tool in the island, lighting up left to right.
            HStack(spacing: 7) {
                ForEach(0..<IslandTab.allCases.count, id: \.self) { index in
                    let pop = ease(t, from: 2.15 + Double(index) * 0.07, length: 0.3)
                    Circle()
                        .fill(index == 0 ? look.accent : look.text.opacity(0.35))
                        .frame(width: 5, height: 5)
                        .scaleEffect(pop < 1 ? 0.2 + pop * 1.3 : 1)
                        .opacity(pop)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
        // The whole thing breathes in a touch as it starts.
        .scaleEffect(0.94 + 0.06 * ease(t, from: 0, length: 0.6))
        .opacity(ease(t, from: 0, length: 0.25))
    }

    /// 0 before `from`, 1 after `from + length`, eased out in between.
    private func ease(_ t: Double, from: Double, length: Double, curve: Bool = true) -> CGFloat {
        let x = min(1, max(0, (t - from) / length))
        return CGFloat(curve ? 1 - pow(1 - x, 3) : x)
    }
}

/// The "QoL Notch" wordmark as strokes, on the logo's 962 x 140 grid (stroke 20, cap height 140).
struct Wordmark: Shape {
    enum Part { case letter(Int), tail, all }
    var part: Part

    static let letterCount = 8
    /// The logo's stroke (20 on a 140-high grid) for a wordmark drawn `height` points tall.
    static func stroke(height: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: 20 * height / 140, lineCap: .round, lineJoin: .round)
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 962, rect.height / 140)
        let origin = CGPoint(x: rect.midX - 481 * scale, y: rect.midY - 70 * scale)
        let transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
        let unscaled: Path
        switch part {
        case .letter(let index): unscaled = Self.letter(index)
        case .tail: unscaled = Self.tail
        case .all:
            var all = Path()
            for index in 0..<Self.letterCount { all.addPath(Self.letter(index)) }
            all.addPath(Self.tail)
            unscaled = all
        }
        return unscaled.applying(transform)
    }

    static let tail: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 92, y: 92))
        p.addLine(to: CGPoint(x: 126, y: 126))
        return p
    }()

    /// Points around a circle, y down, so increasing degrees go clockwise on screen.
    private static func arc(_ p: inout Path, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                            from: Double, to: Double, move: Bool = true) {
        let steps = Int(abs(to - from) / 4) + 1
        for step in 0...steps {
            let degrees = from + (to - from) * Double(step) / Double(steps)
            let radians = degrees * .pi / 180
            let point = CGPoint(x: cx + r * CGFloat(cos(radians)), y: cy + r * CGFloat(sin(radians)))
            if step == 0 && move { p.move(to: point) } else { p.addLine(to: point) }
        }
    }

    static func letter(_ index: Int) -> Path {
        var p = Path()
        switch index {
        case 0: arc(&p, 70, 70, 60, from: -90, to: 270)                               // Q
        case 1: arc(&p, 206, 90, 40, from: -90, to: 270)                              // o
        case 2: p.addLines([CGPoint(x: 282, y: 10), CGPoint(x: 282, y: 130), CGPoint(x: 352, y: 130)])  // L
        case 3: p.addLines([CGPoint(x: 428, y: 130), CGPoint(x: 428, y: 10),         // N
                            CGPoint(x: 528, y: 130), CGPoint(x: 528, y: 10)])
        case 4: arc(&p, 604, 90, 40, from: -90, to: 270)                              // o
        case 5:                                                                       // t
            p.move(to: CGPoint(x: 700, y: 20))
            p.addLine(to: CGPoint(x: 700, y: 105))
            arc(&p, 725, 105, 25, from: 180, to: 90, move: false)
            p.addLine(to: CGPoint(x: 730, y: 130))
            p.move(to: CGPoint(x: 680, y: 50))
            p.addLine(to: CGPoint(x: 730, y: 50))
        case 6: arc(&p, 806, 90, 40, from: -45, to: -315)                             // c, open to the right
        default:                                                                      // h
            p.move(to: CGPoint(x: 872, y: 10))
            p.addLine(to: CGPoint(x: 872, y: 130))
            arc(&p, 912, 90, 40, from: 180, to: 360)
            p.addLine(to: CGPoint(x: 952, y: 130))
        }
        return p
    }
}
