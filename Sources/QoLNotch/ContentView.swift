import SwiftUI

/// The main window: write the script, shape the look, and control the prompter.
struct ContentView: View {
    @ObservedObject var model: PrompterModel
    var toggleListening: () -> Void
    @State private var tab = Tab.script

    private enum Tab: String, CaseIterable, Identifiable {
        case script = "Script"
        case rehearse = "Rehearse"
        case remote = "Remote"
        case theme = "Theme"
        case island = "Island"
        var id: String { rawValue }
    }

    private let languages: [(id: String, name: String)] = [
        ("auto", "Auto (match script)"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("th-TH", "ไทย"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 460)
            .padding(.top, 10)
            .padding(.bottom, 6)

            switch tab {
            case .script:
                HStack(spacing: 10) {
                    Button {
                        NoteImporter.pick(into: model)
                    } label: {
                        Label("Import Note…", systemImage: "square.and.arrow.down")
                    }
                    if let name = model.sourceName {
                        Button {
                            do { try model.reloadNote() }
                            catch { model.status = "Could not reload \(name): \(error.localizedDescription)" }
                        } label: {
                            Label("Reload \(name)", systemImage: "arrow.clockwise")
                        }
                    }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .disabled(model.listening)
                TextEditor(text: $model.text)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .disabled(model.listening)
                    .help("The language QoL Notch listens for. Auto picks Thai or English from your script.")
            case .rehearse:
                RehearseView(model: model)
            case .theme:
                ThemeView(model: model)
            case .island:
                IslandSettingsView()
            case .remote:
                RemoteView()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: toggleListening) {
                        Label(model.listening ? "Pause" : "Start",
                              systemImage: model.listening ? "pause.fill" : model.followMode.startIcon)
                            .frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.listening ? .orange : .accentColor)

                    Button {
                        model.restart()
                    } label: {
                        Label("Restart", systemImage: "arrow.counterclockwise")
                    }

                    Picker("Mode", selection: $model.followMode) {
                        ForEach(FollowMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(model.listening)
                    .help("Voice Follow moves the script as you speak. Auto Scroll moves it on its own at the speed you set.")

                    if model.followMode == .voice {
                        Picker("Language", selection: $model.localeID) {
                            ForEach(languages, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 190)
                        .disabled(model.listening)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                            Slider(value: $model.autoSpeed, in: AutoScroller.speedRange, step: 5)
                                .frame(width: 130)
                                .accessibilityLabel("Scroll speed")
                                .accessibilityValue("\(Int(model.autoSpeed)) words a minute")
                            Image(systemName: "hare.fill").foregroundStyle(.secondary)
                            Text("\(Int(model.autoSpeed)) wpm")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                        }
                        .help("How fast the script moves, in words a minute. Most people speak at 130 to 160. Change it while it runs with ⌘+ and ⌘−.")
                    }

                    Spacer()

                    Text(progressText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    Toggle("Hide from screen sharing", isOn: $model.hideFromCapture)
                        .help("Keeps the island out of screen shares, recordings and screenshots, so only you see it.")
                    Toggle("Show island", isOn: $model.panelVisible)
                        .help("Shows or hides the island at the notch.")
                    Spacer()
                    Button(model.docked ? "Detach from Notch" : "Snap to Notch") {
                        NotificationCenter.default.post(name: model.docked ? .qolFloat : .qolSnapToNotch, object: nil)
                    }
                    .help("Detach to get a free panel you can drag anywhere and resize. Snap puts it back at the notch.")
                }

                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(14)
        }
    }

    private var progressText: String {
        "\(min(model.current, model.words.count)) / \(model.words.count) words"
    }
}

import AppKit
import UniformTypeIdentifiers

/// Lets the user pick a Markdown note, starting in their Obsidian vault when one is found.
enum NoteImporter {
    static func pick(into model: PrompterModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a note to use as your script"
        if let vault = ObsidianVaults.mostRecent() { panel.directoryURL = vault }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importNote(from: url)
            model.status = "Imported \(url.lastPathComponent)"
        } catch {
            model.status = "Could not read that note: \(error.localizedDescription)"
        }
    }
}
