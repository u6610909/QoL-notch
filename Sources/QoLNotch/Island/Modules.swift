import SwiftUI
import AppKit
import IOKit.ps

// MARK: - Media

/// Now-playing for anything on the Mac: Music, Spotify, and browser tabs in Chrome or Safari.
/// The details come from a small helper run inside the system Perl (see Resources/MediaHelper).
final class MediaModule: ObservableObject {
    static let shared = MediaModule()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var isPlaying = false
    /// The app the sound comes from, such as "Google Chrome".
    @Published private(set) var source = ""
    @Published private(set) var artwork: NSImage?
    /// A colour from the cover, for the island's glow.
    @Published private(set) var artworkColour: RGBA?
    @Published private(set) var duration = 0.0
    /// Shuffle and repeat as last set from QoL Notch. Unknown until the user presses the button.
    @Published private(set) var shuffle: Bool?
    @Published private(set) var repeating: Bool?
    /// Goes up each time the cover picture changes. The file often arrives a moment after the title,
    /// so cross-fades key on this rather than on the track.
    @Published private(set) var artworkVersion = 0

    private var elapsed = 0.0
    private var stamp = Date()
    private var rate = 0.0
    private var bundleID = ""
    private var artworkPath = ""
    private var stream: Process?
    private var pending = Data()

    /// Kept so older code that toggled this keeps compiling; the helper needs no warm-up.
    var tabVisible = false

    private static let scriptable = ["com.apple.Music": "Music", "com.spotify.client": "Spotify"]

    private init() { startStream() }

    var hasTrack: Bool { !title.isEmpty }
    /// Shuffle and repeat can only be set in apps that let other apps script them.
    var canShuffle: Bool { Self.scriptable[bundleID] != nil }

    /// Where playback is right now, in seconds.
    func position(at date: Date = Date()) -> Double {
        let moved = isPlaying ? date.timeIntervalSince(stamp) * (rate > 0 ? rate : 1) : 0
        let value = elapsed + moved
        return duration > 0 ? min(max(0, value), duration) : max(0, value)
    }

    // MARK: Helper

    private static var helperFiles: (script: String, library: String)? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let script = resources + "/qolmedia.pl"
        let library = resources + "/qolmedia.dylib"
        let files = FileManager.default
        return files.fileExists(atPath: script) && files.fileExists(atPath: library) ? (script, library) : nil
    }

    private static func helper(mode: String, argument: String = "") -> Process? {
        guard let files = helperFiles else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [files.script, files.library]
        var environment = ProcessInfo.processInfo.environment
        environment["QOL_MODE"] = mode
        environment["QOL_ARG"] = argument
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func startStream() {
        guard let process = Self.helper(mode: "stream") else { return }
        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        do { try process.run(); stream = process } catch { stream = nil }
    }

    private func receive(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(object) }
        }
    }

    /// Takes one update from the helper. Internal so tests can feed it.
    func apply(_ info: [String: Any]) {
        let number = { (key: String) -> Double in (info[key] as? NSNumber)?.doubleValue ?? 0 }
        let newTitle = info["title"] as? String ?? ""
        if newTitle != title { shuffle = nil; repeating = nil }
        title = newTitle
        artist = info["artist"] as? String ?? ""
        duration = number("duration")
        elapsed = number("elapsed")
        rate = number("rate")
        stamp = Date(timeIntervalSince1970: number("timestamp"))
        isPlaying = number("playing") > 0 && !newTitle.isEmpty

        let pid = pid_t(number("pid"))
        let app = Self.owningApp(of: pid)
        bundleID = app?.bundleIdentifier ?? ""
        source = app?.localizedName ?? ""

        let path = info["artwork"] as? String ?? ""
        if path != artworkPath {
            artworkPath = path
            artworkVersion += 1
            artwork = path.isEmpty ? nil : NSImage(contentsOfFile: path)
            artworkColour = artwork.flatMap(Self.glowColour)
        }
    }

    /// A browser plays sound from a helper process; walk up to the app the user knows.
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard let url = app.bundleURL else { return app }
        var folder = url.deletingLastPathComponent()
        while folder.pathComponents.count > 1 {
            if folder.pathExtension == "app", let bundle = Bundle(url: folder)?.bundleIdentifier,
               let outer = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                return outer
            }
            folder = folder.deletingLastPathComponent()
        }
        return app
    }

    // MARK: Controls

    private func send(_ command: Int) {
        try? Self.helper(mode: "cmd", argument: String(command))?.run()
    }

    func playPause() { send(2); isPlaying.toggle(); stamp = Date() }
    func next() { send(4) }
    func previous() { send(5) }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(duration, 0))
        try? Self.helper(mode: "seek", argument: String(target))?.run()
        elapsed = target
        stamp = Date()
        objectWillChange.send()
    }

    @discardableResult
    private func tell(_ app: String, _ command: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"\(app)\" to \(command)")?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue ?? "" : nil
    }

    func toggleShuffle() {
        guard let app = Self.scriptable[bundleID] else { return }
        let property = app == "Music" ? "shuffle enabled" : "shuffling"
        guard let answer = tell(app, "set \(property) to not \(property)\nreturn (\(property)) as text") else { return }
        shuffle = answer == "true"
    }

    func toggleRepeat() {
        guard let app = Self.scriptable[bundleID] else { return }
        let script = app == "Music"
            ? "if song repeat is off then\nset song repeat to all\nelse\nset song repeat to off\nend if\nreturn (song repeat is not off) as text"
            : "set repeating to not repeating\nreturn repeating as text"
        guard let answer = tell(app, script) else { return }
        repeating = answer == "true"
    }

    func refresh() {}
    func loadArtwork() {}
}

// MARK: - System stats

final class StatsModule: ObservableObject {
    static let shared = StatsModule()

    @Published private(set) var cpu = 0.0        // 0...1
    @Published private(set) var memory = 0.0     // 0...1
    @Published private(set) var battery: Double? // 0...1, nil on a Mac without one
    @Published private(set) var charging = false
    @Published private(set) var diskFree = ""

    private var timer: Timer?
    private var lastTicks: (busy: Double, total: Double)?
    private var watchers = 0

    /// Sampling only runs while something is showing the numbers.
    func startWatching() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = min(1, max(0, (ticks.busy - last.busy) / (ticks.total - last.total)))
            }
            lastTicks = ticks
        }
        memory = Self.memoryUsed() ?? memory
        (battery, charging) = Self.batteryState()
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            diskFree = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        }
    }

    static func cpuTicks() -> (busy: Double, total: Double)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(load.cpu_ticks.0), system = Double(load.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2), nice = Double(load.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    static func memoryUsed() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
        let used = pages * Double(vm_kernel_page_size)
        return min(1, used / Double(ProcessInfo.processInfo.physicalMemory))
    }

    static func batteryState() -> (Double?, Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Double,
                  let max = info[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
            return (current / max, info[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (nil, false)
    }

    /// Minutes until empty, or until full while charging. Nil while macOS is still working it out.
    static func batteryMinutes() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            if let minutes = info[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int, minutes > 0 { return minutes }
        }
        return nil
    }

    static func timeLeft(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - Timer

final class TimerModule: ObservableObject {
    static let shared = TimerModule()

    @Published private(set) var remaining: Double = 0
    @Published private(set) var total: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false

    private var endDate: Date?
    private var ticker: Timer?

    var isActive: Bool { isRunning || (remaining > 0 && remaining < total) }

    func start(minutes: Double) {
        total = minutes * 60
        remaining = total
        finished = false
        resume()
    }

    func resume() {
        guard remaining > 0 else { return }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func pause() {
        tick()
        isRunning = false
        ticker?.invalidate()
        ticker = nil
    }

    func reset() {
        pause()
        remaining = 0
        total = 0
        finished = false
    }

    private func tick() {
        guard isRunning, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 {
            isRunning = false
            finished = true
            ticker?.invalidate()
            ticker = nil
            Self.playChime()
            if IslandFeature.eventPeeks.isOn {
                IslandState.shared.post(Peek(kind: .timerDone, icon: "bell.fill", title: "Timer", value: "Done",
                                             detail: "Your \(Self.spoken(total)) timer is finished", tint: .orange))
            }
        }
    }

    /// A timer's length as said in a sentence: "5-minute" for whole minutes, otherwise "90-second".
    static func spoken(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole >= 60 && whole % 60 == 0 ? "\(whole / 60)-minute" : "\(whole)-second"
    }

    static let chimes = ["Glass", "Ping", "Hero", "Submarine", "None"]
    static var chime: String { UserDefaults.standard.string(forKey: "timerChime") ?? "Glass" }

    static func playChime() {
        guard chime != "None" else { return }
        NSSound(named: chime)?.play()
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
