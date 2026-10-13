import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

/// Results of run A, or A against B with Δ%, the noise band and a per-test history line.
struct BenchmarkResultsTable: View {
    @Bindable var runner: BenchmarkRunner
    @State private var expanded: Set<BenchmarkTest> = []

    var body: some View {
        if let a = runner.run(runner.compareA) {
            let b = runner.run(runner.compareB)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionTitle(text: b == nil ? "Results: \(a.label)" : "A/B: \(a.label) → \(b!.label)")
                    if let b {
                        ChipButton(text: "Copy A/B as Markdown", selected: false) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(BenchmarkExport.markdown(b, against: a), forType: .string)
                        }
                    }
                    ChipButton(text: expanded.isEmpty ? "Expand all" : "Collapse all", selected: false) {
                        expanded = expanded.isEmpty ? Set(BenchmarkTest.allCases) : []
                    }
                }
                if let b {
                    let diffs = BenchmarkCompare.conditionDifferences(a, b)
                    if !diffs.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(diffs, id: \.self) { d in
                                Label(d, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 10)
                    }
                }
                VStack(spacing: 0) {
                    header(hasB: b != nil)
                    Divider()
                    ForEach(BenchmarkTest.allCases) { t in
                        if a.result(t) != nil || b?.result(t) != nil {
                            row(t, a: a, b: b)
                            Divider()
                        }
                    }
                    // Results from tests this build no longer knows about (kept readable, never compared).
                    ForEach(a.results.filter { BenchmarkTest(rawValue: $0.testID) == nil }) { r in
                        HStack {
                            Text(r.name).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(fmtValue(r.value)) \(r.unit)").font(Theme.mono)
                        }.padding(.vertical, 6)
                        Divider()
                    }
                }
                .card(padding: 12)
                Text("Throughput is the best of three samples; latency is the median. A Δ inside the noise band (±) stays grey: it is not a real difference. Green is better, amber worse.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func header(hasB: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Test").frame(maxWidth: .infinity, alignment: .leading)
            Text("A").frame(width: 120, alignment: .trailing)
            if hasB {
                Text("B").frame(width: 120, alignment: .trailing)
                Text("Δ").frame(width: 70, alignment: .trailing)
                Text("Noise").frame(width: 46, alignment: .trailing)
            }
            Text("History").frame(width: 96, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    func row(_ t: BenchmarkTest, a: BenchmarkRun, b: BenchmarkRun?) -> some View {
        let ra = a.result(t), rb = b?.result(t)
        let open = expanded.contains(t)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
                    Text(t.rawValue).font(.system(size: 12.5)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                valueCell(ra).frame(width: 120, alignment: .trailing)
                if b != nil {
                    valueCell(rb).frame(width: 120, alignment: .trailing)
                    let d = (ra != nil && rb != nil) ? BenchmarkCompare.delta(t, ra!, rb!) : nil
                    deltaText(d).frame(width: 70, alignment: .trailing)
                    Text(d.map { String(format: "±%.0f%%", $0.band) } ?? "").font(Theme.monoSmall).foregroundStyle(.tertiary).frame(width: 46, alignment: .trailing)
                }
                BenchmarkSparkline(points: runner.history(t), a: a.id, b: b?.id).frame(width: 96, height: 22)
            }
            .contentShape(Rectangle())
            .onTapGesture { if open { expanded.remove(t) } else { expanded.insert(t) } }

            if open { detail(t, ra: ra, rb: rb, hasB: b != nil).padding(.leading, 15) }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    func valueCell(_ r: BenchmarkResult?) -> some View {
        if let r, r.isValid {
            Text("\(fmtValue(r.value)) \(r.unit)").font(Theme.mono).lineLimit(1)
        } else if let r {
            Text("skipped").font(Theme.monoSmall).foregroundStyle(.secondary).help(r.skipped ?? r.detail)
        } else {
            Text("—").font(Theme.mono).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    func deltaText(_ d: BenchmarkCompare.Delta?) -> some View {
        if let d {
            Text(String(format: "%+.1f%%", d.percent)).font(Theme.mono)
                .foregroundStyle(d.verdict == .noise ? Theme.neutral : (d.verdict == .better ? Theme.on : Theme.warn))
        } else {
            Text("—").font(Theme.mono).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    func detail(_ t: BenchmarkTest, ra: BenchmarkResult?, rb: BenchmarkResult?, hasB: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.explanation).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Text("Affected by: " + t.affectedBy).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let ra { Text((hasB ? "A: " : "") + (ra.skipped ?? ra.detail)).font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let rb { Text("B: " + (rb.skipped ?? rb.detail)).font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            let keys = metricKeys(ra, rb)
            if !keys.isEmpty {
                VStack(spacing: 3) {
                    ForEach(keys, id: \.self) { k in
                        let ma = ra?.metrics?.first { $0.key == k }, mb = rb?.metrics?.first { $0.key == k }
                        let m = ma ?? mb!
                        HStack(spacing: 8) {
                            Text(m.label).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Text(ma.map { metricValue($0) } ?? "—").font(Theme.monoSmall).frame(width: 120, alignment: .trailing)
                            if hasB {
                                Text(mb.map { metricValue($0) } ?? "—").font(Theme.monoSmall).frame(width: 120, alignment: .trailing)
                                let d = (ma != nil && mb != nil) ? BenchmarkCompare.delta(ma!.value, mb!.value, higherIsBetter: m.higherIsBetter, band: t.defaultNoiseBand) : nil
                                deltaText(d).font(Theme.monoSmall).frame(width: 70, alignment: .trailing)
                                Spacer().frame(width: 46)
                            }
                            Spacer().frame(width: 96)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    func metricKeys(_ a: BenchmarkResult?, _ b: BenchmarkResult?) -> [String] {
        var keys: [String] = []
        for m in (a?.metrics ?? []) + (b?.metrics ?? []) where !keys.contains(m.key) { keys.append(m.key) }
        return keys
    }

    func metricValue(_ m: BenchmarkMetric) -> String {
        if m.unit == "×" { return String(format: "×%.2f", m.value) }
        if m.unit.isEmpty { return String(format: "%.0f", m.value) }
        return "\(fmtValue(m.value)) \(m.unit)"
    }
}

/// Flat history line for one test across saved runs, oldest left. A and B are marked.
struct BenchmarkSparkline: View {
    let points: [(date: Date, value: Double, id: UUID)]
    let a: UUID?
    let b: UUID?

    var body: some View {
        if points.count >= 2 {
            let lo = points.map(\.value).min()!, hi = points.map(\.value).max()!
            let pad = max((hi - lo) * 0.15, hi * 0.01)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    LineMark(x: .value("Run", i), y: .value("Value", p.value))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .interpolationMethod(.linear)
                }
                ForEach(Array(points.enumerated()).filter { $0.element.id == a || $0.element.id == b }, id: \.offset) { i, p in
                    PointMark(x: .value("Run", i), y: .value("Value", p.value))
                        .foregroundStyle(Color.primary)
                        .symbolSize(14)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartXScale(domain: 0...(points.count - 1))
            .help("\(points.count) runs: \(fmtValue(lo)) to \(fmtValue(hi))")
        } else {
            Text(points.isEmpty ? "" : "1 run").font(Theme.monoSmall).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
