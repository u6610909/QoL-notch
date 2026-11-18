import SwiftUI
import IOKit.ps

struct PowerSnapshot: Equatable {
    var level: Double
    var pluggedIn: Bool
}

enum PowerEvent: Equatable {
    case pluggedIn(level: Double)
    case low(threshold: Int, level: Double)
}

/// Turns a stream of battery readings into the two moments worth showing. Pure, for tests.
struct PowerTracker {
    static let thresholds = [20, 10]
    private(set) var last: PowerSnapshot?
    private(set) var warned: Set<Int> = []

    mutating func update(_ now: PowerSnapshot) -> PowerEvent? {
        let percent = Int((now.level * 100).rounded())
        defer { last = now }
        guard let last else {
            // Nothing is announced at launch, including a battery that is already low.
            warned = Set(Self.thresholds.filter { percent <= $0 })
            return nil
        }
        if now.pluggedIn && !last.pluggedIn {
            warned = []
            return .pluggedIn(level: now.level)
        }
        if now.pluggedIn { return nil }
        // Charged well above a threshold again: it may warn again next time.
        warned = warned.filter { percent <= $0 + 5 }
        let crossed = Self.thresholds.filter { percent <= $0 && !warned.contains($0) }
        guard let lowest = crossed.min() else { return nil }
        warned.formUnion(crossed)
        return .low(threshold: lowest, level: now.level)
    }
}

/// Watches the battery and posts a peek when the charger goes in or the level runs low.
final class PowerMonitor {
    static let shared = PowerMonitor()
    private var tracker = PowerTracker()
    private var source: CFRunLoopSource?
    private var timer: Timer?

    private init() {}

    func start() {
        guard source == nil, timer == nil else { return }
        if let loop = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { PowerMonitor.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
            source = loop
        }
        refresh()
        // Level changes do not always notify, so look once a minute as well.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        guard let now = Self.read(), let event = tracker.update(now), IslandFeature.batteryPeeks.isOn else { return }
        switch event {
        case .pluggedIn(let level):
            IslandState.shared.post(Peek(kind: .charging, icon: "bolt.fill", title: level >= 0.995 ? "Charged" : "Charging",
                                         value: "\(Self.percent(level))%", amount: level, tint: .green))
        case .low(let threshold, let level):
            let veryLow = threshold <= 10
            IslandState.shared.post(Peek(kind: .lowBattery, icon: veryLow ? "battery.0" : "battery.25", title: "Battery",
                                         value: "\(Self.percent(level))%",
                                         detail: veryLow ? "Very low battery. Plug in now." : "Low battery. Plug in soon.",
                                         tint: veryLow ? .red : .orange))
        }
    }

    private static func percent(_ level: Double) -> Int { Int((level * 100).rounded()) }

    /// The internal battery's level and whether a charger is connected. Nil on a Mac without a battery.
    static func read() -> PowerSnapshot? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Double,
                  let max = info[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
            let plugged = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return PowerSnapshot(level: min(1, current / max), pluggedIn: plugged)
        }
        return nil
    }
}

/// A bolt that fills green from the bottom up to the battery's level, once, as the notch widens.
struct ChargingBolt: View {
    /// 0...1
    let level: Double
    @State private var shown = 0.0
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let bolt = Image(systemName: "bolt.fill").font(.system(size: 12, weight: .semibold))
        ZStack {
            bolt.foregroundStyle(Color.white.opacity(0.25))
            bolt.foregroundStyle(PeekView.green)
                .mask {
                    Rectangle().frame(height: 14 * shown).frame(maxHeight: .infinity, alignment: .bottom)
                }
                .symbolEffect(.bounce, value: filled)
        }
        .frame(width: 12, height: 14)
        .onAppear {
            let target = max(0.12, level)
            guard !reduceMotion else { shown = target; return }
            withAnimation(IslandMotion.fill) { shown = target }
            // One small bounce once the fill has finished.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { filled = true }
        }
        .accessibilityHidden(true)
    }
}
