import Foundation
import NaturalLanguage

/// One speakable unit of the script.
struct Word: Identifiable {
    let id: Int
    let text: String
    /// Lowercased, punctuation-free form used for matching against speech.
    let norm: String
    /// True when a blank line preceded this word in the script.
    let paragraphStart: Bool
    /// True when this word follows the previous one with no space (Thai has no spaces between words).
    let glue: Bool
    /// Who says this word, when the script names speakers with lines like "@Itim:".
    let speaker: String?
    /// True for the first word of a speaker's turn.
    let speakerStart: Bool
}

enum Tokenizer {
    static func isThai(_ scalar: Unicode.Scalar) -> Bool {
        (0x0E00...0x0E7F).contains(scalar.value)
    }

    static func containsThai(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: isThai)
    }

    /// True when at least 30% of the letters in the text are Thai.
    static func isMostlyThai(_ s: String) -> Bool {
        var thai = 0
        var letters = 0
        for scalar in s.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if isThai(scalar) { thai += 1 }
        }
        return letters > 0 && Double(thai) / Double(letters) >= 0.3
    }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Splits the script into words. Space-separated chunks containing Thai are
    /// further segmented into Thai words so each one can be tracked and highlighted.
    /// Recognises a speaker line: "@Name: text" or "@Name" on its own.
    static func speakerTag(_ line: String) -> (name: String, rest: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return nil }
        let body = trimmed.dropFirst()
        let name: Substring
        let rest: Substring
        if let colon = body.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            name = body[..<colon]
            rest = body[body.index(after: colon)...]
        } else {
            name = body
            rest = ""
        }
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.count <= 24, cleaned.split(separator: " ").count <= 3 else { return nil }
        return (cleaned, String(rest))
    }

    static func tokenize(_ text: String) -> [Word] {
        var result: [Word] = []
        var pendingBreak = false
        var speaker: String?
        var speakerPending = false
        for var line in text.components(separatedBy: "\n") {
            if let tag = speakerTag(line) {
                speaker = tag.name
                speakerPending = true
                pendingBreak = !result.isEmpty
                line = tag.rest
            }
            let chunks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if chunks.isEmpty {
                if !speakerPending { pendingBreak = !result.isEmpty }
                continue
            }
            for chunk in chunks {
                let raw = String(chunk)
                let parts = containsThai(raw) ? segment(raw) : [raw]
                for (k, part) in parts.enumerated() {
                    result.append(Word(
                        id: result.count,
                        text: part,
                        norm: normalize(part),
                        paragraphStart: pendingBreak && k == 0,
                        glue: k > 0,
                        speaker: speaker,
                        speakerStart: speakerPending && k == 0
                    ))
                }
                pendingBreak = false
                speakerPending = false
            }
        }
        return result
    }

    /// Breaks an unspaced chunk into words, keeping punctuation attached to a neighbour.
    static func segment(_ chunk: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = chunk
        tokenizer.setLanguage(.thai)

        var parts: [String] = []
        var prefix = ""
        var cursor = chunk.startIndex
        tokenizer.enumerateTokens(in: chunk.startIndex..<chunk.endIndex) { range, _ in
            let gap = String(chunk[cursor..<range.lowerBound])
            if !gap.isEmpty {
                if parts.isEmpty { prefix += gap } else { parts[parts.count - 1] += gap }
            }
            parts.append(prefix + String(chunk[range]))
            prefix = ""
            cursor = range.upperBound
            return true
        }
        let trailing = String(chunk[cursor...])
        if parts.isEmpty { return [chunk] }
        if !trailing.isEmpty { parts[parts.count - 1] += trailing }
        return parts
    }
}
