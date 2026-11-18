import Foundation

/// Turns an Obsidian / Markdown note into plain text you can read aloud.
enum MarkdownCleaner {
    static func speakable(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")

        // YAML front matter at the very top.
        if text.hasPrefix("---\n"), let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let after = text[close.upperBound...]
            text = String(after.drop(while: { $0 != "\n" }))
        }

        text = replace(text, #"(?s)```.*?```"#, "")           // code blocks
        text = replace(text, #"(?s)%%.*?%%"#, "")             // Obsidian comments
        text = replace(text, #"(?s)<!--.*?-->"#, "")          // HTML comments
        text = replace(text, #"!\[\[[^\]]*\]\]"#, "")         // embeds
        text = replace(text, #"!\[[^\]]*\]\([^)]*\)"#, "")    // images
        text = replace(text, #"\[\[[^\]|]*\|([^\]]*)\]\]"#, "$1")   // [[note|alias]]
        text = replace(text, #"\[\[([^\]]*)\]\]"#, "$1")            // [[note]]
        text = replace(text, #"\[([^\]]*)\]\([^)]*\)"#, "$1")       // [text](url)
        text = replace(text, #"<[^>\n]+>"#, "")               // inline HTML

        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { line = "" }  // rules
            if line.hasPrefix("|") { continue }                                   // tables
            line = replace(line, #"^(>\s*)+"#, "")                                // quotes
            line = replace(line, #"^\[![^\]]*\][+-]?\s*"#, "")                    // callout marker
            line = replace(line, #"^#{1,6}\s+"#, "")                              // headings
            line = replace(line, #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, "")      // bullets, numbers, checkboxes
            line = replace(line, #"(\*\*|__|~~|==|`)"#, "")                       // bold, strike, highlight, code
            line = replace(line, #"(?<![\w*])[*_](?=\S)|(?<=\S)[*_](?![\w*])"#, "")  // italics
            line = replace(line, #"\s\^[\w-]+$"#, "")                             // block ids
            line = replace(line, #"(?<!\S)#(?=[\p{L}\p{M}])"#, "")                // tag hashes
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }

        // Collapse runs of blank lines.
        var result: [String] = []
        for line in lines {
            if line.isEmpty && (result.last?.isEmpty ?? true) { continue }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

/// Finds the user's Obsidian vaults from Obsidian's own settings file.
enum ObsidianVaults {
    static func mostRecent() -> URL? {
        let config = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return nil }
        let sorted = vaults.values.sorted {
            let a = ($0["open"] as? Bool ?? false) ? Double.greatestFiniteMagnitude : ($0["ts"] as? Double ?? 0)
            let b = ($1["open"] as? Bool ?? false) ? Double.greatestFiniteMagnitude : ($1["ts"] as? Double ?? 0)
            return a > b
        }
        for vault in sorted {
            if let path = vault["path"] as? String, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }
}
