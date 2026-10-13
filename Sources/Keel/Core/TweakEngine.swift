import Foundation
import AppKit
import KeelShared

/// A batch records each original, runs all root ops together (one admin prompt at most), restarts each
/// affected process once, then re-detects and restores any tweak that did not stick.
enum TweakEngine {
    struct EngineError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Outcome: Sendable {
        case done(TweakState, note: String?)
        case failed(String)
        case skipped(String)
        var isSuccess: Bool { if case .done = self { return true }; return false }
    }

    private static func log(_ level: LogLevel, _ m: String, _ d: String? = nil) { ActivityLog.post(level, m, detail: d) }

    // MARK: - Detect

    static func detect(_ t: Tweak) async -> Detection {
        let m = await Machine.profile()
        for r in t.requires { if let reason = await r.unmetReason(m) { return .na(reason) } }
        switch t.mechanism {
        case .defaults(let settings, _):
            var values: [(String, String)] = []
            var onCount = 0
            for s in settings {
                let v = Prefs.string(s.domain, s.key, currentHost: s.currentHost)
                values.append(("\(s.currentHost ? "[host] " : "")\(s.domain) \(s.key)", v ?? "(not set)"))
                if s.isOn(v) { onCount += 1 }
            }
            return Detection(state: onCount == settings.count ? .on : (onCount == 0 ? .off : .partlyOn), values: values)
        case .pmset(let settings):
            let table = await Pmset.current()
            var values: [(String, String)] = []
            var onCount = 0, total = 0
            for s in settings {
                for src in s.scope.sources where m.powerSources.contains(src) {
                    total += 1
                    let v = table[src]?[s.key]
                    values.append(("\(s.key) (\(src == "Battery Power" ? "battery" : "power adapter"))", v ?? "(absent)"))
                    if v == s.on { onCount += 1 }
                }
            }
            if total == 0 { return .na("This Mac has no \(settings.first?.scope == .battery ? "battery" : "matching power source")") }
            return Detection(state: onCount == total ? .on : (onCount == 0 ? .off : .partlyOn), values: values)
        case .sysctl(let name, let value, let persist):
            let target = value(m)
            guard let v = Sysctl.int(name) else { return .na("\(name) does not exist on this macOS") }
            var values = [(name, String(v)), ("target", String(target))]
            let label = KeelConstants.sysctlDaemonLabel(name)
            let daemon = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(label).plist")
            if persist { values.append(("boot LaunchDaemon", daemon ? "installed" : "not installed")) }
            let live = v == target
            let state: TweakState = persist ? (live && daemon ? .on : (!live && !daemon ? .off : .partlyOn)) : (live ? .on : .off)
            return Detection(state: state, values: values)
        case .launchd(let items):
            var values: [(String, String)] = []
            var gone = 0
            for i in items {
                let present = FileManager.default.fileExists(atPath: i.plistPath)
                let loaded = await Launchd.isLoaded(i)
                let disabled = await Launchd.isDisabled(i)
                let text: String
                switch (present, loaded, disabled) {
                case (_, true, _): text = present ? "loaded and running when scheduled" : "loaded (file removed)"
                case (true, false, true): text = "disabled in launchd (the vendor re-created the file, but it cannot load)"
                case (true, false, false): text = "installed; loads at next login"
                case (false, false, _): text = "removed by Keel"
                }
                values.append((i.label, text))
                if !loaded && (!present || disabled) { gone += 1 }
            }
            if items.isEmpty { return .na("Nothing installed") }
            return Detection(state: gone == items.count ? .on : (gone == 0 ? .off : .partlyOn), values: values)
        case .custom(let c): return await c.detect()
        case .manual(let mm): return await mm.detect()
        }
    }

    // MARK: - Apply

    static func apply(_ tweaks: [Tweak]) async -> [String: Outcome] {
        let m = await Machine.profile()
        let ctx = ApplyContext(machine: m)
        var outcomes: [String: Outcome] = [:]
        var prepared: [(Tweak, BackupRecord)] = []

        for t in tweaks {
            let before = await detect(t)
            if before.state == .notApplicable { outcomes[t.id] = .skipped(before.note ?? "Not applicable"); continue }
            if before.state == .on && !t.isManual && !t.oneShot { outcomes[t.id] = .skipped("Already on"); continue }
            if case .manual(let mm) = t.mechanism {
                if let u = URL(string: mm.settingsURL), !mm.settingsURL.isEmpty { await MainActor.run { _ = NSWorkspace.shared.open(u) } }
                log(.info, "Opened settings for “\(t.name)”", mm.instructions)
                outcomes[t.id] = .skipped("Opened System Settings")
                continue
            }
            ctx.currentTweak = t.id
            log(.info, "Applying “\(t.name)”", t.applyCommands(m).joined(separator: "\n"))
            do {
                let rec = try await prepareApply(t, ctx: ctx, machine: m)
                prepared.append((t, rec))
            } catch {
                log(.error, "“\(t.name)”: \(error.localizedDescription)")
                outcomes[t.id] = .failed(error.localizedDescription)
            }
        }

        var rootFailed: [String: String] = [:]
        if !ctx.ops.isEmpty {
            let names = Set(ctx.ops.map(\.tweakID)).compactMap { id in tweaks.first { $0.id == id }?.name }
            do {
                let results = try await Privileged.run(ctx.ops.map(\.op), reason: names.count == 1 ? "apply “\(names[0])”" : "apply \(names.count) changes")
                for (i, r) in results.enumerated() where i < ctx.ops.count {
                    let (tid, op) = ctx.ops[i]
                    log(r.ok ? .command : .error, op.description, r.output.isEmpty ? nil : r.output)
                    if !r.ok && rootFailed[tid] == nil { rootFailed[tid] = r.output.isEmpty ? op.description : r.output }
                }
            } catch {
                // Cancelled or failed: undo the user-level half of every tweak that needed root.
                let ids = Set(ctx.ops.map(\.tweakID))
                for (t, rec) in prepared where ids.contains(t.id) {
                    await rollbackUserLevel(t, rec, machine: m)
                    outcomes[t.id] = .failed(error.localizedDescription)
                }
                prepared.removeAll { ids.contains($0.0.id) }
                log(.warning, error.localizedDescription)
            }
        }
        for (tid, step) in ctx.afterRoot where rootFailed[tid] == nil && prepared.contains(where: { $0.0.id == tid }) {
            do { try await step() } catch { rootFailed[tid] = error.localizedDescription }
        }
        await runPosts(ctx.posts)
        await ProbeCache.shared.invalidate()

        // Restore anything that did not stick.
        var toRestore: [(Tweak, BackupRecord)] = []
        for (t, rec) in prepared {
            if let why = rootFailed[t.id] { toRestore.append((t, rec)); outcomes[t.id] = .failed(why); continue }
            let after = await detect(t)
            if t.oneShot {
                outcomes[t.id] = .done(after.state, note: after.note)
                log(.success, "“\(t.name)” done", after.values.map { "\($0.0) = \($0.1)" }.joined(separator: "\n"))
                continue
            }
            let deferred = t.postAction == .logout || t.postAction == .restart
            if after.state == .on || (deferred && after.state != .off) {
                BackupStore.save(rec)
                outcomes[t.id] = .done(after.state, note: deferred ? "Takes full effect after you \(t.postAction == .logout ? "log out and back in" : "restart")" : nil)
                log(.success, "“\(t.name)” is on", after.values.map { "\($0.0) = \($0.1)" }.joined(separator: "\n"))
            } else {
                toRestore.append((t, rec))
                outcomes[t.id] = .failed("Did not read back as on (\(after.state.rawValue)); original restored")
                log(.error, "“\(t.name)” did not read back as on; restoring the recorded original", after.values.map { "\($0.0) = \($0.1)" }.joined(separator: "\n"))
            }
        }
        if !toRestore.isEmpty {
            for (_, rec) in toRestore { BackupStore.save(rec) }
            _ = await revert(toRestore.map(\.0), quiet: true)
        }
        return outcomes
    }

    /// Records the original, makes user-level changes and queues root ops.
    private static func prepareApply(_ t: Tweak, ctx: ApplyContext, machine m: MachineProfile) async throws -> BackupRecord {
        switch t.mechanism {
        case .defaults(let settings, let post):
            var orig: [String: String] = ["count": String(settings.count)]
            for (i, s) in settings.enumerated() {
                let v = Prefs.value(s.domain, s.key, currentHost: s.currentHost)
                orig["\(i).existed"] = v == nil ? "0" : "1"
                if let v { orig["\(i).value"] = Prefs.render(v); orig["\(i).type"] = Prefs.type(of: v).rawValue }
            }
            for s in settings {
                guard Prefs.write(s.domain, s.key, s.on, type: s.type, currentHost: s.currentHost) else {
                    throw EngineError(message: "Could not write \(s.domain) \(s.key) (the domain may be protected)")
                }
                log(.command, s.writeCommand(s.on))
            }
            ctx.post(post)
            return BackupRecord(tweakID: t.id, date: Date(), kind: .defaults, original: orig, fileName: nil)
        case .pmset(let settings):
            let table = await Pmset.current(fresh: true)
            var orig: [String: String] = [:]
            for s in settings {
                for src in s.scope.sources where m.powerSources.contains(src) {
                    orig["\(src).\(s.key)"] = table[src]?[s.key] ?? ""
                    ctx.privileged(.pmset(scope: src == "Battery Power" ? "-b" : "-c", key: s.key, value: s.on))
                }
            }
            return BackupRecord(tweakID: t.id, date: Date(), kind: .pmset, original: orig, fileName: nil)
        case .sysctl(let name, let value, let persist):
            let prev = Sysctl.int(name) ?? 0
            let daemonExisted = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(KeelConstants.sysctlDaemonLabel(name)).plist")
            ctx.privileged(.sysctl(name: name, value: value(m)))
            if persist { ctx.privileged(.installSysctlDaemon(name: name, value: value(m))) }
            return BackupRecord(tweakID: t.id, date: Date(), kind: .sysctl, original: ["name": name, "value": String(prev), "daemonExisted": daemonExisted ? "1" : "0"], fileName: nil)
        case .launchd(let items):
            var orig: [String: String] = [:]
            var files: [String] = []
            var n = 0
            for item in items where FileManager.default.fileExists(atPath: item.plistPath) {
                let name = BackupStore.backupName(for: item.plistPath, tag: t.id)
                let dest = BackupStore.fileURL(name).path
                orig["\(n).label"] = item.label; orig["\(n).path"] = item.plistPath; orig["\(n).file"] = name; orig["\(n).domain"] = item.domain.rawValue
                // Record the exact launchd state so restoring brings back what was there, nothing more.
                orig["\(n).loaded"] = await Launchd.isLoaded(item) ? "1" : "0"
                orig["\(n).disabled"] = await Launchd.isDisabled(item) ? "1" : "0"
                files.append(name); n += 1
                let gui = "gui/\(m.uid)"
                switch item.domain {
                case .user:
                    _ = try? await Shell.run("/bin/launchctl", ["bootout", "\(gui)/\(item.label)"])
                    try FileManager.default.copyItem(atPath: item.plistPath, toPath: dest)
                    try FileManager.default.removeItem(atPath: item.plistPath)
                    _ = try? await Shell.run("/bin/launchctl", ["disable", "\(gui)/\(item.label)"])
                    log(.command, "launchctl bootout \(gui)/\(item.label); mv \(item.plistPath) → backups; launchctl disable \(gui)/\(item.label)")
                case .globalAgent:
                    _ = try? await Shell.run("/bin/launchctl", ["bootout", "\(gui)/\(item.label)"])
                    ctx.privileged(.moveFile(from: item.plistPath, to: dest))
                    let label = item.label
                    ctx.afterPrivileged { _ = try? await Shell.run("/bin/launchctl", ["disable", "\(gui)/\(label)"]) }
                case .system:
                    ctx.privileged([.launchctl(verb: "bootout", domain: "system", target: item.label),
                                    .moveFile(from: item.plistPath, to: dest),
                                    .launchctl(verb: "disable", domain: "system", target: item.label)])
                }
            }
            orig["count"] = String(n)
            if n == 0 { throw EngineError(message: "Nothing to disable") }
            return BackupRecord(tweakID: t.id, date: Date(), kind: .plistMoved, original: orig, fileName: files.joined(separator: ","))
        case .custom(let c):
            let orig = try await c.apply(ctx)
            return BackupRecord(tweakID: t.id, date: Date(), kind: .text, original: orig, fileName: nil)
        case .manual:
            throw EngineError(message: "Manual tweak")
        }
    }

    /// After a cancelled admin prompt: undo only what was already done without root.
    private static func rollbackUserLevel(_ t: Tweak, _ rec: BackupRecord, machine m: MachineProfile) async {
        switch t.mechanism {
        case .launchd:
            let count = Int(rec.original["count"] ?? "0") ?? 0
            for i in 0..<count {
                guard let label = rec.original["\(i).label"], let path = rec.original["\(i).path"], rec.original["\(i).domain"] == LaunchdDomain.globalAgent.rawValue else { continue }
                _ = try? await Shell.run("/bin/launchctl", ["bootstrap", "gui/\(m.uid)", path])
                _ = label
            }
        case .custom(let c):
            let ctx = ApplyContext(machine: m)
            try? await c.revert(ctx, rec.original)  // root ops it queues are dropped
        default: break
        }
    }

    // MARK: - Revert

    static func revert(_ tweaks: [Tweak], quiet: Bool = false) async -> [String: Outcome] {
        let m = await Machine.profile()
        let ctx = ApplyContext(machine: m)
        var outcomes: [String: Outcome] = [:]
        var prepared: [(Tweak, BackupRecord?)] = []
        for t in tweaks {
            if t.isManual { outcomes[t.id] = .skipped("Change it back in System Settings"); continue }
            if t.oneShot { outcomes[t.id] = .skipped("A one-time action: nothing to undo"); continue }
            ctx.currentTweak = t.id
            let rec = BackupStore.latest(for: t.id)
            if !quiet {
                if let rec { log(.info, "Reverting “\(t.name)” to the original recorded \(rec.date.formatted(date: .abbreviated, time: .shortened))") }
                else { log(.warning, "No recorded original for “\(t.name)”; restoring the documented default") }
            }
            do {
                try await prepareRevert(t, rec, ctx: ctx, machine: m)
                prepared.append((t, rec))
            } catch {
                outcomes[t.id] = .failed(error.localizedDescription)
                log(.error, "“\(t.name)”: \(error.localizedDescription)")
            }
        }
        var rootFailed: [String: String] = [:]
        if !ctx.ops.isEmpty {
            let names = Set(ctx.ops.map(\.tweakID)).compactMap { id in tweaks.first { $0.id == id }?.name }
            do {
                let results = try await Privileged.run(ctx.ops.map(\.op), reason: names.count == 1 ? "restore “\(names[0])”" : "restore \(names.count) settings")
                for (i, r) in results.enumerated() where i < ctx.ops.count {
                    let (tid, op) = ctx.ops[i]
                    log(r.ok ? .command : .error, op.description, r.output.isEmpty ? nil : r.output)
                    if !r.ok && rootFailed[tid] == nil { rootFailed[tid] = r.output }
                }
            } catch {
                for tid in Set(ctx.ops.map(\.tweakID)) { rootFailed[tid] = error.localizedDescription }
            }
        }
        for (tid, step) in ctx.afterRoot where rootFailed[tid] == nil {
            do { try await step() } catch { rootFailed[tid] = error.localizedDescription }
        }
        await runPosts(ctx.posts)
        await ProbeCache.shared.invalidate()
        for (t, rec) in prepared {
            if let why = rootFailed[t.id] { outcomes[t.id] = .failed(why); continue }
            if let rec { BackupStore.remove(rec) }
            let after = await detect(t)
            outcomes[t.id] = .done(after.state, note: nil)
            if !quiet { log(.success, "“\(t.name)” restored; now \(after.state.rawValue)") }
        }
        return outcomes
    }

    private static func prepareRevert(_ t: Tweak, _ b: BackupRecord?, ctx: ApplyContext, machine m: MachineProfile) async throws {
        switch t.mechanism {
        case .defaults(let settings, let post):
            for (i, s) in settings.enumerated() {
                if let b {
                    if b.original["\(i).existed"] == "1", let v = b.original["\(i).value"] {
                        let type = DefaultsType(rawValue: b.original["\(i).type"] ?? "") ?? s.type
                        Prefs.write(s.domain, s.key, v, type: type, currentHost: s.currentHost)
                        log(.command, DefaultsSetting(domain: s.domain, key: s.key, type: type, on: v, off: nil, currentHost: s.currentHost).writeCommand(v))
                    } else { Prefs.delete(s.domain, s.key, currentHost: s.currentHost); log(.command, s.deleteCommand) }
                } else {
                    if let off = s.off { Prefs.write(s.domain, s.key, off, type: s.type, currentHost: s.currentHost); log(.command, s.writeCommand(off)) }
                    else { Prefs.delete(s.domain, s.key, currentHost: s.currentHost); log(.command, s.deleteCommand) }
                }
            }
            ctx.post(post)
        case .pmset(let settings):
            for s in settings {
                for src in s.scope.sources where m.powerSources.contains(src) {
                    let rec = b?.original["\(src).\(s.key)"] ?? ""
                    ctx.privileged(.pmset(scope: src == "Battery Power" ? "-b" : "-c", key: s.key, value: rec.isEmpty ? s.off : rec))
                }
            }
        case .sysctl(let name, _, let persist):
            let prev = Int(b?.original["value"] ?? "") ?? SysctlDefaults.value(for: name)
            ctx.privileged(.sysctl(name: name, value: prev))
            if persist && b?.original["daemonExisted"] != "1" { ctx.privileged(.removeSysctlDaemon(name: name)) }
        case .launchd:
            guard let b else { throw EngineError(message: "Nothing recorded to restore") }
            let count = Int(b.original["count"] ?? "0") ?? 0
            let gui = "gui/\(m.uid)"
            for i in 0..<count {
                guard let path = b.original["\(i).path"], let file = b.original["\(i).file"], let label = b.original["\(i).label"] else { continue }
                let src = BackupStore.fileURL(file).path
                // Older records lack this key: assume it was loaded and enabled.
                let wasLoaded = b.original["\(i).loaded"] != "0"
                let wasDisabled = b.original["\(i).disabled"] == "1"
                switch LaunchdDomain(rawValue: b.original["\(i).domain"] ?? "user") ?? .user {
                case .user:
                    if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path) }
                    try FileManager.default.copyItem(atPath: src, toPath: path)
                    if !wasDisabled { _ = try? await Shell.run("/bin/launchctl", ["enable", "\(gui)/\(label)"]) }
                    if wasLoaded { _ = try? await Shell.run("/bin/launchctl", ["bootstrap", gui, path]) }
                    log(.command, "cp backup → \(path)\(wasDisabled ? "" : "; launchctl enable \(gui)/\(label)")\(wasLoaded ? "; launchctl bootstrap \(gui) \(path)" : "")")
                case .globalAgent:
                    ctx.privileged(.copyFile(from: src, to: path))
                    ctx.afterPrivileged {
                        if !wasDisabled { _ = try? await Shell.run("/bin/launchctl", ["enable", "\(gui)/\(label)"]) }
                        if wasLoaded { _ = try? await Shell.run("/bin/launchctl", ["bootstrap", gui, path]) }
                    }
                case .system:
                    var ops: [PrivOp] = [.copyFile(from: src, to: path)]
                    if !wasDisabled { ops.append(.launchctl(verb: "enable", domain: "system", target: label)) }
                    if wasLoaded { ops.append(.launchctl(verb: "bootstrap", domain: "system", target: path)) }
                    ctx.privileged(ops)
                }
            }
        case .custom(let c):
            try await c.revert(ctx, b?.original ?? [:])
        case .manual:
            break
        }
    }

    // MARK: - Process restarts

    private static let restartGuard = RestartGuard()

    static func runPosts(_ posts: Set<PostAction>) async {
        var restarted = false
        for p in posts {
            if let name = p.processName {
                await restartGuard.restart(name)
                log(.command, "killall \(name)")
                restarted = true
            } else if p == .logout || p == .restart {
                log(.warning, "Takes full effect after you \(p == .logout ? "log out and back in" : "restart")")
            }
        }
        if restarted { try? await Task.sleep(nanoseconds: 800_000_000) }
    }
}

/// A process killed again right after relaunching can write stale preferences back, so restarts
/// of the same process stay at least 5 s apart.
actor RestartGuard {
    private var last: [String: Date] = [:]
    func restart(_ name: String) async {
        try? await Task.sleep(nanoseconds: 300_000_000)  // let cfprefsd flush
        if let l = last[name] {
            let wait = 5 - Date().timeIntervalSince(l)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        _ = try? await Shell.run("/usr/bin/killall", [name], timeout: 10)
        last[name] = Date()
    }
}

// MARK: - Helpers

enum SysctlDefaults {
    static func value(for name: String) -> Int {
        switch name {
        case "iogpu.wired_limit_mb": return 0
        case "debug.lowpri_throttle_enabled": return 1
        default: return 0
        }
    }
}

extension PmsetScope {
    var sources: [String] {
        switch self {
        case .all: return ["Battery Power", "AC Power"]
        case .battery: return ["Battery Power"]
        case .charger: return ["AC Power"]
        }
    }
}

enum Pmset {
    /// `pmset -g custom` as [source: [key: value]]. Cached for a few seconds unless `fresh`.
    static func current(fresh: Bool = false) async -> [String: [String: String]] {
        if fresh { await ProbeCache.shared.invalidate() }
        guard let r = await Shell.probe("/usr/bin/pmset", ["-g", "custom"]) else { return [:] }
        var table: [String: [String: String]] = [:]
        var section = ""
        for raw in r.stdout.split(separator: "\n") {
            let line = String(raw)
            if line.hasSuffix(":") && !line.hasPrefix(" ") { section = String(line.dropLast()); table[section] = [:]; continue }
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, !section.isEmpty else { continue }
            table[section]?[parts.dropLast().joined(separator: " ")] = String(parts.last!)
        }
        return table
    }
}

enum Launchd {
    /// True when launchd's override database marks the label disabled for its domain.
    static func isDisabled(_ i: LaunchdItem) async -> Bool {
        let dom = i.domain == .system ? "system" : "gui/\(getuid())"
        guard let r = await Shell.probe("/bin/launchctl", ["print-disabled", dom]) else { return false }
        return r.stdout.split(separator: "\n").contains { $0.contains("\"\(i.label)\"") && ($0.contains("=> disabled") || $0.contains("=> true")) }
    }

    static func isLoaded(_ i: LaunchdItem) async -> Bool {
        let dom = i.domain == .system ? "system" : "gui/\(getuid())"
        guard let r = await Shell.probe("/bin/launchctl", ["print", "\(dom)/\(i.label)"]) else { return false }
        return r.ok
    }
}
