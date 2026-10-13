import Foundation
import Observation

/// State for the benchmark page and `--benchmark`. Main-actor, but measuring happens in a detached task
/// and on dedicated threads, so the window stays responsive and a run can be cancelled at any point.
@MainActor @Observable
final class BenchmarkRunner {
    static let shared = BenchmarkRunner()
    var runs: [BenchmarkRun] = []
    var running = false
    var cancelling = false
    var currentTest: String = ""
    var progress: Double = 0
    var status: [BenchmarkTest: TestStatus] = [:]
    var selectedTests: Set<BenchmarkTest> { didSet { saveSelection() } }
    var compareA: UUID? = nil
    var compareB: UUID? = nil
    var conditions: Conditions? = nil
    var lastError: String? = nil

    private var cancelFlag: CancelFlag?
    private var runTask: Task<[BenchmarkResult], Never>?
    private var plannedWeight = 1.0
    private var doneWeight = 0.0
    private var activeWeight = 0.0
    private static let deselectedKey = "benchmark.deselectedTests"

    init() {
        // Store what the user turned off, so tests added in later versions are on by default.
        let off = Set((UserDefaults.standard.stringArray(forKey: Self.deselectedKey) ?? []).compactMap(BenchmarkTest.init(rawValue:)))
        selectedTests = Set(BenchmarkTest.allCases).subtracting(off)
        reload()
    }

    private func saveSelection() {
        let off = BenchmarkTest.allCases.filter { !selectedTests.contains($0) }.map(\.rawValue)
        UserDefaults.standard.set(off, forKey: Self.deselectedKey)
    }

    func reload() {
        runs = BenchmarkStore.all()
        if compareA != nil, !runs.contains(where: { $0.id == compareA }) { compareA = nil }
        if compareB != nil, !runs.contains(where: { $0.id == compareB }) { compareB = nil }
        if compareA == nil { compareA = runs.first?.id }
    }

    func refreshConditions() async {
        conditions = await RunConditions.capture()
    }

    // MARK: Run

    func run(label: String) async {
        guard !running else { return }
        let tests = BenchmarkTest.allCases.filter { selectedTests.contains($0) }
        guard !tests.isEmpty else { return }
        running = true; cancelling = false; lastError = nil
        status = Dictionary(uniqueKeysWithValues: tests.map { ($0, TestStatus.pending) })
        plannedWeight = tests.reduce(0) { $0 + $1.weight }; doneWeight = 0; activeWeight = 0
        progress = 0; currentTest = "Checking conditions"
        let log = ActivityLog.shared
        log.info("Benchmark started: \(tests.map(\.rawValue).joined(separator: ", "))")

        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical], reason: "Keel benchmark")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            running = false; cancelling = false; currentTest = ""; runTask = nil; cancelFlag = nil
        }

        let started = Date()
        let t0 = nowNS()
        let before = await RunConditions.capture()
        conditions = before
        let flag = CancelFlag()
        cancelFlag = flag
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> [BenchmarkResult] in
            let engine = BenchmarkEngine(tests: tests, cancel: flag) { ev in await self?.handle(ev) }
            return await engine.execute()
        }
        runTask = task
        let results = await task.value

        if flag.isCancelled {
            for (t, s) in status where s == .pending || s == .running { status[t] = .cancelled }
            progress = 0
            log.warning("Benchmark cancelled; nothing saved")
            return
        }
        progress = 1
        currentTest = "Saving"
        let after = await RunConditions.capture()
        conditions = after
        let meta = await RunConditions.metadata(before: before, after: after, duration: Double(nowNS() - t0) / 1e9)
        let ordered = BenchmarkTest.allCases.compactMap { t in results.first { $0.testID == t.rawValue } }
        let run = BenchmarkRun(id: UUID(), date: started, label: label.trimmingCharacters(in: .whitespaces).isEmpty ? "Run \(runs.count + 1)" : label,
                               afterReboot: before.freshBoot, minutesSinceBoot: before.minutesSinceBoot,
                               onAC: before.onAC, powerMode: before.powerMode, results: ordered, meta: meta)
        BenchmarkStore.save(run)
        // The new run becomes B against the current A (or the previous run).
        let previousA = compareA ?? runs.first?.id
        reload()
        compareA = previousA ?? run.id
        compareB = previousA == nil ? nil : run.id
        let valid = ordered.filter(\.isValid)
        log.success("Benchmark “\(run.label)” saved (\(valid.count) of \(ordered.count) tests measured)",
                    detail: ordered.map { $0.isValid ? "\($0.name): \(f1($0.value)) \($0.unit)" : "\($0.name): \($0.skipped ?? "skipped")" }.joined(separator: "\n"))
    }

    func cancel() {
        guard running, !cancelling else { return }
        cancelling = true
        currentTest = "Cancelling"
        cancelFlag?.cancel()
        runTask?.cancel()
    }

    private func handle(_ ev: BenchEvent) {
        switch ev {
        case .status(let t, let s):
            let was = status[t]
            status[t] = s
            if s == .running {
                if was != .running { activeWeight += t.weight }
                currentTest = t.rawValue
            } else if was == .running {
                activeWeight -= t.weight; doneWeight += t.weight
            }
            progress = min(1, doneWeight / plannedWeight)
        case .sub(let x):
            progress = min(1, (doneWeight + activeWeight * x) / plannedWeight)
        }
    }

    // MARK: Edit

    func delete(_ r: BenchmarkRun) { BenchmarkStore.delete(r); reload() }

    func rename(_ r: BenchmarkRun, to label: String) {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, var copy = runs.first(where: { $0.id == r.id }) else { return }
        copy.label = l
        BenchmarkStore.save(copy)
        reload()
    }

    func run(_ id: UUID?) -> BenchmarkRun? { id.flatMap { i in runs.first { $0.id == i } } }

    /// Valid values of one test across runs, oldest first, for the sparkline.
    func history(_ t: BenchmarkTest) -> [(date: Date, value: Double, id: UUID)] {
        runs.reversed().compactMap { r in r.result(t).flatMap { $0.isValid ? (r.date, $0.value, r.id) : nil } }
    }

    nonisolated static func minutesSinceBoot() async -> Int { RunConditions.minutesSinceBoot() }
}
