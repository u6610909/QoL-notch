import SwiftUI
import AppKit
import EventKit
import UniformTypeIdentifiers

// MARK: - Calendar

/// Today's and tomorrow's events, read from the Mac's calendars once the user allows it.
final class CalendarModule: ObservableObject {
    static let shared = CalendarModule()

    struct Item: Identifiable {
        let id: String
        let title: String
        let start: Date
        let allDay: Bool
        let colour: Color
    }

    @Published private(set) var events: [Item] = []
    @Published private(set) var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published private(set) var denied = false

    private let store = EKEventStore()
    private var reminderTimer: Timer?
    private var announced: Set<String> = []
    private var lastReload = Date.distantPast

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                self?.denied = !granted
                self?.reload()
            }
        }
    }

    func reload() {
        guard authorized else { return }
        lastReload = Date()
        let calendar = Calendar.current
        let now = Date()
        let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now
        let found = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
        events = found
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
            .map {
                Item(id: ($0.eventIdentifier ?? UUID().uuidString) + "\($0.startDate.timeIntervalSince1970)",
                     title: $0.title ?? "Untitled", start: $0.startDate, allDay: $0.isAllDay,
                     colour: Color(nsColor: $0.calendar.color))
            }
        // Forget announcements for events that are gone, so the set never grows.
        announced.formIntersection(events.map(\.id))
    }

    /// Called once at launch. Does nothing until the user has allowed Calendar access; never asks for it.
    func startReminders() {
        guard reminderTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkReminders() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    private func checkReminders() {
        guard authorized, IslandFeature.eventPeeks.isOn else { return }
        if Date().timeIntervalSince(lastReload) > 300 { reload() }
        guard let event = Self.dueSoon(events, now: Date(), announced: announced) else { return }
        announced.insert(event.id)
        IslandState.shared.post(Peek(kind: .calendarSoon, icon: "calendar", title: "Soon",
                                     value: event.start.formatted(date: .omitted, time: .shortened),
                                     detail: event.title, tint: .accent))
    }

    /// The first timed event starting within the next 75 seconds that has not been announced. Pure, for tests.
    static func dueSoon(_ events: [Item], now: Date, announced: Set<String>) -> Item? {
        events.first { !$0.allDay && !announced.contains($0.id) && (0...75).contains($0.start.timeIntervalSince(now)) }
    }
}

extension CalendarModule {
    /// The weeks of the month holding `date`, as day numbers, with nil for the blanks before and after.
    static func monthGrid(for date: Date, calendar: Calendar = .current) -> [[Int?]] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let lead = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        var cells: [Int?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// How far through the year `date` is: the day's number and the year's length.
    static func yearProgress(for date: Date, calendar: Calendar = .current) -> (day: Int, total: Int) {
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let total = calendar.range(of: .day, in: .year, for: date)?.count ?? 365
        return (day, total)
    }
}

/// The month, what's next and how much of the year has gone, as three small widgets.
struct CalendarTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var calendar = CalendarModule.shared

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                IslandCard { month(context.date) }.frame(width: 148)
                IslandCard { agenda(context.date) }
                IslandCard { year(context.date) }.frame(width: 150)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear { calendar.reload() }
    }

    private func month(_ now: Date) -> some View {
        let cal = Calendar.current
        let today = cal.component(.day, from: now)
        let symbols = cal.veryShortWeekdaySymbols
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 }
        return VStack(alignment: .leading, spacing: 1) {
            Text(now.formatted(.dateTime.month(.wide)).uppercased())
                .font(look.font(10, .bold)).foregroundStyle(look.accent)
                .padding(.leading, 3)
            HStack(spacing: 0) {
                ForEach(order, id: \.self) { index in
                    Text(symbols[index])
                        .font(look.font(8.5, .semibold))
                        .foregroundStyle(look.text.opacity(index == 0 || index == 6 ? 0.4 : 0.7))
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(CalendarModule.monthGrid(for: now, calendar: cal).enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let weekend = order[column] == 0 || order[column] == 6
                        Group {
                            if let day = week[column] {
                                Text("\(day)")
                                    .font(look.font(9.5, day == today ? .bold : .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(day == today ? look.onAccent : look.text.opacity(weekend ? 0.45 : 0.9))
                                    .frame(width: 15, height: 13)
                                    .background(Capsule().fill(day == today ? look.accent : .clear))
                            } else {
                                Color.clear.frame(width: 15, height: 13)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.formatted(date: .complete, time: .omitted))
    }

    private func agenda(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(now.formatted(.dateTime.day()))
                    .font(look.font(24, .semibold)).foregroundStyle(look.text)
                Text(now.formatted(.dateTime.weekday(.wide)))
                    .font(look.font(12, .semibold)).foregroundStyle(look.accent)
                Spacer(minLength: 0)
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(look.font(11, .medium)).monospacedDigit().foregroundStyle(look.secondary)
            }
            if !calendar.authorized {
                Text(calendar.denied
                     ? "Calendar access is off. Turn it on in System Settings → Privacy & Security → Calendars."
                     : "Show today's and tomorrow's events here. Nothing leaves this Mac.")
                    .font(look.font(11)).foregroundStyle(look.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !calendar.denied {
                    Button("Show My Events") { calendar.requestAccess() }.buttonStyle(IslandChipStyle(prominent: true))
                }
            } else if calendar.events.isEmpty {
                Label("Nothing today or tomorrow", systemImage: "checkmark.circle")
                    .font(look.font(11.5)).foregroundStyle(look.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(calendar.events) { event in
                            HStack(spacing: 7) {
                                Capsule().fill(event.colour).frame(width: 3, height: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(event.title).font(look.font(12, .medium)).foregroundStyle(look.text).lineLimit(1)
                                    Text(when(event)).font(look.font(10)).monospacedDigit().foregroundStyle(look.secondary)
                                }
                            }
                        }
                    }
                }
                .contentMargins(.vertical, 4, for: .scrollContent)
                .fadedEdges(.vertical, length: 8)
            }
            Spacer(minLength: 0)
        }
    }

    private func year(_ now: Date) -> some View {
        let progress = CalendarModule.yearProgress(for: now)
        let percent = Int((Double(progress.day) / Double(progress.total) * 100).rounded(.down))
        return VStack(alignment: .leading, spacing: 4) {
            Text("This year has passed").font(look.font(10, .medium)).foregroundStyle(look.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("\(progress.day)/\(progress.total)")
                    .font(look.font(10.5, .medium)).monospacedDigit().foregroundStyle(look.accent)
                Spacer(minLength: 0)
                Text("\(percent)%").font(look.font(24, .semibold)).monospacedDigit().foregroundStyle(look.text)
            }
            // One dot for every day of the year.
            Canvas { context, size in
                let columns = 31
                let step = size.width / CGFloat(columns)
                let dot = step * 0.56
                for index in 0..<progress.total {
                    let x = CGFloat(index % columns) * step + (step - dot) / 2
                    let y = CGFloat(index / columns) * step + (step - dot) / 2
                    let colour = index + 1 < progress.day ? look.accent.opacity(0.85)
                        : index + 1 == progress.day ? look.text : look.text.opacity(0.22)
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)), with: .color(colour))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(percent) percent of the year has passed, day \(progress.day) of \(progress.total)")
    }

    private func when(_ event: CalendarModule.Item) -> String {
        let day = Calendar.current.isDateInToday(event.start) ? "Today" : "Tomorrow"
        if event.allDay { return "\(day), all day" }
        return "\(day) " + event.start.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - File shelf

/// A place to park files: drop them on the island, drag them back out later.
final class ShelfModule: ObservableObject {
    static let shared = ShelfModule()

    @Published private(set) var files: [URL] = []

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "shelf") ?? []
        files = saved.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        var added: [URL] = []
        for url in urls where !files.contains(url) && !added.contains(url) { added.append(url) }
        files.append(contentsOf: added)
        files = Array(files.suffix(12))
        save()
        // The island is open during a drop, so this waits and shows as it settles: a quiet receipt.
        guard !added.isEmpty, IslandFeature.eventPeeks.isOn else { return }
        IslandState.shared.post(Peek(kind: .shelfDrop, icon: "tray.and.arrow.down.fill", title: "Shelf",
                                     value: "\(files.count)",
                                     detail: added.count == 1 ? added[0].lastPathComponent : "\(added.count) files added"))
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(files.map(\.path), forKey: "shelf")
    }

    /// Reads dropped file URLs and adds them to the shelf.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.add([url]) }
            }
        }
        return true
    }
}

struct ShelfTab: View {
    @Environment(\.islandPalette) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var shelf = ShelfModule.shared
    @ObservedObject private var island = IslandState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if shelf.files.isEmpty {
                IslandNotice(icon: "tray.and.arrow.down", title: "Drop files here to keep them handy.",
                             detail: "Drag a file onto the notch, then drag it back out wherever you need it. The files themselves are not moved or copied.")
                    .padding(.horizontal, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(shelf.files, id: \.self) { url in
                            VStack(spacing: 3) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 40, height: 40)
                                Text(url.lastPathComponent)
                                    .font(look.font(10))
                                    .foregroundStyle(look.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 66)
                            }
                            .padding(5)
                            .islandTile(look, radius: 10)
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Remove from Shelf") { shelf.remove(url) }
                            }
                            .help("Drag out to use. Double-click to open.")
                            .accessibilityLabel(url.lastPathComponent)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.open, value: shelf.files)
                }
                // The row runs out under a fade to near the island's edge; at rest it starts at the usual 14 pt.
                .contentMargins(.horizontal, 10, for: .scrollContent)
                .fadedEdges()
                HStack(spacing: 6) {
                    Button("AirDrop") {
                        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: shelf.files)
                    }
                    .buttonStyle(IslandChipStyle(prominent: true))
                    .help("Send everything on the shelf with AirDrop.")
                    Button("Clear Shelf") { shelf.clear() }.buttonStyle(IslandChipStyle())
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
        .overlay {
            if island.dragOpen {
                DropZone(targeted: island.dropTargeted)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .focus(5).combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.tab, value: island.dragOpen)
    }
}

/// Marks the Shelf as a place to drop the file being dragged; solid and brighter once the file is over it.
private struct DropZone: View {
    let targeted: Bool
    @Environment(\.islandPalette) private var look
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(look.accent)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: !targeted && !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                Text(targeted ? "Let go to keep it here" : "Drop here to keep it handy")
                    .font(look.font(13, .semibold))
                    .foregroundStyle(look.text)
                    .contentTransition(.opacity)
                Text("The file stays where it is.")
                    .font(look.font(11))
                    .foregroundStyle(look.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Covers whatever the shelf holds, tinted with the accent.
            ZStack {
                shape.fill(Color.black.opacity(0.72))
                shape.fill(look.accent.opacity(targeted ? 0.18 : 0.08))
            }
        }
        .overlay(shape.strokeBorder(look.accent.opacity(targeted ? 1 : 0.6),
                                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: targeted ? [] : [5, 4])))
        .scaleEffect(targeted && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.quick, value: targeted)
        // The drop must still reach the island underneath.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
