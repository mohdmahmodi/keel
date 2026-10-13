import AppKit
import Foundation

/// Finds developer tools without a login shell. Only absolute paths are ever executed.
enum Tools {
    static func searchDirs(_ home: String) -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin",
                    "\(home)/.deno/bin", "\(home)/Library/pnpm", "\(home)/.volta/bin", "\(home)/go/bin", "/usr/local/go/bin",
                    "/opt/homebrew/opt/go/libexec/bin", "\(home)/flutter/bin", "\(home)/development/flutter/bin",
                    "\(home)/fvm/default/bin", "\(home)/.pub-cache/bin", "\(home)/.yarn/bin", "\(home)/.asdf/shims",
                    "\(home)/.local/share/mise/shims", "\(home)/.rbenv/shims", "\(home)/.pyenv/shims"]
        // nvm / fnm installs: newest version last so it wins when present.
        for base in ["\(home)/.nvm/versions/node", "\(home)/Library/Application Support/fnm/node-versions"] {
            if let v = try? FileManager.default.contentsOfDirectory(atPath: base) {
                for x in v.sorted(by: { $0.versionKey > $1.versionKey }) {
                    dirs.append(base.hasSuffix("node-versions") ? "\(base)/\(x)/installation/bin" : "\(base)/\(x)/bin")
                }
            }
        }
        return dirs
    }

    /// Absolute path of an executable, or nil. Never runs anything. Skips /usr/bin stubs that would
    /// prompt to install the Command Line Tools.
    static func find(_ name: String, home: String = Shell.home()) -> String? {
        for d in searchDirs(home) {
            let p = "\(d)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// A command whose PATH starts with the tool's own folder (npm needs the matching node).
    static func command(_ path: String, _ args: [String]) -> CleanupCommand {
        let dir = (path as NSString).deletingLastPathComponent
        return CleanupCommand(executable: path, args: args, env: ["PATH": "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"])
    }
}

/// Read-only filesystem helpers for the catalog.
enum FS {
    /// Existence check that never looks inside protected app data without Full Disk Access.
    static func exists(_ p: String) -> Bool { Permissions.canRead(p) && FileManager.default.fileExists(atPath: p) }
    static func isDir(_ p: String) -> Bool {
        guard Permissions.canRead(p) else { return false }
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }
    /// Whether an app's container exists, from the listing of ~/Library/Containers (which never prompts).
    static func containerExists(_ bundleID: String, home: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Containers")) ?? []).contains(bundleID)
    }
    /// Children names, hidden entries excluded. Empty when unreadable or when reading could raise a
    /// macOS privacy prompt (protected app data without Full Disk Access).
    static func list(_ p: String) -> [String] {
        guard Permissions.canRead(p) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    /// True when the folder can be listed without a prompt (TCC-protected folders fail silently with EPERM).
    static func readable(_ p: String) -> Bool {
        Permissions.canRead(p) && (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil
    }
    static func existing(_ paths: [String]) -> [String] { paths.filter { exists($0) } }
    static func modified(_ p: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date }
    /// Allocated bytes of one file (sparse-aware), without walking a tree.
    static func allocatedSize(_ p: String) -> UInt64? {
        guard Permissions.canRead(p) else { return nil }
        let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return (v?.totalFileAllocatedSize ?? v?.fileAllocatedSize).map { UInt64($0) }
    }
}

/// Maps cache folder names (usually bundle IDs) to app names with Launch Services.
enum AppNames {
    struct Resolved: Sendable { let name: String; let bundleID: String?; let isApple: Bool }

    static func resolve(_ folder: String) -> Resolved {
        let looksLikeBundleID = folder.contains(".") && folder.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil
        if looksLikeBundleID {
            var id = folder
            // Strip updater / helper suffixes so "com.github.GitHubClient.ShipIt" resolves to GitHub Desktop.
            for suffix in [".ShipIt", ".helper", ".Helper", ".updater"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                let apple = url.path.hasPrefix("/System/") || id.hasPrefix("com.apple.")
                return Resolved(name: name + (id != folder ? " (updater)" : ""), bundleID: id, isApple: apple)
            }
            return Resolved(name: folder, bundleID: id, isApple: id.hasPrefix("com.apple."))
        }
        return Resolved(name: folder, bundleID: nil, isApple: false)
    }
}

/// Running-app checks and the "Quit <App>" button.
@MainActor
enum AppControl {
    static func runningApps(_ o: OwningApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return o.bundleIDs.contains(id) || o.bundlePrefixes.contains { id.hasPrefix($0) }
        }
    }

    static func isRunning(_ o: OwningApp) async -> Bool {
        if !runningApps(o).isEmpty { return true }
        if let pat = o.processPattern, let r = try? await Shell.run("/usr/bin/pgrep", ["-f", pat], timeout: 5) { return r.ok }
        return false
    }

    /// Asks the app to quit normally (it may show its own save dialogs) and waits up to ~8 s.
    static func quit(_ o: OwningApp) async -> Bool {
        for app in runningApps(o) { app.terminate() }
        if let pat = o.processPattern {
            _ = try? await Shell.run("/usr/bin/pkill", ["-TERM", "-f", pat], timeout: 5)
        }
        for _ in 0..<16 {
            if !(await isRunning(o)) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return !(await isRunning(o))
    }
}

/// Bounded concurrency for `du` and other measurements.
actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = n }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
