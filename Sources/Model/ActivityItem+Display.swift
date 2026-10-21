import Foundation

extension ActivityItem {
    var stars: String? {
        guard let rating, rating > 0 else { return nil }
        let whole = Int(rating)
        let half = rating - Double(whole) >= 0.5
        return String(repeating: "★", count: whole) + (half ? "½" : "")
    }

    var filmLabel: String {
        guard let filmYear, !filmYear.isEmpty else { return title }
        return "\(title) (\(filmYear))"
    }

    var filmSlug: String? {
        guard let link else { return nil }
        return LetterboxdURL.filmSlug(in: link)
    }

    var watchedLabel: String? {
        guard let watchedDate, let day = Format.day(watchedDate) else { return nil }
        return (rewatch ? "Rewatched " : "Watched ") + day
    }

    var diaryVerb: String {
        if kind == .review {
            return rewatch ? "Rewatched and reviewed" : "Reviewed"
        }
        return rewatch ? "Rewatched" : "Watched"
    }

    var capitalizedSentence: String? {
        guard let sentence, let first = sentence.first else { return nil }
        return first.uppercased() + sentence.dropFirst()
    }

    var metaLine: String {
        switch kind {
        case .diary, .review:
            if fromRSS { return watchedLabel ?? diaryVerb }
            return capitalizedSentence ?? diaryVerb
        case .list:
            guard let listCount else { return "New list" }
            return listCount == 1 ? "1 film" : "\(listCount) films"
        case .listUpdate:
            let count = listCount ?? 0
            if let previousListCount { return "\(previousListCount) → \(count) films" }
            return "\(count) films"
        case .watchlist:
            return "Added to watchlist"
        case .like, .follow, .comment, .other:
            return capitalizedSentence ?? kind.label
        }
    }

    func snippet(hideSpoilers: Bool) -> String? {
        switch kind {
        case .review:
            guard let text, !text.isEmpty else { return nil }
            return spoilers && hideSpoilers ? "Contains spoilers. Tap to read it anyway." : text
        case .list, .listUpdate:
            guard !listFilms.isEmpty else { return text }
            let shown = listFilms.prefix(4).joined(separator: ", ")
            let more = listFilms.count > 4 || (listCount ?? 0) > 4
            return more ? shown + "…" : shown
        default:
            return nil
        }
    }

    static var sample: ActivityItem {
        let now = Date()
        var item = ActivityItem(id: "sample", username: "logline", kind: .review, date: now, detectedAt: now, title: "Paris, Texas")
        item.filmYear = "1984"
        item.rating = 4.5
        item.liked = true
        item.text = "This is what a Logline alert looks like. Real ones carry the poster, the rating and the start of the review."
        item.fromRSS = true
        return item
    }
}

enum NotificationText {
    struct Parts {
        var title: String
        var subtitle: String
        var body: String
    }

    static func parts(for item: ActivityItem, accountName: String, hideSpoilers: Bool) -> Parts {
        switch item.kind {
        case .diary, .review:
            var subtitle = item.fromRSS ? "\(item.diaryVerb) \(item.filmLabel)" : (item.capitalizedSentence ?? item.filmLabel)
            if item.fromRSS {
                if let stars = item.stars { subtitle += "  " + stars }
                if item.liked { subtitle += "  ♥" }
            }
            var body = ""
            if let text = item.text, !text.isEmpty {
                body = item.spoilers && hideSpoilers ? "Review hidden because it may contain spoilers." : Snippet.make(text, limit: 260)
            } else if let watched = item.watchedLabel {
                body = watched
            }
            return Parts(title: accountName, subtitle: subtitle, body: body)
        case .list:
            return Parts(title: accountName, subtitle: "New list: \(item.title)", body: item.snippet(hideSpoilers: hideSpoilers) ?? item.metaLine)
        case .listUpdate:
            return Parts(title: accountName, subtitle: "Updated \(item.title)", body: item.metaLine)
        default:
            return Parts(title: accountName, subtitle: "", body: item.capitalizedSentence ?? item.title)
        }
    }

    /// One line per item, for digest notifications.
    static func line(for item: ActivityItem) -> String {
        switch item.kind {
        case .diary, .review:
            guard item.fromRSS else { return item.capitalizedSentence ?? item.filmLabel }
            if let stars = item.stars { return "\(item.diaryVerb) \(item.filmLabel) \(stars)" }
            return "\(item.diaryVerb) \(item.filmLabel)"
        case .list:
            return "New list: \(item.title)"
        case .listUpdate:
            return "Updated \(item.title)"
        default:
            return item.capitalizedSentence ?? item.title
        }
    }
}
