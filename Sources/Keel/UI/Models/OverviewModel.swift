import SwiftUI
import Observation

struct AttentionItem: Identifiable, Equatable {
    enum Severity: Int, Comparable { case fail = 0, warn = 1, info = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    let id: String
    var severity: Severity
    var symbol: String
    var title: String
    var detail: String
    var value: String? = nil
    var actionLabel: String? = nil
    var action: AttentionAction? = nil

    var color: Color {
        switch severity { case .fail: return Theme.fail; case .warn: return Theme.warn; case .info: return Theme.neutral }
    }
}

/// The "Needs attention" and "Only you can do these" lists. Published only when they change.
@MainActor @Observable
final class OverviewModel {
    static let shared = OverviewModel()
    private(set) var attention: [AttentionItem] = []
    private(set) var manual: [AttentionItem] = []

    @ObservationIgnored private let info = SystemInfo.shared
    @ObservationIgnored private let digest = TweakDigest.shared
    @ObservationIgnored private let store = TweakStore.shared
    @ObservationIgnored private var scheduled = false
    @ObservationIgnored private var started = false

    init() { started = true; recompute() }

    func start() {
        guard !started else { return }
        started = true
        recompute()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            scheduled = false
            recompute()
        }
    }

    private func recompute() {
        let (a, m) = withObservationTracking { build() } onChange: { [weak self] in
            Task { @MainActor in self?.schedule() }
        }
        if a != attention { attention = a }
        if m != manual { manual = m }
    }

    /// First existing tweak among known IDs, else the first that matches.
    private func tweakID(_ ids: [String], _ match: (Tweak) -> Bool = { _ in false }) -> String? {
        for id in ids where store.item(id) != nil { return id }
        return store.items.first { match($0.tweak) }?.id
    }

    private func build() -> ([AttentionItem], [AttentionItem]) {
        var out: [AttentionItem] = []
        let mem = info.memory, st = info.storage, bat = info.battery, net = info.network, cpu = info.cpu
        let states = digest.states

        if st.containerBytes > 0 && st.availablePercent < 15 {
            out.append(.init(id: "space", severity: st.availablePercent < 8 ? .fail : .warn, symbol: "internaldrive",
                             title: String(format: "Only %.0f%% of the disk is available", st.availablePercent),
                             detail: "APFS slows down and updates fail when space runs low. Cleanup lists measured candidates.",
                             value: max(st.freeBytes, st.importantAvailableBytes).humanBytes, actionLabel: "Cleanup", action: .page(.cleanup)))
        }
        if st.containerBytes > 0, st.purgeableBytes > max(20 * 1_073_741_824, st.containerBytes / 20), !st.localSnapshots.isEmpty {
            let id = tweakID(["tm-thin-local-snapshots", "thin-local-snapshots"]) { $0.id.contains("snapshot") && !$0.isManual }
            out.append(.init(id: "snapshots", severity: .info, symbol: "clock.arrow.circlepath",
                             title: "\(st.purgeableBytes.humanBytes) is held as purgeable space",
                             detail: "\(st.localSnapshots.count) local snapshot\(st.localSnapshots.count == 1 ? "" : "s") keep deleted files on disk until macOS needs the space. Free space looks lower than it is.",
                             value: nil, actionLabel: id == nil ? "Cleanup" : "Open", action: id.map { .tweak($0) } ?? .page(.cleanup)))
        }

        if mem.pressure != .normal || mem.swapUsedBytes > 2 * 1_073_741_824 {
            let top = info.topMemory.first.map { " Largest: \($0.name) at \($0.rssBytes.humanBytes)." } ?? ""
            out.append(.init(id: "memory", severity: mem.pressure == .critical ? .fail : .warn, symbol: "memorychip",
                             title: mem.pressure == .normal ? "\(mem.swapUsedBytes.humanBytes) of swap in use" : "Memory pressure is \(mem.pressure.rawValue)",
                             detail: "macOS is compressing and swapping memory.\(top)",
                             value: nil, actionLabel: "Activity Monitor", action: .app("/System/Applications/Utilities/Activity Monitor.app")))
        }

        if info.simulatorProcesses > 0 {
            let n = max(info.simulatorProcesses, info.bootedSimulators.count)
            let names = info.bootedSimulators.isEmpty ? "" : info.bootedSimulators.joined(separator: ", ") + ". "
            let id = tweakID(["simulators-shutdown"]) { $0.id.contains("simulator") && !$0.isManual }
            let simMem = info.topMemory.first { $0.name == "Simulator devices" }.map { $0.rssBytes.humanBytes }
            out.append(.init(id: "sims", severity: .warn, symbol: "iphone",
                             title: "\(n) simulator device\(n == 1 ? " is" : "s are") booted",
                             detail: "\(names)A booted device keeps its processes in memory after Simulator.app is closed.",
                             value: simMem, actionLabel: id == nil ? nil : "Shut down", action: id.map { .tweak($0) }))
        }

        if bat.present, bat.powerModeBattery == "2" {
            let id = tweakID(["power-battery-automatic"]) { t in
                if case .pmset(let s) = t.mechanism { return s.contains { $0.key == "powermode" && $0.scope == .battery } }
                return false
            }
            out.append(.init(id: "highpower", severity: .warn, symbol: "bolt",
                             title: "High Power Mode is set for battery",
                             detail: "It raises clocks and fan speed on battery and drains it faster.",
                             value: nil, actionLabel: "Open", action: id.map { .tweak($0) } ?? .url(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)))
        }
        if bat.present, bat.healthPercent > 0, bat.healthPercent < 80 || bat.condition.lowercased().contains("service") {
            out.append(.init(id: "battery", severity: .warn, symbol: "battery.25percent",
                             title: "Battery capacity is \(bat.healthPercent)%",
                             detail: bat.condition.isEmpty ? "Below 80% of its design capacity." : "macOS reports: \(bat.condition).",
                             value: "\(bat.cycleCount) cycles", actionLabel: "Battery settings", action: .url(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)))
        }
        if cpu.thermal == .serious || cpu.thermal == .critical {
            out.append(.init(id: "thermal", severity: cpu.thermal == .critical ? .fail : .warn, symbol: "thermometer.medium",
                             title: "The Mac is throttling (thermal state \(cpu.thermalLabel.lowercased()))",
                             detail: "macOS is lowering clock speeds to cool down. Check what is using the CPU.",
                             value: info.topCPU.first.map { "\($0.name) \(Int($0.cpu))%" }, actionLabel: "Activity Monitor", action: .app("/System/Applications/Utilities/Activity Monitor.app")))
        }

        if net.kind == .wifi, net.awdlUp {
            if let id = tweakID(["awdl-session-down"], { $0.id.contains("awdl") }), states[id] != .on, states[id] != .notApplicable {
                out.append(.init(id: "awdl", severity: .info, symbol: "dot.radiowaves.left.and.right",
                                 title: "AWDL is up on Wi-Fi",
                                 detail: "AirDrop and Continuity scan on other channels and can cause short latency spikes.",
                                 value: nil, actionLabel: "Open", action: .tweak(id)))
            }
        }
        if net.kind == .wifi, net.wifi.connected, net.wifi.rssi < -72 {
            out.append(.init(id: "signal", severity: .info, symbol: "wifi.exclamationmark",
                             title: "Weak Wi-Fi signal (\(net.wifi.rssi) dBm)",
                             detail: "Below about -70 dBm the link rate drops and retries rise. Moving closer to the router helps more than any setting.",
                             value: nil))
        }

        for id in digest.failed {
            guard let item = store.item(id) else { continue }
            out.append(.init(id: "failed-\(id)", severity: .fail, symbol: "xmark.octagon",
                             title: "“\(item.tweak.name)” did not apply", detail: item.message ?? "See Activity for the details.",
                             actionLabel: "Open", action: .tweak(id)))
        }
        for id in digest.partlyOn.filter({ store.tweak($0).map { !$0.isManual && !$0.oneShot } ?? false }).prefix(3) {
            guard let t = store.tweak(id), !t.isManual, !t.oneShot, !digest.failed.contains(id) else { continue }
            out.append(.init(id: "partly-\(id)", severity: .warn, symbol: "circle.lefthalf.filled",
                             title: "“\(t.name)” is only partly on", detail: "Something changed part of it back, or it was set by hand.",
                             actionLabel: "Open", action: .tweak(id)))
        }
        let rec = digest.recommendedPending.filter { !digest.partlyOn.contains($0) }
        let strong = rec.compactMap { store.tweak($0) }.filter { $0.impact == .high || $0.impact == .medium }.prefix(3)
        for t in strong {
            out.append(.init(id: "rec-\(t.id)", severity: .info, symbol: t.category.symbol,
                             title: t.name, detail: t.summary, value: nil, actionLabel: "Open", action: .tweak(t.id)))
        }
        if rec.count > strong.count {
            out.append(.init(id: "rec-all", severity: .info, symbol: "checklist",
                             title: strong.isEmpty ? "\(digest.recommendedPending.count) recommended change\(digest.recommendedPending.count == 1 ? " is" : "s are") off" : "\(rec.count - strong.count) more recommended change\(rec.count - strong.count == 1 ? "" : "s")",
                             detail: "Safe for almost every Mac. Each one shows exactly what it runs before anything changes.",
                             value: nil, actionLabel: "Review", action: .tweaks(.recommended)))
        }
        out.sort { $0.severity < $1.severity }

        var man: [AttentionItem] = []
        for id in digest.manualPending {
            guard let t = store.tweak(id) else { continue }
            man.append(.init(id: "m-\(id)", severity: .info, symbol: t.category.symbol, title: t.name, detail: t.summary, actionLabel: "Open", action: .tweak(id)))
        }
        if info.hasFullDiskAccess == false {
            man.append(.init(id: "fda", severity: .info, symbol: "lock.shield",
                             title: "Full Disk Access for Keel",
                             detail: "Lets Cleanup measure Mail downloads, iOS backups and the Trash. Optional.",
                             actionLabel: "Open Settings", action: .url(FullDiskAccess.settingsURL)))
        }
        switch HelperManager.shared.state {
        case .needsApproval:
            man.append(.init(id: "helper", severity: .warn, symbol: "person.badge.shield.checkmark",
                             title: "Approve Keel's helper", detail: "Turn on Keel in Login Items & Extensions so admin changes stop asking for a password.",
                             actionLabel: "Open Login Items", action: .installHelper))
        default: break
        }
        if info.storage.fileVaultOn == false {
            man.append(.init(id: "filevault", severity: .warn, symbol: "lock.laptopcomputer",
                             title: "FileVault is off", detail: "The disk is not encrypted. Turn it on in Privacy & Security.",
                             actionLabel: "Open Settings", action: .url(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault")!)))
        }
        return (out, man)
    }
}
