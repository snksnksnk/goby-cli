import Foundation

enum TOMLStringParser {
    static func string(named key: String, in source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let candidateKey = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard candidateKey == key else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return parse(value: value, following: lines.dropFirst(index + 1))
        }
        return nil
    }

    private static func parse(value: String, following lines: ArraySlice<String>) -> String? {
        if value.hasPrefix("\"\"\"") {
            return parseMultiline(value: String(value.dropFirst(3)), delimiter: "\"\"\"", following: lines, unescape: true)
        }
        if value.hasPrefix("'''") {
            return parseMultiline(value: String(value.dropFirst(3)), delimiter: "'''", following: lines, unescape: false)
        }
        if value.hasPrefix("\"") {
            return parseQuoted(String(value.dropFirst()), quote: "\"", unescape: true)
        }
        if value.hasPrefix("'") {
            return parseQuoted(String(value.dropFirst()), quote: "'", unescape: false)
        }
        let bare = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        let result = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func parseMultiline(
        value: String,
        delimiter: String,
        following lines: ArraySlice<String>,
        unescape shouldUnescape: Bool
    ) -> String? {
        var chunks: [String] = []
        var current = value
        var iterator = lines.makeIterator()
        while true {
            if let closing = current.range(of: delimiter) {
                chunks.append(String(current[..<closing.lowerBound]))
                let joined = chunks.joined(separator: "\n")
                return shouldUnescape ? unescape(joined) : joined
            }
            if !current.isEmpty || !chunks.isEmpty { chunks.append(current) }
            guard let next = iterator.next() else { return nil }
            current = next
        }
    }

    private static func parseQuoted(_ value: String, quote: Character, unescape shouldUnescape: Bool) -> String? {
        var result = ""
        var escaped = false
        for character in value {
            if character == quote, !escaped {
                return shouldUnescape ? unescape(result) : result
            }
            result.append(character)
            if shouldUnescape {
                escaped = character == "\\" && !escaped
            }
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
    }
}
