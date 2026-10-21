import Foundation

/// Cached NSRegularExpression helpers. Every pattern is case-insensitive and lets `.` cross newlines.
enum Rx {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        cache[pattern] = compiled
        return compiled
    }

    /// Whole match first, then each capture group. Groups that didn't take part come back empty.
    static func firstGroups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = regex(pattern) else { return nil }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        return groups(of: match, in: source)
    }

    static func first(_ pattern: String, group: Int = 0, in text: String) -> String? {
        guard let groups = firstGroups(pattern, in: text), group < groups.count else { return nil }
        return groups[group]
    }

    static func all(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = regex(pattern) else { return [] }
        let source = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: source.length))
        return matches.map { groups(of: $0, in: source) }
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        let source = text as NSString
        return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: source.length), withTemplate: template)
    }

    private static func groups(of match: NSTextCheckingResult, in source: NSString) -> [String] {
        (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }
}

enum HTML {
    /// Reads an attribute whether it's double-quoted, single-quoted or bare.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
        guard let groups = Rx.firstGroups(pattern, in: tag) else { return nil }
        let value = groups.dropFirst().first(where: { !$0.isEmpty }) ?? ""
        return decodeEntities(value)
    }

    /// Flattens markup into one line of readable text.
    static func inlineText(_ html: String) -> String {
        var text = Rx.replace("<[^>]+>", in: html, with: " ")
        text = decodeEntities(text).replacingOccurrences(of: "\u{00A0}", with: " ")
        text = Rx.replace("\\s+", in: text, with: " ")
        text = text.replacingOccurrences(of: " ’s ", with: "’s ")
        text = text.replacingOccurrences(of: " ,", with: ",")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps line breaks, drops everything else.
    static func blockText(_ html: String) -> String {
        var text = Rx.replace("<br\\s*/?>", in: html, with: "\n")
        text = Rx.replace("<[^>]+>", in: text, with: "")
        text = decodeEntities(text).replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = text.components(separatedBy: "\n").map { line in
            Rx.replace("[ \\t]+", in: line, with: " ").trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        output.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            if character == "&",
               let end = input[index...].prefix(12).firstIndex(of: ";"),
               let decoded = entity(String(input[input.index(after: index)..<end])) {
                output.append(decoded)
                index = input.index(after: end)
            } else {
                output.append(character)
                index = input.index(after: index)
            }
        }
        return output
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "eacute": "é", "egrave": "è", "aacute": "á",
        "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "ccedil": "ç", "copy": "©", "middot": "·"
    ]

    private static func entity(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        if body.hasPrefix("#") {
            guard let code = UInt32(body.dropFirst(), radix: 10), let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        return named[body]
    }
}

enum DateParsing {
    private static let rfc822Formatters: [DateFormatter] = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// RSS dates, e.g. "Tue, 20 Oct 2026 09:41:10 +1300".
    static func rfc822(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        for formatter in rfc822Formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Activity timestamps, e.g. "2026-10-20T06:32:24.900Z".
    static func iso8601(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}

enum LetterboxdURL {
    /// Lowercased path with leading and trailing slashes, e.g. "/june/film/warrior/1/".
    static func path(_ link: String) -> String {
        var value = link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = value.range(of: "letterboxd.com") {
            value = String(value[host.upperBound...])
        }
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[..<cut])
        }
        if !value.hasPrefix("/") { value = "/" + value }
        if !value.hasSuffix("/") { value += "/" }
        return value
    }

    static func absolute(_ href: String) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        if href.hasPrefix("//") { return "https:" + href }
        return "https://letterboxd.com" + (href.hasPrefix("/") ? href : "/" + href)
    }

    static func filmSlug(in link: String) -> String? {
        let parts = path(link).split(separator: "/").map { String($0) }
        guard let index = parts.firstIndex(of: "film"), index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }
}
