import Foundation

/// What the catalog may look at on this run.
struct CatalogContext: Sendable {
    let home: String
    let hasXcode: Bool
    let brewPrefix: String?
    /// Full Disk Access granted: Trash, iOS backups, Mail, sandboxed VM containers become measurable.
    let hasFDA: Bool
    /// Desktop / Documents / Downloads are TCC-protected; reading them can show a macOS prompt, so the app
    /// only does it after the user asks (the CLI always does).
    let includeUserFolders: Bool

    /// Folders macOS may prompt for (Desktop, Documents, Downloads, media libraries in Movies, Music, Pictures).
    /// A pending prompt blocks the reading process, so these are read only after the user agrees.
    func isUserFolder(_ path: String) -> Bool {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].contains { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }
    }
}

/// Cleanup candidates that exist on this Mac. Independent providers let fast rows appear while slow ones
/// (simctl, brew, Spotlight, repo walks) are still running. Sizes are measured afterwards.
enum CleanupCatalog {
    typealias Provider = @Sendable (CatalogContext) async -> [CleanupItem]

    static let providers: [(name: String, run: Provider)] = [
        ("xcode", xcode),
        ("simulators", simulators),
        ("packages", packages),
        ("homebrew", homebrew),
        ("apps", appCaches),
        ("other-caches", otherCaches),
        ("system", system),
        ("snapshots", snapshots),
        ("downloads", oldInstallers),
        ("protected", protected),
        ("repos", repoBuildFolders),
        ("large-files", largeFiles),
    ]

    static func context(includeUserFolders: Bool) async -> CatalogContext {
        let m = await Machine.profile()
        return CatalogContext(home: Shell.home(), hasXcode: m.hasXcode, brewPrefix: m.brewPrefix,
                              hasFDA: Permissions.hasFullDiskAccess, includeUserFolders: includeUserFolders)
    }

    /// All providers at once, for callers that do not need progressive rows.
    static func build(includeUserFolders: Bool = true) async -> [CleanupItem] {
        let ctx = await context(includeUserFolders: includeUserFolders)
        var out: [CleanupItem] = []
        for p in providers { out += await p.run(ctx) }
        return out
    }
}
