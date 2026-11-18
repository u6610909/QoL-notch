import AppKit
import SwiftUI
import Combine

/// A borderless panel that may sit above the menu bar. It only takes the keyboard
/// while the Notes tab is open, so typing a note works without stealing focus otherwise.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool {
        let island = IslandState.shared
        return island.browsing && island.tab == .notes && !island.greeting
    }
    override var canBecomeMain: Bool { false }

    // Allow the panel to be placed over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets buttons in the island respond to the first click even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the island's window. Docked, the window is a fixed transparent canvas at the top
/// of the screen and the island animates inside it; detached, it is a free resizable panel.
final class PanelController: NSObject, NSWindowDelegate {
    private let model: PrompterModel
    private let island = IslandState.shared
    private let panel: NotchPanel
    private var cancellables: Set<AnyCancellable> = []
    private var pointerTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var idleDragCount = NSPasteboard(name: .drag).changeCount
    private var dragWatch: Timer?
    private var dragOrigin = NSPoint.zero
    /// The drag started on the island or the screenshot thumbnail: something is being dragged out, not in.
    private var dragFromIsland = false

    private static let floatFrameKey = "floatFrame"
    private static let dockedKey = "docked"
    private static let canvas = NSSize(width: 760, height: 340)

    init(model: PrompterModel) {
        self.model = model
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 220, height: 90)
        panel.delegate = self

        let host = FirstMouseHostingView(rootView: PanelRoot(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        if UserDefaults.standard.object(forKey: Self.dockedKey) as? Bool ?? true {
            dock()
        } else {
            float()
        }

        model.$hideFromCapture
            .sink { [weak self] hide in self?.panel.sharingType = hide ? .none : .readOnly }
            .store(in: &cancellables)
        model.$panelVisible
            .sink { [weak self] visible in
                if visible { self?.panel.orderFrontRegardless() } else { self?.panel.orderOut(nil) }
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(dockRequested), name: .qolSnapToNotch, object: nil)
        center.addObserver(self, selector: #selector(floatRequested), name: .qolFloat, object: nil)
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Follow the pointer: the canvas only takes clicks while the pointer is over the island.
        // Mouse movement is followed as it happens, so the island answers without a visible lag.
        // The slow timer only catches what events miss: a drag in progress, or the island resizing under a still pointer.
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: moved) { [weak self] _ in self?.trackPointer() } as Any,
            NSEvent.addLocalMonitorForEvents(matching: moved) { [weak self] event in
                self?.trackPointer()
                return event
            } as Any,
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseWentDown() } as Any,
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.mouseWentDown()
                return event
            } as Any,
        ]
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.trackPointer()
        }
    }

    /// The screen with a camera notch if there is one, otherwise the main screen.
    static func notchScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    @objc private func dockRequested() { dock() }
    @objc private func floatRequested() { float() }
    @objc private func screensChanged() { if model.docked { dock() } }

    private func applyLevel() {
        // Set after style changes, which can reset the level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    }

    func dock() {
        let screen = Self.notchScreen()
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            island.notchWidth = screen.frame.width - left.width - right.width
        } else {
            island.notchWidth = 180
        }
        island.inset = max(screen.safeAreaInsets.top, 28)

        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        applyLevel()
        panel.setFrame(
            NSRect(x: screen.frame.midX - Self.canvas.width / 2,
                   y: screen.frame.maxY - Self.canvas.height,
                   width: Self.canvas.width, height: Self.canvas.height),
            display: true
        )
        if !model.docked { model.docked = true }
        UserDefaults.standard.set(true, forKey: Self.dockedKey)
        trackPointer()
    }

    func float() {
        expandWork?.cancel(); collapseWork?.cancel()
        island.pointerLeft()
        panel.styleMask = [.borderless, .nonactivatingPanel, .resizable]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = false
        applyLevel()

        let screen = Self.notchScreen()
        var frame = NSRect(x: screen.frame.midX - 235, y: screen.frame.maxY - 260, width: 470, height: 150)
        if let saved = UserDefaults.standard.string(forKey: Self.floatFrameKey) {
            let restored = NSRectFromString(saved)
            if restored.width >= 220, restored.height >= 90,
               NSScreen.screens.contains(where: { $0.frame.intersects(restored) }) {
                frame = restored
            }
        }
        if model.docked { model.docked = false }
        UserDefaults.standard.set(false, forKey: Self.dockedKey)
        panel.setFrame(frame, display: true)
    }

    /// Where the island currently is on screen, in screen coordinates.
    private func islandRect() -> NSRect {
        let screen = Self.notchScreen()
        let size = island.size(
            listening: model.listening,
            hasActivity: IslandView.hasActivity(timer: .shared, media: .shared)
        )
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: A file drag anywhere

    /// Mouse-move events are not delivered during another app's drag, so while the button is down a short poll watches.
    private func mouseWentDown() {
        dragOrigin = NSEvent.mouseLocation
        dragFromIsland = islandRect().insetBy(dx: -3, dy: -3).contains(dragOrigin) || ScreenshotDrop.shared.contains(dragOrigin)
        idleDragCount = NSPasteboard(name: .drag).changeCount
        guard dragWatch == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.watchDrag() }
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    private func watchDrag() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        guard down else {
            dragWatch?.invalidate()
            dragWatch = nil
            if island.dragOpen {
                // Give SwiftUI's onDrop a moment to run before deciding where the file went.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [island] in
                    island.endDragOpen(landed: Date().timeIntervalSince(island.lastDropAt) < 1)
                }
            }
            return
        }
        // Keep the window ready to accept the drop before the pointer arrives.
        defer { trackPointer() }
        guard IslandFeature.shelfOnDrag.isOn, model.docked, model.panelVisible, !island.dragOpen, !dragFromIsland else { return }
        // Only the types are read from the drag pasteboard, never its contents.
        let board = NSPasteboard(name: .drag)
        let here = NSEvent.mouseLocation
        guard board.changeCount != idleDragCount, board.types?.contains(.fileURL) == true,
              hypot(here.x - dragOrigin.x, here.y - dragOrigin.y) >= 8 else { return }
        island.beginDragOpen()
    }

    private func trackPointer() {
        guard model.docked, model.panelVisible else { return }
        let inside = islandRect().insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        // A file being dragged to the notch opens the island on the shelf. Dragging a clip or a file out of
        // the island does not.
        let dragBoard = NSPasteboard(name: .drag)
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1
        if !buttonDown { idleDragCount = dragBoard.changeCount }
        if inside, buttonDown, !dragFromIsland, dragBoard.changeCount != idleDragCount,
           dragBoard.types?.contains(.fileURL) == true, island.tab != .shelf || !island.hovering {
            island.tab = .shelf
            island.hovering = true
        }

        if inside {
            collapseWork?.cancel(); collapseWork = nil
            if !island.hovering && expandWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.expandWork = nil
                    self?.island.hovering = true
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.openDwell, execute: work)
            }
        } else {
            expandWork?.cancel(); expandWork = nil
            if island.hovering && collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.collapseWork = nil
                    self?.island.pointerLeft()
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.closeGrace, execute: work)
            }
        }
    }

    func windowDidMove(_ notification: Notification) { saveFloatFrame() }
    func windowDidResize(_ notification: Notification) { saveFloatFrame() }

    private func saveFloatFrame() {
        guard !model.docked else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.floatFrameKey)
    }
}
