import SwiftUI

/// The scrolling script, drawn from the current theme. Used inside the island and the floating panel.
struct PrompterContent: View {
    @ObservedObject var model: PrompterModel

    var body: some View {
        let theme = model.theme
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                FlowLayout(
                    spacing: CGFloat(theme.fontSize * 0.55),
                    lineSpacing: CGFloat(Theme.lineSpacing),
                    centred: true
                ) {
                    ForEach(model.words) { word in
                        wordView(word, theme: theme)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 90)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.1),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .onChange(of: model.current) { _, newValue in
                let target = min(newValue, max(0, model.words.count - 1))
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.4))
                }
            }
            .onAppear {
                proxy.scrollTo(min(model.current, max(0, model.words.count - 1)), anchor: UnitPoint(x: 0.5, y: 0.4))
            }
        }
        // Words never slide when the typeface or size changes.
        .animation(nil, value: theme.font)
        .animation(nil, value: theme.fontSize)
    }

    @ViewBuilder
    private func wordView(_ word: Word, theme: Theme) -> some View {
        let isCurrent = word.id == model.current
        let spoken = word.id < model.current
        // Other people's lines are dimmed once this Mac's speaker is chosen.
        let othersLine = !model.mySpeaker.isEmpty && word.speaker != nil && word.speaker != model.mySpeaker
        let colour: Color = isCurrent
            ? theme.readableAccent
            : Theme.text.opacity((spoken ? Theme.spokenOpacity : 1) * (othersLine ? 0.55 : 1))

        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if word.speakerStart, let name = word.speaker {
                Text(name)
                    .font(.system(size: max(9, theme.fontSize * 0.48), weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(model.colour(for: name).color))
                    .fixedSize()
            }
            Text(word.text)
                .font(theme.swiftFont)
                .foregroundStyle(colour)
        }
        .paragraphStart(word.paragraphStart)
        .glue(word.glue)
        .id(word.id)
        .onTapGesture { model.jump(to: word.id) }
    }
}

/// The prompter as a free panel you can drag anywhere and resize, away from the notch.
struct FloatingPrompterView: View {
    @ObservedObject var model: PrompterModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = model.theme
        let radius = IslandState.shared.ear
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        PrompterContent(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                // Grip: appears on hover. Drag to move, double-click to snap back to the notch.
                Capsule()
                    .fill(Theme.text.opacity(0.3))
                    .frame(width: 34, height: 4)
                    .padding(.vertical, 5)
                    .frame(maxWidth: 80)
                    .contentShape(Rectangle())
                    .opacity(hovering ? 1 : 0)
                    .onTapGesture(count: 2) {
                        NotificationCenter.default.post(name: .qolSnapToNotch, object: nil)
                    }
                    .help("Drag to move. Double-click to snap back to the notch.")
            }
            .overlay(alignment: .topTrailing) {
                if let wordsLeft = model.wordsUntilMyTurn {
                    Text(wordsLeft <= 6 ? "You're next" : "Your turn soon")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(model.colour(for: model.mySpeaker).color))
                        .padding(8)
                }
            }
            .background {
                ZStack {
                    shape.fill(Color.black)
                    AuraView(colour: theme.glowColour, strength: 1, listening: model.listening)
                        .id(model.themeSwitchID)
                        .transition(.opacity)
                        .clipShape(shape)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.2), value: hovering)
            .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.theme, value: model.themeSwitchID)
    }
}

/// Shows the island when docked at the notch, or the free panel when detached.
struct PanelRoot: View {
    @ObservedObject var model: PrompterModel

    var body: some View {
        if model.docked {
            IslandView(model: model)
        } else {
            FloatingPrompterView(model: model)
        }
    }
}

extension Notification.Name {
    static let qolSnapToNotch = Notification.Name("qolSnapToNotch")
}
