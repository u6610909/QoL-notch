import SwiftUI
import AppKit

/// Every timing the island uses, in one place, so its motion stays consistent and easy to tune.
enum IslandMotion {
    /// Growing open: lively, with a small overshoot.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.72)
    /// Closing: quicker and without bounce, so it gets out of the way.
    static let close = Animation.spring(response: 0.3, dampingFraction: 0.95)
    /// The resting notch stretching to make room for a live activity.
    static let stretch = Animation.spring(response: 0.45, dampingFraction: 0.68)
    /// Content arriving once the shape is most of the way open.
    static let arrive = Animation.easeOut(duration: 0.3).delay(0.09)
    /// Content leaving just ahead of the shape.
    static let leave = Animation.easeIn(duration: 0.1)
    /// One tab giving way to another.
    static let tab = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// A button answering a press, an icon changing, a number ticking.
    static let quick = Animation.spring(response: 0.24, dampingFraction: 0.7)
    /// For people who ask the Mac to reduce motion: no movement, only a short fade.
    static let reduced = Animation.easeOut(duration: 0.18)
    /// One theme giving way to another: colours and glow cross-fade. No spring; a colour should not overshoot.
    static let theme = Animation.easeInOut(duration: 0.45)
    /// A short confirmation, such as "Copied" appearing over a picture.
    static let confirm = Animation.easeOut(duration: 0.18)

    // Peeks: the resting notch widening to say something, then settling back.
    static let peekIn = Animation.spring(response: 0.38, dampingFraction: 0.7)
    static let peekOut = Animation.spring(response: 0.32, dampingFraction: 0.9)
    /// A level bar following the keys (volume, brightness).
    static let level = Animation.spring(response: 0.22, dampingFraction: 0.9)
    /// A bar or bolt filling up once, after the notch has widened.
    static let fill = Animation.easeOut(duration: 0.9).delay(0.25)

    // Screenshot drop.
    static let drop = Animation.spring(response: 0.5, dampingFraction: 0.62)
    /// The pendulum settling after the drop: low damping so it swings two or three times.
    static let swing = Animation.spring(response: 0.6, dampingFraction: 0.28).delay(0.1)
    static let tuck = Animation.spring(response: 0.3, dampingFraction: 0.92)

    // Flip digits: the old top half falls, then the new bottom half lands with a small settle.
    static let flipHalf: TimeInterval = 0.15
    static let flipDown = Animation.easeIn(duration: flipHalf)
    static let flipSettle = Animation.spring(response: 0.26, dampingFraction: 0.6).delay(flipHalf)

    // Record player.
    static let armOn = Animation.spring(response: 0.55, dampingFraction: 0.68).delay(0.1)
    static let armOff = Animation.spring(response: 0.4, dampingFraction: 0.9)
    /// Time constants (seconds) for the record reaching speed and coasting to a stop.
    static let spinUp: TimeInterval = 0.45
    static let spinDown: TimeInterval = 0.8

    /// One cover giving way to the next.
    static let crossfade = Animation.easeInOut(duration: 0.6)

    /// How long the pointer the pointer must rest on the notch before it opens, and how long after leaving it stays.
    static let openDwell: TimeInterval = 0.08
    static let closeGrace: TimeInterval = 0.25
}

private struct Blur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// Comes into focus: blurred and faint to sharp and solid.
    static func focus(_ radius: CGFloat = 8) -> AnyTransition {
        .modifier(active: Blur(radius: radius), identity: Blur(radius: 0)).combined(with: .opacity)
    }
}

/// An icon that changes: it blurs and dips for an instant, then sharpens. Pair with .contentTransition(.symbolEffect(.replace)).
private struct SwapBlur<V: Equatable>: ViewModifier {
    let value: V
    @State private var amount: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .blur(radius: amount * 3)
            .scaleEffect(1 - amount * 0.12)
            .onChange(of: value) { _, _ in
                guard !reduceMotion else { return }
                amount = 1                                   // no animation: blurred at the moment of the swap
                withAnimation(IslandMotion.quick) { amount = 0 }
            }
    }
}

extension View {
    func swapBlur<V: Equatable>(_ value: V) -> some View { modifier(SwapBlur(value: value)) }
}

/// How island buttons answer the pointer: a soft highlight on hover, a small dip when pressed.
struct IslandPressStyle: ButtonStyle {
    /// Icon buttons get a round highlight behind them; larger buttons only dip.
    var highlight = true

    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration, highlight: highlight)
    }

    private struct Pressable: View {
        let configuration: ButtonStyleConfiguration
        let highlight: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    if highlight {
                        Circle().fill(Color.white.opacity(configuration.isPressed ? 0.2 : hovering && enabled ? 0.11 : 0))
                            .padding(-2)
                    }
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
                .opacity(configuration.isPressed && reduceMotion ? 0.6 : 1)
                .animation(IslandMotion.quick, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// A light tap on the trackpad when the island opens or changes tab.
enum Haptics {
    static let settingKey = "islandHaptics"

    static func tap() {
        guard UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
