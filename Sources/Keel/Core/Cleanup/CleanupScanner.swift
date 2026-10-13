import AppKit
import Foundation

enum CleanupScanner {
    struct DUResult: Sendable { var bytes: UInt64; var unreadable: Bool }

    /// `du -skx` over the existing paths, one process. Permission errors are reported, not hidden.
    static func du(_ paths: [String]) async -> DUResult {
        let present = paths.map(Shell.expand).filter { FileManager.default.fileExists(atPath: $0) }
        // Never walk protected app data without Full Disk Access: it can raise a privacy prompt.
        let existing = present.filter(Permissions.canRead)
        let skipped = existing.count < present.count
        guard !existing.isEmpty else { return DUResult(bytes: 0, unreadable: skipped) }
        guard let r = try? await Shell.run("/usr/bin/du", ["-skx"] + existing, timeout: 300) else { return DUResult(bytes: 0, unreadable: true) }
        var total: UInt64 = 0
        for line in r.stdout.split(separator: "\n") {
            if let k = UInt64(line.split(separator: "\t").first ?? "") { total += k * 1024 }
        }
        let denied = r.stderr.contains("Operation not permitted") || r.stderr.contains("Permission denied")
        return DUResult(bytes: total, unreadable: denied || skipped)
    }

    static func du(_ paths: [String]) async -> UInt64 { let r: DUResult = await du(paths); return r.bytes }

    static func measure(_ item: CleanupItem) async -> CleanupItem {
        var m = item
        m.sizeFromCache = false
        switch item.measure {
        case .preset, .none: return m
        case .custom(let f):
            m.sizeBytes = await f()
            return m
        case .du:
            if case .needsFullDiskAccess = item.kind {
                // Measure only if the folder is actually readable (Full Disk Access granted).
                if let first = item.paths.first, FS.readable(first) {
                    let r: DUResult = await du(item.paths); m.sizeBytes = r.bytes; m.unreadable = r.unreadable
                } else { m.sizeBytes = nil }
                return m
            }
            guard !item.paths.isEmpty else { return m }
            let r: DUResult = await du(item.paths)
            m.sizeBytes = r.bytes
            m.unreadable = r.unreadable
            return m
        }
    }


    // MARK: Cleaning

    enum CleanError: LocalizedError {
        case refused(String)
        case failed(String)
        var errorDescription: String? {
            switch self { case .refused(let s): return "Refused: \(s)"; case .failed(let s): return s }
        }
    }

    /// Hooks used only by `--cleanup-selftest`. In normal runs they are nil and every action runs for real.
    struct TestHooks: Sendable {
        /// Replaces NSWorkspace.recycle so the test never touches the user's Trash.
        var recycle: @Sendable (URL) async throws -> Void
        /// Only these executables may run; everything else is refused.
        var allowedExecutables: Set<String>
    }
    nonisolated(unsafe) static var testHooks: TestHooks? = nil

    /// Runs every action of a leaf item in order. Stops at the first failure.
    static func clean(_ item: CleanupItem) async throws {
        guard item.deletable, !item.isParent else { throw CleanError.refused("not deletable by Keel") }
        for action in item.actions {
            switch action {
            case .run(let c):
                if let hooks = testHooks, !hooks.allowedExecutables.contains(c.executable) {
                    throw CleanError.refused("command not allowed in self-test: \(c.display)")
                }
                let r = try await Shell.run(c.executable, c.args, timeout: 1800, env: c.env.isEmpty ? nil : c.env)
                await ActivityLog.shared.command(c.display, detail: r.combined.isEmpty ? nil : String(r.combined.prefix(2000)))
                if !r.ok { throw CleanError.failed(r.combined.isEmpty ? "exit status \(r.status)" : String(r.combined.prefix(400))) }
            case .removeContents(let p, let except):
                let path = Shell.expand(p)
                try CleanupSafety.check(path, contentsOnly: true)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let kids = try FileManager.default.contentsOfDirectory(atPath: path)
                var failures = 0
                for k in kids where !except.contains(k) {
                    // removeItem deletes a symbolic link itself, never what it points to.
                    do { try FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(k)) } catch { failures += 1 }
                }
                await ActivityLog.shared.command(action.preview, detail: failures > 0 ? "\(failures) of \(kids.count) entries could not be removed (in use or protected)." : nil)
            case .removePath(let p):
                let path = Shell.expand(p)
                try CleanupSafety.check(path, contentsOnly: false)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                try FileManager.default.removeItem(atPath: path)
                await ActivityLog.shared.command(action.preview)
            case .moveToTrash(let p):
                let path = Shell.expand(p)
                try CleanupSafety.check(path, contentsOnly: false)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if let hooks = testHooks { try await hooks.recycle(URL(fileURLWithPath: path)) }
                else { try await recycle(URL(fileURLWithPath: path)) }
                await ActivityLog.shared.command(action.preview)
            case .emptyTrashViaFinder:
                if testHooks != nil { throw CleanError.refused("emptying the Trash is not allowed in self-test") }
                let r = try await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 600)
                await ActivityLog.shared.command(action.preview, detail: r.combined.isEmpty ? nil : r.combined)
                if !r.ok { throw CleanError.failed(r.combined.isEmpty ? "Finder did not empty the Trash (Automation permission may be off)." : r.combined) }
            }
        }
    }

    @MainActor
    static func recycle(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// Whether a process with exactly this name is running.
    static func isRunning(_ appName: String) async -> Bool {
        guard let r = try? await Shell.run("/usr/bin/pgrep", ["-x", appName], timeout: 5) else { return false }
        return r.ok
    }
}

/// Last line of defence for file deletions. Commands run by tools (simctl, brew, npm…) are not paths and are
/// not checked here; every FileManager deletion and every move to the Trash is.
enum CleanupSafety {
    /// Home folder used by the checks. Only `--cleanup-selftest` changes it.
    nonisolated(unsafe) static var homeOverride: String? = nil

    /// Folders (relative to home) that are never deleted or emptied themselves.
    static let neverExact: Set<String> = [
        "Library", "Library/Caches", "Library/Application Support", "Library/Containers", "Library/Group Containers",
        "Library/Preferences", "Library/Developer", "Library/Developer/Xcode", "Library/Mobile Documents", "Library/Mail",
        "Library/Messages", "Library/Photos", "Library/Keychains", "Library/Logs", "Documents", "Desktop", "Downloads",
        "Movies", "Music", "Pictures", "Public", "Applications", ".Trash", ".ssh", ".gnupg", ".config", ".local", ".cache",
    ]

    /// Folders whose contents may be emptied even though the folder itself is in `neverExact`.
    static let contentsAllowed: Set<String> = ["Library/Logs"]

    /// Resolves symbolic links in every component (`realpath`). For a missing path, resolves its parent.
    static func real(_ p: String) -> String {
        if let r = realpath(p, nil) { defer { free(r) }; return String(cString: r) }
        let parent = (p as NSString).deletingLastPathComponent
        guard parent != p, !parent.isEmpty else { return p }
        return (real(parent) as NSString).appendingPathComponent((p as NSString).lastPathComponent)
    }

    static func check(_ path: String, contentsOnly: Bool) throws {
        func refuse(_ why: String) -> CleanupScanner.CleanError { .refused("\(why): \(path)") }
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/.."), !path.contains("/./"), !path.contains("//") else {
            throw refuse("path is not absolute and normalized")
        }
        let home = real(homeOverride ?? Shell.home())
        // Resolve symbolic links: a link inside the home folder that points elsewhere is refused.
        let resolved = real(path)
        guard resolved.hasPrefix(home + "/") else { throw refuse("outside the home folder, or a link that points outside it") }
        let rel = String(resolved.dropFirst(home.count + 1))
        let comps = rel.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { throw refuse("the home folder itself") }
        if neverExact.contains(rel) && !(contentsOnly && contentsAllowed.contains(rel)) { throw refuse("protected folder") }
        if comps.count < 2 { throw refuse("top-level folder of the home folder") }
        // Apple caches and iCloud state are never touched (Xcode's own cache is the one exception).
        if comps.count >= 3, comps[0] == "Library", comps[1] == "Caches" {
            let c = comps[2]
            if (c.hasPrefix("com.apple.") && c != "com.apple.dt.Xcode") || c == "CloudKit" { throw refuse("Apple system cache") }
        }
        if comps.contains(where: { $0 == "Keychains" || $0 == "Mobile Documents" }) { throw refuse("protected data") }
        // Reading protected app data without Full Disk Access can raise a macOS privacy prompt.
        if homeOverride == nil, !Permissions.canRead(path) { throw refuse("protected by macOS; needs Full Disk Access") }
    }
}
