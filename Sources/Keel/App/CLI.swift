import SwiftUI
import AppKit
import KeelShared
import ServiceManagement

/// Headless modes for tests and CI.
@MainActor
enum CLI {
    static func arg(after flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > i + 1 else { return nil }
        let v = CommandLine.arguments[i + 1]
        return v.hasPrefix("--") ? nil : v
    }

    static func machine() async {
        let m = await Machine.profile()
        print("""
        model        \(m.modelName) (\(m.modelID))
        chip         \(m.chip): \(m.perfCores)P + \(m.effCores)E, GPU working set \(m.metalWorkingSetBytes / 1_048_576) MiB
        memory       \(m.memoryGB) GB
        macOS        \(m.osString) (\(m.osBuild))
        battery      \(m.hasBattery)  sources: \(m.powerSources.joined(separator: ", "))
        pmset caps   \(m.pmsetCapabilities.sorted().joined(separator: " "))
        wifi         \(m.wifiDevice ?? "-") / \(m.wifiService ?? "-")   primary: \(m.primaryDevice ?? "-") / \(m.primaryService ?? "-")
        display      max \(Int(m.mainDisplayMaxRefresh)) Hz
        xcode        \(m.hasXcode)   CLT \(m.hasCommandLineTools)   brew \(m.brewPrefix ?? "-")
        """)
    }

    /// Runs the helper's allow-list over good and hostile requests without executing anything.
    static func validateOps() async {
        let m = await Machine.profile()
        let home = m.home
        let cases: [(PrivOp, Bool)] = [
            (.pmset(scope: "-b", key: "powermode", value: "0"), true),
            (.pmset(scope: "-b", key: "hibernatemode", value: "0; rm -rf /"), false),
            (.pmset(scope: "-x", key: "powermode", value: "0"), false),
            (.pmset(scope: "-a", key: "autorestart", value: "1"), true),
            (.pmset(scope: "-a", key: "gpuswitch", value: "1"), false),
            (.sysctl(name: "iogpu.wired_limit_mb", value: max(2048, m.memoryMB - 4096)), true),
            (.sysctl(name: "iogpu.wired_limit_mb", value: 0), true),
            (.sysctl(name: "iogpu.wired_limit_mb", value: 1024), false),
            (.sysctl(name: "iogpu.wired_limit_mb", value: m.memoryMB), false),
            (.sysctl(name: "kern.maxfiles", value: 1), false),
            (.launchctl(verb: "bootout", domain: "system", target: "us.zoom.ZoomDaemon"), true),
            (.launchctl(verb: "bootout", domain: "system", target: "x; reboot"), false),
            (.launchctl(verb: "kickstart", domain: "system", target: "com.apple.foo"), false),
            (.launchctl(verb: "bootstrap", domain: "system", target: "/tmp/evil.plist"), false),
            (.moveFile(from: "/Library/LaunchDaemons/does-not-exist.plist", to: "\(home)/Library/Application Support/Keel/backups/x.plist"), false),
            (.rootDefaults(domain: "/Library/Preferences/com.apple.SoftwareUpdate", key: "AutomaticDownload", value: false), true),
            (.rootDefaults(domain: "/Library/Preferences/com.apple.security", key: "GKAutoRearm", value: false), false),
            (.systemsetup(flag: "-setremotelogin", on: false), true),
            (.systemsetup(flag: "-setusingnetworktime", on: false), false),
            (.nvram(name: "StartupMute", value: "%01"), true),
            (.nvram(name: "StartupMute", value: nil), true),
            (.nvram(name: "boot-args", value: "-v"), false),
            (.nvram(name: "StartupMute", value: "%02"), false),
            (.moveFile(from: "/etc/sudoers", to: "\(home)/Library/Application Support/Keel/backups/x.plist"), false),
            (.copyFile(from: "\(home)/Library/Application Support/Keel/backups/x.plist", to: "/Library/LaunchDaemons/../../etc/x.plist"), false),
            (.removeFile(path: "/System/Library/CoreServices/x.plist"), false),
            (.setDNS(service: "Wi-Fi", servers: ["1.1.1.1", "2606:4700:4700::1111"]), true),
            (.setDNS(service: "Wi-Fi", servers: ["1.1.1.1; rm"]), false),
            (.interface(name: "awdl0", up: false), true),
            (.interface(name: "en0", up: false), false),
            (.tmExclusion(path: "/System", add: true), false),
            (.powermetrics(samplers: "cpu_power,gpu_power", ms: 1000), true),
            (.powermetrics(samplers: "cpu_power; rm", ms: 1000), false),
        ]
        var bad = 0
        for (op, expected) in cases {
            var accepted = true
            do { try op.validate(home: home, memoryMB: m.memoryMB) } catch { accepted = false }
            let ok = accepted == expected
            if !ok { bad += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(accepted ? "accept" : "reject")  \(op.description)")
        }
        print("\(cases.count - bad)/\(cases.count) allow-list checks behave as expected")
    }

    /// Exercises apply, verify, auto-restore and revert against the private domain com.keel.enginetest.
    static func engineTest() async {
        let dom = "com.keel.enginetest"
        for k in ["flag", "name", "count", "sticky"] { Prefs.delete(dom, k) }
        Prefs.write(dom, "name", "Alpha", type: .string)
        var pass = 0, fail = 0
        func check(_ label: String, _ ok: Bool, _ extra: String = "") { print("\(ok ? "PASS" : "FAIL")  \(label)\(extra.isEmpty ? "" : "  (\(extra))")"); if ok { pass += 1 } else { fail += 1 } }

        let tFlag = Tweak(id: "enginetest-flag", name: "Engine test flag", category: .developer, summary: "", explanation: "", risk: .safe, recommended: false,
                          mechanism: .defaults([DefaultsSetting(domain: dom, key: "flag", type: .bool, on: "true", off: nil)], post: .none))
        let tName = Tweak(id: "enginetest-name", name: "Engine test name", category: .developer, summary: "", explanation: "", risk: .safe, recommended: false,
                          mechanism: .defaults([DefaultsSetting(domain: dom, key: "name", type: .string, on: "Beta", off: nil),
                                                DefaultsSetting(domain: dom, key: "count", type: .int, on: "7", off: nil)], post: .none))
        // Detection never reads back ON, so this one must be auto-restored.
        let tBad = Tweak(id: "enginetest-bad", name: "Engine test bad", category: .developer, summary: "", explanation: "", risk: .safe, recommended: false,
                         mechanism: .custom(CustomMechanism(
                            detect: { Detection(state: .off, values: [("sticky", Prefs.string(dom, "sticky") ?? "(not set)")]) },
                            apply: { _ in Prefs.write(dom, "sticky", "1", type: .int); return ["previous": Prefs.string(dom, "sticky") ?? ""] },
                            revert: { _, _ in Prefs.delete(dom, "sticky") },
                            applyCommands: ["defaults write \(dom) sticky 1"], revertCommands: ["defaults delete \(dom) sticky"], needsAdmin: false)))

        let t0 = Date()
        let out = await TweakEngine.apply([tFlag, tName, tBad])
        let dt = Date().timeIntervalSince(t0)
        check("batch of 3 returns 3 outcomes", out.count == 3, String(format: "%.2f s", dt))
        check("flag applied and verified", out["enginetest-flag"]?.isSuccess == true && Prefs.string(dom, "flag") == "1")
        check("name+count applied", Prefs.string(dom, "name") == "Beta" && Prefs.string(dom, "count") == "7")
        if case .failed = out["enginetest-bad"] { check("unverifiable tweak reported as failed", true) } else { check("unverifiable tweak reported as failed", false) }
        check("unverifiable tweak auto-restored", Prefs.string(dom, "sticky") == nil)
        check("originals recorded", BackupStore.latest(for: "enginetest-flag") != nil && BackupStore.latest(for: "enginetest-name") != nil)
        check("no record kept for the failed tweak", BackupStore.latest(for: "enginetest-bad") == nil)
        let again = await TweakEngine.apply([tFlag])
        if case .skipped = again["enginetest-flag"] { check("re-apply of an ON tweak is skipped", true) } else { check("re-apply of an ON tweak is skipped", false) }

        let back = await TweakEngine.revert([tFlag, tName])
        check("revert batch succeeded", back.values.allSatisfy(\.isSuccess))
        check("flag deleted (it did not exist before)", Prefs.string(dom, "flag") == nil)
        check("name restored to Alpha with its type", Prefs.string(dom, "name") == "Alpha" && Prefs.value(dom, "name") is String)
        check("count deleted (it did not exist before)", Prefs.string(dom, "count") == nil)
        check("records removed after revert", BackupStore.latest(for: "enginetest-flag") == nil && BackupStore.latest(for: "enginetest-name") == nil)

        let none = await TweakEngine.revert([tFlag])
        check("revert without a record falls back to the documented default", none["enginetest-flag"]?.isSuccess == true && Prefs.string(dom, "flag") == nil)

        for k in ["flag", "name", "count", "sticky"] { Prefs.delete(dom, k) }
        try? FileManager.default.removeItem(atPath: "\(NSHomeDirectory())/Library/Preferences/\(dom).plist")
        print("engine test: \(pass) passed, \(fail) failed")
    }

    static func permissions() {
        let home = NSHomeDirectory()
        print("Full Disk Access: \(Permissions.hasFullDiskAccess)")
        for p in ["Library/Application Support/Google/Chrome/Local State", "Library/Application Support/Microsoft Edge/Local State",
                  "Library/Application Support/BraveSoftware/Brave-Browser/Local State", "Library/Group Containers/group.com.docker/settings-store.json",
                  "Library/Application Support/Code/User/settings.json", "Library/Containers/com.utmapp.UTM/Data"] {
            print("\(Permissions.isProtected(home + "/" + p) ? "protected" : "readable ")  ~/\(p)")
        }
    }

    static func detect() async {
        let store = TweakStore.shared
        let start = Date()
        await store.detectAll()
        print(store.table())
        let items = store.items
        let on = items.filter { $0.state == .on }.count
        let na = items.filter { $0.state == .notApplicable }.count
        print("\n\(items.count) tweaks: \(on) on, \(na) not applicable on this Mac; detection took \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    }

    static func cleanupScan() async {
        let m = CleanupModel.shared
        await m.scan()
        for i in m.items {
            let size = i.sizeBytes?.humanBytes ?? "—"
            print("\(i.deletable ? "D" : "L") \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(i.name)  [\(i.group.rawValue)]")
            for c in i.children { print("     \((c.sizeBytes?.humanBytes ?? "—").padding(toLength: 10, withPad: " ", startingAt: 0))  - \(c.name)\(c.defaultOn ? "  (selected)" : "")") }
        }
        let total = m.items.filter(\.deletable).reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        print("Deletable total: \(total.humanBytes); selected by default: \(m.selectedBytes.humanBytes)")
    }

    static func screenshots() async {
        let dir = arg(after: "--screenshots") ?? "screenshots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        _ = await Machine.profile()
        await SystemInfo.shared.refresh()
        await TweakStore.shared.detectAll()
        await CleanupModel.shared.scan()
        for p in Page.allCases {
            let view = MainView(page: p, selectedTweak: nil).frame(width: 1280, height: 820).preferredColorScheme(.dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                let path = "\(dir)/\(p.rawValue.lowercased()).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
        }
    }

    static func benchmark() async {
        let label = arg(after: "--benchmark") ?? "CLI run"
        let runner = BenchmarkRunner.shared
        await runner.run(label: label)
        guard let run = runner.runs.first else { print("no run saved"); return }
        print("Run “\(run.label)” \(run.date.formatted()) afterReboot=\(run.afterReboot) minutesSinceBoot=\(run.minutesSinceBoot) onAC=\(run.onAC) powermode=\(run.powerMode)")
        for r in run.results { print("\(r.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(f1(r.value)) \(r.unit)  \(r.detail)") }
    }

    /// Applies then restores the given tweak IDs (default: two safe user-level ones).
    static func selfTest() async {
        let store = TweakStore.shared
        await store.detectAll()
        let ids = (arg(after: "--selftest")?.split(separator: ",").map(String.init)) ?? ["dock-show-recents-off", "finder-no-ds-store-network"]
        var pass = 0, fail = 0
        for id in ids {
            guard let item = store.item(id) else { print("[\(id)] missing"); fail += 1; continue }
            let before = item.state
            print("[\(id)] before: \(before.rawValue)")
            if before == .notApplicable { print("[\(id)] skipped: \(item.detection?.note ?? "")"); continue }
            let t0 = Date()
            if before == .on { await store.revert(item.tweak) } else { await store.apply(item.tweak) }
            let mid = item.state
            let ok1 = before == .on ? mid != .on : mid == .on
            print("[\(id)] after \(before == .on ? "revert" : "apply"): \(mid.rawValue) \(ok1 ? "PASS" : "FAIL") (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)\(item.message.map { " — \($0)" } ?? "")")
            let t1 = Date()
            if before == .on { await store.apply(item.tweak) } else { await store.revert(item.tweak) }
            let after = item.state
            let ok2 = after == before
            print("[\(id)] back to original: \(after.rawValue) \(ok2 ? "PASS" : "FAIL") (\(String(format: "%.1f", Date().timeIntervalSince(t1))) s)")
            if ok1 && ok2 { pass += 1 } else { fail += 1 }
        }
        print("selftest: \(pass) passed, \(fail) failed")
    }
}

// MARK: - Catalog lint and hardware simulation

extension CLI {
    static let bannedWords = ["seamless", "supercharge", "unlock", "boost your", "game-changer", "game changer", "leverage", "delve",
                              "elevate", "effortless", "blazing", "ultimate", "revolutionary", "harness", "empower", "in today's",
                              "it's worth noting", "cutting-edge", "next-level", "turbocharge", "unleash", "magic", "lightning-fast", "a breeze"]

    /// Checks catalog copy and detection speed. Exit code 1 on errors.
    /// `--move-check`: how Keel sees its own location (used to test the move to Applications).
    static func moveCheck() async {
        await MainActor.run {
            let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let source = AppMover.originalURL(of: running)
            print("running      \(running.path)")
            print("original     \(source.path)\(source == running ? "" : "  (translocated)")")
            print("origin       \(AppMover.origin(of: source))")
            print("in Apps      \(AppMover.isInApplications(source))")
            print("dev build    \(AppMover.isDevelopmentBuild(source))")
            print("would offer  \(!AppMover.isInApplications(source) && !AppMover.isDevelopmentBuild(source))")
        }
    }

    /// `--catalog-json`: the tweak catalog as JSON, used to build the website's tweak table.
    static func catalogJSON() async {
        let m = await Machine.profile()
        let rows: [[String: Any]] = TweakCatalog.all.map { t in
            var r: [String: Any] = [
                "id": t.id, "name": t.name, "category": t.category.rawValue, "summary": t.summary,
                "benefit": t.expectedBenefit, "tradeoff": t.tradeoff,
                "risk": t.risk.rawValue, "impact": t.impact.rawValue.replacingOccurrences(of: " IMPACT", with: ""),
                "recommended": t.recommended, "gem": t.isHiddenGem, "admin": t.needsAdmin,
                "manual": t.isManual, "oneShot": t.oneShot,
                "audience": t.audiences.map(\.rawValue).sorted(),
                "commands": t.isManual ? [] : t.applyCommands(m)
            ]
            if let p = t.postAction.processName { r["restarts"] = p }
            return r
        }
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data)
    }

    static func lint() async -> Int32 {
        let store = TweakStore.shared
        var errors: [String] = [], warnings: [String] = []
        var seen = Set<String>()
        for t in TweakCatalog.all {
            func e(_ m: String) { errors.append("\(t.id): \(m)") }
            func w(_ m: String) { warnings.append("\(t.id): \(m)") }
            if !seen.insert(t.id).inserted { e("duplicate id") }
            if t.name.isEmpty || t.summary.isEmpty || t.explanation.isEmpty { e("missing name/summary/explanation") }
            if t.summary.count > 120 { w("summary is \(t.summary.count) chars (keep ≤ 120)") }
            if t.expectedBenefit.isEmpty { e("missing expectedBenefit") }
            if t.tradeoff.isEmpty { e("missing tradeoff") }
            if t.sources.isEmpty { w("no sources") }
            if t.recommended && t.risk == .medium { e("recommended but MEDIUM risk") }
            if t.recommended && t.impact == .cosmetic { w("recommended but cosmetic") }
            if !t.isManual && t.applyCommands(Machine.current).isEmpty { e("no apply commands") }
            let text = (t.name + " " + t.summary + " " + t.explanation + " " + t.expectedBenefit + " " + t.tradeoff).lowercased().replacingOccurrences(of: "auto unlock", with: "")
            for b in bannedWords where text.contains(b) { e("uses \"\(b)\"") }
            let dashes = text.components(separatedBy: "—").count - 1
            if dashes > 2 { w("\(dashes) em dashes") }
            if text.contains("!") { w("exclamation mark") }
        }
        // A recorded original without a tweak could never be restored.
        for id in Set(BackupStore.all().map(\.tweakID)) where store.item(id) == nil && !id.hasPrefix("enginetest") {
            errors.append("backup record for \(id) has no tweak (cannot be restored)")
        }
        await ProbeCache.shared.invalidate()
        for t in TweakCatalog.all {
            let t0 = Date()
            _ = await TweakEngine.detect(t)
            let dt = Date().timeIntervalSince(t0)
            if dt > 1.5 { warnings.append("\(t.id): detection took \(String(format: "%.2f", dt)) s") }
        }
        for x in errors { print("ERROR  \(x)") }
        for x in warnings { print("warn   \(x)") }
        let cats = Dictionary(grouping: TweakCatalog.all, by: \.category).map { "\($0.key.rawValue) \($0.value.count)" }.sorted()
        print("\(TweakCatalog.all.count) tweaks (\(cats.joined(separator: ", "))); \(TweakCatalog.hiddenGems.count) hidden gems; \(errors.count) errors, \(warnings.count) warnings")
        return errors.isEmpty ? 0 : 1
    }

    /// Runs detection under simulated hardware profiles. Live reads still come from this Mac, so this
    /// checks applicability and crash-safety only.
    static func simulate() async {
        let real = await Machine.profile()
        func profile(_ f: (inout MachineProfile) -> Void) -> MachineProfile { var p = real; f(&p); return p }
        let profiles: [(String, MachineProfile)] = [
            ("Mac mini M1, 8 GB, macOS 15, Ethernet, no Xcode/Homebrew", profile {
                $0.modelName = "Mac mini (M1, 2020)"; $0.chip = "Apple M1"; $0.perfCores = 4; $0.effCores = 4; $0.totalCores = 8; $0.memoryBytes = 8 << 30
                $0.metalWorkingSetBytes = UInt64(Double(8 << 30) * 0.67); $0.hasBattery = false; $0.powerSources = ["AC Power"]
                $0.pmsetCapabilities = ["displaysleep", "disksleep", "sleep", "womp", "autorestart", "powernap", "ttyskeepawake", "tcpkeepalive"]
                $0.osMajor = 15; $0.osMinor = 5; $0.wifiDevice = "en1"; $0.wifiService = "Wi-Fi"; $0.primaryDevice = "en0"; $0.primaryService = "Ethernet"
                $0.mainDisplayMaxRefresh = 60; $0.hasXcode = false; $0.hasCommandLineTools = false; $0.brewPrefix = nil }),
            ("MacBook Air M2, 16 GB, macOS 26, no Xcode", profile {
                $0.modelName = "MacBook Air (M2, 2022)"; $0.chip = "Apple M2"; $0.perfCores = 4; $0.effCores = 4; $0.totalCores = 8; $0.memoryBytes = 16 << 30
                $0.metalWorkingSetBytes = UInt64(Double(16 << 30) * 0.74); $0.hasBattery = true; $0.powerSources = ["Battery Power", "AC Power"]
                $0.pmsetCapabilities.remove("highpowermode"); $0.osMajor = 26; $0.osMinor = 4; $0.mainDisplayMaxRefresh = 60; $0.hasXcode = false }),
            ("Mac Studio M3 Ultra, 256 GB, macOS 26, Xcode", profile {
                $0.modelName = "Mac Studio (2025)"; $0.chip = "Apple M3 Ultra"; $0.perfCores = 24; $0.effCores = 8; $0.totalCores = 32; $0.memoryBytes = 256 << 30
                $0.metalWorkingSetBytes = UInt64(Double(256 << 30) * 0.75); $0.hasBattery = false; $0.powerSources = ["AC Power"]
                $0.pmsetCapabilities = ["displaysleep", "disksleep", "sleep", "womp", "autorestart", "powernap", "highpowermode", "lowpowermode"]
                $0.osMajor = 26; $0.osMinor = 2; $0.primaryDevice = "en0"; $0.primaryService = "Ethernet"; $0.wifiDevice = "en1" }),
            ("This Mac", real),
        ]
        for (name, p) in profiles {
            Machine.override(p)
            await ProbeCache.shared.invalidate()
            let t0 = Date()
            var counts: [TweakState: Int] = [:]
            var naReasons: [String: Int] = [:]
            for t in TweakCatalog.all {
                let d = await TweakEngine.detect(t)
                counts[d.state, default: 0] += 1
                if d.state == .notApplicable { naReasons[d.note ?? "?", default: 0] += 1 }
                // Hardware-scoped tweaks must not claim a state on hardware that lacks the feature.
                if !p.hasBattery, t.requires.contains(where: { if case .laptop = $0 { return true }; return false }), d.state != .notApplicable {
                    print("  FAIL \(t.id): laptop-only but \(d.state.rawValue) on a desktop")
                }
            }
            let summary = [TweakState.on, .off, .partlyOn, .notApplicable, .unknown].map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: " · ")
            print("\(name): \(summary) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
            for (r, n) in naReasons.sorted(by: { $0.value > $1.value }).prefix(6) { print("    N/A ×\(n): \(r)") }
        }
        Machine.override(real)
    }
}

// MARK: - Live round-trip tests

extension CLI {
    /// Applies every OFF `.defaults` tweak, restores them, and compares each key's raw value with the original.
    static func selfTestDefaults() async {
        let store = TweakStore.shared
        await store.detectAll()
        let skip = Set((arg(after: "--selftest-defaults") ?? "").split(separator: ",").map(String.init))
        let candidates = store.items.filter { item in
            if case .defaults = item.tweak.mechanism { return item.state == .off && !skip.contains(item.id) }
            return false
        }.map(\.tweak)
        func snapshot() -> [String: String] {
            var s: [String: String] = [:]
            for t in candidates { if case .defaults(let settings, _) = t.mechanism {
                for d in settings { s["\(d.currentHost ? "host:" : "")\(d.domain) \(d.key)"] = Prefs.value(d.domain, d.key, currentHost: d.currentHost).map { "\(Prefs.type(of: $0).rawValue):\(Prefs.render($0))" } ?? "(absent)" }
            } }
            return s
        }
        let before = snapshot()
        print("Testing \(candidates.count) preference tweaks: \(candidates.map(\.id).joined(separator: ", "))")
        let t0 = Date()
        let applied = await TweakEngine.apply(candidates)
        let t1 = Date()
        var pass = 0, fail = 0
        for t in candidates {
            switch applied[t.id] {
            case .done: pass += 1
            case .failed(let why): fail += 1; print("FAIL apply \(t.id): \(why)")
            case .skipped(let why): print("skip \(t.id): \(why)")
            case .none: fail += 1; print("FAIL apply \(t.id): no outcome")
            }
        }
        print(String(format: "apply: %d on, %d failed in %.1f s", pass, fail, t1.timeIntervalSince(t0)))
        let reverted = await TweakEngine.revert(candidates)
        let t2 = Date()
        let after = snapshot()
        var exact = 0, diff = 0
        for (k, v) in before.sorted(by: { $0.key < $1.key }) {
            if after[k] == v { exact += 1 } else { diff += 1; print("DIFF \(k): before \(v), after \(after[k] ?? "?")") }
        }
        let rf = reverted.values.filter { if case .failed = $0 { return true }; return false }.count
        print(String(format: "restore: %d failed in %.1f s; %d/%d keys byte-identical to the original", rf, t2.timeIntervalSince(t1), exact, exact + diff))
        print(diff == 0 && fail == 0 && rf == 0 ? "selftest-defaults: PASS" : "selftest-defaults: FAIL")
    }
}

extension CLI {
    /// Round trip for user-level custom tweaks; compares checksums of the files they touch.
    static func selfTestCustom() async {
        let store = TweakStore.shared
        await store.detectAll()
        let skip = Set((arg(after: "--selftest-custom") ?? "").split(separator: ",").map(String.init))
        let candidates = store.items.filter { i in
            if case .custom = i.tweak.mechanism { return i.state == .off && !i.tweak.needsAdmin && !i.tweak.oneShot && !skip.contains(i.id) }
            return false
        }.map(\.tweak)
        let home = NSHomeDirectory()
        let files = ["\(home)/.gitconfig", "\(home)/.ssh/config", "\(home)/.homebrew/services/ollama.env", "\(home)/.ollama/server.json",
                     "\(home)/Library/Group Containers/group.com.docker/settings-store.json", "\(home)/Library/LaunchAgents/com.keel.ollama-env.plist"]
        func sums() -> [String: String] {
            var d: [String: String] = [:]
            for f in files { d[f] = FileManager.default.contents(atPath: f).map { "\($0.count)B:\($0.hashValue)" } ?? "(absent)" }
            return d
        }
        let before = sums()
        print("Testing \(candidates.count) custom tweaks: \(candidates.map(\.id).joined(separator: ", "))")
        let applied = await TweakEngine.apply(candidates)
        var fail = 0
        for t in candidates {
            if case .done = applied[t.id] { continue }
            if case .skipped(let why) = applied[t.id] { print("skip \(t.id): \(why)"); continue }
            fail += 1; print("FAIL apply \(t.id): \(String(describing: applied[t.id]))")
        }
        _ = await TweakEngine.revert(candidates)
        await ProbeCache.shared.invalidate()
        var stateDiff = 0
        for t in candidates {
            let d = await TweakEngine.detect(t)
            if d.state != .off { stateDiff += 1; print("STATE \(t.id): \(d.state.rawValue) after restore") }
        }
        let after = sums()
        var fileDiff = 0
        for f in files where before[f] != after[f] { fileDiff += 1; print("FILE \(f): before \(before[f]!), after \(after[f]!)") }
        print("selftest-custom: \(candidates.count - fail) applied, \(fail) failed; \(stateDiff) not OFF after restore; \(fileDiff) files differ → \(fail + stateDiff + fileDiff == 0 ? "PASS" : "FAIL")")
    }
}

extension CLI {
    /// Round trip for user-domain launchd tweaks: plist bytes, loaded state and disabled flag must match.
    static func selfTestLaunchd() async {
        let store = TweakStore.shared
        await store.detectAll()
        let candidates: [(Tweak, [LaunchdItem])] = store.items.compactMap { i in
            guard case .launchd(let items) = i.tweak.mechanism, i.state == .off, items.allSatisfy({ $0.domain == .user }) else { return nil }
            return (i.tweak, items)
        }
        func snapshot() async -> [String: String] {
            await ProbeCache.shared.invalidate()
            var s: [String: String] = [:]
            for (_, items) in candidates { for it in items {
                let data = FileManager.default.contents(atPath: it.plistPath)
                s[it.label] = "\(data.map { "\($0.count)B:\($0.hashValue)" } ?? "absent") loaded=\(await Launchd.isLoaded(it)) disabled=\(await Launchd.isDisabled(it))"
            } }
            return s
        }
        let before = await snapshot()
        print("Testing \(candidates.count) launchd tweaks: \(candidates.map(\.0.id).joined(separator: ", "))")
        for (k, v) in before.sorted(by: { $0.key < $1.key }) { print("  before \(k): \(v)") }
        let applied = await TweakEngine.apply(candidates.map(\.0))
        for (t, _) in candidates { print("  apply \(t.id): \(applied[t.id].map { "\($0)" } ?? "none")") }
        let mid = await snapshot()
        for (k, v) in mid.sorted(by: { $0.key < $1.key }) { print("  while on \(k): \(v)") }
        _ = await TweakEngine.revert(candidates.map(\.0))
        let after = await snapshot()
        var diff = 0
        for (k, v) in before where after[k] != v { diff += 1; print("  DIFF \(k): before \(v) after \(after[k] ?? "?")") }
        print("selftest-launchd: \(diff == 0 ? "PASS" : "FAIL") (\(before.count) items compared)")
    }
}

extension CLI {
    /// Registers the helper, waits for approval if needed, makes one no-op XPC call, then unregisters
    /// unless --keep is passed.
    static func helperTest() async {
        let hm = HelperManager.shared
        func name(_ s: SMAppService.Status) -> String {
            switch s { case .notRegistered: return "not registered"; case .enabled: return "enabled"; case .requiresApproval: return "waiting for your approval"; case .notFound: return "not found"; @unknown default: return "unknown" }
        }
        guard let team = HelperManager.teamIdentifier else { print("This build is not signed with a Developer ID, so the helper cannot be installed. Build with KEEL_SIGN_IDENTITY set."); return }
        guard hm.bundleHasDaemon else { print("The helper's launchd plist is missing from the app bundle."); return }
        print("Signed by team \(team). App: \(Bundle.main.bundlePath)")
        let svc = hm.service
        print("Helper status: \(name(svc.status))")
        if svc.status != .enabled {
            // Throws "Operation not permitted" when approval is needed; the status then reads requiresApproval.
            try? svc.register()
            print("Helper status after registering: \(name(svc.status))")
        }
        if svc.status == .requiresApproval {
            print("""

            macOS needs your approval once:
              System Settings › General › Login Items & Extensions › "Allow in the Background" › turn on Keel.
            Opening that pane now. Waiting up to 3 minutes…
            """)
            SMAppService.openSystemSettingsLoginItems()
            for _ in 0..<90 where svc.status != .enabled { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            print("Helper status: \(name(svc.status))")
        }
        guard svc.status == .enabled else { print("\nThe helper is not enabled yet. Turn on Keel in Login Items & Extensions, then run this command again."); return }
        let current = await Pmset.current()
        let source = current["Battery Power"] != nil ? "Battery Power" : "AC Power"
        let value = current[source]?["lessbright"] ?? current[source]?["displaysleep"] ?? "0"
        let key = current[source]?["lessbright"] != nil ? "lessbright" : "displaysleep"
        do {
            let r = try await Privileged.run([.pmset(scope: source == "Battery Power" ? "-b" : "-c", key: key, value: value)], reason: "helper test", helperOnly: true)
            let ok = r.first?.ok == true
            print(ok ? "\nPASS: the helper ran a privileged command over XPC (pmset \(key) \(value), the value it already had). No password was needed."
                     : "\nFAIL: the helper answered but the command failed: \(r.first?.output ?? "")")
        } catch { print("\nFAIL: \(error.localizedDescription)") }
        if !CommandLine.arguments.contains("--keep") {
            do { try await svc.unregister(); print("Helper removed again (run with --keep to leave it installed).") } catch { print("unregister(): \(error.localizedDescription)") }
        }
    }
}

extension CLI {
    /// Runs Cleanup's delete paths against the fake home in KEEL_CLEANUP_TEST_HOME.
    static func cleanupSelfTest() async -> Int32 { await CleanupSelfTest.run() ? 0 : 1 }
}
