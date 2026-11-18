import SwiftUI

/// The island: rests inside the notch, grows open on hover or while you are reading.
struct IslandView: View {
    @ObservedObject var model: PrompterModel
    @ObservedObject private var island = IslandState.shared
    @ObservedObject private var timer = TimerModule.shared
    @ObservedObject private var media = MediaModule.shared
    @ObservedObject private var style = IslandLook.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var strip

    /// How content arrives when the island opens: it grows and comes into focus, or only fades when motion is reduced.
    private var enter: AnyTransition {
        reduceMotion ? .opacity : .focus().combined(with: .scale(scale: 0.9, anchor: .top))
    }

    /// How one tab replaces another: the new one slides in from the side it lives on.
    private var slide: AnyTransition {
        reduceMotion ? .opacity : .focus(5).combined(with: .offset(x: 16 * island.tabDirection))
    }

    static func hasActivity(timer: TimerModule, media: MediaModule) -> Bool {
        timer.isActive || timer.finished || media.isPlaying
    }

    var body: some View {
        let theme = model.theme
        let expanded = island.isExpanded(listening: model.listening)
        let tab = island.shownTab
        let prompting = expanded && tab == .prompter
        let size = island.size(listening: model.listening, hasActivity: Self.hasActivity(timer: timer, media: media))
        let ear = expanded ? island.ear : IslandState.collapsedEar
        // By default the bottom corners take the size of the curves that flare into the screen edge.
        let radius = island.ear
        let peek = island.peek
        // A peek with a line underneath is taller, so its corners round a little more.
        let shape = NotchShape(ear: ear, radius: expanded ? radius : (peek?.detail != nil ? 13 : 9))
        let palette = Self.palette(theme, islandRadius: radius)

        ZStack(alignment: .top) {
            // The island is black, like the notch it grows from. Only the script wears the theme's own surface.
            // The script's surface is always solid, so a see-through theme never turns the island grey.
            // The Glass style frosts the tool tabs, but stays dark enough to keep white text readable.
            shape.fill(Color.black)
            // Behind the script the glow is the theme's own and follows the voice. Behind the tools it is
            // the user's choice: off, the theme's colour, or the colour of the cover that is playing.
            let coverGlow = style.glow == .cover && !island.greeting && (tab == .media || tab == .home) && media.hasTrack
                ? media.artworkColour : nil
            let glowStrength: Double = prompting ? 1
                : style.glow == .off ? 0
                : coverGlow != nil ? 0.5 : 0.25
            if expanded && glowStrength > 0 {
                AuraView(colour: coverGlow ?? theme.glowColour, strength: glowStrength, listening: model.listening)
                    // A new identity on each theme switch, so the old glow fades out while the new one fades in.
                    .id(model.themeSwitchID)
                    .clipShape(shape)
                    .transition(.opacity)
            }
            Group {
                if expanded {
                    expandedContent(tab: island.greeting ? .home : tab)
                        .transition(.asymmetric(
                            insertion: enter.animation(reduceMotion ? IslandMotion.reduced : IslandMotion.arrive),
                            removal: (reduceMotion ? AnyTransition.opacity : .focus(6)).animation(IslandMotion.leave)
                        ))
                } else if let peek {
                    PeekView(peek: peek, notchWidth: island.notchWidth, inset: island.inset)
                        .id(peek.id)
                        .transition(reduceMotion ? .opacity : .focus(5).combined(with: .scale(scale: 0.86)))
                } else {
                    CollapsedActivity(notchWidth: island.notchWidth)
                        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.12)))
                }
            }
            .environment(\.islandPalette, palette)
            .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.peekIn, value: peek?.id)
            .padding(.horizontal, ear)
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        // Clip everything to the island so content fading out never spills past its edge.
        .clipShape(shape)
        .onDrop(of: [.fileURL], isTargeted: $island.dropTargeted) { providers in
            guard ShelfModule.shared.accept(providers) else { return false }
            island.noteDrop()
            island.open(.shelf)
            return true
        }
        // Opening bounces a little; closing is quick and flat; the resting notch stretches softly for an activity.
        // The closest of these to fire wins, so opening and closing never borrow the stretch's bounce.
        // Switching theme cross-fades the accent and glow; the settings window's own animations cannot reach this panel.
        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.theme, value: model.themeSwitchID)
        .animation(reduceMotion ? IslandMotion.reduced : expanded ? IslandMotion.open : IslandMotion.close, value: expanded)
        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.stretch,
                   value: Self.hasActivity(timer: timer, media: media))
        // A peek widens with its own spring and settles without bounce; everything else uses the open spring.
        .animation(reduceMotion ? IslandMotion.reduced
                   : peek != nil ? IslandMotion.peekIn
                   : island.peekSettling ? IslandMotion.peekOut : IslandMotion.open, value: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The island's palette, with tile corners running parallel to the island's own bottom corners.
    private static func palette(_ theme: Theme, islandRadius: CGFloat) -> IslandPalette {
        var palette = IslandPalette(theme)
        // 12 is the bottom margin between the tiles and the island's edge.
        palette.tileRadius = IslandPalette.concentric(outer: islandRadius, padding: 12)
        return palette
    }

    @ViewBuilder
    private func expandedContent(tab: IslandTab) -> some View {
        let browsing = island.browsing && !island.greeting
        VStack(spacing: 0) {
            // The strip beside the notch: three tools on each side, hugging the notch, with the
            // prompter's controls at the far ends. Everything else opens from More.
            let pins = island.pinnedTabs
            let half = (pins.count + 1) / 2
            let ink = tab == .prompter ? Theme.text : Color.white
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    if tab == .prompter && !island.showingMore {
                        stripButton(model.listening ? "pause.fill" : model.followMode.startIcon,
                                    model.followMode == .auto ? "Start or pause scrolling" : "Start or pause listening", ink) {
                            NotificationCenter.default.post(name: .qolToggleListening, object: nil)
                        }
                        stripButton("arrow.counterclockwise", "Restart from the top", ink) { model.restart() }
                    }
                    Spacer(minLength: 4)
                    ForEach(pins.prefix(half)) { tabButton($0, current: tab, ink) }
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity)
                .opacity(browsing ? 1 : 0)

                Color.clear.frame(width: island.notchWidth)

                HStack(spacing: 2) {
                    if browsing {
                        ForEach(pins.dropFirst(half)) { tabButton($0, current: tab, ink) }
                        if !island.moreTabs.isEmpty {
                            stripToggle("ellipsis", "More tools", on: island.showingMore || !pins.contains(tab), ink) {
                                island.showingMore.toggle()
                            }
                        }
                        Spacer(minLength: 4)
                        if tab == .prompter && !island.showingMore {
                            stripButton(island.pinned ? "pin.fill" : "pin", "Keep the prompter open", ink) {
                                island.pinned.toggle()
                            }
                        }
                        stripButton("chevron.up", "Close", ink) { island.collapse() }
                    } else if let wordsLeft = model.wordsUntilMyTurn {
                        Spacer(minLength: 0)
                        Text(wordsLeft <= 6 ? "You're next" : "Your turn soon")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(model.colour(for: model.mySpeaker).color))
                            .fixedSize()
                    }
                }
                .padding(.leading, 6)
                .frame(maxWidth: .infinity)
            }
            .frame(height: island.inset)

            Group {
                if island.greeting {
                    WelcomeView().id(island.greetRun)
                } else if island.showingMore {
                    MoreTools().transition(enter)
                } else {
                switch tab {
                case .prompter:
                    // Keep the reading width fixed so the lines do not reflow when the island widens on hover.
                    PrompterContent(model: model)
                        .frame(width: island.prompterWidth - island.ear * 2)
                case .home: HomeTab()
                case .media: MediaTab()
                case .calendar: CalendarTab()
                case .mirror: MirrorTab()
                case .notes: LockGate(name: "Notes") { NotesTab(model: model) }
                case .shelf: ShelfTab()
                case .timer: TimerTab()
                case .clipboard: LockGate(name: "Clipboard") { ClipboardTab() }
                case .apps: AppsTab()
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One view at a time: the old one goes, then the new one grows in.
            .id(island.showingMore ? "more" : tab.rawValue)
            .transition(.asymmetric(insertion: slide.animation(reduceMotion ? IslandMotion.reduced : IslandMotion.tab.delay(0.05)),
                                    removal: .opacity.animation(.easeOut(duration: 0.07))))
            .animation(IslandMotion.tab, value: tab)
            .animation(IslandMotion.tab, value: island.showingMore)
        }
    }

    private func tabButton(_ item: IslandTab, current: IslandTab, _ ink: Color) -> some View {
        stripToggle(item.icon, item.title, on: item == current && !island.showingMore, ink) { island.tab = item }
    }

    /// A tool in the strip: full strength with a dot under it when it is the one showing.
    private func stripToggle(_ icon: String, _ title: String, on: Bool, _ ink: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink.opacity(on ? 1 : 0.5))
                .frame(width: 24, height: 24)
                .contentTransition(.symbolEffect(.replace))
                .overlay(alignment: .bottom) {
                    // One dot, shared by every tool, so it slides from the old tab to the new one.
                    if on {
                        Circle().fill(ink).frame(width: 3, height: 3).offset(y: 2)
                            .matchedGeometryEffect(id: "dot", in: strip)
                    }
                }
                .contentShape(Rectangle())
                .animation(IslandMotion.tab, value: on)
        }
        .buttonStyle(IslandPressStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func stripButton(_ icon: String, _ help: String, _ ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.opacity(0.7))
                .frame(width: 22, height: 24)
                .contentTransition(.symbolEffect(.replace))
                .swapBlur(icon)
                .contentShape(Rectangle())
                .animation(IslandMotion.quick, value: icon)
        }
        .buttonStyle(IslandPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The tools that are not pinned beside the notch, as labelled tiles.
private struct MoreTools: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var island = IslandState.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(island.moreTabs) { tab in
                Button { island.tab = tab } label: {
                    VStack(spacing: 7) {
                        Image(systemName: tab.icon).font(.system(size: 20, weight: .medium))
                        Text(tab.title).font(look.font(11, .medium))
                    }
                    .foregroundStyle(tab == island.tab ? look.accent : look.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .islandTile(look)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IslandPressStyle(highlight: false))
                .accessibilityLabel(tab.title)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

// MARK: - Collapsed live activity

/// What shows either side of the notch while the island is resting.
private struct CollapsedActivity: View {
    let notchWidth: CGFloat
    @ObservedObject private var timer = TimerModule.shared
    @ObservedObject private var media = MediaModule.shared
    @AppStorage("vinylArtwork") private var vinyl = true

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if timer.isActive || timer.finished {
                    Image(systemName: timer.finished ? "bell.fill" : "timer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(timer.finished ? Color.orange : Color.white.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .swapBlur(timer.finished)
                } else if media.isPlaying {
                    if media.artwork != nil, vinyl {
                        VinylArtwork(size: 20).transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else if let artwork = media.artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.pink)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)

            Color.clear.frame(width: notchWidth)

            Group {
                if timer.isActive || timer.finished {
                    Text(timer.finished ? "Done" : TimerModule.clock(timer.remaining))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(IslandMotion.quick, value: timer.remaining.rounded(.up))
                        .foregroundStyle(timer.finished ? Color.orange : Color.white.opacity(0.85))
                } else if media.isPlaying {
                    PlayingBars().transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 8)
        }
        .animation(IslandMotion.stretch.delay(0.08), value: media.isPlaying)
        .animation(IslandMotion.stretch.delay(0.08), value: timer.isActive)
    }
}

/// Three little bars that bounce while music plays.
private struct PlayingBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.pink)
                        .frame(width: 2.5, height: 4 + 8 * abs(sin(t * (2.2 + Double(i) * 0.7) + Double(i))))
                }
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Tabs

private struct MediaTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var media = MediaModule.shared
    @AppStorage("vinylArtwork") private var vinyl = true

    var body: some View {
        HStack(spacing: 14) {
            if vinyl { VinylArtwork(size: 96).padding(.trailing, 8) } else { Artwork(size: 76) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(media.hasTrack ? media.title : "Nothing playing")
                        .font(look.font(15, .semibold))
                        .foregroundStyle(look.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if media.hasTrack && !media.source.isEmpty {
                        Text(media.source)
                            .font(look.font(9.5, .medium))
                            .foregroundStyle(look.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(look.fill))
                            .fixedSize()
                    }
                    MediaButton(icon: "arrow.up.left.and.arrow.down.right", label: "Show full screen", size: 10) {
                        NowPlayingScreen.shared.open()
                    }
                }
                Text(media.hasTrack ? media.artist : "Play something in Music, Spotify, Chrome or Safari")
                    .font(look.font(12))
                    .foregroundStyle(look.secondary)
                    .lineLimit(1)
                ScrubBar()
                    .padding(.top, 3)
                HStack(spacing: 16) {
                    MediaButton(icon: "shuffle", label: media.canShuffle ? "Shuffle" : "Shuffle is not available for this app",
                                size: 11, active: media.shuffle == true) { media.toggleShuffle() }
                        .disabled(!media.canShuffle)
                    Spacer(minLength: 0)
                    MediaButton(icon: "backward.fill", label: "Previous track") { media.previous() }
                    MediaButton(icon: media.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause", size: 19) { media.playPause() }
                    MediaButton(icon: "forward.fill", label: "Next track") { media.next() }
                    Spacer(minLength: 0)
                    MediaButton(icon: "repeat", label: media.canShuffle ? "Repeat" : "Repeat is not available for this app",
                                size: 11, active: media.repeating == true) { media.toggleRepeat() }
                        .disabled(!media.canShuffle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

/// The track's progress. Drag or click anywhere on it to jump.
struct ScrubBar: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var media = MediaModule.shared
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = dragging ?? media.position(at: context.date)
            let fraction = media.duration > 0 ? min(1, max(0, position / media.duration)) : 0
            HStack(spacing: 7) {
                Text(Self.clock(position)).lineLimit(1).fixedSize().frame(minWidth: 34, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(look.fill)
                        Capsule().fill(look.accent).frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: dragging == nil ? 4 : 7)
                    .animation(IslandMotion.quick, value: dragging != nil)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard media.duration > 0 else { return }
                                dragging = media.duration * min(1, max(0, value.location.x / geo.size.width))
                            }
                            .onEnded { _ in
                                if let target = dragging { media.seek(to: target) }
                                dragging = nil
                            }
                    )
                }
                .frame(height: 14)
                Text(media.duration > 0 ? Self.clock(media.duration) : "–:––").lineLimit(1).fixedSize().frame(minWidth: 34, alignment: .trailing)
            }
            .font(look.font(9.5, .medium))
            .monospacedDigit()
            .foregroundStyle(look.secondary)
            .opacity(media.duration > 0 ? 1 : 0.5)
        }
        .accessibilityLabel("Track progress")
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

private struct TimerTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var timer = TimerModule.shared
    @AppStorage("timerChime") private var chime = "Glass"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    if timer.finished {
                        Text("Done").font(look.font(54, .semibold)).foregroundStyle(look.accent)
                            .transition(reduceMotion ? .opacity : .focus(6).combined(with: .scale(scale: 0.9, anchor: .leading)))
                    } else {
                        // Each digit rolls to the next as it changes, like the system's own timers.
                        Text(TimerModule.clock(timer.remaining))
                            .font(.system(size: 54, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(look.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.quick, value: timer.remaining.rounded(.up))
                    }
                }
                .frame(height: 60, alignment: .leading)
                .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.tab, value: timer.finished)
                // How much of the timer is left.
                GeometryReader { geo in
                    let fraction = timer.total > 0 ? timer.remaining / timer.total : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(look.fill)
                        Capsule().fill(look.accent).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            .frame(width: 200, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach([1, 5, 10, 25], id: \.self) { minutes in
                        Button("\(minutes)m") { timer.start(minutes: Double(minutes)) }
                            .buttonStyle(IslandChipStyle())
                            .accessibilityLabel("Start \(minutes) minute timer")
                    }
                }
                HStack(spacing: 6) {
                    if timer.isRunning {
                        Button("Pause") { timer.pause() }.buttonStyle(IslandChipStyle(prominent: true))
                    } else if timer.remaining > 0 {
                        Button("Resume") { timer.resume() }.buttonStyle(IslandChipStyle(prominent: true))
                    }
                    if timer.total > 0 || timer.finished {
                        Button("Reset") { timer.reset() }.buttonStyle(IslandChipStyle())
                    }
                    Button {
                        let all = TimerModule.chimes
                        chime = all[((all.firstIndex(of: chime) ?? 0) + 1) % all.count]
                        TimerModule.playChime()
                    } label: {
                        Label(chime, systemImage: chime == "None" ? "bell.slash" : "bell")
                            .contentTransition(.symbolEffect(.replace))
                            .swapBlur(chime)
                    }
                    .buttonStyle(IslandChipStyle())
                    .help("The sound when the timer ends. Click to hear the next one.")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}

extension Notification.Name {
    static let qolToggleListening = Notification.Name("qolToggleListening")
    static let qolFloat = Notification.Name("qolFloat")
}
