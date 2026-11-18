import SwiftUI
import AppKit
import Combine

/// Experimental: shows what's playing on the Mac's lock screen.
///
/// macOS hides every ordinary window once the screen locks. This puts one small window in a
/// window space of its own that sits above the lock screen, using undocumented SkyLight functions
/// that are looked up at run time. If any of them is missing, the feature quietly does nothing.
/// It is off unless the user turns it on, because a macOS update can change or remove these.
final class LockScreenMusic {
    static let shared = LockScreenMusic()
    static let settingKey = "lockScreenMusic"

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesChange = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private struct SkyLight {
        let connection: MainConnection
        let create: SpaceCreate
        let setLevel: SpaceSetLevel
        let show: SpacesChange
        let hide: SpacesChange
        let add: AddWindows

        static func load() -> SkyLight? {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
                  let connection = dlsym(handle, "SLSMainConnectionID"),
                  let create = dlsym(handle, "SLSSpaceCreate"),
                  let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
                  let show = dlsym(handle, "SLSShowSpaces"),
                  let hide = dlsym(handle, "SLSHideSpaces"),
                  let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return nil }
            return SkyLight(connection: unsafeBitCast(connection, to: MainConnection.self),
                            create: unsafeBitCast(create, to: SpaceCreate.self),
                            setLevel: unsafeBitCast(setLevel, to: SpaceSetLevel.self),
                            show: unsafeBitCast(show, to: SpacesChange.self),
                            hide: unsafeBitCast(hide, to: SpacesChange.self),
                            add: unsafeBitCast(add, to: AddWindows.self))
        }
    }

    private lazy var sky = SkyLight.load()
    private var space: UInt64 = 0
    private var panel: NSPanel?
    private var locked = false
    private var watching: AnyCancellable?
    private var layout: LockScreenLayout?

    /// Whether this Mac has what the feature needs.
    var isSupported: Bool { sky != nil }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.settingKey) }

    /// Starts listening for the screen locking and unlocking. Cheap; does nothing else until then.
    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.update()
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.update()
        }
        // Music that starts or stops while the screen is locked shows or hides the card.
        watching = MediaModule.shared.$title.combineLatest(MediaModule.shared.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.update() }
    }

    private func update() {
        if locked && enabled && MediaModule.shared.hasTrack { show() } else { hide() }
    }

    private func show() {
        guard let sky, let screen = NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        let layout = LockScreenLayout.make(screen: screen.frame.size, large: IslandFeature.lockScreenLargeCover.isOn)
        // A fresh view each time the panel comes back, so the stack arrives again on every lock.
        if !panel.isVisible || layout != self.layout {
            panel.contentView = NSHostingView(rootView: LockScreenStack(layout: layout))
            // The large stack draws its own shadows inside its margin; the compact card keeps the window's.
            panel.hasShadow = layout.cover == 0
            self.layout = layout
        }
        panel.setFrame(NSRect(x: screen.frame.midX - layout.panel.width / 2, y: screen.frame.minY + layout.bottom,
                              width: layout.panel.width, height: layout.panel.height), display: true)
        panel.orderFrontRegardless()

        let connection = sky.connection()
        if space == 0 {
            space = sky.create(connection, 1, 0)
            // High enough to sit above the lock screen's own shield.
            _ = sky.setLevel(connection, space, 400)
        }
        _ = sky.add(connection, space, [panel.windowNumber] as CFArray, 7)
        _ = sky.show(connection, [space] as CFArray)
    }

    private func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        if let sky, space != 0 { _ = sky.hide(sky.connection(), [space] as CFArray) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }
}

/// Where the lock-screen music sits and how big it is. Pure, for tests.
struct LockScreenLayout: Equatable {
    /// Side of the cover; 0 for the compact card.
    var cover: CGFloat
    var card: CGSize
    var panel: CGSize
    /// Distance of the panel's bottom edge from the screen's bottom.
    var bottom: CGFloat
    static let gap: CGFloat = 10, margin: CGFloat = 28

    static func make(screen: CGSize, large: Bool) -> LockScreenLayout {
        guard large else {
            let card = CGSize(width: 420, height: 132)
            return LockScreenLayout(cover: 0, card: card, panel: card, bottom: screen.height * 0.24)
        }
        // Clear of the clock above and the password field below on the usual screens.
        let cover = min(320, max(200, (screen.height * 0.28).rounded()))
        let card = CGSize(width: max(260, cover - 24), height: 104)
        let panel = CGSize(width: max(cover, card.width) + 2 * margin, height: cover + gap + card.height + 2 * margin)
        return LockScreenLayout(cover: cover, card: card, panel: panel, bottom: (screen.height * 0.19 - margin).rounded())
    }
}

/// What the lock-screen panel shows: the compact card, or a large cover above a small controls card.
private struct LockScreenStack: View {
    let layout: LockScreenLayout
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if layout.cover == 0 {
                LockScreenCard()
            } else {
                VStack(spacing: LockScreenLayout.gap) {
                    LockCover(side: layout.cover)
                    LockControls(size: layout.card)
                }
                .padding(LockScreenLayout.margin)
            }
        }
        .environment(\.islandPalette, IslandPalette())
        .environment(\.colorScheme, .dark)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.96)
        .blur(radius: shown || reduceMotion ? 0 : 8)
        .onAppear { withAnimation(reduceMotion ? IslandMotion.reduced : IslandMotion.arrive) { shown = true } }
    }
}

/// The large cover. A new picture comes into focus over the old one; pausing lets it sink back a little.
private struct LockCover: View {
    let side: CGFloat
    @ObservedObject private var media = MediaModule.shared
    @Environment(\.islandPalette) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.075, style: .continuous)
        ZStack {
            Group {
                if let artwork = media.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [look.glow, look.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note").font(.system(size: side * 0.38, weight: .semibold))
                            .foregroundStyle(.white))
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .id(media.artworkVersion)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.04)).combined(with: .focus(8)))
        }
        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.crossfade, value: media.artworkVersion)
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        // Breathes with play and pause, as in Apple Music.
        .scaleEffect(media.isPlaying || reduceMotion ? 1 : 0.9)
        .opacity(media.isPlaying ? 1 : 0.8)
        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.stretch, value: media.isPlaying)
        .accessibilityLabel(media.hasTrack ? "Cover of \(media.title)" : "Cover")
    }
}

/// The small glass card under the large cover: track, progress and the three main controls.
private struct LockControls: View {
    let size: CGSize
    @ObservedObject private var media = MediaModule.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 4) {
            Text(media.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .id(media.title)
                .transition(reduceMotion ? .opacity : .focus(4))
                .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.tab, value: media.title)
            Text(media.artist)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
                .id(media.artist)
                .transition(reduceMotion ? .opacity : .focus(4))
                .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.tab, value: media.artist)
            ScrubBar()
            HStack(spacing: 26) {
                MediaButton(icon: "backward.fill", label: "Previous track", size: 15) { media.previous() }
                MediaButton(icon: media.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause", size: 20) { media.playPause() }
                MediaButton(icon: "forward.fill", label: "Next track", size: 15) { media.next() }
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: size.width, height: size.height)
        .background {
            ZStack {
                if reduceTransparency {
                    Color(white: 0.1)
                } else {
                    GlassBackdrop()
                    Color.black.opacity(0.45)
                }
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }
}

/// The card on the lock screen: cover, track, progress and the three main controls.
private struct LockScreenCard: View {
    @ObservedObject private var media = MediaModule.shared

    var body: some View {
        HStack(spacing: 14) {
            Artwork(size: 92)
            VStack(alignment: .leading, spacing: 4) {
                Text(media.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(media.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                ScrubBar().padding(.top, 2)
                HStack(spacing: 22) {
                    Spacer(minLength: 0)
                    MediaButton(icon: "backward.fill", label: "Previous track", size: 15) { media.previous() }
                    MediaButton(icon: media.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause", size: 20) { media.playPause() }
                    MediaButton(icon: "forward.fill", label: "Next track", size: 15) { media.next() }
                    Spacer(minLength: 0)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: 420, height: 132)
        .background(
            ZStack {
                GlassBackdrop()
                Color.black.opacity(0.45)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
        )
        .environment(\.islandPalette, IslandPalette())
        .environment(\.colorScheme, .dark)
    }
}
