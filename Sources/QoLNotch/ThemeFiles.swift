import Foundation

/// Reading and writing `.qoltheme` files. The folder is passed in so tests can use a temporary one.
enum ThemeFiles {
    static let fileExtension = "qoltheme"

    static func fileName(for name: String) -> String {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " ? $0 : "_" }
        return String(safe) + "." + fileExtension
    }

    /// Every theme file in `dir` that opens, sorted by name. A file named like a built-in theme is
    /// listed as "<name> 2" so the two never get mixed up; the file itself is left alone.
    static func load(from dir: URL) -> [Theme] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var themes: [Theme] = []
        for url in files where url.pathExtension == fileExtension {
            guard var theme = try? read(url) else { continue }
            if Theme.isPresetName(theme.name) {
                theme.name = uniqueName(theme.name, taken: Theme.presets.map(\.name) + themes.map(\.name))
            }
            themes.append(theme)
        }
        return themes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    static func write(_ theme: Theme, to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(for: theme.name))
        try encode(theme).write(to: url, options: .atomic)
        return url
    }

    static func encode(_ theme: Theme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(theme)
    }

    static func read(_ url: URL) throws -> Theme {
        do {
            return try JSONDecoder().decode(Theme.self, from: Data(contentsOf: url))
        } catch {
            throw ThemeError.notATheme
        }
    }

    /// "Forest", then "Forest 2", "Forest 3"… An empty name becomes "My Theme".
    static func uniqueName(_ wanted: String, taken: [String]) -> String {
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "My Theme" : wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = Set(taken.map { $0.lowercased() })
        if !lower.contains(base.lowercased()) { return base }
        var number = 2
        while lower.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    static func trash(named name: String, in dir: URL) {
        let url = dir.appendingPathComponent(fileName(for: name))
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
