import AppKit
import Foundation
import Observation

@MainActor @Observable
final class CleanupModel {
    static let shared = CleanupModel()

    // MARK: Public state (CLI.swift reads items, selectedBytes, scan())
    var items: [CleanupItem] = []
    var scanning = false
    var cleaning = false
    var selected: Set<String> = []
    var lastScan: Date? = nil
    /// Free-space increase of the last cleanup (0 when snapshots held everything).
    var lastFreed: UInt64 = 0
    /// Leaf ids whose size is being measured right now.
    var measuring: Set<String> = []
    var space = VolumeSpace()
    var snapshots: [LocalSnapshot] = []
    var hasFDA = false
    /// Names of owning apps that are running now (drives "Quit <App>").
    var runningOwners: Set<String> = []
    var steps: [CleanStep] = []
    var summary: CleanSummary? = nil
    var scanDuration: TimeInterval = 0

    // UI state that survives page switches.
    var collapsedGroups: Set<String> = []
    var expanded: Set<String> = []
    var sortBySize = true

    /// Desktop, Documents and Downloads are TCC-protected. The app reads them only after the user agrees.
    var includeUserFolders: Bool {
        didSet { UserDefaults.standard.set(includeUserFolders, forKey: "cleanup.includeUserFolders") }
    }

    private var selectionTouched = false
    private var index: [String: (Int, Int?)] = [:]
    private var cache: [String: UInt64] = [:]
    private var observers: [NSObjectProtocol] = []

    private static var cacheURL: URL { AppPaths.support.appendingPathComponent("cleanup-sizes.json") }

    init() {
        let cli = CommandLine.arguments.contains("--cleanup-scan") || CommandLine.arguments.contains("--screenshots")
        includeUserFolders = cli || UserDefaults.standard.bool(forKey: "cleanup.includeUserFolders")
        loadCache()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in await CleanupModel.shared.refreshRunning() }
            })
        }
    }

    // MARK: Derived

    var allLeaves: [CleanupItem] { items.flatMap(\.leaves) }

    var selectedLeaves: [CleanupItem] { allLeaves.filter { selected.contains($0.id) && $0.deletable } }

    var selectedBytes: UInt64 { selectedLeaves.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    /// Part of the selection that goes to the Trash (space returns only when the Trash is emptied).
    var selectedTrashBytes: UInt64 {
        selectedLeaves.filter { $0.actions.contains { if case .moveToTrash = $0 { return true }; return false } }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    var selectedCount: Int { selectedLeaves.count }

    /// Part of the selection that will be skipped because its app is open.
    var selectedBlockedBytes: UInt64 { selectedLeaves.filter { isRunning($0.owner) }.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    var progressText: String? {
        guard cleaning else { return nil }
        let done = steps.filter { if case .pending = $0.state { return false }; if case .running = $0.state { return false }; return true }.count
        let current = steps.first { $0.state == .running }?.name
        return "Cleaning \(min(done + 1, steps.count)) of \(steps.count)" + (current.map { ": \($0)" } ?? "")
    }

    func items(in group: CleanupGroup) -> [CleanupItem] { items.filter { $0.group == group } }

    func isRunning(_ owner: OwningApp?) -> Bool { owner.map { runningOwners.contains($0.name) } ?? false }

    // MARK: Selection

    func setSelected(_ id: String, _ on: Bool) {
        selectionTouched = true
        if on { selected.insert(id) } else { selected.remove(id) }
    }

    func setSelected(_ item: CleanupItem, _ on: Bool) {
        selectionTouched = true
        for l in item.leaves where l.deletable && (on ? canSelect(l) : true) {
            if on { selected.insert(l.id) } else { selected.remove(l.id) }
        }
    }

    func selectionState(_ item: CleanupItem) -> Bool? {
        let ls = item.leaves.filter { $0.deletable && canSelect($0) }
        guard !ls.isEmpty else { return false }
        let n = ls.filter { selected.contains($0.id) }.count
        return n == 0 ? false : (n == ls.count ? true : nil)
    }

    /// Leaves with a measured size of 0 cannot be selected (nothing to free); unknown sizes can.
    func canSelect(_ l: CleanupItem) -> Bool { l.deletable && (l.sizeBytes ?? 1) > 0 }

    func selectSnapshots() {
        selectionTouched = true
        for l in items.first(where: { $0.id == "snapshots" })?.leaves ?? [] where l.deletable { selected.insert(l.id) }
        collapsedGroups.remove(CleanupGroup.system.rawValue)
        expanded.insert("snapshots")
    }

    // MARK: Scan

    func scanIfStale() async {
        if scanning || cleaning { return }
        if items.isEmpty || (lastScan.map { Date().timeIntervalSince($0) > 600 } ?? true) { await scan() }
    }

    func scan() async {
        guard !scanning, !cleaning else { return }
        scanning = true
        defer { scanning = false }
        let started = Date()
        ActivityLog.shared.info("Measuring cleanup candidates")
        space = DiskSpace.read()
        let ctx = await CleanupCatalog.context(includeUserFolders: includeUserFolders)
        hasFDA = ctx.hasFDA
        var produced = Set<String>()
        // Deletable items are measured first; list-only folders (repositories, media) can take much longer.
        let fast = Limiter(5), slow = Limiter(2)
        var deletableDone: TimeInterval = 0

        enum Event: Sendable {
            case snapshots([LocalSnapshot])
            case items([CleanupItem])
            case measured(CleanupItem)
        }

        await withTaskGroup(of: Event.self) { group in
            group.addTask { .snapshots(await DiskSpace.localSnapshots()) }
            for p in CleanupCatalog.providers {
                let run = p.run
                group.addTask { .items(await run(ctx)) }
            }
            for await ev in group {
                switch ev {
                case .snapshots(let s):
                    snapshots = s
                case .items(let new):
                    for item in new { produced.insert(item.id); upsert(item) }
                    for leaf in new.flatMap(\.leaves) where Self.needsMeasure(leaf) {
                        measuring.insert(leaf.id)
                        let limiter = leaf.deletable ? fast : slow
                        group.addTask {
                            await limiter.acquire()
                            let t0 = Date()
                            let m = await CleanupScanner.measure(leaf)
                            await limiter.release()
                            if ProcessInfo.processInfo.environment["KEEL_CLEANUP_TIMING"] != nil {
                                FileHandle.standardError.write("measure \(String(format: "%6.2f", Date().timeIntervalSince(t0))) s  \(leaf.id)\n".data(using: .utf8)!)
                            }
                            return .measured(m)
                        }
                    }
                case .measured(let m):
                    apply(m)
                    measuring.remove(m.id)
                    if m.deletable { deletableDone = Date().timeIntervalSince(started) }
                }
            }
        }

        items.removeAll { !produced.contains($0.id) }
        // Stable order by group so every consumer (CLI, UI) sees the same layout.
        let order = Dictionary(uniqueKeysWithValues: CleanupGroup.allCases.enumerated().map { ($1, $0) })
        items = items.enumerated().sorted { (order[$0.element.group]!, $0.offset) < (order[$1.element.group]!, $1.offset) }.map(\.element)
        rebuildIndex()
        let valid = Set(allLeaves.map(\.id))
        selected = selected.filter { valid.contains($0) }
        if !selectionTouched { applyDefaultSelection() }
        await refreshRunning()
        space = DiskSpace.read()
        lastScan = Date()
        scanDuration = Date().timeIntervalSince(started)
        saveCache()
        let deletable = allLeaves.filter(\.deletable).reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        ActivityLog.shared.success("Cleanup scan done in \(String(format: "%.1f", scanDuration)) s (deletable items measured in \(String(format: "%.1f", deletableDone)) s): \(deletable.humanBytes) deletable, \(selectedBytes.humanBytes) selected"
                                   + (snapshots.isEmpty ? "" : "; \(snapshots.count) local snapshot\(snapshots.count == 1 ? "" : "s") may hold up to \(space.purgeable.humanBytes)"))
    }

    private static func needsMeasure(_ l: CleanupItem) -> Bool {
        switch l.measure { case .du, .custom: return true; case .preset, .none: return false }
    }

    /// Inserts or replaces a top-level item. Known sizes stay visible (marked as cached) until re-measured.
    private func upsert(_ fresh: CleanupItem) {
        var item = fresh
        let old = index[item.id].map { items[$0.0] }
        func fill(_ leaf: inout CleanupItem, previous: CleanupItem?) {
            guard leaf.sizeBytes == nil, Self.needsMeasure(leaf) else { return }
            if let p = previous?.sizeBytes { leaf.sizeBytes = p; leaf.sizeFromCache = true }
            else if let c = cache[leaf.id] { leaf.sizeBytes = c; leaf.sizeFromCache = true }
        }
        if item.isParent {
            let oldKids = Dictionary((old?.children ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for i in item.children.indices { fill(&item.children[i], previous: oldKids[item.children[i].id]) }
            recomputeParent(&item)
        } else {
            fill(&item, previous: old)
        }
        if let (i, _) = index[item.id] { items[i] = item } else { items.append(item) }
        rebuildIndex()
        if !selectionTouched {
            for l in item.leaves where l.defaultOn && canSelect(l) && l.sizeBytes != nil && !l.sizeFromCache { selected.insert(l.id) }
        }
    }

    private func apply(_ m: CleanupItem) {
        guard let (i, c) = index[m.id] else { return }
        if let c {
            items[i].children[c].sizeBytes = m.sizeBytes
            items[i].children[c].unreadable = m.unreadable
            items[i].children[c].sizeFromCache = false
            recomputeParent(&items[i])
        } else {
            items[i].sizeBytes = m.sizeBytes
            items[i].unreadable = m.unreadable
            items[i].sizeFromCache = false
        }
        if !selectionTouched, m.defaultOn, m.deletable, (m.sizeBytes ?? 0) > 0 { selected.insert(m.id) }
        if selectionTouched == false, m.sizeBytes == 0 { selected.remove(m.id) }
    }

    private func recomputeParent(_ p: inout CleanupItem) {
        guard p.isParent else { return }
        let sizes = p.children.compactMap(\.sizeBytes)
        // Parents whose own size comes from the catalog (snapshots) keep it while no child has a size.
        var keepPreset = false
        if case .preset = p.measure { keepPreset = sizes.isEmpty }
        if !keepPreset { p.sizeBytes = sizes.isEmpty ? nil : sizes.reduce(0, +) }
        p.unreadable = p.children.contains(where: \.unreadable)
        p.sizeFromCache = p.children.contains(where: \.sizeFromCache)
    }

    private func rebuildIndex() {
        index.removeAll(keepingCapacity: true)
        for (i, it) in items.enumerated() {
            index[it.id] = (i, nil)
            for (c, ch) in it.children.enumerated() { index[ch.id] = (i, c) }
        }
    }

    private func applyDefaultSelection() {
        selected = Set(allLeaves.filter { $0.defaultOn && canSelect($0) && ($0.sizeBytes != nil || !Self.needsMeasure($0)) && ($0.sizeBytes ?? 1) > 0 }.map(\.id))
    }

    // MARK: Running apps

    func refreshRunning() async {
        var owners: [String: OwningApp] = [:]
        for it in items {
            if let o = it.owner { owners[o.name] = o }
            for c in it.children { if let o = c.owner { owners[o.name] = o } }
        }
        var running = Set<String>()
        for (name, o) in owners where await AppControl.isRunning(o) { running.insert(name) }
        runningOwners = running
    }

    func quit(_ owner: OwningApp) async {
        ActivityLog.shared.info("Asking \(owner.name) to quit")
        let ok = await AppControl.quit(owner)
        await refreshRunning()
        if ok { ActivityLog.shared.success("\(owner.name) quit") }
        else { ActivityLog.shared.warning("\(owner.name) is still running", detail: "It may be showing a dialog (unsaved work). Quit it yourself, then clean again.") }
    }

    // MARK: Trash size

    var measuringTrash = false

    /// Asks Finder for the size of the items in the Trash. The first time, macOS asks whether Keel may
    /// control Finder, which is why this never runs during the automatic scan.
    func measureTrashViaFinder() async {
        guard !measuringTrash, let loc = index["trash"], loc.1 == nil else { return }
        let i = loc.0
        measuringTrash = true
        defer { measuringTrash = false }
        let script = """
        tell application "Finder"
            set total to 0
            repeat with f in (get items of trash)
                try
                    set s to physical size of f
                    if s is not missing value then set total to total + s
                end try
            end repeat
            return total
        end tell
        """
        guard let r = try? await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 60), r.ok,
              let n = Double(r.output.replacingOccurrences(of: ",", with: ".")) else {
            ActivityLog.shared.warning("Finder did not report the size of the Trash", detail: "Allow Keel to control Finder in System Settings › Privacy & Security › Automation.")
            return
        }
        items[i].sizeBytes = UInt64(max(0, n))
        items[i].sizeKind = .reported
        items[i].sizeFromCache = false
    }

    // MARK: Clean

    /// Deletes the selected items one by one, measures what each actually removed, and reports deleted bytes
    /// and the free-space change separately (local snapshots can keep deleted blocks allocated).
    func cleanSelected() async {
        guard !cleaning, !scanning else { return }
        let targets = selectedLeaves
        guard !targets.isEmpty else { return }
        cleaning = true
        summary = nil
        steps = targets.map { CleanStep(id: $0.id, name: $0.name) }
        ActivityLog.shared.info("Cleaning \(targets.count) item\(targets.count == 1 ? "" : "s") (\(selectedBytes.humanBytes) selected)")
        let s = await CleanupRunner.run(targets, hooks: .live) { i, step in self.steps[i] = step }
        summary = s
        lastFreed = UInt64(max(0, s.freeDelta))
        ActivityLog.shared.success(CleanupRunner.logLine(s))
        // Start the next round from the defaults again (items that were skipped come back pre-selected).
        selected.removeAll()
        selectionTouched = false
        cleaning = false
        await scan()
    }

    func dismissSummary() { summary = nil; steps = [] }

    // MARK: Size cache (last sizes, shown on relaunch)

    private func loadCache() {
        guard let d = try? Data(contentsOf: Self.cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let sizes = obj["sizes"] as? [String: NSNumber] { cache = sizes.mapValues(\.uint64Value) }
        if let t = obj["date"] as? Double { lastScan = Date(timeIntervalSince1970: t) }
    }

    private func saveCache() {
        var sizes: [String: UInt64] = [:]
        for l in allLeaves where Self.needsMeasure(l) { if let s = l.sizeBytes { sizes[l.id] = s } }
        cache = sizes
        let obj: [String: Any] = ["date": Date().timeIntervalSince1970, "sizes": sizes]
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: Self.cacheURL, options: .atomic) }
    }
}
