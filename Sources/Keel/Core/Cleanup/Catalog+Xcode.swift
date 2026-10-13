import Foundation

extension CleanupCatalog {
    static let xcodeApp = OwningApp(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"])
    static let simulatorApp = OwningApp(name: "Simulator", bundleIDs: ["com.apple.iphonesimulator"])

    static func simctl(_ args: [String]) -> CleanupCommand { CleanupCommand(executable: "/usr/bin/xcrun", args: ["simctl"] + args) }

    // MARK: Xcode folders (filesystem only, fast)

    static let xcode: Provider = { ctx in
        let h = ctx.home
        let dev = "\(h)/Library/Developer"
        var items: [CleanupItem] = []

        if FS.isDir("\(dev)/Xcode/DerivedData") {
            items.append(.folders(id: "deriveddata", name: "Xcode DerivedData", group: .developer,
                summary: "Build output and indexes for each project. Xcode rebuilds them on the next build.",
                explanation: "Xcode keeps build output, module caches and the code index for each project in ~/Library/Developer/Xcode/DerivedData. Apple's developer support states that the folder can be deleted at any time and is recreated as projects are opened and built. Quit Xcode first so it does not write to the folder while it is deleted.",
                paths: ["\(dev)/Xcode/DerivedData"], rebuildCost: "One full build and re-index per project (minutes)", owner: xcodeApp))
        }

        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            if let item = deviceSupport(platform: platform, root: "\(dev)/Xcode/\(platform) DeviceSupport") { items.append(item) }
        }

        let archives = "\(dev)/Xcode/Archives"
        if FS.isDir(archives) {
            var list: [String] = []
            for day in FS.list(archives) { for a in FS.list("\(archives)/\(day)") where a.hasSuffix(".xcarchive") { list.append("\(archives)/\(day)/\(a)") } }
            items.append(.listOnly(id: "xcode-archives", name: "Xcode Archives", group: .developer,
                summary: "\(list.count) archive\(list.count == 1 ? "" : "s") with dSYMs. Needed to symbolicate crash reports.",
                explanation: "Archives are builds you exported or uploaded from Xcode, together with their debug symbols (dSYMs). Without the dSYMs, crash reports from TestFlight and the App Store cannot be symbolicated. Keel does not delete archives; remove individual ones in Xcode › Window › Organizer.\n\n" + list.suffix(30).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"),
                paths: [archives]))
        }

        if ctx.hasXcode {
            let previews = "\(dev)/Xcode/UserData/Previews"
            if FS.isDir(previews) {
                items.append(CleanupItem(id: "xcode-previews", name: "SwiftUI Previews simulators", group: .developer,
                    summary: "Simulator devices Xcode creates to show SwiftUI previews.",
                    explanation: "SwiftUI previews run in a separate set of simulator devices under ~/Library/Developer/Xcode/UserData/Previews. Keel removes them with `xcrun simctl --set previews delete all`, which keeps CoreSimulator's records consistent; deleting the folder by hand has been reported to break previews. The first preview of each project then takes longer while its device is recreated.",
                    paths: [previews], actions: [.run(simctl(["--set", "previews", "delete", "all"]))],
                    defaultOn: true, rebuildCost: "The first preview of each project is slower once", owner: xcodeApp))
            }
            for (id, name, folder, why) in [("xctestdevices", "XCTest clones", "XCTestDevices", "Simulator copies that `xcodebuild test` creates to run tests in parallel."),
                                            ("xcpgdevices", "Playground simulators", "XCPGDevices", "Simulator devices that Xcode playgrounds use.")] {
                let path = "\(dev)/\(folder)"
                guard FS.isDir(path) else { continue }
                items.append(CleanupItem(id: id, name: name, group: .developer, summary: why,
                    explanation: "\(why) Xcode recreates them on the next run. Keel removes them with `xcrun simctl --set <folder> delete all` instead of deleting the files directly. Quit Xcode and stop any running tests first.",
                    paths: [path], actions: [.run(simctl(["--set", path, "delete", "all"]))],
                    defaultOn: true, rebuildCost: "Recreated on the next run", owner: xcodeApp))
            }
            let dyld = "/Library/Developer/CoreSimulator/Caches/dyld"
            if FS.isDir(dyld) {
                items.append(CleanupItem(id: "sim-dyld-caches", name: "Simulator dyld caches", group: .developer,
                    summary: "Prepared system libraries for each simulator runtime. Rebuilt on the next simulator start.",
                    explanation: "CoreSimulator prepares a shared cache of system libraries (the dyld shared cache) for each runtime and each macOS build, in /Library/Developer/CoreSimulator/Caches/dyld. Caches made for earlier macOS builds remain after macOS updates. Keel runs `xcrun simctl runtime dyld_shared_cache remove --all`; runtimes that are still used rebuild their cache on first start, which takes a few minutes and 2–3 GB each.",
                    paths: [dyld], actions: [.run(simctl(["runtime", "dyld_shared_cache", "remove", "--all"]))],
                    risk: .low, defaultOn: false, rebuildCost: "First simulator start per runtime takes a few minutes longer", owner: simulatorApp))
            }
        }

        let ib = "\(dev)/Xcode/UserData/IB Support"
        let caches = FS.existing(["\(h)/Library/Caches/com.apple.dt.Xcode", "\(dev)/Xcode/DocumentationCache", "\(dev)/Xcode/DocumentationIndex", "\(dev)/DVTDownloads", ib])
        if !caches.isEmpty {
            items.append(.folders(id: "xcode-caches", name: "Xcode caches", group: .developer,
                summary: "Download, documentation and Interface Builder caches. Xcode recreates them.",
                explanation: "Smaller caches that Xcode recreates when needed: ~/Library/Caches/com.apple.dt.Xcode, the documentation cache and index, download staging (DVTDownloads) and the Interface Builder device set. Apple's developer support recommends deleting DocumentationCache and DocumentationIndex together. The rest of Xcode/UserData (key bindings, themes, snippets, Coding Assistant settings) is not touched.",
                paths: caches, rebuildCost: "Rebuilt on demand", owner: xcodeApp))
        }
        return items
    }

    /// One parent per platform, one child per OS build folder. The newest build per device model is kept.
    static func deviceSupport(platform: String, root: String) -> CleanupItem? {
        let folders = FS.list(root).filter { FS.isDir("\(root)/\($0)") }
        guard !folders.isEmpty else { return nil }
        let keep = newestPerModel(folders, root: root)
        let kids = folders.map { f -> CleanupItem in
            let isNewest = keep.contains(f)
            let model = deviceModel(f)
            let used = FS.modified("\(root)/\(f)").map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "unknown"
            return CleanupItem(id: "ds-\(platform)-\(f)", name: f, group: .developer,
                summary: isNewest ? "Newest build for \(model.isEmpty ? "this platform" : model). Kept by default." : "Older OS build. Last changed \(used).",
                explanation: "Debug symbols Xcode copied from a device running this OS build. Xcode copies them again the next time a device with this build is connected for debugging, so older builds can be deleted.",
                paths: ["\(root)/\(f)"], actions: [.removePath("\(root)/\(f)")],
                defaultOn: !isNewest, rebuildCost: "Re-copied from the device on next connect (minutes)", owner: xcodeApp)
        }
        return CleanupItem(id: "ds-\(platform)", name: "\(platform) DeviceSupport", group: .developer,
            summary: "Debug symbols for each device OS build. The newest build per device model is kept.",
            explanation: "When a device is used for debugging, Xcode copies that OS build's debug symbols to ~/Library/Developer/Xcode/\(platform) DeviceSupport. Xcode does not remove old builds, and each folder is typically 3–13 GB. Keel pre-selects every folder except the newest OS build for each device model.",
            paths: [root], rebuildCost: "Re-copied from the device on next connect", children: kids)
    }

    /// "iPhone16,2 27.0 (24A5408d)" → "iPhone16,2"; old style "16.4 (20E247) arm64e" → "".
    static func deviceModel(_ folder: String) -> String {
        let first = folder.split(separator: " ").first.map(String.init) ?? ""
        return first.contains(",") || first.range(of: "^[A-Za-z]", options: .regularExpression) != nil ? first : ""
    }

    static func osVersion(_ folder: String) -> [Int] {
        for t in folder.split(separator: " ") where t.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil {
            return t.split(separator: ".").compactMap { Int($0) }
        }
        return []
    }

    static func newestPerModel(_ folders: [String], root: String) -> Set<String> {
        var best: [String: (String, [Int], Date)] = [:]
        for f in folders {
            let model = deviceModel(f), v = osVersion(f)
            let mtime = FS.modified("\(root)/\(f)") ?? .distantPast
            if let cur = best[model] {
                let c = compare(v, cur.1)
                if c > 0 || (c == 0 && mtime > cur.2) { best[model] = (f, v, mtime) }
            } else { best[model] = (f, v, mtime) }
        }
        return Set(best.values.map { $0.0 })
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: Simulators (simctl, slower)

    static let simulators: Provider = { ctx in
        guard ctx.hasXcode, let inv = await SimInventory.load() else { return [] }
        var items: [CleanupItem] = []

        // Runtimes, keyed by the image identifier UUID.
        if !inv.images.isEmpty {
            let kids = inv.images.map { rt -> CleanupItem in
                let devices = inv.devices(onRuntime: rt.runtimeID)
                let used = rt.lastUsed.map { "last used \($0)" } ?? "never used"
                var warnings: [String] = []
                if !devices.isEmpty {
                    warnings.append("\(devices.count) simulator\(devices.count == 1 ? "" : "s") use \(rt.name): \(devices.prefix(6).map(\.name).joined(separator: ", "))\(devices.count > 6 ? "…" : ""). After the runtime is deleted they become unavailable but their app data stays on disk; Keel then lists them under Unavailable simulators. Reinstalling \(rt.name) brings them back.")
                }
                return CleanupItem(id: "runtime-\(rt.identifier)", name: "\(rt.name) (\(rt.build))", group: .developer,
                    summary: (devices.isEmpty ? "No simulators" : "\(devices.count) simulator\(devices.count == 1 ? "" : "s")") + " · \(used)",
                    explanation: "A simulator runtime is the disk image of an operating system that simulators start from, here \(rt.name) build \(rt.build). Keel deletes it with `xcrun simctl runtime delete \(rt.identifier)`. It can be downloaded again in Xcode › Settings › Components or with `xcodebuild -downloadPlatform \(rt.platform) -buildVersion \(rt.version)`. Some Xcode 26 releases leave the image on disk after deletion; Keel checks afterwards and reports it.",
                    actions: rt.deletable ? [.run(simctl(["runtime", "delete", rt.identifier]))] : [],
                    kind: rt.deletable ? .clean : .listOnly, risk: devices.isEmpty ? .safe : .low,
                    defaultOn: devices.isEmpty && rt.deletable,
                    rebuildCost: "Re-download about \(rt.sizeBytes.humanBytes) from Apple",
                    sizeBytes: rt.sizeBytes, sizeKind: .reported, measure: .preset,
                    detail: "identifier \(rt.identifier)\nruntime \(rt.runtimeID)\nbuild \(rt.build)\nlast used \(rt.lastUsed ?? "never")\nsimulators \(devices.count)",
                    warnings: warnings, verifyRuntimeGone: rt.identifier, simRuntimeID: rt.runtimeID)
            }
            items.append(CleanupItem(id: "runtimes", name: "Simulator runtimes", group: .developer,
                summary: "Operating system images for simulators. Images no simulator uses are pre-selected.",
                explanation: "Simulator runtimes are disk images of 7–9 GB each that CoreSimulator stores in /System/Library/AssetsV2 or /Library/Developer/CoreSimulator. Keel deletes them only with `xcrun simctl runtime delete`, never by removing files. Runtimes bundled inside Xcode cannot be deleted here.",
                rebuildCost: "Re-download from Apple", sizeKind: .reported, measure: .none, children: kids))
        }

        let unavailable = inv.unavailable
        let recentlyDeleted = DeletedRuntimes.recent()
        if !unavailable.isEmpty {
            let kids = unavailable.map { d -> CleanupItem in
                let reason = inv.reason(d)
                let rtName = SimInventory.runtimeName(d.runtimeID)
                let removed = reason == .runtimeRemoved
                let deletedOn = removed ? recentlyDeleted[d.runtimeID] : nil
                let why: String
                switch reason {
                case .runtimeRemoved: why = "\(rtName) is not installed any more"
                case .runtimeNotReady(let e): why = "\(rtName) is installed but not ready: \(e)"
                }
                let summary = !removed ? "Runtime not ready. This is usually temporary after a macOS or Xcode update."
                    : deletedOn.map { "Runtime deleted on \($0.formatted(date: .abbreviated, time: .omitted)). Not selected, in case you reinstall it." } ?? "Its runtime is no longer installed, so it cannot start."
                return CleanupItem(id: "unavail-\(d.udid)", name: "\(d.name) · \(rtName)", group: .developer,
                    summary: summary,
                    explanation: removed
                        ? "This simulator cannot start because \(why). Its apps and data stay on disk until it is deleted, and reinstalling \(rtName) makes it usable again."
                        : "This simulator cannot start right now because \(why). This is usually temporary after a macOS or Xcode update: open Xcode once so it can finish installing components, or run `xcrun simctl runtime dyld_shared_cache update --all`, then measure again. Deleting it removes its apps and data permanently.",
                    paths: d.folder.map { [$0] } ?? [], actions: [.run(simctl(["delete", d.udid]))],
                    risk: removed ? (deletedOn == nil ? .safe : .low) : .medium, defaultOn: removed && deletedOn == nil,
                    rebuildCost: removed ? "None (it cannot boot)" : "App data inside this simulator is lost",
                    detail: "UDID \(d.udid)\nruntime \(d.runtimeID)\n\(d.availabilityError ?? "")")
            }
            let notReady = unavailable.filter { inv.reason($0) != .runtimeRemoved }.count
            let kept = kids.count - notReady - kids.filter(\.defaultOn).count
            var parts: [String] = []
            if notReady > 0 { parts.append("\(notReady) temporarily unavailable") }
            if kept > 0 { parts.append("\(kept) from a runtime deleted in the last 14 days") }
            items.append(CleanupItem(id: "sim-unavailable", name: "Unavailable simulators", group: .developer,
                summary: parts.isEmpty ? "Simulators whose runtime is no longer installed." : parts.joined(separator: ", ") + ". Those are not selected.",
                explanation: "Simulators that cannot start because their runtime is missing or not ready. Keel deletes each one by its UDID with `xcrun simctl delete <UDID>` and never runs `simctl delete unavailable`, so a simulator that becomes unavailable after the scan is never removed without being listed. Only simulators whose runtime is no longer installed are pre-selected.",
                rebuildCost: "None for devices whose runtime is gone", children: kids))
        }

        // Erasing available devices is opt-in.
        let available = inv.available
        if !available.isEmpty {
            let kids = available.map { d -> CleanupItem in
                let rtName = SimInventory.runtimeName(d.runtimeID)
                var actions: [CleanupAction] = []
                if d.state == "Booted" { actions.append(.run(simctl(["shutdown", d.udid]))) }
                actions.append(.run(simctl(["erase", d.udid])))
                return CleanupItem(id: "simdev-\(d.udid)", name: "\(d.name) · \(rtName)", group: .developer,
                    summary: (d.state == "Booted" ? "Running. " : "") + (d.lastBooted.map { "Last started \($0)." } ?? "Never started."),
                    explanation: "Erasing keeps the simulator but removes its installed apps, photos and data, like Device › Erase All Content and Settings in Simulator. Keel runs `xcrun simctl erase <UDID>` and shuts the simulator down first if it is running.",
                    paths: d.folder.map { [$0] } ?? [], actions: actions, risk: .low, defaultOn: false,
                    rebuildCost: "Apps and test data in this simulator are lost", detail: "UDID \(d.udid)\nruntime \(d.runtimeID)")
            }
            items.append(CleanupItem(id: "sim-devices", name: "Simulator app data", group: .developer,
                summary: "Erase the apps and data of individual simulators. Nothing is selected by default.",
                explanation: "Each simulator keeps its installed apps and data in ~/Library/Developer/CoreSimulator/Devices. Keel never deletes that folder directly. Select a simulator to erase its content with simctl.",
                rebuildCost: "Reinstall apps into the simulator", children: kids))
        }
        return items
    }
}
