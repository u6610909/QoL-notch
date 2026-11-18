import Foundation

/// How the script moves: by listening to the reader, or on its own at a set pace.
enum FollowMode: String, CaseIterable, Identifiable {
    case voice, auto
    var id: String { rawValue }
    var title: String { self == .voice ? "Voice Follow" : "Auto Scroll" }
    /// The symbol on Start buttons for this mode.
    var startIcon: String { self == .voice ? "mic.fill" : "play.fill" }
}

/// Moves through the script one word at a time at a steady reading pace, with short rests at
/// commas and longer ones at the end of sentences and paragraphs, the way people read aloud.
final class AutoScroller {
    static let speedRange = 60.0...240.0
    static let defaultSpeed = 140.0

    private var work: DispatchWorkItem?
    var isRunning: Bool { work != nil }

    /// Seconds to stay on `word` before moving on, at `wordsPerMinute`. Pure, so it can be tested.
    static func dwell(on word: Word, next: Word?, wordsPerMinute: Double) -> TimeInterval {
        guard !word.norm.isEmpty else { return 0 }
        let base = 60 / min(max(wordsPerMinute, speedRange.lowerBound), speedRange.upperBound)
        let end = word.text.trimmingCharacters(in: .whitespaces).last
        var factor = 1.0
        if let end, ".!?…".contains(end) { factor = 2.2 }
        else if let end, ",;:—–".contains(end) { factor = 1.5 }
        // A new paragraph after this word is a natural breath.
        if next?.paragraphStart == true { factor = max(factor, 2.6) }
        // Very long words take a little longer to say.
        if word.norm.count > 9 { factor *= 1.25 }
        return base * factor
    }

    /// Starts moving `model` through its script; `finished` runs once the last word is reached.
    func start(_ model: PrompterModel, finished: @escaping () -> Void) {
        stop()
        scheduleNext(model, finished: finished)
    }

    func stop() {
        work?.cancel()
        work = nil
    }

    private func scheduleNext(_ model: PrompterModel, finished: @escaping () -> Void) {
        let words = model.words
        guard model.current < words.count else {
            stop()
            finished()
            return
        }
        let word = words[model.current]
        let next = model.current + 1 < words.count ? words[model.current + 1] : nil
        let item = DispatchWorkItem { [weak self, weak model] in
            guard let self, let model, self.work != nil else { return }
            var position = model.current + 1
            // Skip tokens with nothing to say (stray punctuation).
            while position < words.count, words[position].norm.isEmpty { position += 1 }
            model.jump(to: position)
            self.scheduleNext(model, finished: finished)
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell(on: word, next: next, wordsPerMinute: model.autoSpeed),
                                      execute: item)
    }
}
