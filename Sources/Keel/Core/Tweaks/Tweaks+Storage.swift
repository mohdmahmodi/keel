import Foundation
import KeelShared

// Never offer turning Spotlight or local snapshots off globally, and never trust "available": it includes
// purgeable space macOS may not release.

extension TweakCatalog {
    static let storage: [Tweak] = [
        // MARK: Free space

        Tweak(id: "free-space-headroom", name: "At least 15 % of the disk is free", category: .storage,
              summary: "Checks that the startup disk has real free space, not only space macOS might purge later.",
              explanation: "Keel shows how much of the startup disk is actually free; it only reads the numbers. APFS writes every change to a new block (copy-on-write), so editing files, swap, Time Machine snapshots and macOS updates, which stage tens of GB, all need free space, and an SSD with little free space has fewer spare blocks to spread writes over. FileVault needs no extra space, because the internal disk of an Apple silicon Mac is always hardware-encrypted. Keel treats 15 % free or more as healthy, the low end of the 15–20 % range in its storage research. The “available” figure in Finder adds purgeable space (snapshots, iCloud files, caches) that macOS may not release in time, so Keel shows both and judges by the strictly free one.",
              risk: .safe, impact: .medium, recommended: false,
              mechanism: .manual(ManualMechanism(detect: { StorageSupport.freeSpaceDetection() },
                 settingsURL: "x-apple.systempreferences:com.apple.settings.Storage",
                 instructions: "Free space: System Settings > General > Storage, Keel's Cleanup page, and the local-snapshot item below if purgeable space is large")),
              sources: ["https://eclecticlight.co/2022/05/18/how-much-free-space-does-an-apfs-disk-need/", "https://support.apple.com/guide/security/volume-encryption-with-filevault-sec4c6dc1b6e/web"],
              expectedBenefit: "A warning before low space makes updates fail, apps stall while saving, or swap run out.",
              tradeoff: "Nothing; Keel only reads the numbers.",
              audience: [.everyone]),

        Tweak(id: "tm-thin-local-snapshots", name: "Release space held by local snapshots", category: .storage,
              summary: "Frees space that Time Machine local snapshots still hold after files are deleted.",
              explanation: "Space from files you already deleted becomes free again once Keel deletes Time Machine local snapshots. Time Machine keeps hourly snapshots of the disk for about 24 hours, and each one holds on to every block that existed when it was taken, so after a large cleanup, a macOS update or a VM session they can hold tens of GB, and a cleanup can report almost nothing freed. macOS should release them when space runs low, but Howard Oakley found it did not do so when expected on macOS 26. Keel estimates what snapshots hold from the purgeable figure and runs tmutil thinlocalsnapshots / <bytes> 4, which asks Time Machine to delete snapshots at the highest urgency until that much space is reclaimed; no administrator password is needed. Keel never turns local snapshots off, because they are the only on-device undo for the last day.",
              risk: .low, impact: .medium, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: { await StorageSupport.snapshotDetection() },
                apply: { _ in
                    let cap = StorageSupport.capacity()
                    let target = max(cap.purgeable, 1_000_000_000)
                    let r = try await Shell.run("/usr/bin/tmutil", ["thinlocalsnapshots", "/", String(target), "4"], timeout: 300)
                    guard r.ok else { throw TweakEngine.EngineError(message: "tmutil thinlocalsnapshots failed: \(r.combined)") }
                    ActivityLog.post(.command, "tmutil thinlocalsnapshots / \(target) 4", detail: r.combined.isEmpty ? nil : r.combined)
                    await ProbeCache.shared.invalidate()
                    return ["requestedBytes": String(target), "before": String(cap.purgeable)]
                },
                revert: { _, _ in
                    ActivityLog.post(.info, "Deleted snapshots cannot be restored; Time Machine creates new ones on its own schedule.")
                },
                applyCommands: ["tmutil listlocalsnapshots /", "tmutil thinlocalsnapshots / <purgeable bytes> 4"],
                revertCommands: ["Nothing to undo: deleted snapshots cannot be restored. Time Machine takes new ones automatically."],
                needsAdmin: false)),
              sources: ["https://eclecticlight.co/2026/08/24/arent-snapshots-purgeable/", "https://support.apple.com/en-us/HT204015", "man tmutil (macOS 27.0.1): thinlocalsnapshots mount_point [purge_amount] [urgency]"],
              expectedBenefit: "Space you already deleted shows up as free again, often many GB right after a big cleanup or update.",
              tradeoff: "The hourly on-device restore points for the last day are gone; Time Machine starts taking new ones within the hour.", oneShot: true,
              audience: [.everyone]),

        // MARK: Time Machine

        Tweak(id: "tm-exclude-dev-caches", name: "Time Machine: skip developer caches", category: .storage,
              summary: "Keeps build output, simulators and package caches out of Time Machine backups.",
              explanation: "Time Machine stops backing up folders that tools rebuild or download again on their own: Xcode DerivedData and device support files, simulators, Gradle, npm, Cargo, Go, Maven, pnpm, Yarn, Bun, Conda, CocoaPods and pub caches, the Android SDK, ~/.cache, and downloaded Ollama and LM Studio models. Only folders that exist on this Mac are listed. Keel runs tmutil addexclusion on each, which tags the folder itself (a sticky exclusion that needs no administrator password); if a tool deletes and recreates the folder, the tag is lost and the item shows as partly on again. macOS already excludes ~/Library/Caches. The effect starts with the next backup to a configured destination.",
              risk: .safe, impact: .medium, recommended: true,
              mechanism: .custom(CustomMechanism(
                detect: { await StorageSupport.exclusionDetection(StorageSupport.devCachePaths(), fixedPath: false) },
                apply: { _ in
                    let state = await StorageSupport.excluded(StorageSupport.devCachePaths())
                    let todo = StorageSupport.devCachePaths().filter { state[$0] == false }
                    guard !todo.isEmpty else { return ["paths": ""] }
                    let r = try await Shell.run("/usr/bin/tmutil", ["addexclusion"] + todo, timeout: 60)
                    guard r.ok else { throw TweakEngine.EngineError(message: "tmutil addexclusion failed: \(r.combined)") }
                    ActivityLog.post(.command, "tmutil addexclusion " + todo.map { shq($0) }.joined(separator: " "))
                    await ProbeCache.shared.invalidate()
                    return ["paths": todo.joined(separator: "\n")]
                },
                revert: { _, orig in
                    // No record: restore the documented default (included) for every candidate.
                    let recorded = (orig["paths"] ?? "").split(separator: "\n").map(String.init)
                    let paths = orig["paths"] == nil ? StorageSupport.devCachePaths() : recorded
                    guard !paths.isEmpty else { return }
                    _ = try await Shell.run("/usr/bin/tmutil", ["removeexclusion"] + paths, timeout: 60)
                    ActivityLog.post(.command, "tmutil removeexclusion " + paths.map { shq($0) }.joined(separator: " "))
                    await ProbeCache.shared.invalidate()
                },
                applyCommands: ["tmutil addexclusion <each listed folder that is still included>"],
                revertCommands: ["tmutil removeexclusion <each folder Keel excluded>"],
                needsAdmin: false)),
              sources: ["https://eclecticlight.co/2026/01/06/exclude-or-include-items-in-backup-search-icloud-drive-and-quicklook-preview/"],
              requires: [.custom({ StorageSupport.devCachePaths().isEmpty ? "No developer cache folders on this Mac" : nil })],
              expectedBenefit: "Smaller, faster hourly backups and more backup history kept on the same drive.",
              tradeoff: "After a restore from backup, these caches are rebuilt or downloaded again on first use.",
              audience: [.developer]),

        Tweak(id: "tm-exclude-vms", name: "Time Machine: skip virtual machine disks", category: .storage,
              summary: "Keeps UTM, Parallels, VMware, OrbStack, Docker and other VM images out of backups.",
              explanation: "Time Machine stops backing up virtual machine disks. A VM disk is one large file that changes whenever the VM runs, so each hourly backup copies the whole file again, often many GB. Keel adds fixed-path exclusions (sudo tmutil addexclusion -p) for the VM folders that exist on this Mac, which asks for your administrator password; they appear in System Settings > General > Time Machine > Options and survive the folder being recreated. If you need the VMs backed up, use another method, such as an export or a snapshot inside the VM app.",
              risk: .low, impact: .medium, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: { await StorageSupport.exclusionDetection(StorageSupport.vmPaths(), fixedPath: true) },
                apply: { ctx in
                    let state = await StorageSupport.excluded(StorageSupport.vmPaths())
                    let todo = StorageSupport.vmPaths().filter { state[$0] != true }
                    ctx.privileged(todo.map { PrivOp.tmExclusion(path: $0, add: true) })
                    return ["paths": todo.joined(separator: "\n")]
                },
                revert: { ctx, orig in
                    let paths = orig["paths"] == nil ? StorageSupport.vmPaths() : (orig["paths"] ?? "").split(separator: "\n").map(String.init)
                    ctx.privileged(paths.map { PrivOp.tmExclusion(path: $0, add: false) })
                },
                applyCommands: ["sudo tmutil addexclusion -p <each listed VM folder>"],
                revertCommands: ["sudo tmutil removeexclusion -p <each folder Keel excluded>"],
                needsAdmin: true)),
              sources: ["man tmutil (macOS 27.0.1): addexclusion -p"],
              requires: [.custom({ StorageSupport.vmPaths().isEmpty ? "No virtual machine folders found (UTM, Parallels, VMware Fusion, OrbStack, Docker, Tart, Lima, Colima)" : nil })],
              confidence: .medium,
              expectedBenefit: "Hourly backups stop copying whole VM disks, so they finish sooner and the backup drive holds more history.",
              tradeoff: "VMs are not in Time Machine; restoring the Mac from backup will not bring them back.",
              audience: [.developer]),

        Tweak(id: "tm-unthrottle-io", name: "Time Machine backup at full disk speed", category: .storage,
              summary: "Turns off background disk throttling until restart, for a first or overdue backup.",
              explanation: "A Time Machine backup can use the disk at full speed instead of yielding to your apps. macOS slows background disk work (Time Machine, Spotlight indexing, iCloud sync) whenever something in the foreground uses the disk; setting the kernel variable debug.lowpri_throttle_enabled to 0 removes that limit, and needs an administrator password. Howard Oakley measured a whole backup rising from about 160 to 276 MB/s on macOS 12.2.1 with an M1 Pro; there is no newer measurement, though the kernel code is unchanged. The setting is global, so Spotlight and iCloud also stop yielding, and it resets at restart; Keel never makes it permanent. Keel offers it only when a Time Machine destination is configured.",
              risk: .medium, impact: .medium, recommended: false,
              mechanism: .sysctl(name: "debug.lowpri_throttle_enabled", value: { _ in 0 }, persist: false),
              sources: ["https://eclecticlight.co/2022/02/28/does-removing-i-o-throttling-make-backups-faster/", "https://github.com/apple-oss-distributions/xnu/blob/main/bsd/miscfs/specfs/spec_vnops.c"],
              requires: [.custom({ await StorageSupport.tmDestinationConfigured() ? nil : "No Time Machine destination is configured" })],
              confidence: .medium,
              expectedBenefit: "A large backup finishes sooner; in the one published test it took about 60 % as long.",
              tradeoff: "While it is on, apps can pause when Spotlight, iCloud or the backup use the disk heavily. Turn it off or restart when the backup is done.",
              audience: [.everyone]),

        Tweak(id: "tm-no-new-disk-prompt", name: "Time Machine new-disk prompt: off", category: .storage,
              summary: "Connecting a new drive no longer asks whether to use it for Time Machine backups.",
              explanation: "Connecting a drive that Time Machine has not seen before no longer brings up “Do you want to use this disk to back up with Time Machine?”. Keel sets com.apple.TimeMachine DoNotOfferNewDisksForBackup to true in your user preferences. The Time Machine helper (TMHelperAgent) on macOS 27.0.1 still checks this key; its log text names it. Backup disks can still be added in System Settings > General > Time Machine.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.TimeMachine", key: "DoNotOfferNewDisksForBackup", type: .bool, on: "1", off: nil)], post: .none),
              sources: ["https://www.macworld.com/article/190317/105notmdrive.html", "Local check: strings /System/Library/CoreServices/TimeMachine/TMHelperAgent.app on macOS 27.0.1"],
              expectedBenefit: "No dialog each time a USB drive or SD card is connected.",
              tradeoff: "Time Machine no longer suggests new backup disks; set one up in System Settings when you want one.",
              audience: [.everyone]),

        Tweak(id: "optimize-storage-note", name: "iCloud “Optimize Mac Storage” status", category: .storage,
              summary: "Shows whether iCloud Drive may remove local copies of files. Keel only reads it.",
              explanation: "Keel shows whether iCloud Drive is allowed to remove local copies of files. With Optimize Mac Storage on, iCloud Drive deletes the local copy of files you have not opened lately and keeps them only in iCloud, downloading them again when you open them. That frees space, but those files are then not on this Mac and Time Machine cannot back them up. Keel reads com.apple.bird optimize-storage and opens System Settings > Apple Account; this is information, not a recommendation either way.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let v = Prefs.string("com.apple.bird", "optimize-storage")
                  return Detection(state: v == "1" ? .on : .off, values: [("com.apple.bird optimize-storage", v ?? "(not set)")],
                                   note: v == "1" ? "Files evicted to iCloud are not on disk and are not in local Time Machine backups." : nil)
              }, settingsURL: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
                 instructions: "System Settings > Apple Account > iCloud > Drive > Optimize Mac Storage")),
              sources: ["Local check (macOS 27.0): com.apple.bird optimize-storage, the iCloud Drive Optimize Mac Storage switch"], confidence: .medium,
              expectedBenefit: "You can see whether every iCloud Drive file is on this Mac and in your backups.",
              tradeoff: "Nothing; Keel only reads it.",
              audience: [.everyone]),

        // MARK: Trash

        Tweak(id: "finder-trash-auto-empty", name: "Empty Trash items older than 30 days", category: .storage,
              summary: "Finder permanently deletes items that have been in the Trash for 30 days.",
              explanation: "Finder deletes items for good once they have been in the Trash for 30 days. Until then, deleted files keep using disk space. Keel turns on Finder's “Remove items from the Trash after 30 days” (com.apple.finder FXRemoveOldTrashItems, present in the Finder binary on macOS 27.0.1) and restarts Finder. Items trashed less than 30 days ago stay recoverable.",
              risk: .low, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.finder", key: "FXRemoveOldTrashItems", type: .bool, on: "1", off: nil)], post: .killFinder),
              sources: ["https://support.apple.com/guide/mac-help/mchlp1093/mac", "Local check: strings Finder on macOS 27.0.1"],
              expectedBenefit: "The Trash no longer grows to many GB unnoticed.",
              tradeoff: "Anything left in the Trash for 30 days is deleted permanently.",
              audience: [.everyone]),
    ]
}

// MARK: - Helpers (file-private)

private enum StorageSupport {
    static let home = NSHomeDirectory()

    /// Regenerable developer/tool caches, relative to the home folder.
    static let devCacheCandidates = [
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
        "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport",
        "Library/Developer/Xcode/macOS DeviceSupport",
        "Library/Developer/CoreSimulator/Devices", "Library/Developer/CoreSimulator/Caches", "Library/Developer/XCTestDevices",
        ".gradle/caches", ".gradle/wrapper/dists", ".npm", ".pub-cache", "Library/Android/sdk", ".cache",
        ".cargo/registry", ".rustup/toolchains", "go/pkg/mod", ".m2/repository", ".bun/install/cache",
        "Library/pnpm/store", ".local/share/pnpm/store", ".yarn/berry/cache", ".conda/pkgs", ".cocoapods/repos",
        ".ollama/models", ".lmstudio/models",
    ]

    /// Virtual machine and container-VM storage, relative to the home folder.
    static let vmCandidates = [
        "Library/Containers/com.utmapp.UTM", "Parallels", "Library/Parallels",
        "Virtual Machines.localized", "Documents/Virtual Machines.localized", "Virtual Machines",
        ".orbstack", "Library/Containers/com.docker.docker", ".tart", ".lima", ".colima",
    ]

    static func existing(_ rel: [String]) -> [String] {
        rel.map { "\(home)/\($0)" }.filter { FileManager.default.fileExists(atPath: $0) }
    }
    static func devCachePaths() -> [String] { existing(devCacheCandidates) }
    static func vmPaths() -> [String] { existing(vmCandidates) }
    static func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    /// Fixed-path exclusions (SkipPaths) from the system Time Machine preferences (world-readable).
    static func skipPaths() -> Set<String> {
        let path = "/Library/Preferences/com.apple.TimeMachine.plist"
        var list = (NSDictionary(contentsOfFile: path)?["SkipPaths"] as? [String]) ?? []
        if list.isEmpty, let v = CFPreferencesCopyAppValue("SkipPaths" as CFString, "/Library/Preferences/com.apple.TimeMachine" as CFString) as? [String] { list = v }
        return Set(list.map { ($0 as NSString).expandingTildeInPath })
    }

    /// path → excluded? (nil = unknown, e.g. a protected folder) from one `tmutil isexcluded` call.
    static func excluded(_ paths: [String]) async -> [String: Bool?] {
        var out: [String: Bool?] = [:]
        for p in paths { out[p] = .some(nil) }
        guard !paths.isEmpty, let r = await Shell.probe("/usr/bin/tmutil", ["isexcluded"] + paths) else { return out }
        for line in r.stdout.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            for (tag, value) in [("[Excluded]", true), ("[Included]", false)] where t.hasPrefix(tag) {
                let p = t.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
                if out.keys.contains(p) { out[p] = value }
            }
        }
        let skip = skipPaths()
        for p in paths where skip.contains(p) { out[p] = true }
        return out
    }

    static func exclusionDetection(_ paths: [String], fixedPath: Bool) async -> Detection {
        if paths.isEmpty { return .na("No matching folders on this Mac") }
        let state = await excluded(paths)
        var values: [(String, String)] = []
        var yes = 0, known = 0
        for p in paths {
            let e = state[p] ?? nil
            if e != nil { known += 1 }
            if e == true { yes += 1 }
            values.append((tilde(p), e == true ? "excluded" : (e == false ? "included" : "unknown (protected folder)")))
        }
        let dest = await tmDestinationConfigured()
        values.append(("Time Machine destination", dest ? "configured" : "none yet (takes effect with the first backup)"))
        let st: TweakState = known > 0 && yes == known ? .on : (yes == 0 ? .off : .partlyOn)
        return Detection(state: st, values: values)
    }

    static func tmDestinationConfigured() async -> Bool {
        guard let r = await Shell.probe("/usr/bin/tmutil", ["destinationinfo"], ttl: 30) else { return false }
        let text = r.combined
        if text.contains("No destinations configured") { return false }
        return r.ok && (text.contains("Name") || text.contains("ID"))
    }

    // MARK: Capacity

    struct Capacity { var total: Int64 = 0, free: Int64 = 0, important: Int64 = 0; var purgeable: Int64 { max(0, important - free) } }

    static func capacity() -> Capacity {
        let path = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return Capacity() }
        return Capacity(total: Int64(v.volumeTotalCapacity ?? 0), free: Int64(v.volumeAvailableCapacity ?? 0),
                        important: v.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
    static func pct(_ part: Int64, _ total: Int64) -> String { total > 0 ? String(format: "%.0f %%", Double(part) * 100 / Double(total)) : "?" }

    static func freeSpaceDetection() -> Detection {
        let c = capacity()
        guard c.total > 0 else { return .unknown }
        let freeRatio = Double(c.free) / Double(c.total)
        let withPurgeable = Double(c.free + c.purgeable) / Double(c.total)
        let values = [("disk size", gb(c.total)),
                      ("free now (like df)", "\(gb(c.free))  (\(pct(c.free, c.total)))"),
                      ("purgeable (may be released)", gb(c.purgeable)),
                      ("“available” as Finder shows it", "\(gb(c.important))  (\(pct(c.important, c.total)))")]
        if freeRatio >= 0.15 { return Detection(state: .on, values: values) }
        if withPurgeable >= 0.15 {
            return Detection(state: .partlyOn, values: values, note: "Enough space exists only if macOS releases purgeable space; thin local snapshots or clean up.")
        }
        return Detection(state: .off, values: values, note: "Less than 15 % free. Updates, swap and snapshots may fail or slow the Mac down.")
    }

    // MARK: Snapshots

    static func snapshotNames() async -> [String]? {
        guard let r = await Shell.probe("/usr/bin/tmutil", ["listlocalsnapshots", "/"]), r.ok else { return nil }
        return r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("com.apple.") }
    }

    /// ON = nothing significant pinned: no snapshots, or purgeable space below max(10 GB, 5 % of the disk).
    static func snapshotDetection() async -> Detection {
        guard let names = await snapshotNames() else { return .unknown }
        let c = capacity()
        let threshold = max(Int64(10_000_000_000), c.total / 20)
        var values: [(String, String)] = [("local snapshots", "\(names.count)")]
        if let first = names.first, let last = names.last, names.count > 0 {
            values.append(("oldest", first.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")))
            if names.count > 1 { values.append(("newest", last.replacingOccurrences(of: "com.apple.TimeMachine.", with: ""))) }
        }
        values.append(("purgeable space (upper bound for what snapshots pin)", gb(c.purgeable)))
        values.append(("free now", "\(gb(c.free))  (\(pct(c.free, c.total)))"))
        if names.isEmpty { return Detection(state: .on, values: values, note: "No local snapshots: deleted files free their space immediately.") }
        if c.purgeable < threshold { return Detection(state: .on, values: values, note: "Snapshots exist but hold little space; nothing to do.") }
        return Detection(state: .off, values: values, note: "Up to \(gb(c.purgeable)) may be held by snapshots and other purgeable data.")
    }
}
