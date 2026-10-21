import Foundation

enum LetterboxdError: LocalizedError {
    case notFound
    case blocked(Int)
    case http(Int)
    case unreadable(String)
    case network(String)

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Letterboxd member has that username."
        case .blocked(let code):
            return "Letterboxd turned the request away (HTTP \(code)). This usually clears up on its own."
        case .http(let code):
            return "Letterboxd returned HTTP \(code)."
        case .unreadable(let detail):
            return "Letterboxd sent back something unexpected: \(detail)."
        case .network(let detail):
            return detail
        }
    }
}

/// Talks to letterboxd.com like a desktop browser would, so the pages match what was saved and parsed.
struct LetterboxdClient {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
    private static let htmlAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    private static let feedAccept = "application/rss+xml,application/xml;q=0.9,*/*;q=0.8"

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpAdditionalHeaders = [
            "User-Agent": LetterboxdClient.userAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        session = URLSession(configuration: configuration)
    }

    /// Accepts "june", "@june", "letterboxd.com/june" or a full profile URL.
    static func username(from input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        for prefix in ["www.", "m."] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasPrefix("letterboxd.com/") {
            value = String(value.dropFirst("letterboxd.com/".count))
        }
        if value.hasPrefix("@") {
            value = String(value.dropFirst())
        }
        value = value.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map { String($0) } ?? ""
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        guard !value.isEmpty, value.count <= 40, value.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    func fetchFeed(username: String, bypassCache: Bool) async throws -> FeedSnapshot {
        let data = try await get("/\(username)/rss/", accept: LetterboxdClient.feedAccept, bypassCache: bypassCache, marker: "<rss")
        return try FeedParser.parse(data)
    }

    func fetchProfile(username: String, bypassCache: Bool) async throws -> ProfileSnapshot {
        let data = try await get("/\(username)/", accept: LetterboxdClient.htmlAccept, bypassCache: bypassCache, marker: "og:url")
        return ProfileParser.parse(String(decoding: data, as: UTF8.self))
    }

    func filmArtwork(slug: String) async -> String? {
        guard let data = try? await get("/film/\(slug)/", accept: LetterboxdClient.htmlAccept, bypassCache: false, marker: nil) else {
            return nil
        }
        return ProfileParser.filmArtwork(in: String(decoding: data, as: UTF8.self))
    }

    private func get(_ path: String, accept: String, bypassCache: Bool, marker: String?) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "letterboxd.com"
        components.path = path
        if bypassCache {
            // A throwaway query keeps a cached copy from holding back a brand-new post.
            components.queryItems = [URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970)))]
        }
        guard let url = components.url else { throw LetterboxdError.unreadable("a bad URL") }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LetterboxdError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw LetterboxdError.unreadable("no HTTP response") }
        switch http.statusCode {
        case 200...299:
            if let marker, !LetterboxdClient.contains(marker, in: data) {
                throw LetterboxdClient.looksLikeChallenge(data) ? LetterboxdError.blocked(http.statusCode)
                                                                 : LetterboxdError.unreadable("a page that wasn't a Letterboxd profile or feed")
            }
            return data
        case 404:
            throw LetterboxdError.notFound
        case 403, 429, 503:
            throw LetterboxdError.blocked(http.statusCode)
        default:
            throw LetterboxdError.http(http.statusCode)
        }
    }

    private static func contains(_ marker: String, in data: Data) -> Bool {
        String(decoding: data.prefix(300_000), as: UTF8.self).range(of: marker, options: .caseInsensitive) != nil
    }

    private static func looksLikeChallenge(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(8_000), as: UTF8.self).lowercased()
        return head.contains("just a moment") || head.contains("cf-chl") || head.contains("attention required")
    }
}

/// Everything fetched for one account in one check.
struct AccountFetch {
    var feed: Result<FeedSnapshot, Error>
    var profile: Result<ProfileSnapshot, Error>?

    static func load(username: String, client: LetterboxdClient, includeProfile: Bool, bypassCache: Bool) async -> AccountFetch {
        async let feed = capture { try await client.fetchFeed(username: username, bypassCache: bypassCache) }
        if includeProfile {
            async let profile = capture { try await client.fetchProfile(username: username, bypassCache: bypassCache) }
            return AccountFetch(feed: await feed, profile: await profile)
        }
        return AccountFetch(feed: await feed, profile: nil)
    }
}

func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
