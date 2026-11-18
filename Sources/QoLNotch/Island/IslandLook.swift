import SwiftUI

/// What one of Home's three places can hold.
enum HomeSlot: String, CaseIterable, Identifiable {
    case music, agenda, weather, system, clock
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: "Music"
        case .agenda: "Date and events"
        case .weather: "Weather"
        case .system: "System and battery"
        case .clock: "Clock"
        }
    }
    var icon: String {
        switch self {
        case .music: "music.note"
        case .agenda: "calendar"
        case .weather: "cloud.sun"
        case .system: "gauge.with.dots.needle.33percent"
        case .clock: "clock"
        }
    }
}

/// The choices people make about how the island looks, apart from the script's own theme.
/// Every choice keeps white text on a dark surface, so none of them can make the island hard to read.
final class IslandLook: ObservableObject {
    static let shared = IslandLook()
    static let maxSlots = 3

    enum Glow: String, CaseIterable, Identifiable {
        case off, theme, cover
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .theme: "Glow colour"
            case .cover: "Album cover"
            }
        }
    }

    @Published var glow: Glow { didSet { defaults.set(glow.rawValue, forKey: "islandGlow") } }
    @Published var homeSlots: [HomeSlot] { didSet { defaults.set(homeSlots.map(\.rawValue), forKey: "homeSlots") } }

    private let defaults = UserDefaults.standard

    private init() {
        // Earlier builds had one switch for the cover glow; carry its answer over.
        let coverWasOff = defaults.object(forKey: "artworkGlow") as? Bool == false
        glow = Glow(rawValue: defaults.string(forKey: "islandGlow") ?? "") ?? (coverWasOff ? .theme : .cover)
        if let saved = defaults.stringArray(forKey: "homeSlots") {
            homeSlots = Array(saved.compactMap(HomeSlot.init(rawValue:)).prefix(Self.maxSlots))
        } else {
            // Earlier builds had music, events and one switchable widget.
            let third = HomeSlot(rawValue: defaults.string(forKey: "homeWidget") ?? "") ?? .weather
            homeSlots = [.music, .agenda, third]
        }
    }

    func setSlot(_ slot: HomeSlot, _ on: Bool) {
        if on {
            guard !homeSlots.contains(slot), homeSlots.count < Self.maxSlots else { return }
            homeSlots.append(slot)
        } else {
            homeSlots.removeAll { $0 == slot }
        }
    }

    func moveSlot(_ slot: HomeSlot, by step: Int) {
        guard let index = homeSlots.firstIndex(of: slot), homeSlots.indices.contains(index + step) else { return }
        homeSlots.swapAt(index, index + step)
    }
}
