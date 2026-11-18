import SwiftUI

enum IslandTab: String, CaseIterable, Identifiable {
    case prompter, home, media, calendar, mirror, notes, timer, clipboard, shelf, apps
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .prompter: "text.alignleft"
        case .home: "square.grid.2x2"
        case .media: "music.note"
        case .calendar: "calendar"
        case .mirror: "person.crop.square"
        case .notes: "square.and.pencil"
        case .shelf: "tray"
        case .timer: "timer"
        case .clipboard: "doc.on.clipboard"
        case .apps: "square.grid.3x3"
        }
    }
}

/// What the island at the notch is showing: resting inside the notch, or grown open on a tab.
final class IslandState: ObservableObject {
    static let shared = IslandState()

    @Published var tab: IslandTab {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "islandTab")
            showingMore = false
            guard tab != oldValue else { return }
            // Later tools slide in from the right, earlier ones from the left.
            let order = pinnedTabs + moreTabs
            tabDirection = (order.firstIndex(of: tab) ?? 0) >= (order.firstIndex(of: oldValue) ?? 0) ? 1 : -1
            if browsing { Haptics.tap() }
        }
    }
    /// Which way the last tab change went: 1 towards later tools, -1 towards earlier ones.
    private(set) var tabDirection: CGFloat = 1
    /// The pointer is over the island.
    @Published var hovering = false {
        didSet {
            if hovering && !oldValue { Haptics.tap() }
            peekBlockChanged()
        }
    }
    /// Opened from the menu or a shortcut; stays open until the pointer has visited and left.
    @Published var forcedOpen = false { didSet { peekBlockChanged() } }
    /// The prompter stays open even when the pointer is elsewhere.
    @Published var pinned = false { didSet { peekBlockChanged() } }
    /// The user is typing in the island, so it must stay open and may take the keyboard.
    @Published var editing = false { didSet { peekBlockChanged() } }
    /// A Touch ID prompt is up; the island waits open behind it.
    @Published var authenticating = false { didSet { peekBlockChanged() } }
    /// The few tools that sit beside the notch, in order. The prompter is always one of them.
    @Published var pinnedTabs: [IslandTab] = IslandState.savedPins() {
        didSet { UserDefaults.standard.set(pinnedTabs.map(\.rawValue), forKey: "pinnedTabs") }
    }
    static let maxPinned = 6
    static let defaultPins: [IslandTab] = [.prompter, .home, .media, .calendar, .notes, .timer]
    /// Every tool that is not pinned; these open from the More view.
    var moreTabs: [IslandTab] { IslandTab.allCases.filter { !pinnedTabs.contains($0) } }
    /// The More view is showing in place of a tab.
    @Published var showingMore = false

    /// Moves a pinned tool one place earlier or later in the strip.
    func movePinned(_ tab: IslandTab, by step: Int) {
        guard let index = pinnedTabs.firstIndex(of: tab), pinnedTabs.indices.contains(index + step) else { return }
        pinnedTabs.swapAt(index, index + step)
    }

    private static func savedPins() -> [IslandTab] {
        guard let saved = UserDefaults.standard.stringArray(forKey: "pinnedTabs") else { return defaultPins }
        var pins = saved.compactMap(IslandTab.init(rawValue:))
        if !pins.contains(.prompter) { pins.insert(.prompter, at: 0) }
        return Array(pins.prefix(maxPinned))
    }

    /// Pins or unpins a tool. The prompter stays, and no more than six fit.
    func setPinned(_ tab: IslandTab, _ pinned: Bool) {
        if pinned {
            guard !pinnedTabs.contains(tab), pinnedTabs.count < Self.maxPinned else { return }
            pinnedTabs.append(tab)
        } else if tab != .prompter {
            pinnedTabs.removeAll { $0 == tab }
        }
    }
    // MARK: Dragging a file

    private var tabBeforeDrag: IslandTab?
    /// When a file was last dropped on the island, to tell a drop here from one elsewhere.
    private(set) var lastDropAt = Date.distantPast

    /// A file drag began somewhere on screen: open on the Shelf as a place to drop it.
    func beginDragOpen() {
        // Same rule as peeks: not while reading, typing, or already open.
        guard !dragOpen, canPeek else { return }
        tabBeforeDrag = tab
        tab = .shelf
        dragOpen = true
        Haptics.tap()
    }

    /// The drag ended. `landed`: it was dropped on the island.
    func endDragOpen(landed: Bool) {
        guard dragOpen else { return }
        dragOpen = false
        dropTargeted = false
        if landed {
            tabBeforeDrag = nil
            // The island stays on the Shelf (the drop opened it there); close it shortly if the pointer has left.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, !self.hovering, !self.editing else { return }
                self.forcedOpen = false
            }
        } else if let back = tabBeforeDrag {
            tabBeforeDrag = nil
            // Put the old tab back once the island has closed, so nothing switches on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.browsing else { return }
                self.tab = back
            }
        }
    }

    /// A file was dropped on the island.
    func noteDrop() { lastDropAt = Date() }

    /// The welcome animation is playing.
    @Published var greeting = false { didSet { peekBlockChanged() } }
    /// Width of the physical notch and height of the menu bar strip beside it.
    @Published var notchWidth: CGFloat = 185
    @Published var inset: CGFloat = 32

    private init() {
        tab = IslandTab(rawValue: UserDefaults.standard.string(forKey: "islandTab") ?? "") ?? .prompter
    }

    /// Size of the curve that flares the open island into the top screen edge.
    var ear: CGFloat { min(max(inset, 26), 36) }
    static let collapsedEar: CGFloat = 6
    /// How far the resting island reaches below the notch, so its bottom edge shows as a clean line.
    static let restingOverhang: CGFloat = 2
    /// Extra width on each side of the notch when a live activity is showing.
    static let activityWidth: CGFloat = 62

    func isExpanded(listening: Bool) -> Bool {
        hovering || forcedOpen || pinned || listening || editing || authenticating || dragOpen
    }

    /// The pointer is on the island, or it was opened on purpose: tabs and controls show.
    var browsing: Bool { hovering || forcedOpen || editing || authenticating || dragOpen }

    /// The tab on show. While only pinned or listening, that is always the prompter.
    var shownTab: IslandTab { browsing ? tab : .prompter }

    func size(listening: Bool, hasActivity: Bool) -> CGSize {
        guard isExpanded(listening: listening) else {
            if let peek {
                return CGSize(width: notchWidth + Self.collapsedEar * 2 + Self.peekWidth * 2,
                              height: inset + Self.restingOverhang + (peek.detail == nil ? 0 : Self.peekDetailHeight))
            }
            let width = notchWidth + Self.collapsedEar * 2 + (hasActivity ? Self.activityWidth * 2 : 0)
            return CGSize(width: width, height: inset + Self.restingOverhang)
        }
        // Browsing needs room for the tab icons beside the notch; reading alone stays narrower.
        let width = browsing ? Self.browsingWidth(notch: notchWidth) : prompterWidth
        return CGSize(width: width, height: inset + (shownTab == .prompter ? 118 : 132))
    }

    /// Width of the island while only the script is showing. The script keeps this width when browsing too.
    var prompterWidth: CGFloat { max(notchWidth + 290, 470) }

/// Room for three tools, More and two controls on each side of the notch.
    static func browsingWidth(notch: CGFloat) -> CGFloat { max(notch + 420, 600) }

    func open(_ tab: IslandTab) {
        self.tab = tab
        forcedOpen = true
    }

    func collapse() {
        forcedOpen = false
        hovering = false
        pinned = false
        editing = false
        greeting = false
        showingMore = false
        dragOpen = false
        dropTargeted = false
    }

    /// Called when the pointer leaves: fall back to the prompter if it should stay open.
    func pointerLeft() {
        hovering = false
        if !greeting { forcedOpen = false }
    }

    /// Plays the welcome: the island opens, the wordmark writes itself, then it settles on the Home tab.
    /// Counts welcomes, so playing it again restarts it and the earlier run's timers do nothing.
    @Published private(set) var greetRun = 0

    func greet() {
        greetRun += 1
        let run = greetRun
        greeting = true
        forcedOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + WelcomeView.length + 0.5) { [weak self] in
            guard let self, self.greeting, self.greetRun == run else { return }
            self.tab = .home
            self.greeting = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.greetRun == run, !self.greeting, !self.hovering, !self.editing else { return }
                self.forcedOpen = false
            }
        }
    }

    // MARK: Peeks

    /// The message showing in the resting notch, if any.
    @Published private(set) var peek: Peek?
    /// True for 0.4 s after a peek ends, so the notch settles with peekOut rather than the open spring.
    @Published private(set) var peekSettling = false
    /// A file is being dragged somewhere on screen and the island opened to catch it.
    @Published var dragOpen = false { didSet { peekBlockChanged() } }
    /// A dragged file is over the island.
    @Published var dropTargeted = false
    private var peeks = PeekQueue()
    private var peekTimer: DispatchWorkItem?
    /// Whether peeks were blocked when last checked, to notice the moment they are allowed again.
    private var peekWasBlocked = false

    /// Room each side of the notch while a peek shows, and the height of its optional line underneath.
    static let peekWidth: CGFloat = 96
    static let peekDetailHeight: CGFloat = 24

    /// Nothing may peek while the island is open, the user is typing, reading the prompter, or the welcome plays.
    var canPeek: Bool {
        let prompter = PrompterModel.shared
        return !(hovering || forcedOpen || pinned || editing || authenticating || greeting || dragOpen
                 || prompter.listening || !prompter.docked || !prompter.panelVisible)
    }

    /// Shows a peek now, updates the one showing, or lets it wait. Main thread only.
    func post(_ peek: Peek) {
        switch peeks.post(peek, now: Date(), blocked: !canPeek) {
        case .show:
            withAnimation(IslandMotion.peekIn) { self.peek = peeks.current }
            schedulePeekEnd()
        case .update:
            // No transition: the bar animates itself, and the restarted clock keeps it up while keys are held.
            self.peek = peeks.current
            schedulePeekEnd()
        case .queued, .dropped:
            break
        }
    }

    /// The current peek's time is up: show the next one waiting, or settle back.
    func endPeek() {
        peekTimer?.cancel()
        let next = peeks.finish(now: Date(), blocked: !canPeek)
        if let next {
            withAnimation(IslandMotion.peekIn) { peek = next }
            schedulePeekEnd()
        } else if peek != nil {
            peekSettling = true
            withAnimation(IslandMotion.peekOut) { peek = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.peekSettling = false }
        }
    }

    private func schedulePeekEnd() {
        peekTimer?.cancel()
        guard let duration = peek?.duration else { return }
        let work = DispatchWorkItem { [weak self] in self?.endPeek() }
        peekTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The island opened or closed, or the user started or stopped typing: end or resume peeks.
    private func peekBlockChanged() {
        let blocked = !canPeek
        defer { peekWasBlocked = blocked }
        if blocked {
            // The island is opening over it, so no animation is needed.
            if peek != nil {
                peekTimer?.cancel()
                peeks.suspend()
                peek = nil
            }
            ScreenshotDrop.shared.dismiss()
        } else if peekWasBlocked {
            // Wait for the close spring, then show anything that waited.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.peek == nil, self.canPeek else { return }
                self.endPeek()
            }
        }
    }
}
