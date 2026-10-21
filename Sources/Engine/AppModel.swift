import SwiftUI
import UIKit
import UserNotifications

enum CheckTrigger: String {
    case foreground = "Foreground"
    case instant = "Instant"
    case backgroundRefresh = "Background refresh"
    case backgroundProcessing = "Background processing"
    case manual = "Manual"
}

struct CheckSummary {
    var newItems = 0
    var failures = 0
    var success: Bool { failures == 0 }
}

/// Seen-key bookkeeping for one account during one check.
private final class KeyLedger {
    private var seen: Set<String>
    private(set) var added: [String] = []

    init(_ keys: [String]) {
        seen = Set(keys)
    }

    func contains(_ key: String) -> Bool {
        seen.contains(key)
    }

    func insert(_ key: String) {
        if seen.insert(key).inserted {
            added.append(key)
        }
    }
}

/// Owns the tracked accounts, the activity history and the polling engine.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var accounts: [TrackedAccount]
    @Published private(set) var items: [ActivityItem]
    @Published private(set) var backgroundRuns: [BackgroundRun]
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckAt: Date?
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var timeSensitiveSupported = false
    @Published private(set) var keepAliveRunning = false
    @Published private(set) var availableUpdate: ReleaseInfo?
    @Published private(set) var updateMessage: String?
    @Published private(set) var isCheckingForUpdate = false
    @Published var presentedItem: ActivityItem?
    @Published var prefs: Preferences {
        didSet { preferencesChanged(from: oldValue) }
    }

    private let client = LetterboxdClient()
    private let keepAlive = KeepAlive()
    private var imageCache: [String: String]
    private var artworkMisses: Set<String> = []
    private var loopTask: Task<Void, Never>?
    private var inFlight: Task<CheckSummary, Never>?
    private var isActive = false
    private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    private var lastUpdateCheck: Date?
    private var lastPersist = Date.distantPast

    private static let stateFile = "state.json"
    private static let prefsKey = "logline.preferences"
    private static let maxItems = 600
    private static let seenLimit = 1500

    private init() {
        let state = Storage.read(PersistedState.self, from: AppModel.stateFile) ?? PersistedState()
        accounts = state.accounts
        items = state.items
        backgroundRuns = state.backgroundRuns
        imageCache = state.imageCache
        if let data = UserDefaults.standard.data(forKey: AppModel.prefsKey),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            prefs = saved
        } else {
            prefs = Preferences()
        }
    }

    // MARK: - Reading state

    var unreadCount: Int {
        items.reduce(0) { $0 + ($1.unread ? 1 : 0) }
    }

    func account(_ username: String) -> TrackedAccount? {
        accounts.first { $0.username == username }
    }

    func items(for username: String) -> [ActivityItem] {
        items.filter { $0.username == username }
    }

    // MARK: - App lifecycle

    func didFinishLaunching() {
        let place = UIApplication.shared.applicationState == .background ? "in the background" : "in the foreground"
        Log.shared.add("Launched build \(AppInfo.build) \(place)")
        BackgroundScheduler.scheduleAll()
        applyMonitoring()
        updateBadge()
        Task { await self.refreshNotificationStatus() }
    }

    func willTerminate() {
        Log.shared.add("Logline is closing")
        persist()
        Log.shared.save(force: true)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let loopWasRunning = loopTask != nil
            isActive = true
            endBackgroundTime()
            applyMonitoring()
            if loopWasRunning && Date().timeIntervalSince(lastCheckAt ?? .distantPast) > 10 {
                Task { _ = await self.checkAll(trigger: .foreground) }
            }
            Task {
                await self.refreshNotificationStatus()
                await self.checkForUpdateIfDue()
            }
        case .background:
            isActive = false
            BackgroundScheduler.scheduleAll()
            if inFlight != nil && !wantsKeepAlive {
                beginBackgroundTime()
            }
            applyMonitoring()
            persist()
            Log.shared.save(force: true)
        default:
            break
        }
    }

    // MARK: - Monitoring

    private var wantsKeepAlive: Bool {
        prefs.mode == .instant && !accounts.isEmpty
    }

    /// How long Instant mode can go quiet before the "stopped watching" alert fires.
    private var watchdogDelay: TimeInterval {
        max(600, prefs.pollInterval * 4 + 120)
    }

    private func applyMonitoring() {
        if wantsKeepAlive {
            keepAliveRunning = keepAlive.isPlaying ? true : keepAlive.start()
            if prefs.watchdog {
                Notifier.scheduleWatchdog(after: watchdogDelay)
            } else {
                Notifier.cancelWatchdog()
            }
        } else {
            if keepAlive.isPlaying || keepAliveRunning {
                keepAlive.stop()
            }
            keepAliveRunning = false
            Notifier.cancelWatchdog()
        }
        if wantsKeepAlive || isActive {
            startLoop()
        } else {
            stopLoop()
        }
    }

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.wantsKeepAlive && !self.keepAlive.isPlaying {
                    self.keepAliveRunning = self.keepAlive.start()
                }
                if !self.accounts.isEmpty {
                    _ = await self.checkAll(trigger: self.isActive ? .foreground : .instant)
                }
                let seconds = max(15, self.prefs.pollInterval)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Checking

    /// Runs one check of every account. Overlapping callers share the check already in flight.
    @discardableResult
    func checkAll(trigger: CheckTrigger) async -> CheckSummary {
        if let running = inFlight {
            return await running.value
        }
        let task = Task { await self.runCheck(trigger: trigger) }
        inFlight = task
        let summary = await task.value
        inFlight = nil
        return summary
    }

    private func runCheck(trigger: CheckTrigger) async -> CheckSummary {
        guard !accounts.isEmpty else { return CheckSummary() }
        isChecking = true
        defer {
            isChecking = false
            endBackgroundTime()
        }

        let started = Date()
        let client = self.client
        let bypass = prefs.bypassCache
        let plan: [(username: String, profile: Bool)] = accounts.map { account in
            (username: account.username, profile: prefs.watchProfiles && !account.profilePaused(at: started))
        }

        let fetches = await withTaskGroup(of: (String, AccountFetch).self, returning: [String: AccountFetch].self) { group in
            for entry in plan {
                group.addTask {
                    let fetch = await AccountFetch.load(username: entry.username, client: client,
                                                        includeProfile: entry.profile, bypassCache: bypass)
                    return (entry.username, fetch)
                }
            }
            var collected: [String: AccountFetch] = [:]
            for await (username, fetch) in group {
                collected[username] = fetch
            }
            return collected
        }

        var fresh: [ActivityItem] = []
        var failures = 0
        let now = Date()
        for entry in plan {
            guard let fetch = fetches[entry.username],
                  let index = accounts.firstIndex(where: { $0.username == entry.username }) else { continue }
            let outcome = apply(fetch, at: index, now: now)
            fresh.append(contentsOf: outcome.fresh)
            failures += outcome.failures
        }

        normalizeItems()
        lastCheckAt = Date()

        let freshIDs = fresh.map { $0.id }
        await enrichArtwork(priority: freshIDs)
        await deliver(ids: freshIDs)
        persist(force: !fresh.isEmpty || trigger == .manual)
        updateBadge()

        if wantsKeepAlive && prefs.watchdog {
            Notifier.scheduleWatchdog(after: watchdogDelay)
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.shared.add("\(trigger.rawValue) check: \(plan.count) account(s), \(fresh.count) new, \(failures) failed, \(elapsed)s",
                       level: failures > 0 ? .warning : .info)
        if !isActive {
            Log.shared.save(force: !fresh.isEmpty)
        }
        return CheckSummary(newItems: fresh.count, failures: failures)
    }

    private struct ApplyOutcome {
        var fresh: [ActivityItem] = []
        var failures = 0
    }

    private func apply(_ fetch: AccountFetch, at index: Int, now: Date) -> ApplyOutcome {
        var account = accounts[index]
        var outcome = ApplyOutcome()
        let ledger = KeyLedger(account.seenKeys)
        var claimed = Set<String>()
        var feedEntries: [FeedEntry] = []
        account.lastChecked = now

        switch fetch.feed {
        case .success(let feed):
            feedEntries = feed.entries
            applyFeed(feed, to: &account, ledger: ledger, claimed: &claimed, now: now, outcome: &outcome)
        case .failure(let error):
            outcome.failures += 1
            account.lastError = error.localizedDescription
            Log.shared.add("@\(account.username): RSS failed. \(error.localizedDescription)", level: .warning)
        }

        if let profileResult = fetch.profile {
            switch profileResult {
            case .success(let profile):
                applyProfile(profile, to: &account, ledger: ledger, claimed: &claimed,
                             feedEntries: feedEntries, now: now, outcome: &outcome)
            case .failure(let error):
                if (error as? LetterboxdError)?.isBlocked == true {
                    account.profileBlockedUntil = now.addingTimeInterval(15 * 60)
                    account.profileNote = "Letterboxd turned the profile request away. Logline will try again in 15 minutes, and diary entries keep arriving through RSS."
                } else {
                    account.profileNote = "The last profile check failed: \(error.localizedDescription)"
                }
                Log.shared.add("@\(account.username): profile failed. \(error.localizedDescription)", level: .warning)
            }
        }

        account.seenKeys = Array((account.seenKeys + ledger.added).suffix(AppModel.seenLimit))
        accounts[index] = account
        return outcome
    }

    /// Diary entries, reviews, new lists and list size changes, from RSS.
    private func applyFeed(_ feed: FeedSnapshot, to account: inout TrackedAccount, ledger: KeyLedger,
                           claimed: inout Set<String>, now: Date, outcome: inout ApplyOutcome) {
        if let name = feed.displayName {
            account.displayName = name
        }
        account.lastError = nil
        account.lastSuccess = now

        let username = account.username
        let baseline = !account.feedBaselined
        // Anything older than what was already seen (an old entry sliding into the
        // 50-item window after a deletion, say) is filed quietly instead of alerted.
        let cutoff = (account.newestFeedDate ?? .distantPast).addingTimeInterval(-120)
        var newest = account.newestFeedDate
        let ordered = feed.entries.sorted { ($0.pubDate ?? .distantPast) < ($1.pubDate ?? .distantPast) }

        for entry in ordered {
            var item = ActivityItem(entry: entry, username: username, detectedAt: now)
            if let published = entry.pubDate, published > (newest ?? .distantPast) {
                newest = published
            }

            if item.kind == .list {
                let count = item.listCount ?? 0
                if !baseline, ledger.contains(item.id), let previous = account.listSizes[entry.guid], previous != count, count > 0 {
                    var update = item.listUpdate(previous: previous, at: now)
                    update.unread = true
                    update.live = true
                    upsert(update)
                    claimed.insert(LetterboxdURL.path(entry.link))
                    if account.wants(.listUpdate) {
                        outcome.fresh.append(update)
                    }
                }
                account.listSizes[entry.guid] = count
            }

            if ledger.contains(item.id) {
                refresh(with: item)
                continue
            }
            ledger.insert(item.id)

            // Already reported from the profile sidebar before RSS caught up: upgrade it quietly.
            if let pending = pendingActivityIndex(for: entry, username: username) {
                item.unread = items[pending].unread
                item.live = items[pending].live
                item.detectedAt = items[pending].detectedAt
                items[pending] = item
                continue
            }

            // A diary entry that just gained a review can come back under a new guid prefix.
            if let number = entry.viewingNumber {
                let newID = item.id
                items.removeAll { other in
                    other.username == username && other.fromRSS && other.kind.isDiary
                        && other.id != newID && other.id.hasSuffix("-" + number)
                }
            }

            let isNew = !baseline && (entry.pubDate.map { $0 > cutoff } ?? true)
            item.unread = isNew
            item.live = isNew
            upsert(item)
            if isNew {
                claimed.insert(LetterboxdURL.path(entry.link))
                if account.wants(item.kind) {
                    outcome.fresh.append(item)
                }
            }
        }

        account.newestFeedDate = newest
        account.feedBaselined = true
    }

    /// Watchlist additions, likes, follows and the rest, from the profile page.
    private func applyProfile(_ profile: ProfileSnapshot, to account: inout TrackedAccount, ledger: KeyLedger,
                              claimed: inout Set<String>, feedEntries: [FeedEntry], now: Date, outcome: inout ApplyOutcome) {
        let username = account.username
        let baseline = !account.activityBaselined
        let previousWatchlist = account.stats?.watchlist

        if let avatar = profile.avatarURL, !avatar.isEmpty {
            account.avatarURL = avatar
        }
        if profile.stats.hasValues {
            account.stats = profile.stats
        }
        account.profileBlockedUntil = nil
        account.profileNote = nil

        if profile.hasActivityTimeline {
            account.profileMode = .timeline
            let cutoff = (account.newestActivityDate ?? .distantPast).addingTimeInterval(-120)
            var newest = account.newestActivityDate
            let ordered = profile.activities.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

            for activity in ordered {
                if let date = activity.date, date > (newest ?? .distantPast) {
                    newest = date
                }
                guard !ledger.contains(activity.key) else { continue }
                ledger.insert(activity.key)

                let kind = activity.classify(username: username)
                let path = activity.targetURL.map { LetterboxdURL.path($0) }

                // RSS tells diary activity better: poster, rating and review included.
                if kind.isDiary && (baseline || rssCovers(activity, feedEntries: feedEntries, username: username)) {
                    continue
                }
                // Lists in the feed are reported from RSS, with their films.
                if kind == .list || kind == .listUpdate, let path,
                   feedEntries.contains(where: { LetterboxdURL.path($0.link) == path }) {
                    continue
                }
                if let path, claimed.contains(path) {
                    continue
                }

                let isNew = !baseline && (activity.date.map { $0 > cutoff } ?? true)
                var item = ActivityItem(activity: activity, kind: kind, username: username, detectedAt: now)
                item.unread = isNew
                item.live = isNew
                if let slug = item.filmSlug, let cached = imageCache[slug] {
                    item.imageURL = cached
                }
                upsert(item)
                if isNew {
                    if let path {
                        claimed.insert(path)
                    }
                    if account.wants(kind) {
                        outcome.fresh.append(item)
                    }
                }
            }
            account.newestActivityDate = newest
            // Remember the watchlist preview too, so a later fallback never replays old additions.
            for film in profile.watchlistPreview {
                ledger.insert("wl:" + film.slug)
            }
        } else {
            account.profileMode = .watchlistOnly
            // Without the sidebar, a bigger watchlist count plus unseen films at the
            // front of the preview means new additions. Removals reshuffle the preview,
            // so only as many films as the count grew by are reported.
            var budget = 0
            if !baseline, let current = profile.stats.watchlist, let previous = previousWatchlist, current > previous {
                budget = current - previous
            }
            for film in profile.watchlistPreview {
                let key = "wl:" + film.slug
                guard !ledger.contains(key) else { continue }
                ledger.insert(key)
                guard budget > 0 else { continue }
                budget -= 1
                var item = ActivityItem.watchlistAddition(film, username: username, at: now)
                item.unread = true
                item.live = true
                if let cached = imageCache[film.slug] {
                    item.imageURL = cached
                }
                upsert(item)
                if account.wants(.watchlist) {
                    outcome.fresh.append(item)
                }
            }
        }
        account.activityBaselined = true
    }

    private func rssCovers(_ activity: ProfileActivity, feedEntries: [FeedEntry], username: String) -> Bool {
        if let target = activity.targetURL {
            let path = LetterboxdURL.path(target)
            if feedEntries.contains(where: { LetterboxdURL.path($0.link) == path }) {
                return true
            }
            let storedMatch = items.contains { item in
                guard item.username == username, item.fromRSS, LetterboxdURL.path(item.link ?? "") == path else { return false }
                guard let date = activity.date else { return true }
                return abs(item.date.timeIntervalSince(date)) < 86_400
            }
            if storedMatch {
                return true
            }
        }
        guard let date = activity.date, let film = activity.targetText, !film.isEmpty else { return false }
        return feedEntries.contains { entry in
            guard let published = entry.pubDate, let title = entry.filmTitle else { return false }
            return abs(published.timeIntervalSince(date)) < 180 && title.caseInsensitiveCompare(film) == .orderedSame
        }
    }

    private func pendingActivityIndex(for entry: FeedEntry, username: String) -> Int? {
        let path = LetterboxdURL.path(entry.link)
        return items.firstIndex { item in
            guard item.username == username, !item.fromRSS, item.kind.isDiary else { return false }
            let published = entry.pubDate ?? item.date
            let gap = abs(published.timeIntervalSince(item.date))
            if let link = item.link, LetterboxdURL.path(link) == path, gap < 86_400 {
                return true
            }
            guard let film = entry.filmTitle else { return false }
            return gap < 180 && film.caseInsensitiveCompare(item.title) == .orderedSame
        }
    }

    private func upsert(_ item: ActivityItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    /// Keeps a known item current (edited reviews, new posters) without alerting again.
    private func refresh(with latest: ActivityItem) {
        guard let index = items.firstIndex(where: { $0.id == latest.id }) else {
            var quiet = latest
            quiet.unread = false
            quiet.live = false
            items.append(quiet)
            return
        }
        var merged = latest
        merged.unread = items[index].unread
        merged.live = items[index].live
        merged.detectedAt = items[index].detectedAt
        if merged != items[index] {
            items[index] = merged
        }
    }

    private func normalizeItems() {
        items.sort { $0.date > $1.date }
        if items.count > AppModel.maxItems {
            items.removeLast(items.count - AppModel.maxItems)
        }
    }

    /// Finds posters for activity that RSS didn't supply (watchlist adds, likes).
    private func enrichArtwork(priority ids: [String]) async {
        var queue = ids
        let backlog = items
            .filter { $0.imageURL == nil && !$0.fromRSS && !ids.contains($0.id) }
            .compactMap { item -> String? in
                guard let slug = item.filmSlug, !artworkMisses.contains(slug) else { return nil }
                return item.id
            }
        queue.append(contentsOf: backlog.prefix(3))

        var budget = 6
        for id in queue {
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].imageURL == nil,
                  let slug = items[index].filmSlug else { continue }
            if let cached = imageCache[slug] {
                items[index].imageURL = cached
                continue
            }
            guard budget > 0, !artworkMisses.contains(slug) else { continue }
            budget -= 1
            if let url = await client.filmArtwork(slug: slug) {
                imageCache[slug] = url
                if let current = items.firstIndex(where: { $0.id == id }) {
                    items[current].imageURL = url
                }
            } else {
                artworkMisses.insert(slug)
            }
        }
        if imageCache.count > 500 {
            imageCache.removeAll()
        }
    }

    private func deliver(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await refreshNotificationStatus()
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            Log.shared.add("\(ids.count) new item(s), but notifications aren't allowed", level: .warning)
            return
        }
        let batch = ids.compactMap { id in items.first { $0.id == id } }
        let grouped = Dictionary(grouping: batch) { $0.username }
        let badge = unreadCount
        let timeSensitive = timeSensitiveSupported && prefs.timeSensitive
        for (username, group) in grouped {
            let name = account(username)?.displayName ?? username
            let ordered = group.sorted { $0.date < $1.date }
            if ordered.count > 4 {
                await Notifier.postDigest(items: ordered, accountName: name, username: username,
                                          badge: badge, timeSensitive: timeSensitive)
            } else {
                for item in ordered {
                    await Notifier.post(item: item, accountName: name, username: username, prefs: prefs,
                                        badge: badge, timeSensitive: timeSensitive)
                }
            }
        }
        Log.shared.add("Sent \(batch.count) alert(s)")
    }

    // MARK: - Notifications

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
        timeSensitiveSupported = settings.timeSensitiveSetting == .enabled
    }

    func requestNotificationPermission() async {
        _ = await Notifier.requestAuthorization()
        await refreshNotificationStatus()
    }

    func sendTestNotification() async {
        if notificationStatus == .notDetermined {
            await requestNotificationPermission()
        }
        let sample = items.first ?? ActivityItem.sample
        let name = account(sample.username)?.displayName ?? "Logline"
        await Notifier.post(item: sample, accountName: name, username: sample.username, prefs: prefs,
                            badge: unreadCount, timeSensitive: timeSensitiveSupported && prefs.timeSensitive,
                            identifier: "test.\(UUID().uuidString)")
        Log.shared.add("Sent a test notification")
    }

    func handleNotificationResponse(itemID: String?, link: String?, action: String) {
        if action == Notifier.openActionID, let link, !link.isEmpty, let url = URL(string: link) {
            UIApplication.shared.open(url)
            if let itemID {
                markRead(itemID)
            }
            return
        }
        guard let itemID, let item = items.first(where: { $0.id == itemID }) else { return }
        open(item)
    }

    private func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(unreadCount, withCompletionHandler: nil)
    }

    // MARK: - Reading

    func open(_ item: ActivityItem) {
        presentedItem = item
        markRead(item.id)
    }

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].unread else { return }
        items[index].unread = false
        updateBadge()
        persist()
    }

    func markAllRead() {
        guard items.contains(where: { $0.unread }) else { return }
        for index in items.indices where items[index].unread {
            items[index].unread = false
        }
        updateBadge()
        persist()
    }

    // MARK: - Accounts

    enum AddAccountError: LocalizedError {
        case invalid
        case duplicate

        var errorDescription: String? {
            switch self {
            case .invalid: return "That doesn't look like a Letterboxd username or profile link."
            case .duplicate: return "That account is already being tracked."
            }
        }
    }

    /// Validates the username against its RSS feed, then records everything currently there as already seen.
    func addAccount(_ input: String) async throws {
        guard let username = LetterboxdClient.username(from: input) else { throw AddAccountError.invalid }
        guard account(username) == nil else { throw AddAccountError.duplicate }
        let client = self.client
        let feed = try await client.fetchFeed(username: username, bypassCache: true)
        var profile: Result<ProfileSnapshot, Error>?
        if prefs.watchProfiles {
            profile = await capture { try await client.fetchProfile(username: username, bypassCache: true) }
        }
        guard account(username) == nil else { throw AddAccountError.duplicate }

        accounts.append(TrackedAccount(username: username, displayName: feed.displayName ?? username, addedAt: Date()))
        if let index = accounts.firstIndex(where: { $0.username == username }) {
            _ = apply(AccountFetch(feed: .success(feed), profile: profile), at: index, now: Date())
        }
        normalizeItems()
        lastCheckAt = Date()
        persist()
        Log.shared.add("Now tracking @\(username)")
        applyMonitoring()
        if notificationStatus == .notDetermined {
            await requestNotificationPermission()
        }
        await enrichArtwork(priority: [])
        persist()
    }

    func removeAccounts(at offsets: IndexSet) {
        let names = offsets.map { accounts[$0].username }
        for name in names {
            removeAccount(name)
        }
    }

    func removeAccount(_ username: String) {
        accounts.removeAll { $0.username == username }
        items.removeAll { $0.username == username }
        if presentedItem?.username == username {
            presentedItem = nil
        }
        persist()
        updateBadge()
        applyMonitoring()
        Log.shared.add("Stopped tracking @\(username)")
    }

    func updateAccount(_ username: String, _ change: (inout TrackedAccount) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.username == username }) else { return }
        change(&accounts[index])
        persist()
    }

    // MARK: - Background

    func performBackgroundCheck(trigger: CheckTrigger) async -> Bool {
        let started = Date()
        let summary = await checkAll(trigger: trigger)
        let run = BackgroundRun(date: started, trigger: trigger.rawValue, duration: Date().timeIntervalSince(started),
                                newItems: summary.newItems, ok: summary.success)
        backgroundRuns.insert(run, at: 0)
        if backgroundRuns.count > 20 {
            backgroundRuns.removeLast(backgroundRuns.count - 20)
        }
        persist()
        Log.shared.save(force: true)
        return summary.success
    }

    private func beginBackgroundTime() {
        guard backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "logline.check") { [weak self] in
            MainActor.assumeIsolated {
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    // MARK: - Updates

    func checkForUpdate() async {
        guard Updater.repository != nil else {
            updateMessage = "Update checks work in builds made by the GitHub workflow."
            return
        }
        isCheckingForUpdate = true
        lastUpdateCheck = Date()
        defer { isCheckingForUpdate = false }
        do {
            let latest = try await Updater.latestRelease()
            if latest.build > AppInfo.buildNumber {
                availableUpdate = latest
                updateMessage = "Build \(latest.build) is ready to install."
            } else {
                availableUpdate = nil
                updateMessage = "You're on the newest build."
            }
        } catch {
            updateMessage = error.localizedDescription
        }
    }

    private func checkForUpdateIfDue() async {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 3 * 3600 {
            return
        }
        await checkForUpdate()
    }

    // MARK: - Persistence

    /// Unforced saves are throttled so Instant mode doesn't rewrite the file every minute.
    private func persist(force: Bool = true) {
        if !force && Date().timeIntervalSince(lastPersist) < 300 {
            return
        }
        lastPersist = Date()
        var state = PersistedState()
        state.accounts = accounts
        state.items = items
        state.imageCache = imageCache
        state.backgroundRuns = backgroundRuns
        Storage.write(state, to: AppModel.stateFile)
    }

    private func preferencesChanged(from old: Preferences) {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: AppModel.prefsKey)
        }
        if old.mode != prefs.mode {
            Log.shared.add(prefs.mode == .instant ? "Switched to Instant mode" : "Switched to Standard mode")
        }
        if old.pollInterval != prefs.pollInterval {
            stopLoop()
        }
        if old.mode != prefs.mode || old.watchdog != prefs.watchdog || old.pollInterval != prefs.pollInterval {
            applyMonitoring()
        }
    }
}
