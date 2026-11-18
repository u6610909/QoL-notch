import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Theme tab: a live preview, one-click themes, two colours and the script's typeface.
struct ThemeView: View {
    @ObservedObject var model: PrompterModel
    @ObservedObject private var look = IslandLook.shared
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ring
    @State private var naming = false
    @State private var newName = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            ThemePreview(model: model)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            Form {
                themes
                colours
                script
                Section {
                    Button("Reset to Midnight Blue") { model.resetTheme(undo: undoManager) }
                        .disabled(model.theme.name == Theme.midnightBlue.name && model.theme.sameLook(as: .midnightBlue))
                        .help("Go back to the look QoL Notch starts with. Your saved themes are kept.")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { model.loadUserThemes() }
        .alert("Save Theme", isPresented: $naming) {
            TextField("Theme name", text: $newName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved themes appear beside the built-in ones. Saving under the same name replaces the earlier one.")
        }
    }

    // MARK: Themes

    private var themes: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 10)], spacing: 10) {
                ForEach(model.allThemes) { theme in
                    ThemeSwatch(theme: theme, selected: theme.name == model.theme.name, ring: ring) {
                        model.apply(theme, undo: undoManager)
                    }
                    .contextMenu {
                        if model.isUserTheme(theme.name) {
                            Button("Move to Trash", role: .destructive) { model.deleteUserTheme(named: theme.name) }
                        }
                    }
                    .help(model.isUserTheme(theme.name) ? "Right-click to move this theme to the Trash." : "")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.vertical, 4)
            .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.tab, value: model.theme.name)
            .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.quick, value: model.userThemes.map(\.name))

            HStack {
                Button("Save Theme…") {
                    newName = model.isUserTheme(model.theme.name) ? model.theme.name : ""
                    naming = true
                }
                .help("Keep the current colours and font as a theme of your own.")
                Button("Import…", action: importTheme)
                    .help("Open a .qoltheme file someone shared with you.")
                Button("Export…", action: exportTheme)
                    .help("Save the current theme as a small file you can share.")
                Spacer()
                Button("Show in Finder") {
                    let dir = PrompterModel.themesDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .help("Open the folder where your saved themes are kept.")
            }
            .controlSize(.small)
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Themes")
        } footer: {
            Text("A theme sets the accent colour, the glow and the script's text. The island itself always stays black.")
        }
    }

    // MARK: Colours

    private var colours: some View {
        Section {
            ColorPicker("Accent", selection: colourBinding(\.accent), supportsOpacity: false)
                .help("The colour of the word you are on, and of buttons, bars and the selected tool in the island.")
            if model.theme.accentWasLifted {
                Text("Shown a little lighter so it stays easy to read on black.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            LabeledContent("Glow") {
                HStack(spacing: 10) {
                    Button("Match Accent") {
                        var matched = model.theme
                        matched.glowColour = matched.accent
                        model.apply(matched, undo: undoManager, actionName: "Match Accent")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.theme.glowColour.near(model.theme.accent))
                    ColorPicker("Glow", selection: colourBinding(\.glowColour), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            .help("The soft light at the bottom of the island. It brightens with your voice while you read.")
            Picker("Glow behind tools", selection: $look.glow) {
                ForEach(IslandLook.Glow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("The light behind Home, Music and the other tools.")
        } header: {
            Text("Colours")
        } footer: {
            Text("The glow always shows while you read a script. Album cover borrows its colour from the music that is playing.")
        }
        .animation(IslandMotion.confirm, value: model.theme.accentWasLifted)
    }

    /// Colours write straight to the theme while the picker is dragged, so everything follows the hand.
    private func colourBinding(_ keyPath: WritableKeyPath<Theme, RGBA>) -> Binding<Color> {
        Binding(
            get: { model.theme[keyPath: keyPath].color },
            set: { new in
                var colour = RGBA(new)
                colour.a = 1
                model.theme[keyPath: keyPath] = colour
            })
    }

    // MARK: Script text

    private var script: some View {
        Section {
            Picker("Font", selection: $model.theme.font) {
                ForEach(FontChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("The typeface your script is shown in.")
            LabeledContent("Size") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { model.theme.fontSize }, set: { model.setFontSize($0) }),
                           in: Theme.sizeRange, step: 1) {
                        Text("Size")
                    } minimumValueLabel: {
                        Text("A").font(.system(size: 11))
                    } maximumValueLabel: {
                        Text("A").font(.system(size: 17))
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .accessibilityValue("\(Int(model.theme.fontSize)) points")
                    Text("\(Int(model.theme.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .help("Bigger text is easier to read from further away, but shows fewer words at once.")
        } header: {
            Text("Script text")
        } footer: {
            Text("You can also change the size from the phone remote.")
        }
    }

    // MARK: Files

    private var themeType: UTType { UTType(filenameExtension: ThemeFiles.fileExtension) ?? .json }

    private func save() {
        do {
            try model.saveCurrentTheme(named: newName)
            errorText = nil
        } catch let error as ThemeError {
            errorText = error.localizedDescription
        } catch {
            errorText = "Could not save the theme: \(error.localizedDescription)"
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [themeType, .json]
        panel.message = "Choose a theme file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importTheme(from: url, undo: undoManager)
            errorText = nil
        } catch {
            errorText = ThemeError.notATheme.localizedDescription
        }
    }

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [themeType]
        panel.nameFieldStringValue = model.theme.name + "." + ThemeFiles.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportTheme(to: url)
            errorText = nil
        } catch {
            errorText = "Could not export the theme: \(error.localizedDescription)"
        }
    }
}

/// A small black island showing the theme's accent, glow and script font, pinned above the settings.
private struct ThemePreview: View {
    @ObservedObject var model: PrompterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = model.theme
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))

            GeometryReader { geo in
                let width = min(geo.size.width - 48, 420)
                island(theme)
                    .frame(width: width, height: 118)
                    .clipShape(NotchShape(ear: 8, radius: 18))
                    .position(x: geo.size.width / 2, y: 59)
            }

            VStack {
                Spacer()
                Text(model.themeIsEdited ? "\(theme.name) · Edited" : theme.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.bottom, 6)
            }
        }
        .frame(height: 150)
        .environment(\.islandPalette, IslandPalette(theme))
        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.theme, value: model.themeSwitchID)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue("\(theme.name) theme. Accent and glow shown on the island with a line of script.")
    }

    private func island(_ theme: Theme) -> some View {
        ZStack {
            Color.black
            AuraView(colour: theme.glowColour, strength: 1, listening: false)
                .id(model.themeSwitchID)
                .transition(.opacity)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "text.alignleft").foregroundStyle(theme.readableAccent)
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.62))
                    Image(systemName: "timer").foregroundStyle(.white.opacity(0.62))
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(height: 26)
                .padding(.top, 6)

                Spacer(minLength: 0)
                scriptLine(theme)
                    .id(theme.font)
                    .transition(reduceMotion ? .opacity : .focus(4))
                    .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.quick, value: theme.font)
                Spacer(minLength: 0)

                HStack {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(theme.readableAccent).frame(width: 64 * 0.6)
                    }
                    .frame(width: 64, height: 4)
                    Spacer()
                    Button("Start") {}
                        .buttonStyle(IslandChipStyle(prominent: true))
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
            }
        }
    }

    /// One line of script at the real size, so the slider is honest.
    private func scriptLine(_ theme: Theme) -> some View {
        HStack(spacing: theme.fontSize * 0.55) {
            Text("It").foregroundStyle(Theme.text.opacity(Theme.spokenOpacity))
            Text("follows").foregroundStyle(Theme.text.opacity(Theme.spokenOpacity))
            Text("your").foregroundStyle(theme.readableAccent)
            Text("voice").foregroundStyle(Theme.text)
        }
        .font(theme.swiftFont)
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity)
        .fadedEdges(.horizontal, length: 18)
    }
}

/// One theme as a small black tile: its glow, and "Aa" in its accent and typeface.
private struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let ring: Namespace.ID
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                    Ellipse()
                        .fill(theme.glowColour.color.opacity(0.8))
                        .frame(width: 60, height: 30)
                        .blur(radius: 8)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .offset(y: 15)
                    Text("Aa")
                        .font(theme.font(size: 17))
                        .foregroundStyle(theme.readableAccent)
                }
                .frame(width: 84, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(contrast == .increased ? 0.3 : 0.14), lineWidth: 0.5))
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(theme.readableAccent, lineWidth: 2)
                            .padding(-3)
                            .modifier(RingMatch(ring: ring, enabled: !reduceMotion))
                            .transition(.opacity)
                    }
                }

                Text(theme.name)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SwatchPress())
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityHint("Changes the accent, glow and script font.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The selection ring slides between swatches; with Reduce Motion it only fades.
private struct RingMatch: ViewModifier {
    let ring: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.matchedGeometryEffect(id: "ring", in: ring) } else { content }
    }
}

private struct SwatchPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(IslandMotion.quick, value: configuration.isPressed)
    }
}
