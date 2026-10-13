import Foundation

/// `--cleanup-selftest`: real catalog, safety checks, deletes and summary math against a fake home in `KEEL_CLEANUP_TEST_HOME`.
/// `CleanupSafety.homeOverride` confines deletions to it, the Trash is a folder inside it, and only /usr/bin/true and false run.
@MainActor
enum CleanupSelfTest {
    private static var passed = 0
    private static var failures: [String] = []

    private static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("PASS  \(what)") } else { failures.append(what); print("FAIL  \(what)") }
    }

    private static func write(_ path: String, kb: Int) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x5A, count: kb * 1024))
    }

    private static func exists(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    static func run() async -> Bool {
        guard let base = ProcessInfo.processInfo.environment["KEEL_CLEANUP_TEST_HOME"], base.hasPrefix("/") else {
            print("Set KEEL_CLEANUP_TEST_HOME to an absolute folder for the fake home (for example a scratch folder).")
            return false
        }
        let realHome = CleanupSafety.real(NSHomeDirectory())
        let baseReal = CleanupSafety.real(base)
        guard baseReal != realHome, !(realHome + "/").hasPrefix(baseReal + "/") else {
            print("KEEL_CLEANUP_TEST_HOME must not be your home folder or contain it.")
            return false
        }
        let run = "\(baseReal)/run-\(Int(Date().timeIntervalSince1970))-\(getpid())"
        let h = "\(run)/home", outside = "\(run)/outside"
        print("Fake home: \(h)")

        // MARK: Build the fake home
        let L = "\(h)/Library"
        let ds = "\(L)/Developer/Xcode/iOS DeviceSupport"
        write("\(L)/Developer/Xcode/DerivedData/ProjA-abc/Build/Intermediates/o.bin", kb: 256)
        write("\(ds)/iPhone16,2 26.0 (23A341)/Symbols/dyld", kb: 128)
        write("\(ds)/iPhone16,2 27.0 (24A5408d)/Symbols/dyld", kb: 128)
        write("\(ds)/iPad16,5 26.6.1 (23G83)/Symbols/dyld", kb: 128)
        write("\(L)/Caches/com.apple.dt.Xcode/Downloads/x", kb: 64)
        write("\(L)/Caches/com.example.Editor/Cache.db", kb: 128)
        write("\(L)/Caches/com.example.Linker/data", kb: 64)
        write("\(L)/Caches/com.apple.Safari/x", kb: 64)
        write("\(L)/Caches/CloudKit/x", kb: 64)
        write("\(L)/Caches/Google/Chrome/Default/Cache/data_0", kb: 128)
        write("\(L)/Caches/Google/Chrome/Default/Code Cache/js", kb: 64)
        write("\(L)/Logs/SomeApp/app.log", kb: 64)
        write("\(L)/Logs/DiagnosticReports/Crash.ips", kb: 32)
        write("\(h)/.npm/_npx/abc/pkg", kb: 64)
        write("\(h)/.npm/_cacache/x", kb: 64)
        write("\(h)/Documents/notes.txt", kb: 4)
        write("\(h)/Documents/GitHub/web/package.json", kb: 1)
        write("\(h)/Documents/GitHub/web/node_modules/lib/index.js", kb: 128)
        write("\(h)/Projects/Documents/readme.txt", kb: 16)
        write("\(h)/Downloads/Old Installer.dmg", kb: 64)
        write("\(outside)/dir/keep.txt", kb: 8)
        let fm = FileManager.default
        try? fm.createSymbolicLink(atPath: "\(L)/Caches/com.example.Linker/outside-link", withDestinationPath: "\(outside)/dir")
        try? fm.createSymbolicLink(atPath: "\(L)/Caches/EvilLink", withDestinationPath: "\(outside)/dir")
        let testTrash = "\(run)/trash"
        try? fm.createDirectory(atPath: testTrash, withIntermediateDirectories: true)

        CleanupSafety.homeOverride = h
        CleanupScanner.testHooks = .init(recycle: { url in
            try FileManager.default.moveItem(atPath: url.path, toPath: "\(testTrash)/\(url.lastPathComponent)")
        }, allowedExecutables: ["/usr/bin/true", "/usr/bin/false"])
        defer { CleanupSafety.homeOverride = nil; CleanupScanner.testHooks = nil }

        // MARK: Catalog against the fake home
        let ctx = CatalogContext(home: h, hasXcode: false, brewPrefix: nil, hasFDA: false, includeUserFolders: true)
        var items: [CleanupItem] = []
        for p in [CleanupCatalog.xcode, CleanupCatalog.packages, CleanupCatalog.appCaches, CleanupCatalog.otherCaches,
                  CleanupCatalog.system, CleanupCatalog.oldInstallers, CleanupCatalog.repoBuildFolders] {
            items += await p(ctx)
        }
        var measured: [String: CleanupItem] = [:]
        for leaf in items.flatMap(\.leaves) { measured[leaf.id] = await CleanupScanner.measure(leaf) }
        func leaf(_ id: String) -> CleanupItem? { measured[id] }

        let dsKids = items.first { $0.id == "ds-iOS" }?.children ?? []
        expect(dsKids.count == 3, "DeviceSupport lists 3 OS builds")
        expect(dsKids.first { $0.name.hasPrefix("iPhone16,2 26.0") }?.defaultOn == true, "older iPhone build is pre-selected")
        expect(dsKids.first { $0.name.hasPrefix("iPhone16,2 27.0") }?.defaultOn == false, "newest iPhone build is kept")
        expect(dsKids.first { $0.name.hasPrefix("iPad16,5") }?.defaultOn == false, "only iPad build is kept")
        let other = Set(items.first { $0.id == "user-caches" }?.children.map(\.id) ?? [])
        expect(other.contains("cache-com.example.Editor"), "other caches lists com.example.Editor")
        expect(!other.contains("cache-com.apple.Safari") && !other.contains("cache-CloudKit"), "other caches never lists com.apple.* or CloudKit")
        expect(items.contains { $0.id == "repo-build-folders" && !$0.deletable }, "node_modules in a repository is listed and not deletable")
        expect(!items.contains { $0.id == "old-installers" }, "an installer added today is not offered")
        expect(leaf("deriveddata")?.sizeBytes ?? 0 >= 256 * 1024, "DerivedData is measured with du")
        expect(leaf("trash")?.defaultOn == false, "Trash is never pre-selected")

        // MARK: Selection: defaults without external commands, plus explicit cases
        var targets = items.flatMap(\.leaves).compactMap { measured[$0.id] }.filter { l in
            l.id != "npm" && l.defaultOn && l.deletable && (l.sizeBytes ?? 0) > 0 && !l.actions.contains { if case .run = $0 { return true }; return false }
        }
        for id in ["cache-com.example.Editor", "cache-com.example.Linker", "cache-EvilLink"] { if let l = leaf(id) { targets.append(l) } }
        func custom(_ id: String, _ actions: [CleanupAction], paths: [String] = []) -> CleanupItem {
            CleanupItem(id: id, name: id, group: .system, summary: "", explanation: "", paths: paths, actions: actions, defaultOn: true, rebuildCost: "")
        }
        let dmg = "\(h)/Downloads/Old Installer.dmg"
        var extra = [
            custom("nested-documents", [.removePath("\(h)/Projects/Documents")], paths: ["\(h)/Projects/Documents"]),
            custom("top-documents", [.removePath("\(h)/Documents")]),
            custom("home-contents", [.removeContents(h, except: [])]),
            custom("caches-root", [.removeContents("\(L)/Caches", except: [])]),
            custom("apple-cache", [.removePath("\(L)/Caches/com.apple.Safari")]),
            custom("outside-file", [.removePath("\(outside)/dir/keep.txt")]),
            custom("through-link", [.removePath("\(L)/Caches/EvilLink/keep.txt")]),
            custom("dotdot", [.removePath("\(h)/Projects/../Documents")]),
            custom("cmd-true", [.run(CleanupCommand(executable: "/usr/bin/true", args: []))]),
            custom("cmd-false", [.run(CleanupCommand(executable: "/usr/bin/false", args: []))]),
            custom("cmd-rm", [.run(CleanupCommand(executable: "/bin/rm", args: ["-rf", "\(h)/Documents"]))]),
            custom("finder-empty", [.emptyTrashViaFinder]),
            custom("recycle-dmg", [.moveToTrash(dmg)], paths: [dmg]),
        ]
        for i in extra.indices { extra[i] = await CleanupScanner.measure(extra[i]) }
        targets += extra
        let expectedBytes = Dictionary(targets.map { ($0.id, $0.sizeBytes ?? 0) }, uniquingKeysWith: { a, _ in a })

        // MARK: Run the real runner
        var space = VolumeSpace(free: 10_000_000, important: 12_000_000, total: 100_000_000)
        let hooks = CleanupRunner.Hooks(isBlocked: { _ in false },
                                        readSpace: { defer { space.free += 1_000 }; return space },
                                        snapshotCount: { 0 }, settleNanoseconds: 0, verifyRuntimes: false)
        let s = await CleanupRunner.run(targets, hooks: hooks) { _, _ in }
        func state(_ id: String) -> CleanStepState? { s.steps.first { $0.id == id }?.state }
        func done(_ id: String) -> Bool { if case .done = state(id) { return true }; return false }
        func refused(_ id: String) -> Bool { if case .failed(let m) = state(id) { return m.hasPrefix("Refused") }; return false }
        func failed(_ id: String) -> Bool { if case .failed = state(id) { return true }; return false }

        expect(done("deriveddata") && !exists("\(L)/Developer/Xcode/DerivedData/ProjA-abc") && exists("\(L)/Developer/Xcode/DerivedData"), "DerivedData emptied, folder kept")
        expect(!exists("\(ds)/iPhone16,2 26.0 (23A341)"), "older DeviceSupport build deleted")
        expect(exists("\(ds)/iPhone16,2 27.0 (24A5408d)") && exists("\(ds)/iPad16,5 26.6.1 (23G83)"), "kept DeviceSupport builds still exist")
        expect(done("xcode-caches") && !exists("\(L)/Caches/com.apple.dt.Xcode/Downloads"), "Xcode's own cache (com.apple.dt.Xcode) emptied")
        expect(done("chrome-cache") && !exists("\(L)/Caches/Google/Chrome/Default/Cache/data_0") && exists("\(L)/Caches/Google/Chrome/Default/Cache"), "Chrome cache emptied, folders kept")
        expect(done("user-logs") && !exists("\(L)/Logs/SomeApp") && exists("\(L)/Logs/DiagnosticReports/Crash.ips"), "App logs emptied, crash reports kept")
        expect(done("cache-com.example.Editor") && !exists("\(L)/Caches/com.example.Editor/Cache.db") && exists("\(L)/Caches/com.example.Editor"), "app cache emptied, folder kept")
        expect(done("cache-com.example.Linker") && !exists("\(L)/Caches/com.example.Linker/outside-link") && exists("\(outside)/dir/keep.txt"), "a link inside a cache is removed, its target is not")
        expect(refused("cache-EvilLink") && exists("\(outside)/dir/keep.txt"), "a cache folder that links outside the home folder is refused")
        expect(done("nested-documents") && !exists("\(h)/Projects/Documents"), "a nested folder named Documents can be deleted")
        expect(refused("top-documents") && exists("\(h)/Documents/notes.txt"), "~/Documents is refused")
        expect(refused("home-contents") && exists("\(h)/Documents"), "emptying the home folder is refused")
        expect(refused("caches-root") && exists("\(L)/Caches/com.apple.Safari/x"), "emptying ~/Library/Caches as a whole is refused")
        expect(refused("apple-cache") && exists("\(L)/Caches/com.apple.Safari/x") && exists("\(L)/Caches/CloudKit/x"), "Apple caches and CloudKit are refused")
        expect(refused("outside-file") && exists("\(outside)/dir/keep.txt"), "a path outside the home folder is refused")
        expect(refused("through-link") && exists("\(outside)/dir/keep.txt"), "a path through a link pointing outside is refused")
        expect(refused("dotdot"), "a path containing .. is refused")
        expect(done("cmd-true"), "an allowed command runs")
        expect(failed("cmd-false") && !refused("cmd-false"), "a failing command is reported as failed")
        expect(refused("cmd-rm") && exists("\(h)/Documents/notes.txt"), "commands outside the allow-list are refused in the self-test")
        expect(refused("finder-empty"), "emptying the real Trash is refused in the self-test")
        expect(done("recycle-dmg") && !exists(dmg) && exists("\(testTrash)/Old Installer.dmg"), "installer moved to the (test) Trash, not deleted")
        expect(exists("\(h)/.npm/_cacache/x") && exists("\(h)/Documents/GitHub/web/node_modules/lib/index.js"), "unselected items are untouched")

        // MARK: Summary math
        var measuredSum: UInt64 = 0, trashSum: UInt64 = 0, mismatches: [String] = []
        for step in s.steps {
            guard case .done(let b, let m) = step.state else { continue }
            if step.id == "recycle-dmg" { trashSum += b } else if m { measuredSum += b }
            if m, let e = expectedBytes[step.id], e != b { mismatches.append("\(step.id): measured \(b) expected \(e)") }
        }
        expect(mismatches.isEmpty, "bytes removed per item equal the sizes measured before cleaning" + (mismatches.isEmpty ? "" : " (\(mismatches.joined(separator: "; ")))"))
        expect(s.deletedMeasured == measuredSum, "summary deleted (measured) equals the sum of the steps: \(s.deletedMeasured)")
        expect(s.movedToTrash == trashSum && trashSum >= 64 * 1024, "Trash moves are counted separately: \(s.movedToTrash)")
        expect(s.deleted == s.deletedMeasured + s.deletedReported, "deleted = measured + reported")
        expect(s.freeDelta == 1_000, "free-space change comes from the before/after readings")
        var h1 = CleanSummary(); h1.deletedMeasured = 10_000; h1.before.free = 50_000; h1.after.free = 50_000
        expect(h1.heldBack == 10_000, "nothing freed: everything is reported as held back")
        h1.after.free = 54_000
        expect(h1.heldBack == 6_000, "partly freed: the rest is held back")
        h1.after.free = 70_000
        expect(h1.heldBack == 0, "more freed than deleted: nothing held back")
        h1.after.free = 40_000
        expect(h1.heldBack == 10_000 && h1.freeDelta == -10_000, "free space went down: all of it held back, negative delta reported")

        print("\n\(passed) passed, \(failures.count) failed. Test files are in \(run).")
        return failures.isEmpty
    }
}
