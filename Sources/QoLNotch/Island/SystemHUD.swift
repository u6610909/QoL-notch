import CoreAudio
import AppKit

/// Shows volume and brightness changes as a peek. macOS keeps its own indicator: hiding it would need
/// the Accessibility permission or unloading a system agent, and this does neither.
final class SystemHUD {
    static let shared = SystemHUD()

    private var running = false
    private var device: AudioDeviceID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var lastVolume: Float?
    private var lastMuted = false

    private var brightnessTimer: Timer?
    private var lastBrightness: Float?
    private var fastUntil = Date.distantPast
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// No-op if running. Called at launch when the setting is on, and by the setting's switch.
    func start() {
        guard !running else { return }
        running = true
        bind()
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebind() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        deviceListener = block

        lastBrightness = readBrightness()
        schedulePoll(every: 0.4)
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.brightnessTimer?.invalidate()
                self?.brightnessTimer = nil
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                self.lastBrightness = nil
                self.schedulePoll(every: 0.4)
            },
        ]

        // Best effort: catches presses at 0% and 100%, where nothing changes. Without permission macOS may
        // deliver nothing here, and the listeners and the poll still cover normal use.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let code = (event.data1 & 0xFFFF_0000) >> 16
            let down = ((event.data1 & 0xFF00) >> 8) == 0x0A
            guard down else { return }
            switch code {
            case 0, 1, 7:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.volumeChanged(force: true) }
            case 2, 3:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    guard let self, let now = self.readBrightness() else { return }
                    self.lastBrightness = now
                    self.postBrightness(now)
                }
            default: break
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        unbind()
        if let block = deviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            deviceListener = nil
        }
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        lastBrightness = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    /// The glyph for a volume level. Pure, for tests.
    static func volumeIcon(level: Double, muted: Bool) -> String {
        muted || level < 0.005 ? "speaker.slash.fill" : "speaker.wave.3.fill"
    }

    /// Whether a brightness change is big enough to be a key press rather than auto-brightness drifting. Pure.
    static func isKeyStep(from old: Float, to new: Float) -> Bool {
        abs(new - old) >= 0.02
    }

    // MARK: Volume

    /// 'vmvc': the level the volume keys move, present on most built-in and USB outputs.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func readFloat(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Float? {
        guard has(device, address) else { return nil }
        var address = address
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// The addresses that carry this device's volume, best first. Empty for outputs without one (HDMI, DisplayPort).
    private static func volumeAddresses(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let output = kAudioDevicePropertyScopeOutput
        let virtual = address(virtualMainVolume, output)
        if has(device, virtual) { return [virtual] }
        let main = address(kAudioDevicePropertyVolumeScalar, output)
        if has(device, main) { return [main] }
        return [1, 2].map { address(kAudioDevicePropertyVolumeScalar, output, $0) }.filter { has(device, $0) }
    }

    private static func volume(of device: AudioDeviceID) -> Float? {
        let values = volumeAddresses(device).compactMap { readFloat(device, $0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private func bind() {
        guard let device = Self.defaultOutputDevice() else { return }
        self.device = device
        var addresses = Self.volumeAddresses(device)
        let mute = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        if Self.has(device, mute) { addresses.append(mute) }
        for address in addresses {
            var address = address
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                listeners.append((device, address, block))
            }
        }
        // Only a baseline: switching to headphones must not flash the bar.
        lastVolume = Self.volume(of: device)
        lastMuted = Self.isMuted(device)
    }

    private func unbind() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
        device = nil
    }

    private func rebind() {
        guard running else { return }
        unbind()
        bind()
    }

    private func volumeChanged(force: Bool = false) {
        guard running, let device, let level = Self.volume(of: device) else { return }
        let muted = Self.isMuted(device)
        guard force || level != lastVolume || muted != lastMuted else { return }
        lastVolume = level
        lastMuted = muted
        IslandState.shared.post(Peek(kind: .volume, icon: Self.volumeIcon(level: Double(level), muted: muted),
                                     level: muted ? 0 : Double(level)))
    }

    // MARK: Brightness

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    /// Private and undocumented, so looked up at run time; nil leaves brightness quietly off.
    private lazy var getBrightness: GetBrightness? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    private func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func readBrightness() -> Float? {
        guard let getBrightness, let display = builtInDisplay() else { return nil }
        var value: Float = -1
        guard getBrightness(display, &value) == 0, (0...1).contains(value) else { return nil }
        return value
    }

    private func schedulePoll(every interval: TimeInterval) {
        brightnessTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.pollBrightness() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        brightnessTimer = timer
    }

    private func pollBrightness() {
        guard running, let now = readBrightness() else { return }
        defer { lastBrightness = now }
        guard let last = lastBrightness else { return }
        if Self.isKeyStep(from: last, to: now) {
            postBrightness(now)
        } else if brightnessTimer?.timeInterval != 0.4, Date() > fastUntil {
            schedulePoll(every: 0.4)
        }
    }

    private func postBrightness(_ level: Float) {
        IslandState.shared.post(Peek(kind: .brightness, icon: "sun.max.fill", level: Double(level)))
        // Follow held keys closely for a moment, then go back to a slow look.
        fastUntil = Date().addingTimeInterval(2)
        if brightnessTimer?.timeInterval != 0.1 { schedulePoll(every: 0.1) }
    }
}
