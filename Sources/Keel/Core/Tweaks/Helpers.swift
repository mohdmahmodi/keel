import Foundation
import Metal
import CoreGraphics
import AppKit
import KeelShared

enum TweakHelpers {
    static let home = NSHomeDirectory()

    static func isProcessRunning(_ exactName: String) async -> Bool {
        guard let r = try? await Shell.run("/usr/bin/pgrep", ["-x", exactName], timeout: 5) else { return false }
        return r.ok
    }

    /// nil when unreadable. Never opens a privacy-protected file unless Keel has Full Disk Access.
    static func readJSON(_ path: String) -> [String: Any]? {
        guard Permissions.canRead(path), let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Copies the file to backups, applies `mutate`, writes it back. Returns the backup record fields.
    static func editJSON(_ path: String, tag: String, mutate: (inout [String: Any]) -> Void) throws -> [String: String] {
        guard var obj = readJSON(path) else { throw TweakEngine.EngineError(message: "Could not read \(path)") }
        let name = try BackupStore.copyFile(at: path, tag: tag)
        mutate(&obj)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return ["path": path, "file": name]
    }

    /// Restores a file copied with `editJSON` / `BackupStore.copyFile`.
    static func restoreFile(_ orig: [String: String]) throws {
        guard let path = orig["path"], let file = orig["file"] else { throw TweakEngine.EngineError(message: "No recorded file") }
        let src = BackupStore.fileURL(file)
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        try FileManager.default.copyItem(at: src, to: URL(fileURLWithPath: path))
    }

    /// Nested lookup "a.b.c" in a JSON dictionary.
    static func nested(_ obj: [String: Any]?, _ keyPath: String) -> Any? {
        var cur: Any? = obj
        for k in keyPath.split(separator: ".") {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[String(k)]
        }
        return cur
    }
    static func setNested(_ obj: inout [String: Any], _ keyPath: String, _ value: Any) {
        let parts = keyPath.split(separator: ".").map(String.init)
        if parts.count == 1 { obj[parts[0]] = value; return }
        var child = obj[parts[0]] as? [String: Any] ?? [:]
        setNested(&child, parts.dropFirst().joined(separator: "."), value)
        obj[parts[0]] = child
    }

    static var metalRecommendedWorkingSetBytes: UInt64 {
        MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0
    }

    static var mainDisplayRefreshRate: Double {
        CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
    }

    static let dockerStore = "\(home)/Library/Group Containers/group.com.docker/settings-store.json"
    static let chromeLocalState = "\(home)/Library/Application Support/Google/Chrome/Local State"
    static let chromePrefs = "\(home)/Library/Application Support/Google/Chrome/Default/Preferences"
}

// MARK: - Local AI: memory pressure, GPU wired limit, Ollama, LM Studio

extension TweakHelpers {
    static let gib: UInt64 = 1_073_741_824

    // MARK: Memory pressure

    struct MemoryPressure: Sendable {
        /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical (0 if unreadable).
        let level: Int
        /// kern.memorystatus_level: the "free" percentage `memory_pressure` prints.
        let freePercent: Int
        let swapUsedBytes: UInt64
        var label: String {
            switch level { case 1: return "normal"; case 2: return "warning"; case 4: return "critical"; default: return "unknown" }
        }
        var summary: String {
            "\(label) (\(freePercent) % free, swap used \(String(format: "%.1f", Double(swapUsedBytes) / Double(TweakHelpers.gib))) GiB)"
        }
        var isNormal: Bool { level == 1 }
    }

    static func memoryPressure() -> MemoryPressure {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let used: UInt64 = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
        return MemoryPressure(level: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 0,
                              freePercent: Sysctl.int("kern.memorystatus_level") ?? 0,
                              swapUsedBytes: used)
    }

    // MARK: GPU wired limit (iogpu.wired_limit_mb)

    static let wiredLimitSysctl = "iogpu.wired_limit_mb"
    /// Label used by older Keel releases; still treated as Keel's own and migrated to the new label.
    static let legacyWiredDaemonLabel = "com.keel.iogpu-wired-limit"
    static var legacyWiredDaemonPath: String { "/Library/LaunchDaemons/\(legacyWiredDaemonLabel).plist" }
    static var wiredDaemonLabel: String { KeelConstants.sysctlDaemonLabel(wiredLimitSysctl) }
    static var wiredDaemonPath: String { "/Library/LaunchDaemons/\(wiredDaemonLabel).plist" }

    /// Memory left to macOS and apps after the raise: one eighth of RAM, at least 4 GiB, rounded up to a whole GiB.
    static func wiredReserveGiB(memoryBytes: UInt64) -> Int {
        let memGiB = Double(memoryBytes) / Double(gib)
        return max(4, Int((memGiB / 8).rounded(.up)))
    }

    /// Keel's target for iogpu.wired_limit_mb (MiB) on a Mac with this much memory.
    static func wiredTargetMiB(memoryBytes: UInt64) -> Int {
        Int(memoryBytes / 1_048_576) - wiredReserveGiB(memoryBytes: memoryBytes) * 1024
    }

    /// The kernel's default GPU budget. While the limit is 0, Metal reports the default itself (read live so a
    /// change made in this session is seen); once raised Metal reports the raised value, so use the profile's estimate.
    static func defaultGPUBudgetBytes(_ m: MachineProfile) -> UInt64 { m.defaultGPUWorkingSetBytes }

    /// Live from Metal, except under `--simulate` with a different memory size, where the profile's value is used.
    static func currentGPUBudgetBytes(_ m: MachineProfile) -> UInt64 {
        if m.memoryBytes != memsizeNow, m.metalWorkingSetBytes > 0 { return m.metalWorkingSetBytes }
        return metalRecommendedWorkingSetBytes
    }

    static func mlxInstallLocation() -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: "\(brewPrefixGuess)/opt/mlx") { return "Homebrew (\(brewPrefixGuess)/opt/mlx)" }
        var roots: [String] = []
        for base in ["\(home)/Library/Python", "\(brewPrefixGuess)/lib"] {
            for v in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where v.hasPrefix("python3") || v.hasPrefix("3.") {
                roots.append(base.hasSuffix("/lib") ? "\(base)/\(v)/site-packages" : "\(base)/\(v)/lib/python/site-packages")
            }
        }
        return roots.first { fm.fileExists(atPath: "\($0)/mlx") }
    }

    /// The `iogpu.wired_limit_mb=N` a boot daemon re-applies, if its plist exists and is readable.
    static func daemonWiredValue(_ path: String) -> Int? {
        guard let d = NSDictionary(contentsOfFile: path), let args = d["ProgramArguments"] as? [String] else { return nil }
        for a in args where a.hasPrefix(wiredLimitSysctl + "=") { return Int(a.dropFirst(wiredLimitSysctl.count + 1)) }
        return nil
    }

    static func gibString(_ bytes: UInt64) -> String { String(format: "%.2f GiB", Double(bytes) / Double(gib)) }
    static func gibString(mib: Int) -> String { String(format: "%.2f GiB", Double(mib) / 1024) }

    /// hw.memsize read in-process; usable before `Machine.profile()` has loaded (catalog construction).
    static var memsizeNow: UInt64 { UInt64(Sysctl.int64("hw.memsize") ?? 0) }

    // MARK: Ollama: installs

    static var brewPrefixGuess: String {
        if let p = Machine.current.brewPrefix { return p }
        return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew" : "/usr/local"
    }

    /// Homebrew's per-user service override file, `$HOMEBREW_USER_CONFIG_HOME/services/ollama.env`.
    /// brew resolves HOMEBREW_USER_CONFIG_HOME to $XDG_CONFIG_HOME/homebrew when that is set, else ~/.homebrew.
    static var ollamaEnv: String {
        let env = ProcessInfo.processInfo.environment
        if let x = env["XDG_CONFIG_HOME"], !x.isEmpty { return "\(x)/homebrew/services/ollama.env" }
        if let x = env["HOMEBREW_XDG_CONFIG_HOME"], !x.isEmpty { return "\(x)/homebrew/services/ollama.env" }
        return "\(home)/.homebrew/services/ollama.env"
    }
    static let ollamaBrewPlist = "\(home)/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
    static let ollamaBrewLabel = "homebrew.mxcl.ollama"

    private static var brewCandidates: [String] { [brewPrefixGuess, "/opt/homebrew", "/usr/local"] }
    /// The Homebrew formula, not the /usr/local/bin/ollama symlink that Ollama.app installs.
    static func hasBrewOllama() -> Bool {
        brewCandidates.contains { FileManager.default.isExecutableFile(atPath: "\($0)/opt/ollama/bin/ollama") }
    }
    static var brewOllamaPrefix: String {
        brewCandidates.first { FileManager.default.isExecutableFile(atPath: "\($0)/opt/ollama/bin/ollama") } ?? brewPrefixGuess
    }

    nonisolated(unsafe) private static var envFileSupportCache: Bool?
    /// True when this Homebrew merges services/<formula>.env into the service definition (`effective_environment_variables`).
    static func brewSupportsServiceEnvFile() -> Bool {
        if let c = envFileSupportCache { return c }
        let rb = (try? String(contentsOfFile: "\(brewOllamaPrefix)/Library/Homebrew/service.rb", encoding: .utf8)) ?? ""
        let ok = rb.contains("effective_environment_variables")
        envFileSupportCache = ok
        return ok
    }

    /// Bundle ID of the Ollama macOS app as app catalogs list it; the path checks cover a changed ID.
    static let ollamaAppBundleID = "com.electron.ollama"
    static func ollamaAppURL() -> URL? {
        if let u = Machine.appURL(ollamaAppBundleID) { return u }
        for p in ["/Applications/Ollama.app", "\(home)/Applications/Ollama.app"] where FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }
    static func hasOllamaApp() -> Bool { ollamaAppURL() != nil }

    private static func isOllamaApp(_ a: NSRunningApplication) -> Bool {
        a.bundleIdentifier == ollamaAppBundleID || a.bundleURL?.lastPathComponent == "Ollama.app"
    }
    static func ollamaAppRunning() -> Bool { NSWorkspace.shared.runningApplications.contains(where: isOllamaApp) }

    /// Ollama.app's settings database (internal/onboarding/app_state.go AppDatabasePath).
    static var ollamaAppDB: String { "\(home)/Library/Application Support/Ollama/db.sqlite" }

    /// Ollama.app passes these to its server and they override the environment (app/server/server.go):
    /// context_length > 0 sets OLLAMA_CONTEXT_LENGTH, expose sets OLLAMA_HOST=0.0.0.0, browser sets OLLAMA_ORIGINS=*.
    static func ollamaAppSettings() async -> (contextLength: Int, expose: Bool, browser: Bool)? {
        guard FileManager.default.fileExists(atPath: ollamaAppDB), Permissions.canRead(ollamaAppDB) else { return nil }
        guard let r = await Shell.probe("/usr/bin/sqlite3", ["-readonly", "-separator", "|", ollamaAppDB, "SELECT context_length, expose, browser FROM settings WHERE id = 1;"]),
              r.ok else { return nil }
        let f = r.output.split(separator: "|").map(String.init)
        guard f.count == 3, let ctx = Int(f[0]) else { return nil }
        return (ctx, f[1] == "1", f[2] == "1")
    }

    /// e.g. ["127.0.0.1:11434"] or ["*:11434"].
    static func ollamaListenAddresses() async -> [String] {
        guard let r = await Shell.probe("/usr/sbin/lsof", ["-nP", "-iTCP:11434", "-sTCP:LISTEN"]), r.ok else { return [] }
        return r.stdout.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let i = cols.firstIndex(where: { $0.hasSuffix(":11434") }) else { return nil }
            return String(cols[i])
        }
    }

    static func isLoopbackHost(_ v: String?) -> Bool {
        guard var h = v?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return true }  // unset = 127.0.0.1
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        return h.hasPrefix("127.") || h.hasPrefix("localhost") || h.hasPrefix("[::1]") || h == "::1"
    }

    // MARK: Ollama: ~/.ollama/server.json (read by the server and by Ollama.app)

    static var ollamaServerConfig: String { "\(home)/.ollama/server.json" }

    static func ollamaBrewServiceLoaded() async -> Bool {
        await Shell.probe("/bin/launchctl", ["print", "gui/\(getuid())/\(ollamaBrewLabel)"])?.ok ?? false
    }

    /// Restarts whichever Ollama is running so it re-reads its environment and the GPU budget (both are read
    /// once at start): the brew service only when its agent is loaded (never starts it), Ollama.app only when open.
    static func restartOllamaIfRunning() async {
        if hasBrewOllama(), await ollamaBrewServiceLoaded() {
            _ = try? await Shell.run("\(brewOllamaPrefix)/bin/brew", ["services", "restart", "ollama"], timeout: 60)
            ActivityLog.post(.command, "brew services restart ollama")
        }
        if ollamaAppRunning() { await relaunchOllamaApp() }
    }

    /// Uses NSRunningApplication.terminate (no Apple Events, so no permission prompt), then reopens in the background.
    @MainActor static func relaunchOllamaApp() async {
        let apps = NSWorkspace.shared.runningApplications.filter(isOllamaApp)
        guard !apps.isEmpty else { return }
        let url = apps.first?.bundleURL ?? ollamaAppURL()
        apps.forEach { $0.terminate() }
        for _ in 0..<40 where apps.contains(where: { !$0.isTerminated }) { try? await Task.sleep(nanoseconds: 250_000_000) }
        guard let url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        ActivityLog.post(.command, "Quit and reopened Ollama.app")
    }

    // MARK: Ollama: Homebrew service env file (KEY=value lines)

    static func readEnvFile(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out[String(t[..<eq]).trimmingCharacters(in: .whitespaces)] = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Sets or removes a key in an env file; returns the previous value ("" = absent) for the backup.
    /// Comments and other lines are kept. Written 0644: brew skips group- or world-writable override files.
    static func setEnv(_ path: String, key: String, value: String?) throws -> String {
        let fm = FileManager.default
        let existing = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        var previous = ""
        var found = false
        var out: [String] = []
        for l in existing {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + "=") {
                if !found { previous = String(t.dropFirst(key.count + 1)) }
                if !found, let value { out.append("\(key)=\(value)") }
                found = true
                continue
            }
            if !t.isEmpty { out.append(l) }
        }
        if !found, let value { out.append("\(key)=\(value)") }
        if out.isEmpty && !fm.fileExists(atPath: path) { return previous }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (out.joined(separator: "\n") + (out.isEmpty ? "" : "\n")).write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        return found ? previous : ""
    }

    /// Formula env (keg plist, regenerated on upgrade) merged with ollama.env overrides, as brew merges them.
    static func ollamaEffectiveEnv() -> [String: String] {
        var env: [String: String] = [:]
        for p in ["\(brewOllamaPrefix)/opt/ollama/homebrew.mxcl.ollama.plist", ollamaBrewPlist] {
            if let d = NSDictionary(contentsOfFile: p), let e = d["EnvironmentVariables"] as? [String: String] { env = e; break }
        }
        for (k, v) in readEnvFile(ollamaEnv) { env[k] = v }
        return env
    }

    // MARK: Ollama.app: launchd user-domain environment

    /// Ollama.app passes the launchd user environment (`launchctl setenv`) to its server; that environment is lost
    /// at logout. Keel keeps its keys in a LaunchAgent that runs `launchctl setenv K V …` at every login.
    static let ollamaEnvAgentLabel = "com.keel.ollama-env"
    static var ollamaEnvAgentPath: String { "\(home)/Library/LaunchAgents/\(ollamaEnvAgentLabel).plist" }

    static func ollamaAgentEnv() -> [String: String] {
        guard let d = NSDictionary(contentsOfFile: ollamaEnvAgentPath), let args = d["ProgramArguments"] as? [String],
              args.count >= 2, args[1] == "setenv" else { return [:] }
        var out: [String: String] = [:]
        var i = 2
        while i + 1 < args.count { out[args[i]] = args[i + 1]; i += 2 }
        return out
    }

    static func launchdGetenv(_ key: String) async -> String? {
        guard let r = await Shell.probe("/bin/launchctl", ["getenv", key]), r.ok, !r.output.isEmpty else { return nil }
        return r.output
    }

    private static func writeOllamaAgent(_ env: [String: String]) async throws {
        let gui = "gui/\(getuid())"
        let path = ollamaEnvAgentPath
        _ = try? await Shell.run("/bin/launchctl", ["bootout", "\(gui)/\(ollamaEnvAgentLabel)"], timeout: 10)
        if env.isEmpty {
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            ActivityLog.post(.command, "launchctl bootout \(gui)/\(ollamaEnvAgentLabel); rm \(path)")
            return
        }
        var args = ["/bin/launchctl", "setenv"]
        for k in env.keys.sorted() { args += [k, env[k]!] }
        let plist: [String: Any] = ["Label": ollamaEnvAgentLabel, "ProgramArguments": args, "RunAtLoad": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = try? await Shell.run("/bin/launchctl", ["bootstrap", gui, path], timeout: 10)
        ActivityLog.post(.command, "wrote \(path) (\(args.joined(separator: " "))); launchctl bootstrap \(gui) \(path)")
    }

    /// Sets (value) or clears (nil) a key for Ollama.app now and at every login.
    /// `restoreLive` is put back in the live launchd environment when clearing ("" = unset).
    static func setOllamaAppEnv(key: String, value: String?, restoreLive: String = "") async throws {
        var env = ollamaAgentEnv()
        if let value {
            env[key] = value
            _ = try await Shell.run("/bin/launchctl", ["setenv", key, value], timeout: 10)
            ActivityLog.post(.command, "launchctl setenv \(key) \(value)")
        } else {
            env.removeValue(forKey: key)
            if restoreLive.isEmpty {
                _ = try await Shell.run("/bin/launchctl", ["unsetenv", key], timeout: 10)
                ActivityLog.post(.command, "launchctl unsetenv \(key)")
            } else {
                _ = try await Shell.run("/bin/launchctl", ["setenv", key, restoreLive], timeout: 10)
                ActivityLog.post(.command, "launchctl setenv \(key) \(restoreLive)")
            }
        }
        try await writeOllamaAgent(env)
    }

    // MARK: Ollama: models

    static func ollamaModelsDir() async -> String {
        if hasBrewOllama(), let p = ollamaEffectiveEnv()["OLLAMA_MODELS"], !p.isEmpty { return Shell.expand(p) }
        if hasOllamaApp(), let p = await launchdGetenv("OLLAMA_MODELS") { return Shell.expand(p) }
        return "\(home)/.ollama/models"
    }

    /// Installed models: from the API when a server answers on the default port, else counted from manifests on disk.
    static func ollamaModelCount() async -> (count: Int, source: String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        req.timeoutInterval = 1.5
        if let (d, _) = try? await URLSession.shared.data(for: req),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let m = o["models"] as? [[String: Any]] {
            return (m.count, "server")
        }
        return (countManifests("\(await ollamaModelsDir())/manifests"), "disk")
    }

    /// One manifest file per model tag at manifests/<registry>/<namespace>/<model>/<tag>.
    private static func countManifests(_ manifests: String) -> Int {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: manifests), includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var n = 0
        for case let u as URL in e where e.level >= 4 {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
        }
        return n
    }

    static func directorySize(_ path: String) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: UInt64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Ollama's automatic context for a GPU budget (server/routes.go: ≥ 47 GiB → 262144, ≥ 23 GiB → 32768, else 4096,
    /// measured after subtracting OLLAMA_GPU_OVERHEAD).
    static func ollamaAutoContext(budgetBytes: UInt64, overheadBytes: UInt64) -> Int {
        let vram = budgetBytes > overheadBytes ? budgetBytes - overheadBytes : 0
        if vram >= 47 * gib { return 262_144 }
        if vram >= 23 * gib { return 32_768 }
        return 4_096
    }

    // MARK: Ollama: env-backed tweak (Homebrew service and/or Ollama.app)

    /// Sets Ollama server env vars for the Homebrew service (ollama.env, survives brew upgrade) and Ollama.app
    /// (`launchctl setenv` plus a login agent). `applicability` is only checked while nothing is applied.
    static func ollamaEnvTweak(id: String, name: String, summary: String, explanation: String,
                               risk: Risk, impact: Impact = .low, recommended: Bool, confidence: Confidence = .high,
                               benefit: String, tradeoff: String = "", sources: [String],
                               appSupported: Bool = true,
                               appBlocked: @escaping @Sendable () async -> String? = { nil },
                               values: @escaping @Sendable (MachineProfile) -> [(String, String)],
                               matches: @escaping @Sendable (_ key: String, _ target: String, _ current: String?) -> Bool = { _, t, c in c == t },
                               applicability: @escaping @Sendable (MachineProfile) async -> String? = { _ in nil },
                               extraValues: @escaping @Sendable (MachineProfile) async -> [(String, String)] = { _ in [] }) -> Tweak {
        var m0 = MachineProfile()
        m0.memoryBytes = memsizeNow
        let shown = values(m0)
        let applyCmds = shown.map { "echo '\($0.0)=\($0.1)' >> ~/.homebrew/services/ollama.env  # Homebrew service" }
            + ["brew services restart ollama  # only if the service is loaded"]
            + (appSupported ? shown.map { "launchctl setenv \($0.0) \($0.1)  # Ollama.app; login agent \(ollamaEnvAgentLabel) repeats it" } + ["quit and reopen Ollama.app if it is open"] : [])
        let revertCmds = shown.map { "remove \($0.0) from ~/.homebrew/services/ollama.env (or restore the recorded value)" }
            + (appSupported ? shown.map { "launchctl unsetenv \($0.0); drop it from ~/Library/LaunchAgents/\(ollamaEnvAgentLabel).plist" } : [])
            + ["restart whichever Ollama is running"]

        /// Usable targets; `blocked` explains why an installed Ollama.app is not one.
        @Sendable func targets() async -> (brew: Bool, app: Bool, blocked: String?) {
            let brew = hasBrewOllama() && brewSupportsServiceEnvFile()
            guard hasOllamaApp() else { return (brew, false, nil) }
            guard appSupported else { return (brew, false, "Ollama.app is not covered by this setting.") }
            if let why = await appBlocked() { return (brew, false, why) }
            return (brew, true, nil)
        }

        return Tweak(id: id, name: name, category: .ai, summary: summary, explanation: explanation, risk: risk, impact: impact, recommended: recommended,
              mechanism: .custom(CustomMechanism(
                detect: {
                    let m = await Machine.profile()
                    let brewInstalled = hasBrewOllama(), appInstalled = hasOllamaApp()
                    guard brewInstalled || appInstalled else { return .na("Ollama is not installed") }
                    let t = await targets()
                    let wanted = values(m)
                    var vals: [(String, String)] = []
                    var onTargets = 0, total = 0, anySet = false
                    var notes: [String] = []
                    if brewInstalled && !t.brew { notes.append("This Homebrew does not read ~/.homebrew/services/ollama.env; run `brew update` first.") }
                    if t.brew {
                        let env = ollamaEffectiveEnv()
                        var all = true
                        for (k, v) in wanted {
                            let cur = env[k]
                            vals.append(("\(k) (brew service)", cur ?? "(unset: Ollama default)"))
                            if matches(k, v, cur) { anySet = true } else { all = false }
                        }
                        total += 1; if all { onTargets += 1 }
                    }
                    if t.app {
                        let agent = ollamaAgentEnv()
                        var all = true
                        for (k, v) in wanted {
                            let live = await launchdGetenv(k)
                            let persisted = agent[k] != nil
                            vals.append(("\(k) (Ollama.app)", live.map { "\($0) (\(persisted ? "re-applied at login by Keel" : "this login only"))" } ?? "(unset: Ollama default)"))
                            if matches(k, v, live) && persisted { anySet = true } else { all = false }
                        }
                        total += 1; if all { onTargets += 1 }
                    } else if appInstalled, let why = t.blocked {
                        notes.append(why)
                    }
                    if total == 0 { return .na(notes.first ?? "Ollama is not installed") }
                    if !anySet, let reason = await applicability(m) { return .na(reason) }
                    vals += await extraValues(m)
                    if t.brew { vals.append(("brew service", await ollamaBrewServiceLoaded() ? "loaded" : "not loaded (settings apply at next `brew services start ollama`)")) }
                    if t.app { vals.append(("Ollama.app", ollamaAppRunning() ? "running" : "not running")) }
                    let state: TweakState = onTargets == total ? .on : (anySet ? .partlyOn : .off)
                    return Detection(state: state, values: vals, note: notes.isEmpty ? nil : notes.joined(separator: " "))
                },
                apply: { ctx in
                    let t = await targets()
                    guard t.brew || t.app else { throw TweakEngine.EngineError(message: "No Ollama install that Keel can configure") }
                    var rec: [String: String] = ["targets": [t.brew ? "brew" : nil, t.app ? "app" : nil].compactMap { $0 }.joined(separator: ",")]
                    for (k, v) in values(ctx.machine) {
                        if t.brew { rec["brew.\(k)"] = try setEnv(ollamaEnv, key: k, value: v) }
                        if t.app {
                            rec["app.\(k)"] = ollamaAgentEnv()[k] ?? ""
                            rec["applive.\(k)"] = await launchdGetenv(k) ?? ""
                            try await setOllamaAppEnv(key: k, value: v)
                        }
                    }
                    if t.brew { ActivityLog.post(.command, "updated \(ollamaEnv)") }
                    await ProbeCache.shared.invalidate()
                    await restartOllamaIfRunning()
                    return rec
                },
                revert: { ctx, orig in
                    let recorded = Set((orig["targets"] ?? "").split(separator: ",").map(String.init))
                    for k in values(ctx.machine).map(\.0) {
                        if orig.isEmpty {
                            // Nothing recorded: back to Ollama's default (key unset) wherever Keel can reach.
                            if Shell.exists(ollamaEnv) { _ = try setEnv(ollamaEnv, key: k, value: nil) }
                            if ollamaAgentEnv()[k] != nil { try await setOllamaAppEnv(key: k, value: nil) }
                            continue
                        }
                        if orig["key"] == k {  // record from older Keel: {key, previous} for the brew env file
                            let p = orig["previous"] ?? ""
                            _ = try setEnv(ollamaEnv, key: k, value: p.isEmpty ? nil : p)
                        }
                        if recorded.contains("brew"), let p = orig["brew.\(k)"] {
                            _ = try setEnv(ollamaEnv, key: k, value: p.isEmpty ? nil : p)
                        }
                        if recorded.contains("app") {
                            let agentPrev = orig["app.\(k)"] ?? "", livePrev = orig["applive.\(k)"] ?? ""
                            if agentPrev.isEmpty { try await setOllamaAppEnv(key: k, value: nil, restoreLive: livePrev) }
                            else { try await setOllamaAppEnv(key: k, value: agentPrev) }
                        }
                    }
                    await ProbeCache.shared.invalidate()
                    await restartOllamaIfRunning()
                },
                applyCommands: applyCmds, revertCommands: revertCmds, needsAdmin: false)),
              sources: sources, confidence: confidence, expectedBenefit: benefit, tradeoff: tradeoff)
    }

    // MARK: LM Studio

    /// Bundle identifier as app catalogs list it (Developer ID team D65G88RHWN); the path checks cover a changed ID.
    static let lmStudioBundleID = "ai.elementlabs.lmstudio"
    static func lmStudioAppURL() -> URL? {
        if let u = Machine.appURL(lmStudioBundleID) { return u }
        for p in ["/Applications/LM Studio.app", "\(home)/Applications/LM Studio.app"] where FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }
    /// LM Studio's data folder, resolved the way its own tools do (lmstudio-js findLMStudioHome): the path in
    /// ~/.lmstudio-home-pointer, else ~/.cache/lm-studio, else ~/.lmstudio. nil when none exists.
    static func lmStudioHome() -> String? {
        let fm = FileManager.default
        if let p = try? String(contentsOfFile: "\(home)/.lmstudio-home-pointer", encoding: .utf8) {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, fm.fileExists(atPath: t) { return t }
        }
        return ["\(home)/.cache/lm-studio", "\(home)/.lmstudio"].first { fm.fileExists(atPath: $0) }
    }

    /// LM Studio's models folder: `downloadsFolder` in <home>/settings.json (as `lms import` reads it), else <home>/models.
    static func lmStudioModelsFolder(_ lmHome: String) -> String {
        if let f = readJSON("\(lmHome)/settings.json")?["downloadsFolder"] as? String, !f.isEmpty { return Shell.expand(f) }
        return "\(lmHome)/models"
    }

    static func llamaServerPath() -> String? {
        Set([brewPrefixGuess, "/opt/homebrew", "/usr/local"]).map { "\($0)/bin/llama-server" }.sorted().first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func lmStudioRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == lmStudioBundleID || $0.bundleURL?.lastPathComponent == "LM Studio.app" }
    }

    /// Models laid out as <folder>/<publisher>/<model>: total, MLX (safetensors), GGUF, bytes.
    static func lmStudioModels(_ lmHome: String) -> (total: Int, mlx: Int, gguf: Int, bytes: UInt64) {
        let fm = FileManager.default
        let root = lmStudioModelsFolder(lmHome)
        var total = 0, mlx = 0, gguf = 0
        var bytes: UInt64 = 0
        for pub in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !pub.hasPrefix(".") {
            for model in (try? fm.contentsOfDirectory(atPath: "\(root)/\(pub)")) ?? [] where !model.hasPrefix(".") {
                let dir = "\(root)/\(pub)/\(model)"
                let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                let isGGUF = files.contains { $0.lowercased().hasSuffix(".gguf") }
                let isMLX = files.contains { $0.lowercased().hasSuffix(".safetensors") }
                guard isGGUF || isMLX else { continue }
                total += 1
                if isGGUF { gguf += 1 } else { mlx += 1 }
                bytes += directorySize(dir)
            }
        }
        return (total, mlx, gguf, bytes)
    }
}
