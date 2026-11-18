import SwiftUI
import AppKit

@main
struct QoLNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = PrompterModel.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarMenu(model: model, toggleListening: { delegate.toggleListening() })
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }

        Window("QoL Notch", id: "main") {
            ContentView(model: model, toggleListening: { delegate.toggleListening() })
                .frame(minWidth: 460, minHeight: 380)
        }
        .commands {
            MainWindowCommands()
            CommandGroup(replacing: .newItem) {
                Button("Import Note…") { NoteImporter.pick(into: model) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Reload Note") { try? model.reloadNote() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.sourcePath == nil || model.listening)
            }
            CommandMenu("Prompter") {
                Button(model.listening ? "Pause Listening" : "Start Listening") {
                    delegate.toggleListening()
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Restart from Top") { model.restart() }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                Picker("Mode", selection: $model.followMode) {
                    ForEach(FollowMode.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.listening)
                Button("Scroll Faster") { model.changeSpeed(by: 10) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(model.followMode != .auto)
                Button("Scroll Slower") { model.changeSpeed(by: -10) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.followMode != .auto)

                Divider()

                Button("Back One Word") { model.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward One Word") { model.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Back Ten Words") { model.step(-10) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Forward Ten Words") { model.step(10) }
                    .keyboardShortcut(.downArrow, modifiers: .command)

                Divider()

                Button(model.panelVisible ? "Hide Prompter" : "Show Prompter") {
                    model.panelVisible.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Snap to Notch") {
                    NotificationCenter.default.post(name: .qolSnapToNotch, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Detach from Notch") {
                    NotificationCenter.default.post(name: .qolFloat, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Island") {
                ForEach(Array(IslandTab.allCases.enumerated()), id: \.element) { index, tab in
                    if index < 9 {
                        Button("Open \(tab.title)") { IslandState.shared.open(tab) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button("Open \(tab.title)") { IslandState.shared.open(tab) }
                    }
                }
                Divider()
                Button("Play Welcome") { IslandState.shared.greet() }
                Button("Close Island") { IslandState.shared.collapse() }
                    .keyboardShortcut(.escape, modifiers: .command)
            }
        }
    }
}

/// A way back to the main window after it has been closed: Window menu, ⌘0 and the Dock icon.
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let show = {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        let _ = AppDelegate.showMainWindow = show
        CommandGroup(before: .windowArrangement) {
            Button("QoL Notch Window", action: show)
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the main window; set once the app's commands are built.
    static var showMainWindow: () -> Void = {}

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon brings the main window back even when only the island is showing.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { Self.showMainWindow() }
        return true
    }

    private let model = PrompterModel.shared
    private let tracker = SpeechTracker()
    private let scroller = AutoScroller()
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController(model: model)
        LockScreenMusic.shared.start()
        // The notch's own events: a meeting about to start.
        CalendarModule.shared.startReminders()
        PowerMonitor.shared.start()
        if IslandFeature.systemHUD.isOn { SystemHUD.shared.start() }
        // Start recording copies at launch, not only once the Clipboard tab has been opened.
        _ = ClipboardModule.shared

        // Say hello the first time QoL Notch runs.
        if !UserDefaults.standard.bool(forKey: "greeted") {
            UserDefaults.standard.set(true, forKey: "greeted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { IslandState.shared.greet() }
        }

        NotificationCenter.default.addObserver(forName: .qolToggleListening, object: nil, queue: .main) { [weak self] _ in
            self?.toggleListening()
        }
        tracker.onWords = { [weak self] words, transcript in self?.model.heard(words: words, transcript: transcript) }
        tracker.onStatus = { [weak self] status in self?.model.status = status }
        tracker.onRestart = { [weak self] in self?.model.recognitionRestarted() }
        tracker.onLevel = { level in VoiceLevel.shared.push(level) }
        tracker.onStopped = { [weak self] in
            self?.model.listening = false
            self?.model.sessionStopped()
        }

        // Stop by itself at the end of the script.
        NotificationCenter.default.addObserver(forName: .qolReachedEnd, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.model.listening, !self.scroller.isRunning else { return }
            self.tracker.stop()
            self.model.status = "Finished. See the Rehearse tab for how it went."
        }

        let remote = RemoteController.shared.server
        remote.stateProvider = { [weak self] in self?.model.remoteState() ?? [:] }
        remote.onCommand = { [weak self] action in
            guard let self else { return }
            switch action {
            case "toggle": self.toggleListening()
            case "faster": self.model.changeSpeed(by: 10)
            case "slower": self.model.changeSpeed(by: -10)
            case "restart": self.model.restart()
            case "back1": self.model.step(-1)
            case "fwd1": self.model.step(1)
            case "back10": self.model.step(-10)
            case "fwd10": self.model.step(10)
            case "smaller": self.model.setFontSize(self.model.theme.fontSize - 1)
            case "larger": self.model.setFontSize(self.model.theme.fontSize + 1)
            case "snap": NotificationCenter.default.post(name: .qolSnapToNotch, object: nil)
            default: break
            }
        }
    }

    func toggleListening() {
        if model.listening {
            if scroller.isRunning {
                scroller.stop()
                model.listening = false
                model.status = "Paused"
            } else {
                tracker.stop()
            }
        } else if model.followMode == .auto {
            // Auto Scroll: no microphone, and no rehearsal report, since the pace is set rather than spoken.
            model.listening = true
            IslandState.shared.pinned = true
            IslandState.shared.tab = .prompter
            model.status = "Scrolling at \(Int(model.autoSpeed)) words a minute"
            scroller.start(model) { [weak self] in
                self?.model.listening = false
                self?.model.status = "Finished."
            }
        } else {
            model.listening = true
            // Reading keeps the prompter open until you close it.
            IslandState.shared.pinned = true
            IslandState.shared.tab = .prompter
            model.status = "Starting…"
            model.activeLocaleID = model.effectiveLocaleID
            model.sessionStarted()
            tracker.start(localeID: model.activeLocaleID)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
