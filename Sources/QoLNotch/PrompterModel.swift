import Foundation
import Combine

final class PrompterModel: ObservableObject {
    static let shared = PrompterModel()

    @Published var text: String {
        didSet {
            defaults.set(text, forKey: Keys.text)
            retokenize()
        }
    }
    @Published private(set) var words: [Word] = []
    /// Index of the next word the speaker is expected to say.
    @Published var current: Int = 0
    @Published var listening = false
    @Published var status = "Ready"
    @Published var docked = true

    /// The look of the island and the script. Saved under `themeKey`; the older "theme" key is left alone.
    @Published var theme: Theme { didSet { if theme != oldValue { saveTheme() } } }
    /// Goes up by one on a whole-theme switch (preset, saved theme, reset, import, undo). Views cross-fade on it.
    @Published private(set) var themeSwitchID = 0
    @Published private(set) var userThemes: [Theme] = []
    @Published var hideFromCapture: Bool { didSet { defaults.set(hideFromCapture, forKey: Keys.hide) } }
    @Published var localeID: String { didSet { defaults.set(localeID, forKey: Keys.locale) } }
    /// Voice Follow listens to the reader; Auto Scroll moves at `autoSpeed` on its own.
    @Published var followMode: FollowMode { didSet { defaults.set(followMode.rawValue, forKey: Keys.mode) } }
    /// Auto Scroll's pace in words per minute.
    @Published var autoSpeed: Double { didSet { defaults.set(autoSpeed, forKey: Keys.speed) } }
    @Published var panelVisible = true

    /// Names found in the script's "@Name:" lines, in order of first appearance.
    @Published private(set) var speakers: [String] = []
    /// Which speaker the person at this Mac is; empty means no cue.
    @Published var mySpeaker: String { didSet { defaults.set(mySpeaker, forKey: Keys.me) } }
    @Published private(set) var report: RehearsalReport?
    @Published private(set) var history: [RehearsalReport] = []
    @Published var targetMinutes: Double { didSet { defaults.set(targetMinutes, forKey: Keys.target) } }
    private var recorder: RehearsalRecorder?

    private let defaults = UserDefaults.standard
    private var lastTail: [String] = []
    private var lastTranscript = ""
    private var charIndex = Matcher.CharIndex(words: [])
    /// Language the recogniser is using right now.
    var activeLocaleID = "en-US"
    /// Note this script was imported from, so it can be reloaded.
    @Published var sourcePath: String? { didSet { defaults.set(sourcePath, forKey: Keys.source) } }

    private enum Keys {
        static let text = "script"
        static let hide = "hideFromCapture"
        static let locale = "localeID"
        static let mode = "followMode"
        static let speed = "autoSpeed"
        static let source = "sourcePath"
        static let me = "mySpeaker"
        static let target = "targetMinutes"
        static let history = "rehearsalHistory"
    }

    static let sampleScript = """
    This is QoL Notch. A teleprompter that sits right next to your camera, so you can read your script without looking like you're reading.

    It follows your voice. Pause, and it waits. Start again, and it picks up right where you left off.

    Drag it anywhere, resize it, and make it yours.
    """

    private init() {
        defaults.register(defaults: [
            Keys.hide: true,
            Keys.locale: "auto",
        ])
        text = defaults.string(forKey: Keys.text) ?? Self.sampleScript
        theme = defaults.data(forKey: Self.themeKey).flatMap { try? JSONDecoder().decode(Theme.self, from: $0) }
            ?? .midnightBlue
        hideFromCapture = defaults.bool(forKey: Keys.hide)
        localeID = defaults.string(forKey: Keys.locale) ?? "auto"
        followMode = FollowMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .voice
        let savedSpeed = defaults.double(forKey: Keys.speed)
        autoSpeed = savedSpeed > 0 ? savedSpeed : AutoScroller.defaultSpeed
        sourcePath = defaults.string(forKey: Keys.source)
        mySpeaker = defaults.string(forKey: Keys.me) ?? ""
        targetMinutes = defaults.double(forKey: Keys.target)
        if let data = defaults.data(forKey: Keys.history),
           let saved = try? JSONDecoder().decode([RehearsalReport].self, from: data) {
            history = saved
            report = saved.first
        }
        retokenize()
        loadUserThemes()
    }

    // MARK: - Themes

    static let themeKey = "themeV2"
    static var themeExtension: String { ThemeFiles.fileExtension }

    static var themesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QoL Notch/Themes", isDirectory: true)
    }

    var allThemes: [Theme] { Theme.presets + userThemes }
    /// The preset or saved theme the current one is named after, if any.
    var themeSource: Theme? { allThemes.first { $0.name == theme.name } }
    var themeIsEdited: Bool { themeSource.map { !$0.sameLook(as: theme) } ?? true }

    func isUserTheme(_ name: String) -> Bool { userThemes.contains { $0.name == name } }

    func loadUserThemes() { userThemes = ThemeFiles.load(from: Self.themesDirectory) }

    private func saveTheme() {
        if let data = try? JSONEncoder().encode(theme) { defaults.set(data, forKey: Self.themeKey) }
    }

    /// Switches to a whole theme. Views cross-fade on `themeSwitchID`; Edit > Undo goes back.
    func apply(_ new: Theme, undo: UndoManager? = nil, actionName: String = "Change Theme") {
        let previous = theme
        guard previous != new else { return }
        theme = new
        themeSwitchID += 1
        undo?.registerUndo(withTarget: self) { model in model.apply(previous, undo: undo, actionName: actionName) }
        undo?.setActionName(actionName)
    }

    func resetTheme(undo: UndoManager?) { apply(.midnightBlue, undo: undo, actionName: "Reset Theme") }

    func setFontSize(_ size: Double) {
        theme.fontSize = min(Theme.sizeRange.upperBound, max(Theme.sizeRange.lowerBound, size.rounded()))
    }

    /// Saves the current look as a theme of the user's own, under `name`.
    func saveCurrentTheme(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ThemeError.emptyName }
        guard !Theme.isPresetName(trimmed) else { throw ThemeError.reservedName }
        var copy = theme
        copy.name = trimmed
        try ThemeFiles.write(copy, to: Self.themesDirectory)
        theme = copy
        loadUserThemes()
    }

    func importTheme(from url: URL, undo: UndoManager?) throws {
        let imported = try ThemeFiles.read(url)
        if let same = allThemes.first(where: { $0.sameLook(as: imported) }) {
            apply(same, undo: undo, actionName: "Import Theme")
            return
        }
        var named = imported
        named.name = ThemeFiles.uniqueName(imported.name, taken: allThemes.map(\.name))
        try ThemeFiles.write(named, to: Self.themesDirectory)
        loadUserThemes()
        apply(named, undo: undo, actionName: "Import Theme")
    }

    func exportTheme(to url: URL) throws {
        try ThemeFiles.encode(theme).write(to: url, options: .atomic)
    }

    func deleteUserTheme(named name: String) {
        ThemeFiles.trash(named: name, in: Self.themesDirectory)
        loadUserThemes()
    }

    // MARK: - Script

    private func retokenize() {
        words = Tokenizer.tokenize(text)
        charIndex = Matcher.CharIndex(words: words)
        var names: [String] = []
        for word in words { if let name = word.speaker, !names.contains(name) { names.append(name) } }
        speakers = names
        if !mySpeaker.isEmpty && !names.contains(mySpeaker) { mySpeaker = "" }
        current = min(current, words.count)
        resetMatching()
    }

    private func resetMatching() {
        lastTail = []
        lastTranscript = ""
    }

    /// Changes Auto Scroll's pace by `delta` words per minute, within its range.
    func changeSpeed(by delta: Double) {
        autoSpeed = min(AutoScroller.speedRange.upperBound, max(AutoScroller.speedRange.lowerBound, autoSpeed + delta))
    }

    func restart() {
        recorder = nil
        current = 0
        resetMatching()
    }

    func step(_ delta: Int) {
        current = max(0, min(words.count, current + delta))
        resetMatching()
    }

    func jump(to index: Int) {
        current = max(0, min(words.count, index))
        resetMatching()
    }

    /// The recognition language to use: the chosen one, or picked from the script when set to Auto.
    var effectiveLocaleID: String {
        guard localeID == "auto" else { return localeID }
        return Tokenizer.isMostlyThai(text) ? "th-TH" : "en-US"
    }

    // MARK: - Obsidian / Markdown import

    func importNote(from url: URL) throws {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        current = 0
        text = MarkdownCleaner.speakable(markdown)
        sourcePath = url.path
    }

    var sourceName: String? {
        sourcePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }

    func reloadNote() throws {
        guard let sourcePath else { return }
        try importNote(from: URL(fileURLWithPath: sourcePath))
    }

    // MARK: - Voice matching

    /// Feed what the recogniser has heard so far: its word segments and the full transcript.
    func heard(words spoken: [String], transcript: String) {
        guard current < words.count else { return }
        recorder?.noteTranscript(transcript)
        var next: Int?
        if activeLocaleID.hasPrefix("th") {
            guard transcript != lastTranscript else { return }
            lastTranscript = transcript
            next = Matcher.advanceByChars(index: charIndex, current: current, transcript: transcript)
        } else {
            let tail = spoken.suffix(4).map(Tokenizer.normalize).filter { !$0.isEmpty }
            guard !tail.isEmpty, tail != lastTail else { return }
            lastTail = tail
            next = Matcher.advanceByWords(words: words, current: current, tail: tail)
        }
        guard var position = next else { return }
        // Skip tokens with nothing to say (stray punctuation).
        while position < words.count, words[position].norm.isEmpty { position += 1 }
        current = position
        recorder?.record(position: position)
        if position >= words.count {
            NotificationCenter.default.post(name: .qolReachedEnd, object: nil)
        }
    }

    func recognitionRestarted() {
        resetMatching()
        recorder?.recognitionTaskEnded()
    }

    // MARK: - Team scripts

    private static let speakerPalette: [RGBA] = [
        RGBA(0.45, 0.62, 1), RGBA(1, 0.62, 0.35), RGBA(0.45, 0.85, 0.55),
        RGBA(0.95, 0.5, 0.75), RGBA(0.95, 0.85, 0.4), RGBA(0.6, 0.85, 0.9),
    ]

    func colour(for speaker: String) -> RGBA {
        let index = speakers.firstIndex(of: speaker) ?? 0
        return Self.speakerPalette[index % Self.speakerPalette.count]
    }

    /// How many words until this Mac's speaker is up, when someone else is talking and it is close.
    var wordsUntilMyTurn: Int? {
        guard !mySpeaker.isEmpty, current < words.count, words[current].speaker != mySpeaker else { return nil }
        let limit = min(words.count, current + 20)
        for i in current..<limit where words[i].speakerStart && words[i].speaker == mySpeaker {
            return i - current
        }
        return nil
    }

    // MARK: - Rehearsal

    /// Call when listening begins. A run continues across pauses until Restart.
    func sessionStarted() {
        if recorder == nil || current == 0 {
            recorder = RehearsalRecorder(startPosition: current)
        }
        recorder?.resume()
    }

    /// Call when listening ends; turns what was recorded into a report.
    func sessionStopped() {
        guard var active = recorder else { return }
        active.pause()
        recorder = active
        let result = active.report(words: words, scriptText: text)
        guard result.wordsSpoken >= 3 else { return }
        report = result
        history.removeAll { $0.id == result.id }
        history.insert(result, at: 0)
        history = Array(history.prefix(20))
        saveHistory()
    }

    var elapsedSeconds: Double { recorder?.elapsed() ?? 0 }

    func clearHistory() {
        history = report.map { [$0] } ?? []
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Keys.history) }
    }

    // MARK: - Phone remote

    func remoteState() -> [String: Any] {
        let at = min(current, words.count)
        let before = RehearsalReport.join(words[max(0, at - 8)..<at])
        let now = at < words.count ? words[at].text : ""
        let after = at + 1 < words.count ? RehearsalReport.join(words[(at + 1)..<min(words.count, at + 16)]) : ""
        return [
            "listening": listening, "auto": followMode == .auto, "current": at, "total": words.count,
            "before": before, "now": now, "after": after, "elapsed": elapsedSeconds,
        ]
    }
}

extension Notification.Name {
    static let qolReachedEnd = Notification.Name("qolReachedEnd")
}
