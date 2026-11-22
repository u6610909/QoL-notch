import SwiftUI
import AppKit

/// Switches for the notch's extras. Each is a Bool in UserDefaults; `isOn` applies the default.
enum IslandFeature: String, CaseIterable {
    case eventPeeks = "peekEvents"
    case batteryPeeks = "batteryPeek"
    case screenshotDrop = "screenshotDrop"
    case systemHUD = "systemHUD"                // opt-in: macOS keeps its own indicator
    case hideSystemHUD = "hideSystemHUD"        // with systemHUD: take over the keys so macOS draws nothing
    case shelfOnDrag = "shelfOnDrag"
    case tonearm = "vinylTonearm"
    case lockScreenLargeCover = "lockScreenLargeCover"

    var defaultValue: Bool { self != .systemHUD }
    var isOn: Bool { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? defaultValue }
}

/// A short message in the resting notch: it widens, says a few characters either side of the camera, then settles.
struct Peek: Identifiable, Equatable {
    enum Kind: String { case volume, brightness, lowBattery, timerDone, calendarSoon, charging, screenshot, shelfDrop }
    enum Tint: Equatable { case white, accent, green, orange, red }

    var id = UUID()
    var kind: Kind
    /// SF Symbol, left of the notch.
    var icon: String
    /// Left, after the icon; at most 9 characters.
    var title: String = ""
    /// Right of the notch, e.g. "54%".
    var value: String?
    /// 0...1, drawn as a bar right of the notch; when set, `value` is ignored.
    var level: Double?
    /// One line under the notch.
    var detail: String?
    /// A 0...1 quantity the icon may draw; not shown as a bar.
    var amount: Double?
    var tint: Tint = .white

    /// Seconds on screen.
    var duration: TimeInterval {
        switch kind {
        case .volume, .brightness: 1.5
        case .screenshot: 1.6
        case .shelfDrop: 2.2
        case .charging: 3.0
        case .lowBattery, .timerDone: 4.0
        case .calendarSoon: 5.0
        }
    }

    /// Higher shows first and may interrupt a lower one.
    var priority: Int {
        switch kind {
        case .volume, .brightness: 100
        case .lowBattery: 80
        case .timerDone: 70
        case .calendarSoon: 60
        case .charging: 50
        case .screenshot: 40
        case .shelfDrop: 30
        }
    }

    /// How long it may wait while the island is busy before it is no longer worth showing. 0: never waits.
    var patience: TimeInterval {
        switch kind {
        case .volume, .brightness, .screenshot: 0
        case .charging: 5
        case .shelfDrop: 6
        case .timerDone: 20
        case .calendarSoon: 45
        case .lowBattery: 600
        }
    }
}

/// Which peek shows and which wait. A plain value with no timers, so the rules can be tested.
struct PeekQueue {
    enum Outcome: Equatable { case show, update, queued, dropped }
    private(set) var current: Peek?
    private(set) var waiting: [(peek: Peek, deadline: Date)] = []

    /// `blocked`: the island is open, or the user is reading or typing.
    mutating func post(_ peek: Peek, now: Date, blocked: Bool) -> Outcome {
        if blocked {
            guard peek.patience > 0 else { return .dropped }
            enqueue(peek, until: now.addingTimeInterval(peek.patience))
            return .queued
        }
        guard let shown = current else {
            current = peek
            return .show
        }
        if shown.kind == peek.kind {
            // Same message with new content: keep its identity so the view updates in place.
            var updated = peek
            updated.id = shown.id
            current = updated
            return .update
        }
        if peek.priority > shown.priority {
            current = peek
            return .show
        }
        enqueue(peek, until: now.addingTimeInterval(max(peek.patience, 8)))
        return .queued
    }

    /// The current peek's time is up (or it was cut short). Returns the next one to show, if any.
    mutating func finish(now: Date, blocked: Bool) -> Peek? {
        current = nil
        waiting.removeAll { $0.deadline < now }
        guard !blocked, !waiting.isEmpty else { return nil }
        // Highest priority first; on a tie the earliest posted, which sits first in the list.
        var best = 0
        for index in waiting.indices where waiting[index].peek.priority > waiting[best].peek.priority { best = index }
        let next = waiting.remove(at: best).peek
        current = next
        return next
    }

    /// The island opened: the current peek ends and is not shown again. Waiting ones stay.
    mutating func suspend() {
        current = nil
    }

    private mutating func enqueue(_ peek: Peek, until deadline: Date) {
        waiting.removeAll { $0.peek.kind == peek.kind }
        waiting.append((peek, deadline))
    }
}

/// The peek drawn in the resting notch: icon and title left of the camera, a value or bar right of it,
/// and an optional line underneath.
struct PeekView: View {
    let peek: Peek
    let notchWidth: CGFloat
    let inset: CGFloat
    @Environment(\.islandPalette) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    static let barWidth: CGFloat = 62

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    icon
                    if !peek.title.isEmpty {
                        Text(peek.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)

                Color.clear.frame(width: notchWidth)

                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
            }
            .frame(height: inset)

            if let detail = peek.detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandState.peekDetailHeight)
                    .transition(reduceMotion ? .opacity : .focus(4).combined(with: .offset(y: -4)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .onAppear {
            if !reduceMotion { appeared = true }
            guard peek.kind != .volume, peek.kind != .brightness else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: label,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    private var label: String {
        [peek.title, peek.value, peek.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var colour: Color {
        switch peek.tint {
        case .white: .white
        case .accent: look.accent
        case .green: Self.green
        case .orange: .orange
        case .red: Color(red: 1, green: 0.27, blue: 0.23)
        }
    }

    static let green = Color(red: 0.2, green: 0.84, blue: 0.4)

    @ViewBuilder
    private var icon: some View {
        let font = Font.system(size: 12, weight: .semibold)
        switch peek.kind {
        case .volume, .brightness:
            Image(systemName: peek.icon, variableValue: peek.level)
                .font(font)
                .foregroundStyle(colour)
                .contentTransition(.symbolEffect(.replace))
                .swapBlur(peek.icon)
        case .charging:
            ChargingBolt(level: peek.amount ?? 0)
        case .lowBattery:
            // Arrives with one bounce, then pulses twice so a low battery is noticed.
            Image(systemName: peek.icon)
                .font(font)
                .foregroundStyle(colour)
                .symbolEffect(.bounce, value: appeared)
                .symbolEffect(.pulse, options: .repeat(2), value: appeared)
        default:
            Image(systemName: peek.icon)
                .font(font)
                .foregroundStyle(colour)
                .symbolEffect(.bounce, value: appeared)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let level = peek.level {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(colour).frame(width: max(4, Self.barWidth * min(1, max(0, level))))
            }
            .frame(width: Self.barWidth, height: 4)
            .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.level, value: level)
        } else if let value = peek.value {
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }
}
