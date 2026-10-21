import Foundation

// MARK: - Kinds of activity

enum ActivityKind: String, Codable, CaseIterable, Identifiable {
    case diary
    case review
    case list
    case listUpdate
    case watchlist
    case like
    case follow
    case comment
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .diary: return "Diary"
        case .review: return "Review"
        case .list: return "List"
        case .listUpdate: return "List change"
        case .watchlist: return "Watchlist"
        case .like: return "Like"
        case .follow: return "Follow"
        case .comment: return "Comment"
        case .other: return "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .diary: return "film"
        case .review: return "text.quote"
        case .list: return "list.bullet.rectangle"
        case .listUpdate: return "list.bullet.indent"
        case .watchlist: return "clock"
        case .like: return "heart"
        case .follow: return "person.badge.plus"
        case .comment: return "bubble.left"
        case .other: return "sparkles"
        }
    }

    var isDiary: Bool { self == .diary || self == .review }
}

/// Groups of kinds that can be muted per account.
enum NotificationTopic: String, CaseIterable, Identifiable {
    case diary
    case lists
    case watchlist
    case likes
    case follows
    case other

    var id: String { rawValue }

    var kinds: [ActivityKind] {
        switch self {
        case .diary: return [.diary, .review]
        case .lists: return [.list, .listUpdate]
        case .watchlist: return [.watchlist]
        case .likes: return [.like]
        case .follows: return [.follow]
        case .other: return [.comment, .other]
        }
    }

    var label: String {
        switch self {
        case .diary: return "Diary entries and reviews"
        case .lists: return "New and changed lists"
        case .watchlist: return "Watchlist additions"
        case .likes: return "Likes"
        case .follows: return "Follows"
        case .other: return "Comments and anything else"
        }
    }
}

// MARK: - Preferences

enum MonitoringMode: String, Codable, CaseIterable, Identifiable {
    case instant
    case standard

    var id: String { rawValue }
    var label: String { self == .instant ? "Instant" : "Standard" }
}

struct Preferences: Codable, Equatable {
    static let intervals: [Double] = [30, 60, 120, 300, 900]

    var mode: MonitoringMode = .instant
    var pollInterval: Double = 60
    var watchdog = true
    var attachImages = true
    var timeSensitive = true
    var hideSpoilers = true
    var watchProfiles = true
    var bypassCache = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case mode, pollInterval, watchdog, attachImages, timeSensitive, hideSpoilers, watchProfiles, bypassCache
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        mode = (try? values.decode(MonitoringMode.self, forKey: .mode)) ?? defaults.mode
        pollInterval = (try? values.decode(Double.self, forKey: .pollInterval)) ?? defaults.pollInterval
        watchdog = (try? values.decode(Bool.self, forKey: .watchdog)) ?? defaults.watchdog
        attachImages = (try? values.decode(Bool.self, forKey: .attachImages)) ?? defaults.attachImages
        timeSensitive = (try? values.decode(Bool.self, forKey: .timeSensitive)) ?? defaults.timeSensitive
        hideSpoilers = (try? values.decode(Bool.self, forKey: .hideSpoilers)) ?? defaults.hideSpoilers
        watchProfiles = (try? values.decode(Bool.self, forKey: .watchProfiles)) ?? defaults.watchProfiles
        bypassCache = (try? values.decode(Bool.self, forKey: .bypassCache)) ?? defaults.bypassCache
    }
}

// MARK: - Accounts

struct ProfileStats: Codable, Hashable {
    var films: Int?
    var thisYear: Int?
    var lists: Int?
    var following: Int?
    var followers: Int?
    var watchlist: Int?

    var hasValues: Bool {
        films != nil || thisYear != nil || following != nil || followers != nil || watchlist != nil
    }

    var summary: String {
        var parts: [String] = []
        if let films { parts.append(films == 1 ? "1 film" : "\(films) films") }
        if let thisYear { parts.append("\(thisYear) this year") }
        if let followers { parts.append(followers == 1 ? "1 follower" : "\(followers) followers") }
        return parts.joined(separator: ", ")
    }
}

enum ProfileMode: String, Codable {
    case unknown
    case timeline
    case watchlistOnly
}

struct TrackedAccount: Codable, Identifiable, Hashable {
    var username: String
    var displayName: String
    var avatarURL: String?
    var addedAt: Date
    var notificationsEnabled = true
    var mutedKinds: [ActivityKind] = []
    var stats: ProfileStats?
    var lastChecked: Date?
    var lastSuccess: Date?
    var lastError: String?
    var profileNote: String?
    var profileMode: ProfileMode = .unknown
    var profileBlockedUntil: Date?
    var feedBaselined = false
    var activityBaselined = false
    var seenKeys: [String] = []
    var newestFeedDate: Date?
    var newestActivityDate: Date?
    var listSizes: [String: Int] = [:]

    var id: String { username }

    init(username: String, displayName: String, addedAt: Date) {
        self.username = username
        self.displayName = displayName
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case username, displayName, avatarURL, addedAt, notificationsEnabled, mutedKinds, stats
        case lastChecked, lastSuccess, lastError, profileNote, profileMode, profileBlockedUntil
        case feedBaselined, activityBaselined, seenKeys, newestFeedDate, newestActivityDate, listSizes
    }

    var profileURL: URL? { URL(string: "https://letterboxd.com/\(username)/") }

    func wants(_ kind: ActivityKind) -> Bool {
        notificationsEnabled && !mutedKinds.contains(kind)
    }

    func profilePaused(at date: Date) -> Bool {
        (profileBlockedUntil ?? .distantPast) > date
    }
}

extension TrackedAccount {
    /// Tolerant decoding so new fields in later builds never wipe saved accounts.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .username)
        username = name
        displayName = (try? values.decode(String.self, forKey: .displayName)) ?? name
        avatarURL = try? values.decode(String.self, forKey: .avatarURL)
        addedAt = (try? values.decode(Date.self, forKey: .addedAt)) ?? Date()
        notificationsEnabled = (try? values.decode(Bool.self, forKey: .notificationsEnabled)) ?? true
        let muted = (try? values.decode([String].self, forKey: .mutedKinds)) ?? []
        mutedKinds = muted.compactMap { ActivityKind(rawValue: $0) }
        stats = try? values.decode(ProfileStats.self, forKey: .stats)
        lastChecked = try? values.decode(Date.self, forKey: .lastChecked)
        lastSuccess = try? values.decode(Date.self, forKey: .lastSuccess)
        lastError = try? values.decode(String.self, forKey: .lastError)
        profileNote = try? values.decode(String.self, forKey: .profileNote)
        profileMode = (try? values.decode(ProfileMode.self, forKey: .profileMode)) ?? .unknown
        profileBlockedUntil = try? values.decode(Date.self, forKey: .profileBlockedUntil)
        feedBaselined = (try? values.decode(Bool.self, forKey: .feedBaselined)) ?? false
        activityBaselined = (try? values.decode(Bool.self, forKey: .activityBaselined)) ?? false
        seenKeys = (try? values.decode([String].self, forKey: .seenKeys)) ?? []
        newestFeedDate = try? values.decode(Date.self, forKey: .newestFeedDate)
        newestActivityDate = try? values.decode(Date.self, forKey: .newestActivityDate)
        listSizes = (try? values.decode([String: Int].self, forKey: .listSizes)) ?? [:]
    }
}

// MARK: - Activity

struct ActivityItem: Codable, Identifiable, Hashable {
    var id: String
    var username: String
    var kind: ActivityKind
    /// When it happened on Letterboxd.
    var date: Date
    /// When Logline first saw it.
    var detectedAt: Date
    /// Film title, list name, or whatever the activity points at.
    var title: String
    /// Letterboxd's own phrasing without the member's name, e.g. "added Fjord to her watchlist".
    var sentence: String?
    var filmYear: String?
    var rating: Double?
    var liked = false
    var rewatch = false
    var spoilers = false
    var watchedDate: String?
    /// Review text, or a list's description.
    var text: String?
    var imageURL: String?
    var link: String?
    var listFilms: [String] = []
    var listRanked = false
    var listCount: Int?
    var previousListCount: Int?
    var unread = false
    /// Caught as it happened, rather than found in history when the account was added.
    var live = false
    var fromRSS = false

    init(id: String, username: String, kind: ActivityKind, date: Date, detectedAt: Date, title: String) {
        self.id = id
        self.username = username
        self.kind = kind
        self.date = date
        self.detectedAt = detectedAt
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, username, kind, date, detectedAt, title, sentence, filmYear, rating, liked, rewatch, spoilers
        case watchedDate, text, imageURL, link, listFilms, listRanked, listCount, previousListCount
        case unread, live, fromRSS
    }
}

extension ActivityItem {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id = try values.decode(String.self, forKey: .id)
        username = try values.decode(String.self, forKey: .username)
        kind = (try? values.decode(ActivityKind.self, forKey: .kind)) ?? .other
        date = (try? values.decode(Date.self, forKey: .date)) ?? now
        detectedAt = (try? values.decode(Date.self, forKey: .detectedAt)) ?? now
        title = (try? values.decode(String.self, forKey: .title)) ?? ""
        sentence = try? values.decode(String.self, forKey: .sentence)
        filmYear = try? values.decode(String.self, forKey: .filmYear)
        rating = try? values.decode(Double.self, forKey: .rating)
        liked = (try? values.decode(Bool.self, forKey: .liked)) ?? false
        rewatch = (try? values.decode(Bool.self, forKey: .rewatch)) ?? false
        spoilers = (try? values.decode(Bool.self, forKey: .spoilers)) ?? false
        watchedDate = try? values.decode(String.self, forKey: .watchedDate)
        text = try? values.decode(String.self, forKey: .text)
        imageURL = try? values.decode(String.self, forKey: .imageURL)
        link = try? values.decode(String.self, forKey: .link)
        listFilms = (try? values.decode([String].self, forKey: .listFilms)) ?? []
        listRanked = (try? values.decode(Bool.self, forKey: .listRanked)) ?? false
        listCount = try? values.decode(Int.self, forKey: .listCount)
        previousListCount = try? values.decode(Int.self, forKey: .previousListCount)
        unread = (try? values.decode(Bool.self, forKey: .unread)) ?? false
        live = (try? values.decode(Bool.self, forKey: .live)) ?? false
        fromRSS = (try? values.decode(Bool.self, forKey: .fromRSS)) ?? false
    }
}

struct BackgroundRun: Codable, Hashable, Identifiable {
    var date: Date
    var trigger: String
    var duration: Double
    var newItems: Int
    var ok: Bool

    var id: Date { date }
}

struct PersistedState: Codable {
    var accounts: [TrackedAccount] = []
    var items: [ActivityItem] = []
    var imageCache: [String: String] = [:]
    var backgroundRuns: [BackgroundRun] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case accounts, items, imageCache, backgroundRuns
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try? values.decode([TrackedAccount].self, forKey: .accounts)) ?? []
        items = (try? values.decode([ActivityItem].self, forKey: .items)) ?? []
        imageCache = (try? values.decode([String: String].self, forKey: .imageCache)) ?? [:]
        backgroundRuns = (try? values.decode([BackgroundRun].self, forKey: .backgroundRuns)) ?? []
    }
}
