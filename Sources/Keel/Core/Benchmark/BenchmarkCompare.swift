import Foundation

/// A/B comparison: Δ%, a noise band, and which differences in conditions make Δ unreliable.
enum BenchmarkCompare {
    enum Verdict: Sendable { case better, worse, noise }

    struct Delta: Sendable {
        let percent: Double          // (B − A) / A × 100
        let band: Double             // ± % treated as noise
        let verdict: Verdict
    }

    /// Noise band: the test's typical spread, widened by either run's best-of-N spread. Latency tests with
    /// many samples use the default only, since their range is the distribution, not measurement noise.
    static func band(_ t: BenchmarkTest?, _ a: BenchmarkResult, _ b: BenchmarkResult) -> Double {
        var band = t?.defaultNoiseBand ?? 5
        for s in [a.samples, b.samples] where s.count >= 2 && s.count <= 5 {
            if let h = Stats.halfRangePercent(s) { band = max(band, h) }
        }
        return band
    }

    static func delta(_ a: Double, _ b: Double, higherIsBetter: Bool, band: Double) -> Delta? {
        guard a > 0, b > 0, a.isFinite, b.isFinite else { return nil }
        let pct = (b - a) / a * 100
        let v: Verdict = abs(pct) < band ? .noise : ((higherIsBetter ? pct > 0 : pct < 0) ? .better : .worse)
        return Delta(percent: pct, band: band, verdict: v)
    }

    static func delta(_ t: BenchmarkTest?, _ a: BenchmarkResult, _ b: BenchmarkResult) -> Delta? {
        guard a.isValid, b.isValid, a.unit == b.unit else { return nil }
        return delta(a.value, b.value, higherIsBetter: a.higherIsBetter, band: band(t, a, b))
    }

    /// Differences between two runs' conditions that can move results on their own.
    static func conditionDifferences(_ a: BenchmarkRun, _ b: BenchmarkRun) -> [String] {
        var out: [String] = []
        if a.onAC != b.onAC { out.append("Power source differs (\(a.onAC ? "AC" : "battery") vs \(b.onAC ? "AC" : "battery"))") }
        if a.powerMode != b.powerMode { out.append("Energy mode differs (\(PowerModeName.name(a.powerMode)) vs \(PowerModeName.name(b.powerMode)))") }
        if a.afterReboot != b.afterReboot { out.append("Only one run was within 15 minutes of a restart") }
        if let ma = a.meta, let mb = b.meta {
            if ma.buildConfig != mb.buildConfig { out.append("Different Keel builds (\(ma.buildConfig) vs \(mb.buildConfig)): CPU and latency kernels are not comparable") }
            if ma.modelID != mb.modelID || ma.chip != mb.chip { out.append("Different Macs (\(ma.chip) vs \(mb.chip))") }
            if ma.thermalBefore != mb.thermalBefore { out.append("Thermal state differed at start (\(ma.thermalBefore) vs \(mb.thermalBefore))") }
            if (ma.pressureBefore ?? 1) != (mb.pressureBefore ?? 1) { out.append("Memory pressure differed at start") }
            if ma.osBuild != mb.osBuild { out.append("macOS changed (\(ma.osVersion) \(ma.osBuild) → \(mb.osVersion) \(mb.osBuild))") }
        } else if (a.meta == nil) != (b.meta == nil) {
            out.append("One run is from an older Keel: some tests were measured differently (CPU samples were ~30 ms, pings reported the mean)")
        }
        return out
    }
}

/// pmset powermode names. Duplicated from the Overview page's `PowerMode` so this module stands alone.
enum PowerModeName {
    static func name(_ v: String) -> String {
        switch v { case "0": return "Automatic"; case "1": return "Low Power"; case "2": return "High Power"; default: return v.isEmpty ? "—" : v }
    }
}

/// Markdown and JSON export of a run (optionally against another).
enum BenchmarkExport {
    static func json(_ r: BenchmarkRun) -> Data? { try? BenchmarkStore.encoder().encode(r) }

    static func markdown(_ r: BenchmarkRun, against a: BenchmarkRun? = nil) -> String {
        var s = "# Keel benchmark: \(r.label)\n\n"
        s += "- Date: \(r.date.formatted(date: .abbreviated, time: .shortened))\n"
        if let m = r.meta {
            s += "- Mac: \(m.modelName) (\(m.modelID)), \(m.chip), \(m.perfCores)P + \(m.effCores)E CPU\(m.gpuCores.map { ", \($0)-core GPU" } ?? ""), \(m.memoryGB) GB\n"
            s += "- macOS \(m.osVersion) (\(m.osBuild)), Keel \(m.keelVersion) \(m.buildConfig)\n"
            s += "- Thermal \(m.thermalBefore) → \(m.thermalAfter ?? "?"), memory pressure \(m.pressureBefore.map(String.init) ?? "?") → \(m.pressureAfter.map(String.init) ?? "?"), load average \(m.loadAvgBefore.map { String(format: "%.1f", $0) } ?? "?")\n"
            if let f = m.fanRPMBefore, !f.isEmpty { s += "- Fans \(f.map { String(format: "%.0f", $0) }.joined(separator: "/")) → \((m.fanRPMAfter ?? []).map { String(format: "%.0f", $0) }.joined(separator: "/")) rpm\n" }
            if let t = m.socTempBefore { s += String(format: "- Hottest SoC sensor %.0f → %.0f °C\n", t, m.socTempAfter ?? 0) }
            if let d = m.durationSeconds { s += String(format: "- Duration %.0f s\n", d) }
        }
        s += "- Power: \(r.onAC ? "AC" : "battery"), energy mode \(PowerModeName.name(r.powerMode)), \(r.minutesSinceBoot) min after boot\(r.afterReboot ? " (fresh boot)" : "")\n\n"
        if let a {
            s += "Compared with **\(a.label)** (\(a.date.formatted(date: .abbreviated, time: .shortened))).\n\n"
            let diffs = BenchmarkCompare.conditionDifferences(a, r)
            if !diffs.isEmpty { s += diffs.map { "> \($0)" }.joined(separator: "\n") + "\n\n" }
            s += "| Test | \(a.label) | \(r.label) | Δ | Noise |\n|---|---:|---:|---:|---:|\n"
        } else {
            s += "| Test | Result | Median | Notes |\n|---|---:|---:|---|\n"
        }
        for t in BenchmarkTest.allCases {
            guard let x = r.result(t) ?? a?.result(t) else { continue }
            let mine = r.result(t)
            let val = mine.map { $0.isValid ? "\(fmtValue($0.value)) \($0.unit)" : "—" } ?? "—"
            if let a {
                let ax = a.result(t)
                let av = ax.map { $0.isValid ? "\(fmtValue($0.value)) \($0.unit)" : "—" } ?? "—"
                var d = "—", n = "—"
                if let ax, let mine, let dl = BenchmarkCompare.delta(t, ax, mine) { d = String(format: "%+.1f%%", dl.percent); n = String(format: "±%.0f%%", dl.band) }
                s += "| \(t.rawValue) | \(av) | \(val) | \(d) | \(n) |\n"
            } else {
                let med = x.median.map { "\(fmtValue($0)) \(x.unit)" } ?? "—"
                let note = (x.skipped ?? x.detail).replacingOccurrences(of: "\n", with: "; ").replacingOccurrences(of: "|", with: "/")
                s += "| \(t.rawValue) | \(val) | \(med) | \(note) |\n"
            }
        }
        s += "\nThroughput tests report the best of three samples; latency tests report the median. Δ inside the noise band is not a real difference.\n"
        return s
    }
}
