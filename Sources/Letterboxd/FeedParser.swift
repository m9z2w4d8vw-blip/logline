import Foundation

struct FeedEntry: Hashable {
    var guid: String
    var title: String
    var link: String
    var pubDate: Date?
    var descriptionHTML: String
    var filmTitle: String?
    var filmYear: String?
    var rating: Double?
    var liked: Bool
    var rewatch: Bool
    var watchedDate: String?

    /// Diary entries keep their number if a review is added later, even when the prefix changes.
    var viewingNumber: String? {
        guard guid.hasPrefix("letterboxd-review-") || guid.hasPrefix("letterboxd-watch-") else { return nil }
        return guid.components(separatedBy: "-").last
    }
}

struct FeedSnapshot {
    var channelTitle: String
    var entries: [FeedEntry]

    /// The channel title reads "Letterboxd - june".
    var displayName: String? {
        let prefix = "Letterboxd - "
        let name = channelTitle.hasPrefix(prefix) ? String(channelTitle.dropFirst(prefix.count)) : channelTitle
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Reads https://letterboxd.com/<username>/rss/ — the last 50 diary entries followed by the member's lists.
final class FeedParser: NSObject, XMLParserDelegate {
    private var entries: [FeedEntry] = []
    private var fields: [String: String]?
    private var buffer = ""
    private var channelTitle = ""

    static func parse(_ data: Data) throws -> FeedSnapshot {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let finished = parser.parse()
        if !finished && delegate.entries.isEmpty && delegate.channelTitle.isEmpty {
            throw LetterboxdError.unreadable(parser.parserError?.localizedDescription ?? "the RSS feed couldn't be read")
        }
        return FeedSnapshot(channelTitle: delegate.channelTitle, entries: delegate.entries)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" {
            fields = [:]
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        buffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if elementName == "item" {
            if let current = fields, let entry = FeedParser.entry(from: current) {
                entries.append(entry)
            }
            fields = nil
        } else if fields != nil {
            fields?[elementName] = value
        } else if elementName == "title" && channelTitle.isEmpty {
            channelTitle = value
        }
    }

    private static func entry(from fields: [String: String]) -> FeedEntry? {
        func text(_ key: String) -> String? {
            guard let value = fields[key], !value.isEmpty else { return nil }
            return value
        }
        let link = fields["link"] ?? ""
        let guid = text("guid") ?? link
        guard !guid.isEmpty else { return nil }
        return FeedEntry(
            guid: guid,
            title: fields["title"] ?? "",
            link: link,
            pubDate: text("pubDate").flatMap { DateParsing.rfc822($0) },
            descriptionHTML: fields["description"] ?? "",
            filmTitle: text("letterboxd:filmTitle"),
            filmYear: text("letterboxd:filmYear"),
            rating: text("letterboxd:memberRating").flatMap { Double($0) },
            liked: text("letterboxd:memberLike")?.lowercased() == "yes",
            rewatch: text("letterboxd:rewatch")?.lowercased() == "yes",
            watchedDate: text("letterboxd:watchedDate")
        )
    }
}

struct ParsedDescription {
    var posterURL: String?
    var paragraphs: [String] = []
    var spoilers = false
    var listFilms: [String] = []
    var listMore = 0
    var listRanked = false
}

/// Picks apart the HTML inside an RSS item's description.
enum DescriptionParser {
    static func parse(_ html: String) -> ParsedDescription {
        var result = ParsedDescription()
        if let tag = Rx.first("<img\\b[^>]*>", in: html) {
            result.posterURL = HTML.attribute("src", in: tag)
        }
        result.spoilers = html.range(of: "may contain spoilers", options: .caseInsensitive) != nil
        result.listRanked = Rx.first("<ol\\b", in: html) != nil
        result.listFilms = Rx.all("<li\\b[^>]*>\\s*<a\\b[^>]*>(.*?)</a>", in: html)
            .map { HTML.inlineText($0[1]) }
            .filter { !$0.isEmpty }
        if let more = Rx.first("plus\\s+([\\d,]+)\\s+more", group: 1, in: html) {
            result.listMore = Int(more.replacingOccurrences(of: ",", with: "")) ?? 0
        }
        for groups in Rx.all("<p\\b[^>]*>(.*?)</p>", in: html) {
            let inner = groups[1]
            if inner.range(of: "<img", options: .caseInsensitive) != nil { continue }
            let text = HTML.blockText(inner)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            if lower.contains("may contain spoilers") { continue }
            if lower.hasPrefix("watched on ") || lower.hasPrefix("rewatched on ") { continue }
            if lower.contains("view the full list on letterboxd") { continue }
            result.paragraphs.append(text)
        }
        return result
    }
}

extension ActivityItem {
    init(entry: FeedEntry, username: String, detectedAt: Date) {
        let parsed = DescriptionParser.parse(entry.descriptionHTML)
        let isList = entry.guid.contains("-list-")
        let isFilm = entry.filmTitle != nil || entry.viewingNumber != nil
        let body = parsed.paragraphs.joined(separator: "\n\n")
        let kind: ActivityKind
        if isList {
            kind = .list
        } else if isFilm {
            kind = body.isEmpty ? .diary : .review
        } else {
            kind = .other
        }
        let title = isList ? entry.title : (entry.filmTitle ?? entry.title)
        self.init(id: "rss:" + entry.guid, username: username, kind: kind,
                  date: entry.pubDate ?? detectedAt, detectedAt: detectedAt, title: title)
        filmYear = isList ? nil : entry.filmYear
        rating = entry.rating
        liked = entry.liked
        rewatch = entry.rewatch
        spoilers = parsed.spoilers || entry.title.lowercased().contains("(contains spoilers)")
        watchedDate = entry.watchedDate
        text = body.isEmpty ? nil : body
        imageURL = parsed.posterURL
        link = entry.link.isEmpty ? nil : entry.link
        listFilms = isList ? parsed.listFilms : []
        listRanked = isList && parsed.listRanked
        listCount = isList ? parsed.listFilms.count + parsed.listMore : nil
        fromRSS = true
    }

    func listUpdate(previous: Int, at date: Date) -> ActivityItem {
        let count = listCount ?? 0
        var update = ActivityItem(id: "listupd:\(id):\(count):\(Int(date.timeIntervalSince1970))", username: username,
                                  kind: .listUpdate, date: date, detectedAt: date, title: title)
        update.listFilms = listFilms
        update.listRanked = listRanked
        update.listCount = count
        update.previousListCount = previous
        update.link = link
        update.text = text
        update.fromRSS = true
        return update
    }
}
