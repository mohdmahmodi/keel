import Foundation
import AppKit
import Observation

/// A semantic version ("1.2.3", "v1.2.0-beta.2"). Build metadata after "+" is ignored.
struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    let core: [Int]            // always three numbers: major, minor, patch
    let prerelease: [String]   // empty for a final release

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        core = nums
        prerelease = pre
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func == (a: Self, b: Self) -> Bool { a.core == b.core && a.prerelease == b.prerelease }

    /// Semantic Versioning 2.0 precedence: 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-beta < 1.0.0.
    static func < (a: Self, b: Self) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true     // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

struct LatestRelease: Codable, Equatable, Sendable {
    var tag: String
    var name: String
    var notes: String
    var pageURL: URL
    var dmgURL: URL?
    var dmgSize: Int?
    var publishedAt: Date?

    var version: ReleaseVersion? { ReleaseVersion(tag) }

    /// First few lines of the release notes, Markdown stripped.
    var notesExcerpt: String {
        var lines: [String] = []
        var inCode = false
        for raw in notes.components(separatedBy: .newlines) {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || l.isEmpty { continue }
            if l.hasPrefix("#") {
                // Stop at the verification section; skip other headings.
                if l.lowercased().contains("verify") { break }
                continue
            }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            lines.append(l)
            if lines.count == 6 { break }
        }
        let text = lines.joined(separator: "\n")
        return text.count > 420 ? String(text.prefix(420)) + "…" : text
    }
}

/// Checks GitHub Releases with one anonymous GET to api.github.com; never downloads or installs.
/// The repository comes from the `KeelUpdateRepo` Info.plist key ("owner/name").
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(LatestRelease)
        case noReleases
        case failed(String)
        case notConfigured
    }

    private(set) var status: Status = .idle
    private(set) var latest: LatestRelease?
    private(set) var lastChecked: Date?

    var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Keys.automatic) }
    }

    static let interval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let automatic = "updates.automatic"
        static let lastChecked = "updates.lastChecked"
        static let latest = "updates.latest"
    }
    private var loop: Task<Void, Never>?

    init() {
        automatic = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        if let data = defaults.data(forKey: Keys.latest), let cached = try? JSONDecoder().decode(LatestRelease.self, from: data) {
            latest = cached
            status = evaluate(cached)
        }
        if repo == nil { status = .notConfigured }
    }

    // MARK: Inputs

    nonisolated static var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    var currentVersion: ReleaseVersion? { ReleaseVersion(Self.currentVersionString) }

    /// "owner/name" from Info.plist, validated so it can only form a github.com API path.
    var repo: String? {
        guard let r = Bundle.main.infoDictionary?["KeelUpdateRepo"] as? String,
              r.range(of: #"^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        return r
    }

    var isDue: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= Self.interval
    }

    // MARK: Checking

    /// Starts the daily background check; safe to call repeatedly. A pass runs only when automatic
    /// checks are on and the last check is over a day old.
    func startAutomaticChecks() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.automatic, self.isDue, self.status != .checking { await self.check() }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Checks now, regardless of when the last check ran.
    func check() async {
        guard let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            status = .notConfigured; return
        }
        guard status != .checking else { return }
        status = .checking
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Keel/\(Self.currentVersionString)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)   // no cookies, no cache on disk
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            switch code {
            case 200:
                let release = try Self.parse(data)
                latest = release
                if let encoded = try? JSONEncoder().encode(release) { defaults.set(encoded, forKey: Keys.latest) }
                status = evaluate(release)
            case 404:
                latest = nil
                defaults.removeObject(forKey: Keys.latest)
                status = .noReleases
            case 403, 429:
                status = .failed("GitHub rate limit reached. Try again in an hour.")
            default:
                status = .failed("GitHub answered HTTP \(code).")
            }
        } catch let e as URLError {
            status = .failed(e.code == .notConnectedToInternet ? "No internet connection." : e.localizedDescription)
        } catch {
            status = .failed("Could not read the release information.")
        }
    }

    private func evaluate(_ release: LatestRelease) -> Status {
        guard let remote = release.version, let local = currentVersion else { return .upToDate }
        return remote > local ? .available(release) : .upToDate
    }

    /// Opens the DMG, or the release page if there is none. Only GitHub hosts are opened.
    func openDownload(_ release: LatestRelease) {
        let url = release.dmgURL ?? release.pageURL
        guard Self.isTrustedGitHubURL(url) else { return }
        NSWorkspace.shared.open(url)
    }

    func openReleasePage(_ release: LatestRelease) {
        guard Self.isTrustedGitHubURL(release.pageURL) else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    nonisolated static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    // MARK: Parsing

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int?
            let content_type: String?
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let published_at: Date?
        let assets: [Asset]?
    }

    nonisolated static func parse(_ data: Data) throws -> LatestRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let r = try decoder.decode(APIRelease.self, from: data)
        let dmg = (r.assets ?? []).first { $0.name.lowercased().hasSuffix(".dmg") && isTrustedGitHubURL($0.browser_download_url) }
        return LatestRelease(tag: r.tag_name,
                             name: (r.name?.isEmpty == false ? r.name! : r.tag_name),
                             notes: r.body ?? "",
                             pageURL: r.html_url,
                             dmgURL: dmg?.browser_download_url,
                             dmgSize: dmg?.size,
                             publishedAt: r.published_at)
    }
}
