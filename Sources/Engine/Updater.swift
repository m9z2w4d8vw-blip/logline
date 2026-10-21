import Foundation

struct ReleaseInfo: Equatable {
    var tag: String
    var build: Int
    var title: String
    var pageURL: URL
    var ipaURL: URL?
    var notes: String?
}

enum UpdateError: LocalizedError {
    case notConfigured
    case http(Int)
    case noBuildNumber

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build doesn't know which GitHub repo it came from."
        case .http(let code):
            if code == 404 {
                return "No public release found. Releases in a private repo can't be checked without a token."
            }
            return "GitHub returned HTTP \(code)."
        case .noBuildNumber:
            return "The newest release has no build number in its tag."
        }
    }
}

/// Reads this repo's newest GitHub release so new builds can be installed from inside the app.
enum Updater {
    static var repository: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "LoglineGitHubRepo") as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("/"), !value.contains("$(") else { return nil }
        return value
    }

    static func latestRelease() async throws -> ReleaseInfo {
        guard let repository, let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard let build = Int(release.tagName.filter { $0.isNumber }) else { throw UpdateError.noBuildNumber }
        let ipa = release.assets.first { $0.name.lowercased().hasSuffix(".ipa") }
        return ReleaseInfo(tag: release.tagName,
                           build: build,
                           title: release.name ?? release.tagName,
                           pageURL: URL(string: release.htmlUrl) ?? url,
                           ipaURL: ipa.flatMap { URL(string: $0.browserDownloadUrl) },
                           notes: release.body)
    }

    /// TrollStore's install scheme. It has to be switched on in TrollStore's settings.
    static func trollStoreURL(for ipa: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "apple-magnifier"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        return components.url
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
    }

    let tagName: String
    let name: String?
    let htmlUrl: String
    let body: String?
    let assets: [Asset]
}
