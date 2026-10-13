import Foundation
import Observation

/// One tweak plus its live state. Each card observes only its own item, so updates re-render one card.
@MainActor @Observable
final class TweakItem: Identifiable {
    enum Phase: Equatable { case idle, detecting, applying, reverting }
    let tweak: Tweak
    nonisolated var id: String { tweak.id }
    var detection: Detection? = nil
    var phase: Phase = .idle
    /// Failure reason or a note such as "takes effect after logout".
    var message: String? = nil
    var failed = false
    init(_ t: Tweak) { tweak = t }
    var state: TweakState { detection?.state ?? .unknown }
    var isBusy: Bool { phase == .applying || phase == .reverting }
    var isApplicable: Bool { state != .notApplicable }
}

@MainActor @Observable
final class TweakStore {
    static let shared = TweakStore()
    let items: [TweakItem]
    private let byID: [String: TweakItem]
    var detecting = false
    var lastDetect: Date? = nil
    /// Number of tweaks in the batch currently running (0 = idle).
    var running = 0
    private var prunedSnapshots = false

    init() {
        var seen = Set<String>()
        var list: [TweakItem] = []
        for t in TweakCatalog.all {
            if seen.insert(t.id).inserted { list.append(TweakItem(t)) }
            else { ActivityLog.post(.warning, "Duplicate tweak id \(t.id) ignored") }
        }
        items = list
        byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    var tweaks: [Tweak] { items.map(\.tweak) }
    func item(_ id: String) -> TweakItem? { byID[id] }
    func tweak(_ id: String) -> Tweak? { byID[id]?.tweak }
    func state(_ t: Tweak) -> TweakState { byID[t.id]?.state ?? .unknown }

    /// Eight at a time; each card updates as its result arrives.
    func detectAll() async {
        guard !detecting else { return }
        detecting = true
        defer { detecting = false; lastDetect = Date() }
        await ProbeCache.shared.invalidate()
        _ = await Machine.profile()
        await Machine.refreshNetwork()
        if !prunedSnapshots { prunedSnapshots = true; Task.detached { await SnapshotHelper.pruneOwnSnapshots() } }
        let list = items.map(\.tweak)
        await withTaskGroup(of: (String, Detection).self) { g in
            var it = list.makeIterator()
            for _ in 0..<8 { if let t = it.next() { g.addTask { (t.id, await TweakEngine.detect(t)) } } }
            for await (id, d) in g {
                if let item = byID[id], item.phase == .idle || item.phase == .detecting { item.detection = d }
                if let t = it.next() { g.addTask { (t.id, await TweakEngine.detect(t)) } }
            }
        }
    }

    func redetect(_ ids: [String]) async {
        await ProbeCache.shared.invalidate()
        for id in ids { if let item = byID[id] { item.detection = await TweakEngine.detect(item.tweak) } }
    }

    func apply(_ list: [Tweak]) async { await run(list, revert: false) }
    func revert(_ list: [Tweak]) async { await run(list, revert: true) }
    func apply(_ t: Tweak) async { await run([t], revert: false) }
    func revert(_ t: Tweak) async { await run([t], revert: true) }
    func applyAll(_ list: [Tweak]) async { await run(list, revert: false) }

    private func run(_ list: [Tweak], revert: Bool) async {
        let targets = list.compactMap { byID[$0.id] }.filter { !$0.isBusy }
        guard !targets.isEmpty else { return }
        for i in targets { i.phase = revert ? .reverting : .applying; i.message = nil; i.failed = false }
        running += targets.count
        AppState.shared.busyMessage = revert ? "Restoring \(targets.count == 1 ? "“\(targets[0].tweak.name)”" : "\(targets.count) settings")…"
                                             : "Applying \(targets.count == 1 ? "“\(targets[0].tweak.name)”" : "\(targets.count) changes")…"
        let tweaks = targets.map(\.tweak)
        let outcomes = revert ? await TweakEngine.revert(tweaks) : await TweakEngine.apply(tweaks)
        await ProbeCache.shared.invalidate()
        let fresh = await withTaskGroup(of: (String, Detection).self) { g -> [String: Detection] in
            for i in targets { let t = i.tweak; g.addTask { (t.id, await TweakEngine.detect(t)) } }
            var d: [String: Detection] = [:]
            for await (id, det) in g { d[id] = det }
            return d
        }
        for i in targets {
            switch outcomes[i.id] {
            case .done(_, let note): i.message = note
            case .failed(let why): i.message = why; i.failed = true
            case .skipped(let why): i.message = why == "Already on" ? nil : why
            case .none: break
            }
            if let d = fresh[i.id] { i.detection = d }
            i.phase = .idle
        }
        running -= targets.count
        AppState.shared.busyMessage = nil
        let ok = outcomes.values.filter(\.isSuccess).count
        let bad = outcomes.values.filter { if case .failed = $0 { return true }; return false }.count
        if targets.count > 1 { ActivityLog.shared.log(bad == 0 ? .success : .warning, "\(revert ? "Restore" : "Apply") finished: \(ok) done, \(bad) failed, \(targets.count - ok - bad) skipped") }
    }

    var recommendedPending: [Tweak] {
        items.filter { $0.tweak.recommended && !$0.tweak.isManual && [.off, .partlyOn].contains($0.state) }.map(\.tweak)
    }

    /// Plain-text table for `--detect`.
    func table() -> String {
        var lines = ["ID | Category | Name | State | Risk | Impact | Rec | Values"]
        for i in items.sorted(by: { ($0.tweak.category.rawValue, $0.tweak.name) < ($1.tweak.category.rawValue, $1.tweak.name) }) {
            let t = i.tweak, d = i.detection
            let vals = (d?.values ?? []).map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
            lines.append("\(t.id) | \(t.category.rawValue) | \(t.name) | \(d?.state.rawValue ?? "?") | \(t.risk.rawValue) | \(t.impact.rawValue) | \(t.recommended ? "rec" : "opt-in") | \(vals)\(d?.note.map { " (\($0))" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}

/// Safety snapshot before the first change. A local snapshot pins deleted blocks, so Keel removes its own
/// after a day and never touches snapshots it did not create.
enum SnapshotHelper {
    static let defaultsKey = "keelSafetySnapshots"
    static let keepFor: TimeInterval = 24 * 3600

    static var ownSnapshots: [String] { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }

    static func date(of name: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: name)
    }

    /// `tmutil localsnapshot` needs no admin and no Time Machine destination.
    @MainActor static func takeLocalSnapshot() async -> Bool {
        AppState.shared.busyMessage = "Taking a local APFS snapshot…"
        defer { AppState.shared.busyMessage = nil }
        guard let r = try? await Shell.run("/usr/bin/tmutil", ["localsnapshot"], timeout: 120) else { ActivityLog.shared.error("tmutil localsnapshot could not run"); return false }
        ActivityLog.shared.command("tmutil localsnapshot", detail: r.combined)
        guard r.ok, let rg = r.combined.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}", options: .regularExpression) else {
            ActivityLog.shared.warning("Snapshot not created: \(r.combined)")
            return false
        }
        let name = String(r.combined[rg])
        UserDefaults.standard.set(ownSnapshots + [name], forKey: defaultsKey)
        ActivityLog.shared.success("Safety snapshot \(name) created; Keel deletes it automatically after 24 hours")
        return true
    }

    /// Deletes Keel's own snapshots older than `age` and returns the count.
    @discardableResult
    static func pruneOwnSnapshots(olderThan age: TimeInterval = keepFor) async -> Int {
        let mine = ownSnapshots
        guard !mine.isEmpty else { return 0 }
        let listed = (await Shell.probe("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], ttl: 0))?.stdout ?? ""
        var keep: [String] = [], removed = 0
        for name in mine {
            guard listed.contains(name) else { continue }                  // already gone
            if let d = date(of: name), Date().timeIntervalSince(d) < age { keep.append(name); continue }
            let r = try? await Shell.run("/usr/bin/tmutil", ["deletelocalsnapshots", name], timeout: 120)
            if r?.ok == true { removed += 1; ActivityLog.post(.success, "Deleted Keel's safety snapshot \(name)", detail: r?.combined) }
            else { keep.append(name); ActivityLog.post(.warning, "Could not delete safety snapshot \(name)", detail: r?.combined) }
        }
        UserDefaults.standard.set(keep, forKey: defaultsKey)
        return removed
    }
}
