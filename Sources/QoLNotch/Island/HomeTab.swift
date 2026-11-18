import SwiftUI
import AppKit

// MARK: - Weather

/// Current weather for a city the user typed in. Uses Open-Meteo, which needs no account;
/// only the city name is sent, and nothing is sent until a city is set.
final class WeatherModule: ObservableObject {
    static let shared = WeatherModule()

    struct Reading: Equatable {
        var place: String
        var temperature: Double
        var feelsLike: Double
        var wind: Double
        var rainChance: Int
        var code: Int
    }

    @Published var city: String {
        didSet {
            guard city != oldValue else { return }
            UserDefaults.standard.set(city, forKey: "weatherCity")
            reading = nil
            error = nil
            lastFetch = .distantPast
        }
    }
    @Published private(set) var reading: Reading?
    @Published private(set) var error: String?
    private var lastFetch = Date.distantPast
    private var loading = false

    private init() { city = UserDefaults.standard.string(forKey: "weatherCity") ?? "" }

    static var usesFahrenheit: Bool { Locale.current.measurementSystem == .us }
    static var unit: String { usesFahrenheit ? "°F" : "°C" }
    static var windUnit: String { usesFahrenheit ? "mph" : "km/h" }

    /// Fetches at most every 20 minutes, and only while something is showing the weather.
    func refreshIfNeeded() {
        let name = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !loading, Date().timeIntervalSince(lastFetch) > 1200 else { return }
        loading = true
        var search = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        search.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "1")]
        URLSession.shared.dataTask(with: search.url!) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let place = (json["results"] as? [[String: Any]])?.first,
                  let latitude = place["latitude"] as? Double, let longitude = place["longitude"] as? Double
            else {
                self?.finish(nil, error: data == nil ? "No connection." : "Could not find that city.")
                return
            }
            var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            forecast.queryItems = [
                .init(name: "latitude", value: String(latitude)),
                .init(name: "longitude", value: String(longitude)),
                .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
                .init(name: "hourly", value: "precipitation_probability"),
                .init(name: "forecast_hours", value: "1"),
                .init(name: "temperature_unit", value: Self.usesFahrenheit ? "fahrenheit" : "celsius"),
                .init(name: "wind_speed_unit", value: Self.usesFahrenheit ? "mph" : "kmh"),
            ]
            URLSession.shared.dataTask(with: forecast.url!) { [weak self] data, _, _ in
                guard let data, let reading = Self.parse(data, place: place["name"] as? String ?? name) else {
                    self?.finish(nil, error: "No weather right now.")
                    return
                }
                self?.finish(reading, error: nil)
            }.resume()
        }.resume()
    }

    /// Reads Open-Meteo's forecast answer. Internal so tests can call it.
    static func parse(_ data: Data, place: String) -> Reading? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue
        else { return nil }
        let number = { (key: String) -> Double in (current[key] as? NSNumber)?.doubleValue ?? 0 }
        let rain = ((json["hourly"] as? [String: Any])?["precipitation_probability"] as? [NSNumber])?.first?.intValue ?? 0
        return Reading(place: place, temperature: temperature, feelsLike: number("apparent_temperature"),
                       wind: number("wind_speed_10m"), rainChance: rain, code: Int(number("weather_code")))
    }

    private func finish(_ reading: Reading?, error: String?) {
        DispatchQueue.main.async {
            self.loading = false
            self.lastFetch = Date()
            if let reading { self.reading = reading }
            self.error = error
        }
    }

    /// An SF Symbol and a word for a WMO weather code.
    static func describe(_ code: Int) -> (icon: String, text: String) {
        switch code {
        case 0: ("sun.max.fill", "Clear")
        case 1, 2: ("cloud.sun.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51...57: ("cloud.drizzle.fill", "Drizzle")
        case 61...67, 80...82: ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86: ("cloud.snow.fill", "Snow")
        case 95...99: ("cloud.bolt.rain.fill", "Storm")
        default: ("cloud.fill", "Cloudy")
        }
    }
}

// MARK: - Home

/// Music, what's next and one small widget, side by side.
struct HomeTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var media = MediaModule.shared
    @ObservedObject private var calendar = CalendarModule.shared
    @ObservedObject private var island = IslandState.shared
    @ObservedObject private var style = IslandLook.shared
    @AppStorage("dailyLine") private var showLine = true
    @AppStorage("dailyLineText") private var ownLine = ""

    var body: some View {
        let slots = style.homeSlots
        // Music takes the spare width. Without it, the other widgets share the width evenly.
        let hasMusic = slots.contains(.music)
        HStack(spacing: 8) {
            if slots.isEmpty {
                IslandNotice(icon: "square.grid.2x2", title: "Home is empty.",
                             detail: "Choose up to three widgets in QoL Notch's Island settings.")
            }
            ForEach(slots) { slot in
                switch slot {
                case .music: IslandCard { music.frame(maxHeight: .infinity) }
                case .agenda: IslandCard { agenda }.frame(maxWidth: hasMusic ? 142 : .infinity)
                case .weather: tile(WeatherWidget(), wide: !hasMusic)
                case .system: tile(SystemWidget(), wide: !hasMusic)
                case .clock: tile(ClockWidget(), wide: !hasMusic)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear { calendar.reload() }
    }

    private func tile(_ content: some View, wide: Bool) -> some View {
        content
            .frame(maxWidth: wide ? .infinity : 132, maxHeight: .infinity)
            .islandTile(look)
    }

    private var music: some View {
        HStack(spacing: 10) {
            // Concentric with the card around it, whose padding is 8.
            Artwork(size: 58, radius: look.inner(8))
            VStack(alignment: .leading, spacing: 2) {
                Text(media.hasTrack ? media.title : "Nothing playing")
                    .font(look.font(13, .semibold)).foregroundStyle(look.text).lineLimit(1)
                Text(media.hasTrack ? media.artist : "Music, Spotify or a browser tab")
                    .font(look.font(11)).foregroundStyle(look.secondary).lineLimit(1)
                HStack(spacing: 14) {
                    MediaButton(icon: "backward.fill", label: "Previous track") { media.previous() }
                    MediaButton(icon: media.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause", size: 16) { media.playPause() }
                    MediaButton(icon: "forward.fill", label: "Next track") { media.next() }
                }
                .padding(.top, 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { island.tab = .media }
    }

    private var agenda: some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(now.formatted(.dateTime.day()))
                    .font(look.font(22, .semibold)).foregroundStyle(look.text)
                Text(now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated)))
                    .font(look.font(11, .semibold)).foregroundStyle(look.accent)
            }
            if !calendar.authorized {
                Button("Show Events") { island.tab = .calendar }.buttonStyle(IslandChipStyle())
            } else if calendar.events.isEmpty {
                if !showLine { Text("Nothing coming up").font(look.font(11)).foregroundStyle(look.secondary) }
            } else {
                ForEach(calendar.events.prefix(showLine ? 1 : 2)) { event in
                    HStack(spacing: 5) {
                        Capsule().fill(event.colour).frame(width: 3, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(event.title).font(look.font(11, .medium)).foregroundStyle(look.text).lineLimit(1)
                            Text(event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                                .font(look.font(9.5)).foregroundStyle(look.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if showLine {
                Text(DailyLine.line(for: now, custom: ownLine))
                    .font(.system(size: 11, weight: .medium, design: .serif)).italic()
                    .foregroundStyle(look.text.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Today's line. Change it in the main window's Island tab.")
            }
        }
    }
}

/// The current track's cover, or a themed placeholder.
struct Artwork: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var media = MediaModule.shared
    var size: CGFloat
    /// Corner radius; a fifth of the size unless the cover sits inside a tile.
    var radius: CGFloat?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? size * 0.2, style: .continuous)
        Group {
            if let artwork = media.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [look.glow, look.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Dark covers keep an edge on black.
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

struct MediaButton: View {
    @Environment(\.islandPalette) private var look
    let icon: String
    let label: String
    var size: CGFloat = 13
    var active = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(look.text.opacity(active ? 1 : 0.4))
                .frame(width: max(24, size * 1.5), height: max(22, size * 1.3))
                .contentTransition(.symbolEffect(.replace))
                .swapBlur(icon)
                .contentShape(Rectangle())
                .animation(IslandMotion.quick, value: icon)
        }
        .buttonStyle(IslandPressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct WeatherWidget: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var weather = WeatherModule.shared

    var body: some View {
        VStack(spacing: 3) {
            if let reading = weather.reading {
                let about = WeatherModule.describe(reading.code)
                HStack(spacing: 6) {
                    Image(systemName: about.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(look.accent)
                    Text("\(Int(reading.temperature.rounded()))\(WeatherModule.unit)")
                        .font(look.font(22, .semibold)).foregroundStyle(look.text)
                }
                Text("\(about.text) · \(reading.place)")
                    .font(look.font(10.5, .medium)).foregroundStyle(look.text).lineLimit(1)
                Text("Rain \(reading.rainChance)%  Wind \(Int(reading.wind.rounded())) \(WeatherModule.windUnit)")
                    .font(look.font(9.5)).foregroundStyle(look.secondary).lineLimit(1)
            } else if weather.city.trimmingCharacters(in: .whitespaces).isEmpty {
                Image(systemName: "cloud.sun.fill").font(.system(size: 20, weight: .medium)).foregroundStyle(look.secondary)
                Text("Set your city in QoL Notch's Island tab")
                    .font(look.font(10.5)).foregroundStyle(look.secondary).multilineTextAlignment(.center)
            } else {
                Image(systemName: "cloud.fill").font(.system(size: 20, weight: .medium)).foregroundStyle(look.secondary)
                Text(weather.error ?? "Loading…").font(look.font(10.5)).foregroundStyle(look.secondary)
            }
        }
        .onAppear { weather.refreshIfNeeded() }
    }
}

private struct SystemWidget: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var stats = StatsModule.shared

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                gauge("CPU", stats.cpu)
                gauge("Memory", stats.memory)
            }
            if let battery = stats.battery {
                Label("\(Int((battery * 100).rounded()))%" + (StatsModule.batteryMinutes().map { " · " + StatsModule.timeLeft($0) } ?? ""),
                      systemImage: stats.charging ? "battery.100.bolt" : "battery.75")
                    .font(look.font(10, .medium)).foregroundStyle(look.secondary).lineLimit(1)
                    .help(stats.charging ? "Battery, and the time until it is full" : "Battery, and the time left")
            } else {
                Text(stats.diskFree.isEmpty ? " " : "\(stats.diskFree) free")
                    .font(look.font(10)).foregroundStyle(look.secondary).lineLimit(1)
            }
        }
        .onAppear { stats.startWatching() }
        .onDisappear { stats.stopWatching() }
    }

    private func gauge(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 3) {
            ZStack {
                // The track sits on a tile, so it takes the lighter step.
                Circle().stroke(look.raised, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(look.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: value)
                Text("\(Int((value * 100).rounded()))")
                    .font(look.font(11, .semibold)).monospacedDigit().foregroundStyle(look.text)
            }
            .frame(width: 42, height: 42)
            Text(label).font(look.font(9.5)).foregroundStyle(look.secondary)
        }
    }
}

/// Battery level for the strip beside the notch. Hidden on a Mac without a battery.
struct BatteryBadge: View {
    let colour: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let state = StatsModule.batteryState()
            if let level = state.0 {
                HStack(spacing: 3) {

                    Text("\(Int((level * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: state.1 ? "battery.100.bolt" : Self.icon(level))
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .swapBlur(state.1)
                }
                .foregroundStyle(level < 0.2 && !state.1 ? Color.red : colour)
                .fixedSize()
                .help(Self.detail(charging: state.1))
            }
        }
    }

    /// The time left stays out of the strip to keep it quiet; it shows when you point at the battery.
    private static func detail(charging: Bool) -> String {
        guard let minutes = StatsModule.batteryMinutes() else { return charging ? "Charging" : "Battery" }
        return StatsModule.timeLeft(minutes) + (charging ? " until full" : " left")
    }

    private static func icon(_ level: Double) -> String {
        switch level {
        case ..<0.13: "battery.0"
        case ..<0.38: "battery.25"
        case ..<0.63: "battery.50"
        case ..<0.88: "battery.75"
        default: "battery.100"
        }
    }
}
