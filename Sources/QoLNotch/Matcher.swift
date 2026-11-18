import Foundation

/// Works out how far through the script the speaker has got.
enum Matcher {
    // MARK: - Word matching (languages written with spaces)

    static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        // Tolerate plural / tense / recogniser spelling differences on longer words.
        if min(a.count, b.count) >= 4 {
            return a.commonPrefix(with: b).count >= min(a.count, b.count) - 1
                && abs(a.count - b.count) <= 2
        }
        return false
    }

    /// Returns the new position if the most recent spoken words line up with the
    /// script a little ahead of `current`, or nil if nothing matched.
    static func advanceByWords(words: [Word], current: Int, tail: [String]) -> Int? {
        guard !tail.isEmpty, current < words.count else { return nil }
        let hi = min(words.count - 1, current + 25)
        var bestEnd = -1
        var bestScore = 0
        for j in current...hi {
            var score = 0
            while score < tail.count, j - score >= 0,
                  fuzzyEqual(words[j - score].norm, tail[tail.count - 1 - score]) {
                score += 1
            }
            guard score > 0 else { continue }
            // A single matching word only counts if it is the very next word or the one after;
            // jumping further ahead needs at least two words in a row.
            let acceptable = score >= 2 || (j - current) <= 1
            if acceptable && score > bestScore {
                bestScore = score
                bestEnd = j
            }
        }
        return bestEnd >= 0 ? bestEnd + 1 : nil
    }

    // MARK: - Character matching (Thai and mixed scripts)

    /// The whole script as one run of normalised characters, with a map back to words.
    struct CharIndex {
        var scalars: [Unicode.Scalar] = []
        /// Word that owns each character.
        var owner: [Int] = []
        /// Offset of each word's first character; has one extra entry for the end.
        var wordStart: [Int] = [0]

        init(words: [Word]) {
            for word in words {
                for scalar in word.norm.unicodeScalars {
                    scalars.append(scalar)
                    owner.append(word.id)
                }
                wordStart.append(scalars.count)
            }
        }
    }

    /// Thai speech arrives as unspaced text whose word boundaries may not match the
    /// script's, so the end of the transcript is aligned to the script character by character.
    static func advanceByChars(index: CharIndex, current: Int, transcript: String) -> Int? {
        guard current < index.wordStart.count - 1 else { return nil }
        let tail = Array(Tokenizer.normalize(transcript).unicodeScalars.suffix(12))
        guard tail.count >= 3 else { return nil }

        let start = index.wordStart[current]
        let end = min(index.scalars.count, start + 80)
        guard start < end else { return nil }

        var bestJ = -1
        var bestLength = 0
        for j in start..<end {
            var length = 0
            while length < tail.count, j - length >= 0,
                  index.scalars[j - length] == tail[tail.count - 1 - length] {
                length += 1
            }
            // Short matches only count close to the current position; a jump needs more evidence.
            let near = j - start < 6
            if (length >= 5 || (length >= 3 && near)) && length > bestLength {
                bestLength = length
                bestJ = j
            }
        }
        guard bestJ >= 0 else { return nil }
        let word = index.owner[bestJ]
        let finishedWord = bestJ + 1 == index.wordStart[word + 1]
        let position = finishedWord ? word + 1 : word
        return position > current ? position : nil
    }
}
