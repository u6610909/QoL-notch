import SwiftUI
import AppKit

/// A colour stored as plain sRGB numbers so themes stay readable JSON.
struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent)
        g = Double(ns.greenComponent)
        b = Double(ns.blueComponent)
        a = Double(ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Contrast against pure black, as WCAG measures it.
    var contrastOnBlack: Double { (luminance + 0.05) / 0.05 }

    /// The colour as drawn on black: mixed toward white just enough to read, otherwise unchanged.
    func liftedForBlack(minimum: Double = 4.5) -> RGBA {
        if contrastOnBlack >= minimum { return RGBA(r, g, b) }
        for step in 1...50 {
            let t = Double(step) * 0.02
            let lifted = RGBA(r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t)
            if lifted.contrastOnBlack >= minimum { return lifted }
        }
        return RGBA(1, 1, 1)
    }

    /// Equal within the rounding a colour picker introduces.
    func near(_ other: RGBA, tolerance: Double = 0.002) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }
}

enum FontChoice: String, Codable, CaseIterable, Identifiable {
    case typewriter, rounded, serif, sans          // the order shown in settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var design: Font.Design {
        switch self {
        case .typewriter: .monospaced
        case .rounded: .rounded
        case .serif: .serif
        case .sans: .default
        }
    }

    /// Reads names from older theme files: "mono" and anything unknown become Typewriter.
    init(legacy raw: String) {
        self = FontChoice(rawValue: raw) ?? .typewriter
    }
}

enum ThemeError: LocalizedError {
    case reservedName, emptyName, notATheme
    var errorDescription: String? {
        switch self {
        case .reservedName: "That name belongs to a built-in theme. Choose another name."
        case .emptyName: "Give the theme a name."
        case .notATheme: "That file is not a QoL Notch theme."
        }
    }
}

/// A look for the island and the script: an accent colour, a glow colour and the script's typeface.
/// The island itself is always black, so no theme can make it hard to read.
struct Theme: Codable, Equatable, Identifiable {
    static let formatVersion = 2
    static let sizeRange = 14.0...40.0
    static let defaultSize = 23.0

    var name = "Midnight Blue"
    var accent = RGBA(0.04, 0.52, 1)
    var glowColour = RGBA(0.04, 0.4, 1)
    var font = FontChoice.typewriter
    var fontSize = Theme.defaultSize
    var id: String { name }

    // The fixed parts of the look. They are not stored in theme files.
    static let text = Color.white.opacity(0.96)
    static let spokenOpacity = 0.5
    static let lineSpacing = 8.0

    init() {}

    init(name: String, accent: RGBA, glow: RGBA, font: FontChoice, size: Double = Theme.defaultSize) {
        self.name = name
        self.accent = accent
        self.glowColour = glow
        self.font = font
        self.fontSize = size
    }

    static let midnightBlue = Theme()

    static let presets: [Theme] = [
        .midnightBlue,
        Theme(name: "Graphite", accent: RGBA(0.663, 0.706, 0.769), glow: RGBA(0.357, 0.420, 0.525), font: .sans),
        Theme(name: "Forest", accent: RGBA(0.188, 0.820, 0.345), glow: RGBA(0.055, 0.624, 0.310), font: .typewriter),
        Theme(name: "Sunset", accent: RGBA(1, 0.624, 0.039), glow: RGBA(1, 0.353, 0.122), font: .serif),
        Theme(name: "Rose", accent: RGBA(1, 0.392, 0.510), glow: RGBA(0.910, 0.188, 0.416), font: .rounded),
    ]

    static func isPresetName(_ name: String) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.contains { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// The accent as drawn: lifted if needed so it reads on black.
    var readableAccent: Color { accent.liftedForBlack().color }
    var accentWasLifted: Bool { accent.contrastOnBlack < 4.5 }

    var swiftFont: Font { font(size: fontSize) }

    func font(size: CGFloat) -> Font {
        // PT Mono ships with macOS and has the slab, typewriter feel.
        if font == .typewriter { return .custom("PTMono-Regular", fixedSize: size) }
        return .system(size: size, weight: .medium, design: font.design)
    }

    /// The same colours, typeface and size; the name is ignored.
    func sameLook(as other: Theme) -> Bool {
        accent.near(other.accent) && glowColour.near(other.glowColour)
            && font == other.font && abs(fontSize - other.fontSize) < 0.01
    }

    /// Opaque colours, a whole-number size within range, and a trimmed name.
    func normalised() -> Theme {
        var theme = self
        theme.accent.a = 1
        theme.glowColour.a = 1
        theme.fontSize = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize.rounded()))
        theme.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return theme
    }

    // MARK: Files

    // New and old key names together, so files from earlier versions still open.
    private enum CodingKeys: String, CodingKey {
        case version, name, accent, glowColour, font, fontSize, highlight, aura, auraStrength
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(accent, forKey: .accent)
        try c.encode(glowColour, forKey: .glowColour)
        try c.encode(font.rawValue, forKey: .font)
        try c.encode(fontSize, forKey: .fontSize)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fontName = try? c.decodeIfPresent(String.self, forKey: .font)
        let size = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? Self.defaultSize
        if let accent = try? c.decodeIfPresent(RGBA.self, forKey: .accent) {
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Imported"
            self.accent = accent
            glowColour = (try? c.decodeIfPresent(RGBA.self, forKey: .glowColour)) ?? accent
        } else {
            // A file from before themes were simplified: highlight became the accent, aura the glow.
            let highlight = try? c.decodeIfPresent(RGBA.self, forKey: .highlight)
            let oldName = try? c.decodeIfPresent(String.self, forKey: .name)
            guard highlight != nil || oldName != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a theme"))
            }
            name = oldName ?? "Imported"
            accent = highlight ?? Theme.midnightBlue.accent
            let aura = try? c.decodeIfPresent(RGBA.self, forKey: .aura)
            let strength = try? c.decodeIfPresent(Double.self, forKey: .auraStrength)
            glowColour = (aura == nil || (strength ?? 1) < 0.05) ? accent : aura!
        }
        font = fontName.map(FontChoice.init(legacy:)) ?? .typewriter
        fontSize = size
        self = normalised()
    }
}
