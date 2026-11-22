import AppKit
import ApplicationServices

/// Takes over the volume and brightness keys so macOS doesn't draw its own indicator on top of the notch's.
///
/// A session event tap sees each media-key press before the system does. For keys we can act on, it changes
/// the level itself and swallows the event; anything it can't act on (an output with no volume control, no
/// built-in display, keyboard backlight keys) passes through untouched, so macOS keeps working as before.
/// Needs the Accessibility permission; without it `start()` does nothing and macOS keeps its indicator.
final class MediaKeyTap {
    static let shared = MediaKeyTap()

    /// The media keys, as macOS numbers them in NX_SYSDEFINED events (subtype 8).
    enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    /// Return true when the key was handled and the system should not see it.
    var handler: ((Key, _ fine: Bool) -> Bool)?

    private var tap: CFMachPort?
    /// Keys whose key-down we swallowed, so their key-up is swallowed too (and only theirs).
    private var owned = Set<Int>()
    private var source: CFRunLoopSource?

    private init() {}

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Accessibility" prompt (only if not yet trusted).
    static func askForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings at Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Decodes a media-key event's data1. Pure, for tests: key code, key down, and whether it's an auto-repeat.
    static func decode(data1: Int) -> (code: Int, down: Bool, isRepeat: Bool) {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        let down = ((flags & 0xFF00) >> 8) == 0x0A
        return (code, down, flags & 0x1 == 1)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else { return false }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        owned = []
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a slow tap off; switch it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let decoded = Self.decode(data1: ns.data1)
        guard let key = Key(rawValue: decoded.code) else { return Unmanaged.passUnretained(event) }
        if !decoded.down {
            // Swallow the key-up only for a key whose key-down we took, so the system never half-handles it.
            return owned.remove(decoded.code) != nil ? nil : Unmanaged.passUnretained(event)
        }
        // Mute toggles once per press, not on auto-repeat.
        if key == .mute && decoded.isRepeat { return owned.contains(decoded.code) ? nil : Unmanaged.passUnretained(event) }
        // Option + Shift = fine steps, like macOS.
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        if let handler, handler(key, fine) {
            owned.insert(decoded.code)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}
