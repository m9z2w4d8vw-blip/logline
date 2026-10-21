import Foundation

enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Logline", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let backup = directory.appendingPathComponent(name + ".unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            Log.shared.add("Couldn't read \(name), so a copy was kept as \(name).unreadable: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    static func write<T: Encodable>(_ value: T, to name: String) {
        let url = directory.appendingPathComponent(name)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.shared.add("Couldn't save \(name): \(error.localizedDescription)", level: .error)
        }
    }
}

/// A small persistent diagnostics log, shown in Settings so background behaviour can be checked on the phone.
final class Log: @unchecked Sendable {
    enum Level: String, Codable {
        case info
        case warning
        case error
    }

    struct Entry: Codable, Identifiable, Hashable {
        var id: UUID
        var date: Date
        var level: Level
        var message: String
    }

    static let shared = Log()

    private let lock = NSLock()
    private var entries: [Entry]
    private var lastSave = Date.distantPast
    private let limit = 800
    private let fileURL: URL

    private init() {
        fileURL = Storage.directory.appendingPathComponent("log.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    func add(_ message: String, level: Level = .info) {
        let entry = Entry(id: UUID(), date: Date(), level: level, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        lock.unlock()
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Unforced saves happen at most every two minutes.
    func save(force: Bool = false) {
        lock.lock()
        let due = force || Date().timeIntervalSince(lastSave) > 120
        if due {
            lastSave = Date()
        }
        let current = entries
        lock.unlock()
        guard due, let data = try? JSONEncoder().encode(current) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        save(force: true)
    }

    func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return snapshot()
            .map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var buildNumber: Int {
        Int(build) ?? 0
    }
}

enum Format {
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func latency(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    static func interval(_ seconds: Double) -> String {
        let whole = Int(seconds)
        if whole < 60 { return "\(whole) seconds" }
        let minutes = whole / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    /// "2026-10-19" becomes "Mon, Oct 19". Watched dates are calendar days, so no time zone shift.
    static func day(_ iso: String) -> String? {
        guard let date = isoDay.date(from: iso) else { return nil }
        return dayLabel.string(from: date)
    }
}

enum Snippet {
    static func make(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n\n", with: "\n")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}
