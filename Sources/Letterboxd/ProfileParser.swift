import Foundation

/// One line of the "Activity" sidebar on a profile page.
struct ProfileActivity: Hashable {
    var key: String
    var rawDate: String
    var date: Date?
    /// Full sentence, e.g. "june added Fjord to her watchlist".
    var text: String
    /// The same sentence without the member's name.
    var sentence: String
    var targetURL: String?
    var targetText: String?
    var rating: Double?

    func classify(username: String) -> ActivityKind {
        let lower = sentence.lowercased()
        let path = targetURL.map { LetterboxdURL.path($0) } ?? ""
        let diaryVerbs = ["reviewed", "rated", "watched", "logged", "rewatched"]
        let mentionsDiary = diaryVerbs.contains { lower.contains($0) }
        if lower.contains("watchlist") { return .watchlist }
        if lower.hasPrefix("followed") || lower.contains(" followed ") { return .follow }
        if lower.contains("commented") || lower.contains("replied") { return .comment }
        if path.hasPrefix("/\(username)/film/") && mentionsDiary {
            return lower.contains("reviewed") ? .review : .diary
        }
        if lower.hasPrefix("liked") || lower.contains(" liked ") { return .like }
        if path.contains("/list/") { return lower.contains("created") ? .list : .listUpdate }
        if mentionsDiary { return lower.contains("reviewed") ? .review : .diary }
        return .other
    }
}

struct WatchlistFilm: Hashable {
    var slug: String
    var name: String
}

struct ProfileSnapshot {
    var avatarURL: String?
    var stats = ProfileStats()
    var activities: [ProfileActivity] = []
    var hasActivityTimeline = false
    var watchlistPreview: [WatchlistFilm] = []
}

/// Reads https://letterboxd.com/<username>/ — stats, avatar, the Activity sidebar and the watchlist preview.
enum ProfileParser {
    static func parse(_ html: String) -> ProfileSnapshot {
        var snapshot = ProfileSnapshot()
        let metas = metaTags(in: html)
        snapshot.avatarURL = metas["og:image"]
        snapshot.stats = stats(in: html)
        if let timeline = block(after: "<ul\\b[^>]*activity-timeline[^>]*>", until: "</ul>", in: html) {
            snapshot.hasActivityTimeline = true
            snapshot.activities = activities(in: timeline)
        }
        if let aside = block(after: "<section\\b[^>]*watchlist-aside[^>]*>", until: "</section>", in: html) {
            snapshot.watchlistPreview = watchlistFilms(in: aside)
            snapshot.stats.watchlist = Rx.first("class=[\"']?all-link[\"']?[^>]*>\\s*([\\d.,kKmM]+)\\s*<", group: 1, in: aside)
                .flatMap { number($0) }
        }
        return snapshot
    }

    static func metaTags(in html: String) -> [String: String] {
        var result: [String: String] = [:]
        for groups in Rx.all("<meta\\b[^>]*>", in: html) {
            let tag = groups[0]
            guard let key = HTML.attribute("property", in: tag) ?? HTML.attribute("name", in: tag),
                  let content = HTML.attribute("content", in: tag) else { continue }
            if result[key] == nil {
                result[key] = content
            }
        }
        return result
    }

    static func stats(in html: String) -> ProfileStats {
        var stats = ProfileStats()
        let pattern = "<span[^>]*class=[\"']?value[\"']?[^>]*>\\s*([^<]+?)\\s*</span>\\s*<span[^>]*class=[\"']?definition[^>]*>\\s*([^<]+?)\\s*</span>"
        for groups in Rx.all(pattern, in: html) {
            let value = number(groups[1])
            switch groups[2].lowercased() {
            case "films", "film": stats.films = value
            case "this year": stats.thisYear = value
            case "lists", "list": stats.lists = value
            case "following": stats.following = value
            case "followers", "follower": stats.followers = value
            default: break
            }
        }
        return stats
    }

    static func activities(in block: String) -> [ProfileActivity] {
        var results: [ProfileActivity] = []
        for raw in block.components(separatedBy: "<li").dropFirst() {
            guard let tagEnd = raw.firstIndex(of: ">") else { continue }
            var chunk = String(raw[raw.index(after: tagEnd)...])
            if let close = chunk.range(of: "</li>") {
                chunk = String(chunk[..<close.lowerBound])
            }
            let timeTag = Rx.first("<time\\b[^>]*>", in: chunk)
            let rawDate = timeTag.flatMap { HTML.attribute("datetime", in: $0) } ?? ""
            let withoutTime = Rx.replace("<time\\b[^>]*>.*?</time>", in: chunk, with: " ")

            var targetURL: String?
            var targetText: String?
            var nameAnchor: String?
            for groups in Rx.all("(<a\\b[^>]*>)(.*?)</a>", in: withoutTime) {
                let classes = (HTML.attribute("class", in: groups[1]) ?? "").split(separator: " ").map { String($0) }
                if classes.contains("name") && nameAnchor == nil {
                    nameAnchor = groups[0]
                }
                if classes.contains("target") && targetURL == nil {
                    targetURL = HTML.attribute("href", in: groups[1]).map { LetterboxdURL.absolute($0) }
                    let cleaned = Rx.replace("<span\\b[^>]*context[^>]*>.*?</span>", in: groups[2], with: " ")
                    targetText = HTML.inlineText(cleaned)
                }
            }

            let text = HTML.inlineText(withoutTime)
            guard !text.isEmpty else { continue }
            var sentenceHTML = withoutTime
            if let nameAnchor, let range = sentenceHTML.range(of: nameAnchor) {
                sentenceHTML.replaceSubrange(range, with: " ")
            }
            let sentence = HTML.inlineText(sentenceHTML)
            let rating = Rx.first("rated-(\\d+)", group: 1, in: chunk).flatMap { Double($0) }.map { $0 / 2 }
            let keyTarget = targetURL.map { LetterboxdURL.path($0) } ?? String(text.prefix(80))
            results.append(ProfileActivity(key: "act:\(rawDate)|\(keyTarget)", rawDate: rawDate,
                                           date: DateParsing.iso8601(rawDate), text: text, sentence: sentence,
                                           targetURL: targetURL, targetText: targetText, rating: rating))
        }
        return results
    }

    static func watchlistFilms(in aside: String) -> [WatchlistFilm] {
        var films: [WatchlistFilm] = []
        for groups in Rx.all("<[a-z]+\\b[^>]*data-item-slug[^>]*>", in: aside) {
            let tag = groups[0]
            guard let slug = HTML.attribute("data-item-slug", in: tag), !slug.isEmpty else { continue }
            let name = HTML.attribute("data-item-name", in: tag) ?? HTML.attribute("data-item-full-display-name", in: tag) ?? slug
            if !films.contains(where: { $0.slug == slug }) {
                films.append(WatchlistFilm(slug: slug, name: name))
            }
        }
        return films
    }

    /// Poster from a film page's structured data, falling back to its share image.
    static func filmArtwork(in html: String) -> String? {
        for groups in Rx.all("\"image\"\\s*:\\s*\"(https?:[^\"]+)\"", in: html) {
            let url = groups[1].replacingOccurrences(of: "\\/", with: "/")
            if url.contains("ltrbxd.com") { return url }
        }
        return metaTags(in: html)["og:image"]
    }

    static func number(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "").lowercased()
        if value.hasSuffix("k"), let thousands = Double(value.dropLast()) { return Int(thousands * 1_000) }
        if value.hasSuffix("m"), let millions = Double(value.dropLast()) { return Int(millions * 1_000_000) }
        return Int(value)
    }

    private static func block(after pattern: String, until terminator: String, in html: String) -> String? {
        guard let tag = Rx.first(pattern, in: html), let tagRange = html.range(of: tag) else { return nil }
        let rest = html[tagRange.upperBound...]
        let end = rest.range(of: terminator)?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}

extension ActivityItem {
    init(activity: ProfileActivity, kind: ActivityKind, username: String, detectedAt: Date) {
        let target = activity.targetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: activity.key, username: username, kind: kind, date: activity.date ?? detectedAt,
                  detectedAt: detectedAt, title: target.isEmpty ? activity.sentence : target)
        sentence = activity.sentence
        rating = activity.rating
        link = activity.targetURL
        let lower = activity.sentence.lowercased()
        liked = kind.isDiary && lower.contains("liked")
        rewatch = lower.contains("rewatched")
        fromRSS = false
    }

    /// Used when the profile has no Activity sidebar and only the watchlist preview changed.
    static func watchlistAddition(_ film: WatchlistFilm, username: String, at date: Date) -> ActivityItem {
        var name = film.name
        var year: String?
        if let groups = Rx.firstGroups("^(.*)\\s\\((\\d{4})\\)$", in: film.name) {
            name = groups[1]
            year = groups[2]
        }
        var item = ActivityItem(id: "wl:\(film.slug):\(Int(date.timeIntervalSince1970))", username: username,
                                kind: .watchlist, date: date, detectedAt: date, title: name)
        item.filmYear = year
        item.sentence = "added \(name) to their watchlist"
        item.link = "https://letterboxd.com/film/\(film.slug)/"
        return item
    }
}
