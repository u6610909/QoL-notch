import Foundation

/// What a run-through looked like: pace, pauses, time per section, filler words.
struct RehearsalReport: Codable, Identifiable, Equatable {
    struct Pause: Codable, Equatable, Identifiable {
        var wordIndex: Int
        var seconds: Double
        var context: String
        var id: Int { wordIndex }
    }
    struct Section: Codable, Equatable, Identifiable {
        var title: String
        var seconds: Double
        var words: Int
        var firstWord: Int
        var id: Int { firstWord }
    }
    struct Filler: Codable, Equatable, Identifiable {
        var word: String
        var count: Int
        var id: String { word }
    }

    var id = UUID()
    var date = Date()
    var duration = 0.0
    var wordsSpoken = 0
    var totalWords = 0
    var wordsPerMinute = 0.0
    var pauses: [Pause] = []
    var sections: [Section] = []
    var fillers: [Filler] = []

    var finished: Bool { totalWords > 0 && wordsSpoken >= totalWords }
    var longestPause: Double { pauses.map(\.seconds).max() ?? 0 }
    var fillerCount: Int { fillers.reduce(0) { $0 + $1.count } }

    /// A gap this long between words counts as a pause worth showing.
    static let pauseThreshold = 2.5

    static let englishFillers = ["um", "uh", "er", "ah", "hmm", "basically", "actually", "literally", "like"]
    static let thaiFillers = ["เอ่อ", "อ่า", "เอิ่ม", "อืม", "แบบว่า", "ก็คือ"]

    /// Joins words back into readable text, respecting Thai words that sit together unspaced.
    static func join(_ words: ArraySlice<Word>) -> String {
        var out = ""
        for word in words {
            if !out.isEmpty && !word.glue { out += " " }
            out += word.text
        }
        return out
    }

    /// Builds a report from the moments the tracker advanced.
    /// - Parameter events: (seconds since start, new position) each time the position moved forward.
    static func build(
        words: [Word],
        events: [(t: Double, position: Int)],
        startPosition: Int,
        duration: Double,
        transcript: String,
        scriptText: String,
        id: UUID = UUID(),
        date: Date = Date()
    ) -> RehearsalReport {
        var report = RehearsalReport(id: id, date: date)
        report.duration = duration
        report.totalWords = words.count
        let furthest = events.map(\.position).max() ?? startPosition
        report.wordsSpoken = max(0, furthest - startPosition)
        if duration >= 1 {
            report.wordsPerMinute = Double(report.wordsSpoken) / (duration / 60)
        }

        // Pauses: long gaps between one advance and the next.
        for i in events.indices.dropFirst() {
            let gap = events[i].t - events[i - 1].t
            guard gap > pauseThreshold else { continue }
            let at = min(events[i - 1].position, max(0, words.count - 1))
            let lo = max(0, at - 3)
            let hi = min(words.count, at + 3)
            report.pauses.append(Pause(wordIndex: at, seconds: gap, context: join(words[lo..<hi])))
        }

        // When each word was passed.
        var passed = [Double?](repeating: nil, count: words.count)
        var cursor = startPosition
        for event in events where event.position > cursor {
            for i in cursor..<min(event.position, words.count) { passed[i] = event.t }
            cursor = event.position
        }

        // Sections: one per speaker turn if the script names speakers, otherwise one per paragraph.
        let bySpeaker = words.contains { $0.speaker != nil }
        var starts: [Int] = []
        for word in words {
            let boundary = bySpeaker ? word.speakerStart : word.paragraphStart
            if word.id == 0 || boundary { starts.append(word.id) }
        }
        let firstTime = max(0, (events.first?.t ?? 0) - 1)
        for (n, a) in starts.enumerated() {
            let b = n + 1 < starts.count ? starts[n + 1] : words.count
            guard b > a, let end = passed[b - 1] else { continue }
            let begin = a > 0 ? (passed[a - 1] ?? firstTime) : firstTime
            let title: String
            if bySpeaker {
                title = words[a].speaker ?? "Everyone"
            } else {
                title = join(words[a..<min(b, a + 5)]) + (b - a > 5 ? "…" : "")
            }
            report.sections.append(Section(title: title, seconds: max(0, end - begin), words: b - a, firstWord: a))
        }

        report.fillers = countFillers(heard: transcript, script: scriptText)
        return report
    }

    /// Filler words heard beyond what the script itself contains. Approximate:
    /// speech recognisers often drop "um" and "uh" on their own.
    static func countFillers(heard: String, script: String) -> [Filler] {
        func englishCounts(_ s: String) -> [String: Int] {
            var counts: [String: Int] = [:]
            for token in s.lowercased().split(whereSeparator: { !$0.isLetter }) {
                counts[String(token), default: 0] += 1
            }
            return counts
        }
        func occurrences(of needle: String, in haystack: String) -> Int {
            haystack.components(separatedBy: needle).count - 1
        }
        var result: [Filler] = []
        let heardEnglish = englishCounts(heard)
        let scriptEnglish = englishCounts(script)
        for filler in englishFillers {
            let extra = (heardEnglish[filler] ?? 0) - (scriptEnglish[filler] ?? 0)
            if extra > 0 { result.append(Filler(word: filler, count: extra)) }
        }
        for filler in thaiFillers {
            let extra = occurrences(of: filler, in: heard) - occurrences(of: filler, in: script)
            if extra > 0 { result.append(Filler(word: filler, count: extra)) }
        }
        return result.sorted { $0.count > $1.count }
    }
}

/// Collects what happens during one run-through. Time only runs while listening.
struct RehearsalRecorder {
    let id = UUID()
    let startedAt = Date()
    let startPosition: Int
    private(set) var events: [(t: Double, position: Int)] = []
    private var elapsedBefore = 0.0
    private var resumedAt: Date?
    private var finishedTranscripts: [String] = []
    private var liveTranscript = ""

    init(startPosition: Int) {
        self.startPosition = startPosition
    }

    func elapsed(at now: Date = Date()) -> Double {
        elapsedBefore + (resumedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    mutating func resume(at now: Date = Date()) {
        if resumedAt == nil { resumedAt = now }
    }

    mutating func pause(at now: Date = Date()) {
        elapsedBefore = elapsed(at: now)
        resumedAt = nil
        recognitionTaskEnded()
    }

    mutating func record(position: Int, at now: Date = Date()) {
        events.append((elapsed(at: now), position))
    }

    mutating func noteTranscript(_ transcript: String) {
        liveTranscript = transcript
    }

    /// The recogniser starts a fresh transcript for each task, so bank the finished one.
    mutating func recognitionTaskEnded() {
        if !liveTranscript.isEmpty { finishedTranscripts.append(liveTranscript) }
        liveTranscript = ""
    }

    func report(words: [Word], scriptText: String, now: Date = Date()) -> RehearsalReport {
        // Time counts up to the last word spoken, so trailing silence before pressing Pause is ignored.
        let spokenUntil = events.last?.t ?? 0
        let transcript = (finishedTranscripts + [liveTranscript]).joined(separator: " ")
        return RehearsalReport.build(
            words: words, events: events, startPosition: startPosition,
            duration: spokenUntil, transcript: transcript, scriptText: scriptText,
            id: id, date: startedAt
        )
    }
}
