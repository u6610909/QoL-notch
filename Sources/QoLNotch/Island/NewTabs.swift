import SwiftUI
import AppKit
import LocalAuthentication

// MARK: - Spinning record

/// The record's angle, eased towards full speed while playing and to rest when paused. Pure, for tests.
struct VinylSpin {
    /// One turn in 10 s: calm at 96 pt.
    static let degreesPerSecond = 36.0
    /// Degrees, kept within 0..<360.
    private(set) var angle = 0.0
    /// 0...1 of full speed.
    private(set) var speed: Double
    private var last: Date?

    init(speed: Double = 0) { self.speed = speed }

    mutating func advance(to date: Date, playing: Bool, instant: Bool = false) -> Double {
        // Clamped so the record does not jump after the view was hidden for a while.
        let dt = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        let target = playing ? 1.0 : 0.0
        let tau = playing ? IslandMotion.spinUp : IslandMotion.spinDown
        speed += (target - speed) * (instant ? 1 : 1 - exp(-dt / tau))
        angle = (angle + speed * Self.degreesPerSecond * dt).truncatingRemainder(dividingBy: 360)
        last = date
        return angle
    }

    var isStill: Bool { speed < 0.004 }
}

/// The current cover as a vinyl record that gathers speed when the music plays and coasts to a stop when it pauses.
struct VinylArtwork: View {
    @Environment(\.islandPalette) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var media = MediaModule.shared
    @AppStorage(IslandFeature.tonearm.rawValue) private var tonearm = true
    var size: CGFloat

    /// The spin lives in a reference so the timeline can move it on while drawing.
    private final class SpinBox {
        // Already turning if the music is: opening the tab should not spin the record up again.
        var spin = VinylSpin(speed: MediaModule.shared.isPlaying ? 1 : 0)
    }
    @State private var box = SpinBox()
    @State private var coasting = false
    @State private var armDown = MediaModule.shared.isPlaying

    var body: some View {
        let showArm = size >= 60 && tonearm
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(media.isPlaying || coasting))) { context in
            let angle = box.spin.advance(to: context.date, playing: media.isPlaying, instant: reduceMotion)
            let progress = media.duration > 0 ? media.position(at: context.date) / media.duration : 0
            ZStack {
                Circle().fill(Color(white: 0.07))
                ForEach(0..<4, id: \.self) { ring in
                    Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
                        .padding(size * (0.05 + 0.045 * CGFloat(ring)))
                }
                label
                    .frame(width: size * 0.56, height: size * 0.56)
                    .clipShape(Circle())
                Circle().fill(Color(white: 0.07)).frame(width: size * 0.07, height: size * 0.07)
            }
            .rotationEffect(.degrees(angle))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .overlay {
                if showArm {
                    // The slow inward tracking moves with the timeline; only lifting and dropping animate.
                    Tonearm(size: size, angle: Self.armAngle(playing: armDown, progress: progress),
                            lifted: !armDown, reduceMotion: reduceMotion)
                        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.armOff, value: media.title)
                }
            }
        }
        .frame(width: size, height: size)
        .onChange(of: media.isPlaying) { _, playing in
            withAnimation(reduceMotion ? IslandMotion.reduced : playing ? IslandMotion.armOn : IslandMotion.armOff) {
                armDown = playing
            }
            guard !playing else { return }
            // Keep drawing while the record coasts down; 3.5 s is a little over four time constants.
            coasting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { if !media.isPlaying { coasting = false } }
        }
        .accessibilityLabel("Record")
    }

    /// Where the arm rests: off the record when paused, and tracking inwards as the song plays. Pure, for tests.
    static func armAngle(playing: Bool, progress: Double) -> Double {
        playing ? 14 + 6 * min(1, max(0, progress)) : -8
    }

    @ViewBuilder private var label: some View {
        if let artwork = media.artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [look.glow, look.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The player's arm, drawn in the record's square and pivoting near its top right corner.
private struct Tonearm: View {
    /// The record's diameter.
    let size: CGFloat
    /// Degrees; positive swings the head onto the record.
    let angle: Double
    let lifted: Bool
    let reduceMotion: Bool

    private static let pivot = UnitPoint(x: 0.93, y: 0.09)

    var body: some View {
        let s = size
        let px = s * 0.93, py = s * 0.09
        let armWidth = max(1.5, s * 0.028)
        let armLength = s * 0.62
        ZStack(alignment: .topLeading) {
            Circle().fill(Color.white.opacity(0.16))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .frame(width: s * 0.17, height: s * 0.17)
                .position(x: px, y: py)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: s * 0.02, style: .continuous)
                    .fill(Color.white.opacity(0.4))
                    .frame(width: s * 0.07, height: s * 0.09)
                    .position(x: px, y: py - s * 0.07)
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.82), .white.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: armWidth, height: armLength)
                    .position(x: px, y: py + armLength / 2)
                RoundedRectangle(cornerRadius: s * 0.02, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: s * 0.085, height: s * 0.13)
                    .rotationEffect(.degrees(18), anchor: .top)
                    .position(x: px, y: py + armLength + s * 0.065 - s * 0.01)
            }
            .frame(width: s, height: s)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0.5), radius: lifted ? 4 : 1.5, x: lifted ? 3 : 1, y: lifted ? 5 : 1.5)
            // The arm rises off the record before it swings away.
            .scaleEffect(lifted && !reduceMotion ? 1.03 : 1, anchor: Self.pivot)
            .rotationEffect(.degrees(angle), anchor: Self.pivot)

            Circle().fill(Color.white.opacity(0.55))
                .frame(width: s * 0.07, height: s * 0.07)
                .position(x: px, y: py)
        }
        .frame(width: s, height: s)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension MediaModule {
    /// A lively colour taken from a cover, for the island's glow.
    static func glowColour(of image: NSImage) -> RGBA? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[index]); g += Double(pixels[index + 1]); b += Double(pixels[index + 2])
        }
        let count = Double(side * side) * 255
        let average = NSColor(srgbRed: r / count, green: g / count, blue: b / count, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Covers average out dull; lift them so the glow reads as a colour, not as grey.
        let lively = NSColor(hue: hue, saturation: min(1, saturation * 1.5 + 0.1), brightness: max(0.6, brightness), alpha: 1)
            .usingColorSpace(.sRGB) ?? average
        return RGBA(Double(lively.redComponent), Double(lively.greenComponent), Double(lively.blueComponent))
    }
}

// MARK: - Daily line

/// One short line a day on Home: the user's own, or one from a small built-in list. Nothing is fetched.
enum DailyLine {
    static let builtIn = [
        "Done is better than perfect.",
        "Start small. Start now.",
        "One thing at a time.",
        "Say it simply.",
        "Slow is smooth. Smooth is fast.",
        "Rest is part of the work.",
        "Make it work, then make it nice.",
        "Ask the question.",
        "Show up, then show off.",
        "Breathe before you begin.",
        "Small steps still move you.",
        "Finish what you started today.",
        "Practice out loud.",
        "Leave it better than you found it.",
        "You know more than you think.",
        "Drink some water.",
        "Fewer tabs, clearer head.",
        "Write it down before it leaves.",
        "Be kind to tomorrow's you.",
        "Look up from the screen for a minute.",
        "Good enough ships.",
        "Listen first.",
        "Try the simple way first.",
        "A short walk fixes a lot.",
        "Progress, not polish.",
        "Read it once more, then send.",
        "Save your work.",
        "Curious beats certain.",
        "Stand up and stretch.",
        "Today counts.",
    ]

    static func line(for date: Date, custom: String, calendar: Calendar = .current) -> String {
        let own = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return builtIn[day % builtIn.count]
    }
}

// MARK: - Clock widget

enum ClockStyle: String, CaseIterable, Identifiable {
    case plain, serif, mono
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var design: Font.Design {
        switch self {
        case .plain: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

struct ClockWidget: View {
    @Environment(\.islandPalette) private var look
    @AppStorage("clockStyle") private var style = ClockStyle.plain

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 2) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 30, weight: .semibold, design: style.design))
                    .monospacedDigit()
                    .foregroundStyle(style == .mono ? look.accent : look.text)
                    .contentTransition(.numericText())
                    .animation(IslandMotion.quick, value: context.date.formatted(date: .omitted, time: .shortened))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(context.date.formatted(.dateTime.weekday(.wide)))
                    .font(look.font(10.5, .medium)).foregroundStyle(look.secondary)
            }
            .padding(.horizontal, 6)
        }
    }
}

// MARK: - App launcher

/// A row of apps the user picked, one click away.
final class LauncherModule: ObservableObject {
    static let shared = LauncherModule()

    @Published private(set) var apps: [URL] = []

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "launcherApps") ?? []
        apps = saved.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for url in urls where url.pathExtension == "app" && !apps.contains(url) { apps.append(url) }
        apps = Array(apps.prefix(14))
        save()
    }

    func remove(_ url: URL) {
        apps.removeAll { $0 == url }
        save()
    }

    private func save() { UserDefaults.standard.set(apps.map(\.path), forKey: "launcherApps") }

    func pick() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose apps to keep in the notch."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

struct AppsTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var launcher = LauncherModule.shared

    var body: some View {
        Group {
            if launcher.apps.isEmpty {
                IslandNotice(icon: "square.grid.3x3", title: "Keep your favourite apps here.",
                             detail: "Pick the apps you open most, then start them from the notch with one click.",
                             button: "Add Apps") { launcher.pick() }
                    .padding(.horizontal, 10)
            } else {
                Group {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(launcher.apps, id: \.self) { url in
                                Button {
                                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                                    IslandState.shared.collapse()
                                } label: {
                                    VStack(spacing: 3) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                            .resizable().frame(width: 46, height: 46)
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .font(look.font(10)).foregroundStyle(look.secondary)
                                            .lineLimit(1).frame(width: 60)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Remove") { launcher.remove(url) } }
                                .help("Open \(url.deletingPathExtension().lastPathComponent). Right-click to remove.")
                            }
                            Button { launcher.pick() } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(look.secondary)
                                    .frame(width: 46, height: 46)
                                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(look.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                    .padding(.bottom, 16)
                            }
                            .buttonStyle(.plain)
                            .help("Add apps")
                            .accessibilityLabel("Add apps")
                        }
                        .frame(maxHeight: .infinity)
                    }
                    // The row runs out under a fade to near the island's edge; at rest it starts at the usual 14 pt.
                    .contentMargins(.horizontal, 10, for: .scrollContent)
                    .fadedEdges()
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }
}

// MARK: - Private tabs lock

/// Keeps Notes and Clipboard behind Touch ID (or the Mac's password) when the user asks for it.
final class PrivacyLock: ObservableObject {
    static let shared = PrivacyLock()
    /// How long the tabs stay open after unlocking.
    static let openFor: TimeInterval = 120

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "lockPrivateTabs")
            unlocked = false
        }
    }
    @Published private(set) var unlocked = false
    @Published private(set) var message: String?
    private var relock: DispatchWorkItem?

    private init() { enabled = UserDefaults.standard.bool(forKey: "lockPrivateTabs") }

    var isLocked: Bool { enabled && !unlocked }

    func unlock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "This Mac has no Touch ID or password to check."
            return
        }
        // Keep the island open while the system asks.
        IslandState.shared.authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open your notes and clipboard") { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                IslandState.shared.authenticating = false
                IslandState.shared.forcedOpen = true
                self.message = success ? nil : "Not unlocked."
                guard success else { return }
                self.unlocked = true
                self.relock?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.unlocked = false }
                self.relock = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.openFor, execute: work)
            }
        }
    }

    func lockNow() {
        relock?.cancel()
        unlocked = false
    }
}

/// Shows its content only once the private tabs are unlocked.
struct LockGate<Content: View>: View {
    @ObservedObject private var lock = PrivacyLock.shared
    let name: String
    @ViewBuilder var content: Content

    var body: some View {
        if lock.isLocked {
            IslandNotice(icon: "lock", title: "\(name) is locked.",
                         detail: lock.message ?? "Unlock with Touch ID or your Mac's password. It locks again after two minutes.",
                         button: "Unlock") { lock.unlock() }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        } else {
            content
        }
    }
}

// MARK: - Big now-playing screen

/// A full-screen view of what's playing: the cover, the time and the controls. Esc or a click closes it.
final class NowPlayingScreen {
    static let shared = NowPlayingScreen()
    private var window: NSWindow?
    /// The app that was in front, so closing hands the keyboard back to it.
    private var previousApp: NSRunningApplication?

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { NowPlayingScreen.shared.close() }
    }

    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard window == nil, let screen = NSScreen.main else { return }
        let window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.contentView = NSHostingView(rootView: NowPlayingView())
        window.alphaValue = 0
        self.window = window
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; window.animator().alphaValue = 1 }
        IslandState.shared.collapse()
    }

    func close() {
        guard let window else { return }
        self.window = nil
        if let previousApp, previousApp != .current { previousApp.activate() }
        previousApp = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; window.animator().alphaValue = 0 },
                                             completionHandler: { window.close() })
    }
}

private struct NowPlayingView: View {
    @ObservedObject private var media = MediaModule.shared

    var body: some View {
        ZStack {
            // The cover, blown up and blurred, fills the screen behind everything.
            if let artwork = media.artwork {
                GeometryReader { geo in
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 70)
                        .clipped()
                }
            }
            Color.black.opacity(media.artwork == nil ? 1 : 0.35)

            VStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 96, weight: .semibold, design: .serif))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white.opacity(0.92))
                }
                Artwork(size: 300)
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                VStack(spacing: 3) {
                    Text(media.hasTrack ? media.title : "Nothing playing")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(media.hasTrack ? media.artist : "Play something in Music, Spotify or a browser")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                ScrubBar().frame(width: 320)
                HStack(spacing: 34) {
                    MediaButton(icon: "backward.fill", label: "Previous track", size: 20) { media.previous() }
                    MediaButton(icon: media.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause", size: 28) { media.playPause() }
                    MediaButton(icon: "forward.fill", label: "Next track", size: 20) { media.next() }
                }
                .frame(height: 40)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { NowPlayingScreen.shared.close() }
        .overlay(alignment: .topTrailing) {
            Button { NowPlayingScreen.shared.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .padding(.top, 44).padding(.trailing, 20)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
        .environment(\.islandPalette, IslandPalette())
    }
}
