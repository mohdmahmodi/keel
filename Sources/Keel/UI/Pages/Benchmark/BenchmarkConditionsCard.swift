import SwiftUI

/// Live pre-flight: what would make a run unrepresentative right now.
struct BenchmarkConditionsCard: View {
    @Bindable var runner: BenchmarkRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Conditions now", trailing: runner.running ? "captured at start" : "updates every 10 s")
            VStack(alignment: .leading, spacing: 8) {
                if let c = runner.conditions {
                    FlowLayout(spacing: 6) {
                        if c.hasBattery { Chip(text: c.onAC ? "AC POWER" : "BATTERY", color: c.onAC ? Theme.neutral : Theme.warn) }
                        Chip(text: PowerModeName.name(c.powerMode).uppercased(), color: c.powerMode == "1" || c.lowPowerMode ? Theme.warn : Theme.neutral)
                        Chip(text: "THERMAL \(c.thermal.uppercased())", color: thermalColor(c.thermal))
                        Chip(text: "MEMORY \(pressureName(c.pressure))", color: c.pressure >= 4 ? Theme.fail : (c.pressure >= 2 ? Theme.warn : Theme.neutral))
                        Chip(text: String(format: "LOAD %.1f / %d", c.loadAvg1, c.cores), color: c.busy ? Theme.warn : Theme.neutral)
                        if c.freshBoot { Chip(text: "FRESH BOOT · \(c.minutesSinceBoot) MIN", color: Theme.on) }
                        else { Chip(text: "UP \(uptime(c.minutesSinceBoot))") }
                        if let f = c.fans {
                            Chip(text: f.isEmpty ? "FANLESS" : "FANS " + f.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " RPM")
                        }
                        if let t = c.socTemp { Chip(text: String(format: "SOC %.0f °C", t), color: t >= 95 ? Theme.warn : Theme.neutral) }
                    }
                    let w = c.warnings
                    if w.isEmpty {
                        Text("Good conditions for a comparable run.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(w, id: \.self) { line in
                                Label(line, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading…").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 10)
        }
        .task {
            // Light reads only (IOKit, sysctl, one pmset call, AppleSMC); paused while a run is in progress.
            while !Task.isCancelled {
                if !runner.running { await runner.refreshConditions() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func thermalColor(_ t: String) -> Color {
        switch t { case "serious", "critical": return Theme.fail; case "fair": return Theme.warn; default: return Theme.neutral }
    }
    func pressureName(_ p: Int) -> String { p >= 4 ? "CRITICAL" : (p >= 2 ? "WARN" : "NORMAL") }
    func uptime(_ m: Int) -> String { m >= 1440 ? "\(m / 1440) D \(m % 1440 / 60) H" : (m >= 60 ? "\(m / 60) H \(m % 60) MIN" : "\(m) MIN") }
}
