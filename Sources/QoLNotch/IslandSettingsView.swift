import SwiftUI

/// Settings for the island itself: how it looks, what Home shows, and which tools sit by the notch.
struct IslandSettingsView: View {
    @ObservedObject private var look = IslandLook.shared
    @ObservedObject private var island = IslandState.shared
    @ObservedObject private var weather = WeatherModule.shared
    @ObservedObject private var clipboard = ClipboardModule.shared
    @ObservedObject private var lock = PrivacyLock.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("clockStyle") private var clockStyle = ClockStyle.plain
    @AppStorage("dailyLine") private var showLine = true
    @AppStorage("dailyLineText") private var ownLine = ""
    @AppStorage("vinylArtwork") private var vinyl = true
    @AppStorage("timerChime") private var chime = "Glass"
    @AppStorage(Haptics.settingKey) private var haptics = true
    @AppStorage(LockScreenMusic.settingKey) private var lockScreenMusic = false
    @AppStorage(IslandFeature.eventPeeks.rawValue) private var eventPeeks = true
    @AppStorage(IslandFeature.batteryPeeks.rawValue) private var batteryPeeks = true
    @AppStorage(IslandFeature.systemHUD.rawValue) private var systemHUD = false
    @AppStorage(IslandFeature.hideSystemHUD.rawValue) private var hideSystemHUD = true
    @State private var keysTrusted = MediaKeyTap.isTrusted
    @AppStorage(IslandFeature.tonearm.rawValue) private var tonearm = true
    @AppStorage(IslandFeature.screenshotDrop.rawValue) private var screenshotDrop = true
    @AppStorage(IslandFeature.shelfOnDrag.rawValue) private var shelfOnDrag = true
    @AppStorage(IslandFeature.lockScreenLargeCover.rawValue) private var largeCover = true
    @State private var city = WeatherModule.shared.city

    var body: some View {
        Form {
            Section {
                ForEach(HomeSlot.allCases) { slot in
                    let index = look.homeSlots.firstIndex(of: slot)
                    HStack {
                        Toggle(isOn: Binding(get: { index != nil }, set: { look.setSlot(slot, $0) })) {
                            Label(slot.title, systemImage: slot.icon)
                        }
                        .disabled(index == nil && look.homeSlots.count >= IslandLook.maxSlots)
                        Spacer()
                        // The arrows keep their space when hidden, so the switches line up.
                        order(first: index == 0, last: index == look.homeSlots.count - 1, name: slot.title) {
                            look.moveSlot(slot, by: $0)
                        }
                        .opacity(index == nil ? 0 : 1)
                        .disabled(index == nil)
                    }
                }
                if look.homeSlots.contains(.clock) {
                    Picker("Clock numbers", selection: $clockStyle) {
                        ForEach(ClockStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if look.homeSlots.contains(.weather) {
                    TextField("Weather city", text: $city, prompt: Text("Bangkok"))
                        .onSubmit { weather.city = city }
                        .help("Type your city and press Return. Only the city name is sent, to Open-Meteo.")
                    if let error = weather.error { Text(error).font(.callout).foregroundStyle(.red) }
                }
                if look.homeSlots.contains(.agenda) {
                    Toggle("Show a daily line", isOn: $showLine)
                    if showLine {
                        TextField("Your own line", text: $ownLine, prompt: Text("Leave empty for a new line each day"))
                    }
                }
            } header: { Text("Home") } footer: { Text("Up to three widgets, left to right in this order.") }

            Section {
                ForEach(IslandTab.allCases) { tab in
                    let index = island.pinnedTabs.firstIndex(of: tab)
                    HStack {
                        Toggle(isOn: Binding(get: { index != nil }, set: { island.setPinned(tab, $0) })) {
                            Label(tab.title, systemImage: tab.icon)
                        }
                        .disabled(tab == .prompter || (index == nil && island.pinnedTabs.count >= IslandState.maxPinned))
                        Spacer()
                        order(first: index == 0, last: index == island.pinnedTabs.count - 1, name: tab.title) {
                            island.movePinned(tab, by: $0)
                        }
                        .opacity(index == nil ? 0 : 1)
                        .disabled(index == nil)
                    }
                }
            } header: { Text("Tools beside the notch") } footer: {
                Text("Up to six. The first half sit left of the notch, the rest to the right. The others open from More.")
            }

            Section {
                Toggle("Tell me about timers, events and the Shelf", isOn: $eventPeeks)
                    .help("The notch widens briefly when a timer ends, a calendar event is a minute away, or a file lands on the Shelf.")
                // A Mac without a battery has nothing to show here.
                if StatsModule.batteryState().0 != nil {
                    Toggle("Show charging and low battery", isOn: $batteryPeeks)
                        .help("Plugging in shows the battery level for a moment. You are warned once at 20% and once at 10%.")
                }
                Toggle("Drop new screenshots from the notch", isOn: $screenshotDrop)
                    .help("A new screenshot hangs under the notch for a few seconds. Click it to copy, or drag it into an app. macOS may ask once to let QoL Notch read the folder screenshots are saved in.")
                    .onChange(of: screenshotDrop) { _, _ in ClipboardModule.shared.refreshWatching() }
                Toggle("Open the Shelf when I drag a file", isOn: $shelfOnDrag)
                    .help("As soon as you start dragging a file anywhere, the notch opens as a place to drop it. Off: it opens only when you drag a file up to the notch.")
                Toggle("Show volume and brightness in the notch", isOn: $systemHUD)
                    .help("The notch widens and a bar follows the volume and brightness keys.")
                    .onChange(of: systemHUD) { _, on in on ? SystemHUD.shared.start() : SystemHUD.shared.stop() }
                if systemHUD {
                    Toggle("Hide the macOS indicator", isOn: $hideSystemHUD)
                        .help("QoL Notch handles the volume and brightness keys itself, so macOS doesn't show its own bar on top. Needs the Accessibility permission. Keys it can't handle (like HDMI audio) still go to macOS.")
                        .onChange(of: hideSystemHUD) { _, _ in SystemHUD.shared.refreshKeyTap() }
                    if hideSystemHUD && !keysTrusted {
                        HStack {
                            Text("Needs Accessibility permission")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Allow…") {
                                MediaKeyTap.askForPermission()
                                MediaKeyTap.openAccessibilitySettings()
                            }
                        }
                        .task {
                            // Notice the moment the permission is granted, and start right away.
                            while !Task.isCancelled && !MediaKeyTap.isTrusted {
                                try? await Task.sleep(for: .seconds(1))
                            }
                            keysTrusted = MediaKeyTap.isTrusted
                            SystemHUD.shared.refreshKeyTap()
                        }
                    }
                }
            } header: { Text("Notch events") } footer: {
                Text("The notch widens for a moment to tell you something, then settles back. It never interrupts while you are reading a script or typing.")
            }

            Section("Tools") {
                Toggle("Show the cover as a spinning record", isOn: $vinyl)
                Toggle("Show the tonearm on the record", isOn: $tonearm)
                    .disabled(!vinyl)
                    .help("The arm swings onto the record when music plays and lifts when it pauses.")
                Picker("Timer sound", selection: $chime) {
                    ForEach(TimerModule.chimes, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: chime) { _, _ in TimerModule.playChime() }
                Toggle("Remember what I copy", isOn: $clipboard.enabled)
                    .help("Keeps the last 30 things you copy, text and screenshots, in a private folder on this Mac, so they are still there after a restart. Password-manager entries are skipped. Turning it off stops recording; Delete all history in the Clipboard tab erases what is saved.")
                Toggle("Lock Notes and Clipboard", isOn: $lock.enabled)
                    .help("Ask for Touch ID or your password before showing them. They lock again after two minutes.")
                Toggle("Show music on the lock screen (experimental)", isOn: $lockScreenMusic)
                    .disabled(!LockScreenMusic.shared.isSupported)
                    .help(LockScreenMusic.shared.isSupported
                          ? "While music plays, a small card with the cover and controls shows on the lock screen. This uses undocumented parts of macOS and may stop working after an update."
                          : "This Mac's version of macOS doesn't offer what this needs.")
                if lockScreenMusic {
                    Toggle("Large cover on the lock screen", isOn: $largeCover)
                        .disabled(!LockScreenMusic.shared.isSupported)
                        .help("Shows the album cover large above the controls. Off: only the small card.")
                }
                Toggle("Tap the trackpad when the island opens", isOn: $haptics)
                    .help("A light tap you can feel on the trackpad when the island opens or changes tab.")
                Toggle("Show QoL Notch in the menu bar", isOn: $showMenuBarIcon)
                Button("Play Welcome Animation") { IslandState.shared.greet() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: weather.city) { _, _ in weather.refreshIfNeeded() }
    }

    private func order(first: Bool, last: Bool, name: String, move: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(first).accessibilityLabel("Move \(name) earlier")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(last).accessibilityLabel("Move \(name) later")
        }
        .buttonStyle(.borderless)
    }
}
