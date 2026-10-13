import Foundation
import Observation

/// Coalesced tweak state. Views read this instead of `TweakStore.items` so a detection pass
/// re-renders them at most every 80 ms instead of once per tweak.
@MainActor @Observable
final class TweakDigest {
    static let shared = TweakDigest()

    struct CategoryStat: Equatable {
        var total = 0, applicable = 0, on = 0
        var recommendedPending: [String] = []
    }

    private(set) var states: [String: TweakState] = [:]
    private(set) var busy: Set<String> = []
    private(set) var failed: Set<String> = []
    /// Recommended, automatic, currently off or partly on (catalog order).
    private(set) var recommendedPending: [String] = []
    /// Recommended manual tweaks that are applicable and not on. Opt-in ones stay off Overview.
    private(set) var manualPending: [String] = []
    private(set) var partlyOn: [String] = []
    private(set) var onCount = 0
    private(set) var applicableCount = 0
    private(set) var detectedCount = 0
    private(set) var categories: [TweakCategory: CategoryStat] = [:]
    private(set) var filterCounts: [TweakFilter: Int] = [:]
    /// Applicable tweaks per audience.
    private(set) var audienceCounts: [Audience: Int] = [:]

    @ObservationIgnored private let store = TweakStore.shared
    @ObservationIgnored private var scheduled = false
    @ObservationIgnored private var started = false

    init() { started = true; recompute() }

    var total: Int { store.items.count }

    func start() {
        guard !started else { return }
        started = true
        recompute()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            scheduled = false
            recompute()
        }
    }

    private func recompute() {
        struct Snapshot {
            var states: [String: TweakState] = [:], busy = Set<String>(), failed = Set<String>()
            var rec: [String] = [], manual: [String] = [], partly: [String] = []
            var on = 0, applicable = 0, detected = 0
            var cats: [TweakCategory: CategoryStat] = [:]
            var counts: [TweakFilter: Int] = [:]
            var audiences: [Audience: Int] = [:]
        }
        let items = store.items
        let s = withObservationTracking {
            var s = Snapshot()
            for i in items {
                let t = i.tweak
                let st = i.state
                let isBusy = i.isBusy
                s.states[t.id] = st
                if isBusy { s.busy.insert(t.id) }
                if i.failed { s.failed.insert(t.id) }
                if i.detection != nil { s.detected += 1 }
                var c = s.cats[t.category] ?? CategoryStat()
                c.total += 1
                if st != .notApplicable {
                    s.applicable += 1; c.applicable += 1
                    for a in TweakAudiences.of(t.id) { s.audiences[a, default: 0] += 1 }
                }
                if st == .on { s.on += 1; c.on += 1 }
                if st == .partlyOn { s.partly.append(t.id) }
                if t.recommended && !t.isManual && (st == .off || st == .partlyOn) { s.rec.append(t.id); c.recommendedPending.append(t.id) }
                if t.isManual && t.recommended && st != .on && st != .notApplicable && st != .unknown { s.manual.append(t.id) }
                s.cats[t.category] = c
                for f in TweakFilter.allCases where TweakFilters.matches(t, state: st, filter: f) { s.counts[f, default: 0] += 1 }
            }
            return s
        } onChange: { [weak self] in
            Task { @MainActor in self?.schedule() }
        }
        if states != s.states { states = s.states }
        if busy != s.busy { busy = s.busy }
        if failed != s.failed { failed = s.failed }
        if recommendedPending != s.rec { recommendedPending = s.rec }
        if manualPending != s.manual { manualPending = s.manual }
        if partlyOn != s.partly { partlyOn = s.partly }
        if onCount != s.on { onCount = s.on }
        if applicableCount != s.applicable { applicableCount = s.applicable }
        if detectedCount != s.detected { detectedCount = s.detected }
        if categories != s.cats { categories = s.cats }
        if filterCounts != s.counts { filterCounts = s.counts }
        if audienceCounts != s.audiences { audienceCounts = s.audiences }
    }

    func state(_ id: String) -> TweakState { states[id] ?? .unknown }
    var recommendedPendingTweaks: [Tweak] { recommendedPending.compactMap { store.tweak($0) } }
}
