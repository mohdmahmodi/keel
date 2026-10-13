import Foundation
import AppKit
import Darwin
import KeelShared

extension TweakCatalog {
    static let memory: [Tweak] = [
        Tweak(id: "simulators-shutdown", name: "Shut down background iOS simulators", category: .memory,
              summary: "Simulators left running after you quit Simulator or Xcode are shut down, and their memory is freed.",
              explanation: """
              iPhone, iPad and other simulators that keep running in the background after you close Simulator or Xcode \
              are shut down. Each booted device runs its own launchd and dozens of system processes, and quitting \
              Simulator.app does not stop them; Xcode Previews boot further devices in a separate device set. Keel shows \
              the memory these processes hold, runs `xcrun simctl shutdown all` (and the same for the Previews set while \
              Xcode is closed), and boots the same regular devices again if you turn this off. It refuses to run while \
              Simulator.app is open, so quit Simulator first.
              """,
              risk: .safe, impact: .high, recommended: true,
              mechanism: .custom(simulatorsMechanism()),
              sources: ["xcrun simctl help shutdown", "Local check: xcrun simctl --set previews list devices, Xcode 27.0 on macOS 27.0.1"],
              requires: [.xcode], confidence: .high,
              expectedBenefit: "The memory held by forgotten simulators, shown in the details, becomes available to other apps.",
              tradeoff: "The next simulator or preview launch is a cold boot and takes a few seconds longer.", audience: [.developer]),

        Tweak(id: "memory-pressure-check", name: "Memory pressure is normal", category: .memory,
              summary: "Checks whether the Mac is actually short of memory. A high \"memory used\" figure on its own is normal.",
              explanation: """
              Keel reports whether the Mac is actually short of memory, using the same measure as the Memory Pressure \
              graph in Activity Monitor. macOS fills unused memory with file cache and compressed pages on purpose, so \
              "memory used" is always high; the kernel's pressure level (normal, warning or critical) is the meaningful \
              signal. RAM cleaners and `purge` discard cache that macOS would reclaim anyway and do not lower pressure. \
              Keel always lists the three apps holding the most memory, and changes nothing.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: { await memoryPressureDetection() },
                settingsURL: "file:///System/Applications/Utilities/Activity%20Monitor.app",
                instructions: "Activity Monitor > Memory: check the Memory Pressure graph and quit the largest apps if it is yellow or red.")),
              sources: ["https://support.apple.com/guide/activity-monitor/check-if-your-mac-needs-more-ram-actmntr34865/mac",
                        "https://eclecticlight.co/2015/05/22/qa-pointless-purges/"],
              confidence: .high,
              expectedBenefit: "You see whether memory is really what slows the Mac down, and which apps use the most.",
              tradeoff: "Nothing. Keel only reads the current state.", audience: [.everyone]),
    ] + chromiumBrowsers.flatMap { browserTweaks($0) }
}

// MARK: - Private helpers

private extension TweakCatalog {
    // MARK: Simulators

    struct BootedSimulator: Sendable { let udid: String; let name: String; let runtime: String }

    /// Booted devices in the default set, or in Xcode Previews' own set (`simctl --set previews`).
    static func bootedSimulators(previews: Bool = false, fresh: Bool = false) async -> [BootedSimulator]? {
        let args = (previews ? ["simctl", "--set", "previews"] : ["simctl"]) + ["list", "devices", "booted", "-j"]
        let r: ShellResult? = fresh ? try? await Shell.run("/usr/bin/xcrun", args, timeout: 30) : await Shell.probe("/usr/bin/xcrun", args)
        guard let r, r.ok, let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devs = obj["devices"] as? [String: [[String: Any]]] else { return nil }
        var out: [BootedSimulator] = []
        for (runtime, list) in devs {
            // "com.apple.CoreSimulator.SimRuntime.iOS-26-0" → "iOS 26.0"
            let short = runtime.components(separatedBy: "SimRuntime.").last.map {
                let p = $0.split(separator: "-"); return p.count > 1 ? "\(p[0]) \(p.dropFirst().joined(separator: "."))" : String($0)
            } ?? runtime
            for d in list where (d["state"] as? String ?? "Booted") == "Booted" {
                if let u = d["udid"] as? String { out.append(BootedSimulator(udid: u, name: d["name"] as? String ?? u, runtime: short)) }
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Resident memory of processes, grouped by app bundle (or executable name), largest first.
    static func residentByApp() async -> [(name: String, kb: Int, path: String)] {
        guard let r = await Shell.probe("/bin/ps", ["-axm", "-o", "rss=,comm="]) else { return [] }
        var groups: [String: (Int, String)] = [:]
        for line in r.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let kb = Int(t[..<sp]) else { continue }
            let path = t[sp...].trimmingCharacters(in: .whitespaces)
            var name = (path as NSString).lastPathComponent
            if let rg = path.range(of: ".app/") {
                name = ((String(path[..<rg.lowerBound]) as NSString).lastPathComponent)
            }
            if path.contains("/RuntimeRoot/") || path.hasSuffix("launchd_sim") { name = "iOS simulators" }
            let cur = groups[name] ?? (0, path)
            groups[name] = (cur.0 + kb, cur.1)
        }
        return groups.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.kb > $1.kb }
    }

    static func simulatorResidentKB() async -> Int {
        guard let r = await Shell.probe("/bin/ps", ["-axm", "-o", "rss=,comm="]) else { return 0 }
        var total = 0
        for line in r.stdout.split(separator: "\n") where line.contains("/RuntimeRoot/") || line.hasSuffix("launchd_sim") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let sp = t.firstIndex(of: " "), let kb = Int(t[..<sp]) { total += kb }
        }
        return total
    }

    static func gbString(kb: Int) -> String { String(format: "%.1f GB", Double(kb) / 1_048_576) }

    static func simulatorAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.iphonesimulator" }
    }

    static func xcodeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.dt.Xcode" }
    }

    static func simulatorsMechanism() -> CustomMechanism {
        CustomMechanism(
            detect: {
                guard let booted = await bootedSimulators() else { return Detection(state: .unknown, values: [("simctl", "did not respond")]) }
                // Preview devices are in use while Xcode is open; only count them once Xcode has quit.
                let previews = await bootedSimulators(previews: true) ?? []
                let xcodeOpen = xcodeRunning()
                var values = booted.map { ("booted", "\($0.name) (\($0.runtime))") }
                values += previews.map { ("booted for Xcode Previews", "\($0.name) (\($0.runtime))") }
                if values.isEmpty { return Detection(state: .on, values: [("booted devices", "none")]) }
                let kb = await simulatorResidentKB()
                if kb > 0 { values.append(("simulator processes hold (resident)", gbString(kb: kb))) }
                let open = simulatorAppRunning()
                values.append(("Simulator.app", open ? "open" : "not running"))
                if !previews.isEmpty { values.append(("Xcode", xcodeOpen ? "open (previews left alone)" : "not running")) }
                let idle = !booted.isEmpty || (!previews.isEmpty && !xcodeOpen)
                return Detection(state: idle ? .off : .on, values: values,
                                 note: open && !booted.isEmpty ? "Simulator is open; quit it first if you are done with these devices." : nil)
            },
            apply: { _ in
                let booted = await bootedSimulators(fresh: true) ?? []
                if !booted.isEmpty {
                    if simulatorAppRunning() { throw TweakEngine.EngineError(message: "Simulator is open. Quit it first (Keel only shuts down devices left running in the background).") }
                    let r = try await Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"], timeout: 180)
                    ActivityLog.post(.command, "xcrun simctl shutdown all", detail: r.combined.isEmpty ? nil : r.combined)
                    guard r.ok else { throw TweakEngine.EngineError(message: "simctl shutdown failed: \(r.combined)") }
                }
                if !xcodeRunning(), !(await bootedSimulators(previews: true, fresh: true) ?? []).isEmpty {
                    let r = try await Shell.run("/usr/bin/xcrun", ["simctl", "--set", "previews", "shutdown", "all"], timeout: 180)
                    ActivityLog.post(.command, "xcrun simctl --set previews shutdown all", detail: r.combined.isEmpty ? nil : r.combined)
                    guard r.ok else { throw TweakEngine.EngineError(message: "simctl shutdown (previews) failed: \(r.combined)") }
                }
                // Preview devices are re-created by Xcode on demand, so only regular devices are recorded for revert.
                return ["udids": booted.map(\.udid).joined(separator: ",")]
            },
            revert: { _, orig in
                for u in (orig["udids"] ?? "").split(separator: ",") where !u.isEmpty {
                    let r = try? await Shell.run("/usr/bin/xcrun", ["simctl", "boot", String(u)], timeout: 120)
                    ActivityLog.post(.command, "xcrun simctl boot \(u)", detail: r?.combined)
                }
            },
            applyCommands: ["xcrun simctl shutdown all   # only while Simulator.app is closed",
                            "xcrun simctl --set previews shutdown all   # only while Xcode is closed"],
            revertCommands: ["xcrun simctl boot <each recorded UDID>"],
            needsAdmin: false)
    }

    // MARK: Memory pressure

    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return nil }
        return (xsw.xsu_used, xsw.xsu_total)
    }

    static func compressedBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(stats.compressor_page_count) * UInt64(vm_kernel_page_size)
    }

    static func memoryPressureDetection() async -> Detection {
        guard let level = Sysctl.int("kern.memorystatus_vm_pressure_level") else { return .unknown }
        let name: String
        switch level {
        case 1: name = "normal"
        case 2: name = "warning"
        case 4: name = "critical"
        default: name = "level \(level)"
        }
        var values: [(String, String)] = [("memory pressure", name)]
        if let free = Sysctl.int("kern.memorystatus_level") { values.append(("available to apps (kernel estimate)", "\(free) %")) }
        let m = await Machine.profile()
        if m.memoryGB > 0 { values.append(("installed memory", "\(m.memoryGB) GB")) }
        if let c = compressedBytes() { values.append(("compressed", c.humanBytes)) }
        if let s = swapUsage() { values.append(("swap used", s.used.humanBytes)) }
        let top = await residentByApp().prefix(3)
        for t in top { values.append(("largest: \(t.name)", gbString(kb: t.kb))) }
        let normal = level == 1
        return Detection(state: normal ? .on : .off, values: values,
                         note: normal ? nil : "Memory is under pressure. Quit or restart the largest apps listed; RAM cleaners will not help.")
    }

    // MARK: Chromium-family browsers

    struct ChromiumBrowser: Sendable {
        let idPrefix: String       // "chrome" keeps the original tweak IDs
        let name: String
        let bundleID: String
        let processName: String
        let localState: String
        let settingsScheme: String
        /// Whether the browser exposes Chromium's Memory Saver / Energy Saver toggles (verified per browser).
        let hasSavers: Bool
    }

    /// Only browsers whose Local State location, bundle ID and settings were confirmed.
    /// Edge (own Efficiency mode / Sleeping tabs), Arc and Vivaldi use their own tab-sleeping prefs and are not included.
    static let chromiumBrowsers: [ChromiumBrowser] = [
        ChromiumBrowser(idPrefix: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome", processName: "Google Chrome",
                        localState: "\(TweakHelpers.home)/Library/Application Support/Google/Chrome/Local State", settingsScheme: "chrome", hasSavers: true),
        ChromiumBrowser(idPrefix: "brave", name: "Brave", bundleID: "com.brave.Browser", processName: "Brave Browser",
                        localState: "\(TweakHelpers.home)/Library/Application Support/BraveSoftware/Brave-Browser/Local State", settingsScheme: "brave", hasSavers: true),
        ChromiumBrowser(idPrefix: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium", processName: "Chromium",
                        localState: "\(TweakHelpers.home)/Library/Application Support/Chromium/Local State", settingsScheme: "chrome", hasSavers: true),
    ]

    static let memorySaverState = "performance_tuning.high_efficiency_mode.state"
    static let memorySaverLevel = "performance_tuning.high_efficiency_mode.aggressiveness"
    static let energySaverState = "performance_tuning.battery_saver_mode.state"
    static let hwAccel = "hardware_acceleration_mode.enabled"

    static func browserRunning(_ b: ChromiumBrowser) async -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == b.bundleID }) { return true }
        return await TweakHelpers.isProcessRunning(b.processName)
    }

    static func browserRequirements(_ b: ChromiumBrowser) -> [Requirement] {
        [.app(bundleID: b.bundleID, name: b.name),
         .custom({ FileManager.default.fileExists(atPath: b.localState) ? nil : "\(b.name) has not been opened yet (no Local State file)" })]
    }

    /// macOS can protect a browser's data folder from other apps (com.apple.macl); then Keel cannot read or edit it.
    static func unreadable(_ b: ChromiumBrowser) -> Detection {
        Detection(state: .unknown, values: [("Local State", "(protected: needs Full Disk Access)")],
                  note: "macOS protects other apps' data. Give Keel Full Disk Access (System Settings > Privacy & Security > Full Disk Access), or check this in \(b.settingsScheme)://settings.")
    }

    static func intValue(_ obj: [String: Any]?, _ keyPath: String) -> Int? { (TweakHelpers.nested(obj, keyPath) as? NSNumber)?.intValue }

    static func removeNested(_ obj: inout [String: Any], _ keyPath: String) {
        let parts = keyPath.split(separator: ".").map(String.init)
        if parts.count == 1 { obj.removeValue(forKey: parts[0]); return }
        guard var child = obj[parts[0]] as? [String: Any] else { return }
        removeNested(&child, parts.dropFirst().joined(separator: "."))
        obj[parts[0]] = child
    }

    /// Applies or restores integer prefs in Local State. `values[key] == nil` removes the key.
    static func editLocalState(_ b: ChromiumBrowser, tag: String, _ values: [String: Int?]) async throws -> [String: String] {
        if await browserRunning(b) { throw TweakEngine.EngineError(message: "Quit \(b.name) first (it rewrites Local State when it quits)") }
        guard TweakHelpers.readJSON(b.localState) != nil else {
            throw TweakEngine.EngineError(message: "Could not read \(b.name)'s Local State (macOS may be protecting it). Change it in \(b.settingsScheme)://settings/performance instead.")
        }
        return try TweakHelpers.editJSON(b.localState, tag: tag) { obj in
            for (k, v) in values {
                if let v { TweakHelpers.setNested(&obj, k, v) } else { removeNested(&obj, k) }
            }
        }
    }

    /// Records the previous value of each key ("absent" when unset) so revert can restore just those keys.
    static func recordPrevious(_ b: ChromiumBrowser, _ keys: [String]) -> [String: String] {
        let obj = TweakHelpers.readJSON(b.localState)
        var rec: [String: String] = [:]
        for (i, k) in keys.enumerated() {
            rec["key.\(i)"] = k
            rec["prev.\(i)"] = intValue(obj, k).map(String.init) ?? "absent"
        }
        return rec
    }

    static func restorePrevious(_ b: ChromiumBrowser, tag: String, _ orig: [String: String]) async throws {
        // Records from older Keel versions hold a full copy of Local State.
        if orig["key.0"] == nil, orig["path"] != nil, orig["file"] != nil {
            if await browserRunning(b) { throw TweakEngine.EngineError(message: "Quit \(b.name) first") }
            try TweakHelpers.restoreFile(orig)
            return
        }
        var values: [String: Int?] = [:]
        var i = 0
        while let k = orig["key.\(i)"] {
            values.updateValue(Int(orig["prev.\(i)"] ?? "absent"), forKey: k)  // nil = was absent: remove
            i += 1
        }
        guard !values.isEmpty else { return }
        _ = try await editLocalState(b, tag: tag, values)
    }

    static func browserTweaks(_ b: ChromiumBrowser) -> [Tweak] {
        let reqs = browserRequirements(b)
        let perf = "\(b.settingsScheme)://settings/performance"
        var out: [Tweak] = []
        if b.hasSavers {
            out.append(Tweak(
                id: "\(b.idPrefix)-memory-saver", name: "\(b.name) Memory Saver", category: .memory,
                summary: "\(b.name) unloads tabs you have not used for a while and reloads them when you return. Quit \(b.name) first.",
                explanation: """
                \(b.name) unloads tabs you have not looked at for a while, so they stop holding memory; a tab reloads \
                when you click it. Chromium browsers run a separate process for each site, so many open tabs can add up \
                to several gigabytes. Keel sets \(memorySaverState) to 2 in \(b.name)'s Local State file, the same switch \
                as \(perf) > Memory Saver, and keeps your chosen level (Balanced if none is set). \(b.name) must be quit \
                because it rewrites that file when it quits; a backup is kept and turning this off restores only these keys.
                """,
                risk: .safe, impact: .medium, recommended: false,
                mechanism: .custom(CustomMechanism(
                    detect: {
                        guard let j = TweakHelpers.readJSON(b.localState) else { return unreadable(b) }
                        let st = intValue(j, memorySaverState), ag = intValue(j, memorySaverLevel)
                        let levels = [0: "0 (Moderate)", 1: "1 (Balanced)", 2: "2 (Maximum)"]
                        var d = Detection(state: st == 2 ? .on : .off,
                                          values: [("high_efficiency_mode.state", st.map { $0 == 2 ? "2 (on)" : "\($0) (off)" } ?? "(not set: browser default)"),
                                                   ("aggressiveness", ag.map { levels[$0] ?? String($0) } ?? "(not set)"),
                                                   (b.name, await browserRunning(b) ? "running" : "not running")])
                        if st == nil { d.note = "Never changed in \(b.name); its default applies. Check \(perf)." }
                        return d
                    },
                    apply: { _ in
                        let rec = recordPrevious(b, [memorySaverState, memorySaverLevel])
                        let level = intValue(TweakHelpers.readJSON(b.localState), memorySaverLevel) ?? 1
                        let backup = try await editLocalState(b, tag: "\(b.idPrefix)-memory-saver", [memorySaverState: 2, memorySaverLevel: level])
                        return rec.merging(backup) { a, _ in a }
                    },
                    revert: { _, orig in try await restorePrevious(b, tag: "\(b.idPrefix)-memory-saver-revert", orig) },
                    applyCommands: ["\(b.name) quit; Local State: \(memorySaverState) = 2, aggressiveness kept (1 = Balanced if unset)"],
                    revertCommands: ["\(b.name) quit; Local State: restore the recorded values of these keys"],
                    needsAdmin: false)),
                sources: ["https://support.google.com/chrome/answer/12929150",
                          "https://chromium.googlesource.com/chromium/src/+/main/components/performance_manager/public/user_tuning/prefs.h",
                          "Local check: pref names in the Google Chrome 155 framework binary"] + (b.idPrefix == "brave" ? ["https://support.brave.app/hc/en-us/articles/13383683902733"] : []),
                requires: reqs, confidence: .medium,
                expectedBenefit: "With many tabs open, the browser holds less memory. How much depends on how many tabs sit unused.",
                tradeoff: "Old tabs reload when you switch back to them, and unsaved text typed into them can be lost.",
                audience: [.everyone]))

            out.append(Tweak(
                id: "\(b.idPrefix)-energy-saver", name: "\(b.name) Energy Saver on battery", category: .power,
                summary: "\(b.name) limits background activity whenever the Mac is on battery, not only below 20 %. Quit \(b.name) first.",
                explanation: """
                \(b.name) cuts back on background tab activity and visual effects such as animations whenever the Mac \
                runs on battery, instead of only when the battery drops below 20 %. Keel sets \(energySaverState) to 2 in \
                \(b.name)'s Local State file, the same as choosing the unplugged option under \(perf) > Energy Saver; with \
                that option, Energy Saver does not run while the Mac is on the power adapter. \(b.name) must be quit first, \
                and turning this off restores only this key.
                """,
                risk: .safe, impact: .low, recommended: false,
                mechanism: .custom(CustomMechanism(
                    detect: {
                        guard let j = TweakHelpers.readJSON(b.localState) else { return unreadable(b) }
                        let st = intValue(j, energySaverState)
                        let names = [0: "0 (off)", 1: "1 (below 20 % battery)", 2: "2 (whenever on battery)", 3: "3 (always)"]
                        return Detection(state: st == 2 || st == 3 ? .on : .off,
                                         values: [("battery_saver_mode.state", st.map { names[$0] ?? String($0) } ?? "(not set: below 20 % battery)"),
                                                  (b.name, await browserRunning(b) ? "running" : "not running")])
                    },
                    apply: { _ in
                        let rec = recordPrevious(b, [energySaverState])
                        let backup = try await editLocalState(b, tag: "\(b.idPrefix)-energy-saver", [energySaverState: 2])
                        return rec.merging(backup) { a, _ in a }
                    },
                    revert: { _, orig in try await restorePrevious(b, tag: "\(b.idPrefix)-energy-saver-revert", orig) },
                    applyCommands: ["\(b.name) quit; Local State: \(energySaverState) = 2"],
                    revertCommands: ["\(b.name) quit; Local State: restore the recorded value"],
                    needsAdmin: false)),
                sources: ["https://support.google.com/chrome/answer/12929150",
                          "https://chromium.googlesource.com/chromium/src/+/main/components/performance_manager/user_tuning/prefs.cc"],
                requires: [.laptop] + reqs, confidence: .high,
                expectedBenefit: "The browser uses less CPU on battery, which helps battery life most with many tabs open.",
                tradeoff: "On battery, background tabs update less often and some animations and video run at a lower frame rate.",
                audience: [.laptop]))
        }

        out.append(Tweak(
            id: "\(b.idPrefix)-hw-accel-check", name: "\(b.name) hardware acceleration stays on", category: .performance,
            summary: "Checks that \(b.name) still draws pages and video with the GPU rather than the CPU.",
            explanation: """
            Keel checks that \(b.name) still uses the graphics chip to draw pages and play video. Turning "Use graphics \
            acceleration when available" off is a common troubleshooting step that moves page compositing, WebGL and \
            video decoding to the CPU, which raises CPU load, heat and battery use. Keel reads \(hwAccel) from \
            \(b.name)'s Local State file and changes nothing; if it is off, turn it on in \(b.settingsScheme)://settings/system \
            and relaunch \(b.name).
            """,
            risk: .safe, impact: .low, recommended: false,
            mechanism: .manual(ManualMechanism(
                detect: {
                    guard let j = TweakHelpers.readJSON(b.localState) else { return unreadable(b) }
                    let v = TweakHelpers.nested(j, hwAccel) as? Bool
                    var d = Detection(state: v == false ? .off : .on, values: [(hwAccel, v.map { "\($0)" } ?? "(not set: on)")])
                    if v == false { d.note = "Graphics acceleration is off in \(b.name)." }
                    return d
                },
                settingsURL: "",
                instructions: "\(b.settingsScheme)://settings/system > Use graphics acceleration when available, then relaunch \(b.name)")),
            sources: ["https://www.chromium.org/developers/design-documents/gpu-accelerated-compositing-in-chrome/",
                      "https://chromium.googlesource.com/chromium/src/+/main/chrome/common/pref_names.h"],
            requires: reqs, confidence: .high,
            expectedBenefit: "You find out if an old troubleshooting step left the browser drawing on the CPU.",
            tradeoff: "Nothing. Keel only reads the current state.", audience: [.everyone]))
        return out
    }
}
