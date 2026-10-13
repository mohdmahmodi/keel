import SwiftUI

/// Each card is its own view reading only its own facts, so a live sample re-renders only cards that changed.
struct OverviewPage: View {
    /// Last measured width, so returning to the page lays the grid out once instead of twice.
    @MainActor private static var lastWidth: CGFloat = 900
    @State private var width: CGFloat = OverviewPage.lastWidth
    private var info: SystemInfo { SystemInfo.shared }
    private var nav: Navigator { Navigator.shared }

    var body: some View {
        VStack(spacing: 0) {
            OverviewHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let cols = width >= 860 ? 3 : (width >= 540 ? 2 : 1)
                    let cards: [OverviewCardKind] = [.memory, .cpu, .storage, .power, .network, .machine]
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(Array(stride(from: 0, to: cards.count, by: cols)), id: \.self) { start in
                            GridRow {
                                ForEach(cards[start..<min(start + cols, cards.count)], id: \.self) { kind in
                                    OverviewCard(kind: kind).gridCellAnchor(.topLeading)
                                }
                            }
                        }
                    }
                    if width >= 760 {
                        HStack(alignment: .top, spacing: 10) {
                            AttentionList().frame(maxWidth: .infinity)
                            ManualList().frame(maxWidth: .infinity)
                        }
                    } else {
                        AttentionList()
                        ManualList()
                    }
                    if width >= 640 {
                        EqualRow { TopProcessesCard(byCPU: false).cell(); TopProcessesCard(byCPU: true).cell() }
                    } else {
                        TopProcessesCard(byCPU: false)
                        TopProcessesCard(byCPU: true)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    if abs(w - width) > 1 { width = w; OverviewPage.lastWidth = w }
                }
            }
        }
        .onAppear { info.startLive("overview") }
        .onDisappear { info.stopLive("overview") }
    }
}

private struct OverviewHeader: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        PageHeader(title: "Overview", subtitle: subtitle) {
            Button { AppStartup.redetect() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(info.refreshing)
                .help("Re-read the machine and re-check every tweak (⌘R)")
        }
    }
    private var subtitle: String {
        let m = Machine.current
        let desc = m.memoryBytes > 0 ? m.shortDescription : "Reading the machine…"
        return info.lastRefresh == nil ? desc : "\(desc) · live"
    }
}

enum OverviewCardKind: Hashable { case memory, cpu, storage, power, network, machine }

private struct OverviewCard: View {
    let kind: OverviewCardKind
    var body: some View {
        switch kind {
        case .memory: MemoryCard()
        case .cpu: CPUCard()
        case .storage: StorageCard()
        case .power: PowerCard()
        case .network: NetworkCard()
        case .machine: MachineCard()
        }
    }
}

/// Card scaffold: title row, big value, meter, detail rows. Fills its grid cell so rows have equal heights.
private struct MetricCard<Chips: View, Meter: View, Rows: View>: View {
    let symbol: String
    let title: String
    let value: String
    var suffix: String = ""
    var valueIsText = false
    @ViewBuilder var chips: Chips
    @ViewBuilder var meter: Meter
    @ViewBuilder var rows: Rows
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14).accessibilityHidden(true)
                Text(title).font(Theme.label).foregroundStyle(.secondary).tracking(0.6).textCase(.uppercase).lineLimit(1)
                Spacer(minLength: 4)
                chips
            }
            .frame(height: 18)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(valueIsText ? .system(size: 18, weight: .semibold) : Theme.monoLarge)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if !suffix.isEmpty { Text(suffix).font(Theme.small).foregroundStyle(.secondary).lineLimit(1) }
            }
            meter
            VStack(spacing: 5) { rows }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .contain)
    }
}

private struct MemoryCard: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let m = info.memory
        MetricCard(symbol: "memorychip", title: "Memory", value: m.totalBytes == 0 ? "—" : m.usedBytes.gb, suffix: m.totalBytes == 0 ? "" : "of \(m.totalBytes.gb) used") {
            Chip(text: m.pressure.label, color: Theme.color(for: m.pressure), filled: true).help("Memory pressure")
        } meter: {
            Bar(fraction: m.usedFraction, color: m.pressure == .normal ? .primary : Theme.color(for: m.pressure))
        } rows: {
            KV(k: "Apps", v: m.appBytes.gb)
            KV(k: "Wired · compressed", v: "\(m.wiredBytes.gb) · \(m.compressedBytes.gb)")
            KV(k: "Swap used", v: m.swapUsedBytes == 0 ? "none" : m.swapUsedBytes.humanBytes, color: m.swapUsedBytes > 1_073_741_824 ? Theme.warn : nil)
            KV(k: "GPU memory limit", v: gpuLimit(m))
        }
    }
    private func gpuLimit(_ m: MemoryFacts) -> String {
        if m.gpuWiredLimitMB > 0 { return String(format: "%.1f GB (raised)", Double(m.gpuWiredLimitMB) / 1024) }
        let d = Machine.current.metalWorkingSetBytes
        return d > 0 ? "\(d.gb) default" : "default"
    }
}

private struct CPUCard: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let c = info.cpu
        let hot = c.thermal == .serious || c.thermal == .critical
        MetricCard(symbol: "cpu", title: "CPU", value: "\(Int((c.usage * 100).rounded()))%",
                   suffix: c.history.count < 2 ? "sampling" : String(format: "user %.0f · system %.0f", c.user * 100, c.system * 100)) {
            Chip(text: c.thermalLabel.uppercased(), color: hot ? Theme.warn : Theme.neutral, filled: hot).help("Thermal state")
        } meter: {
            Sparkline(values: c.history).frame(height: 26)
        } rows: {
            KV(k: "Load 1 · 5 · 15 min", v: String(format: "%.1f · %.1f · %.1f", c.load1, c.load5, c.load15))
            KV(k: "Cores", v: info.hardware.cores.isEmpty ? "—" : info.hardware.cores)
            KV(k: "Busiest app", v: info.topCPU.first.map { "\($0.name) \(Int($0.cpu.rounded()))%" } ?? "—")
        }
    }
}

private struct StorageCard: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let s = info.storage
        let low = s.containerBytes > 0 && s.availablePercent < 15
        let avail = max(s.freeBytes, s.importantAvailableBytes)
        MetricCard(symbol: "internaldrive", title: "Storage", value: s.containerBytes == 0 ? "—" : avail.humanBytes, suffix: s.containerBytes == 0 ? "" : "available") {
            Chip(text: low ? "LOW" : String(format: "%.0f%% FREE", s.availablePercent), color: low ? Theme.warn : Theme.on, filled: true)
        } meter: {
            Bar(fraction: s.usedFraction, color: low ? Theme.warn : .primary)
        } rows: {
            KV(k: "Free now", v: s.freeBytes.humanBytes)
            KV(k: "Purgeable", v: s.purgeableBytes.humanBytes)
            KV(k: "Local snapshots", v: "\(s.localSnapshots.count)")
            KV(k: "FileVault", v: s.fileVaultOn.map { $0 ? "on" : "off" } ?? "—", color: s.fileVaultOn == false ? Theme.warn : nil)
        }
    }
}

private struct PowerCard: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let b = info.battery
        if b.present {
            MetricCard(symbol: b.charging ? "battery.100percent.bolt" : "battery.75percent", title: "Battery", value: "\(b.percent)%", suffix: timeText(b)) {
                if b.lowPowerMode { Chip(text: "LOW POWER", color: Theme.warn) }
                Chip(text: b.charging ? "CHARGING" : (b.onAC ? "ON ADAPTER" : "ON BATTERY"), color: b.onAC ? Theme.on : Theme.neutral, filled: b.onAC)
            } meter: {
                Bar(fraction: Double(b.percent) / 100, color: b.percent <= 15 && !b.onAC ? Theme.warn : .primary)
            } rows: {
                KV(k: "Maximum capacity", v: b.healthPercent > 0 ? "\(b.healthPercent)%" : "—", color: b.healthPercent > 0 && b.healthPercent < 80 ? Theme.warn : nil)
                KV(k: "Cycles", v: b.cycleCount > 0 ? (b.designCycles > 0 ? "\(b.cycleCount) of \(b.designCycles)" : "\(b.cycleCount)") : "—")
                KV(k: "Mode on battery", v: PowerMode.name(b.powerModeBattery), color: b.powerModeBattery == "2" ? Theme.warn : nil)
                KV(k: "Mode on adapter", v: PowerMode.name(b.powerModeAC))
            }
        } else {
            MetricCard(symbol: "powerplug", title: "Power", value: PowerMode.name(b.powerModeAC), suffix: "energy mode", valueIsText: true) {
                Chip(text: "AC POWER", color: Theme.on, filled: true)
            } meter: {
                EmptyView()
            } rows: {
                KV(k: "Type", v: "Desktop, no battery")
                KV(k: "Low Power Mode", v: b.lowPowerMode ? "on" : "off")
                KV(k: "Thermal state", v: info.cpu.thermalLabel)
                KV(k: "Uptime", v: info.hardware.uptime)
            }
        }
    }
    private func timeText(_ b: BatteryFacts) -> String {
        func hm(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
        if let f = b.minutesToFull { return "\(hm(f)) to full" }
        if let e = b.minutesToEmpty { return "\(hm(e)) left" }
        return b.onAC ? (b.charging ? "charging" : "not charging") : ""
    }
}

private struct NetworkCard: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let n = info.network
        switch n.kind {
        case .wifi:
            let w = n.wifi
            let quality = w.rssi >= -60 ? "GOOD" : (w.rssi >= -70 ? "FAIR" : "WEAK")
            MetricCard(symbol: "wifi", title: "Wi-Fi", value: "\(w.rssi) dBm", suffix: "SNR \(w.snr) dB") {
                if n.awdlUp { Chip(text: "AWDL", color: Theme.neutral).help("AWDL (AirDrop, Continuity) interface is up") }
                Chip(text: quality, color: quality == "WEAK" ? Theme.warn : (quality == "GOOD" ? Theme.on : Theme.neutral), filled: quality != "FAIR").help("Signal quality")
            } meter: {
                Bar(fraction: Double(min(max(w.rssi + 90, 0), 50)) / 50, color: quality == "WEAK" ? Theme.warn : .primary)
            } rows: {
                KV(k: "Channel", v: [w.channel, w.band, w.width].filter { !$0.isEmpty }.joined(separator: " · "))
                KV(k: "Link", v: [w.phy, w.txRate > 0 ? "\(w.txRate) Mb/s" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                KV(k: "Traffic", v: "↓ \(n.rxBytesPerSec.rateString)  ↑ \(n.txBytesPerSec.rateString)")
                KV(k: "DNS", v: n.dns.isEmpty ? "—" : n.dns.prefix(2).joined(separator: ", "))
            }
        case .ethernet, .other:
            MetricCard(symbol: n.kind == .ethernet ? "cable.connector" : "network", title: n.displayName.isEmpty ? "Network" : n.displayName,
                       value: n.linkSpeedMbps > 0 ? speed(n.linkSpeedMbps) : "Connected", suffix: n.linkSpeedMbps > 0 ? "link" : "", valueIsText: n.linkSpeedMbps == 0) {
                Chip(text: "CONNECTED", color: Theme.on, filled: true)
            } meter: {
                EmptyView()
            } rows: {
                KV(k: "Interface", v: n.primaryInterface)
                KV(k: "Address", v: n.ipv4.isEmpty ? "—" : n.ipv4)
                KV(k: "Traffic", v: "↓ \(n.rxBytesPerSec.rateString)  ↑ \(n.txBytesPerSec.rateString)")
                KV(k: "DNS", v: n.dns.isEmpty ? "—" : n.dns.prefix(2).joined(separator: ", "))
            }
        case .none:
            MetricCard(symbol: "network.slash", title: "Network", value: info.lastRefresh == nil ? "—" : "Offline", valueIsText: true) {
                if info.lastRefresh != nil { Chip(text: "NO CONNECTION", color: Theme.warn) }
            } meter: {
                EmptyView()
            } rows: {
                KV(k: "Wi-Fi", v: n.wifi.interface.isEmpty ? "no Wi-Fi hardware" : (n.wifi.powerOn ? "on, not connected" : "off"))
                KV(k: "DNS", v: n.dns.isEmpty ? "—" : n.dns.prefix(2).joined(separator: ", "))
            }
        }
    }
    private func speed(_ mbps: Int) -> String { mbps >= 1000 ? String(format: "%g Gb/s", Double(mbps) / 1000) : "\(mbps) Mb/s" }
}

private struct MachineCard: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let h = info.hardware
        MetricCard(symbol: "laptopcomputer.and.iphone", title: "This Mac", value: h.model.isEmpty ? "—" : h.model, valueIsText: true) {
            EmptyView()
        } meter: {
            EmptyView()
        } rows: {
            KV(k: "Chip", v: h.chip.isEmpty ? "—" : h.chip.replacingOccurrences(of: "Apple ", with: ""))
            KV(k: "GPU cores", v: h.gpuCores > 0 ? "\(h.gpuCores)" : "—")
            KV(k: "Memory", v: h.memoryGB > 0 ? String(format: "%.0f GB", h.memoryGB) : "—")
            KV(k: "macOS", v: h.osVersion.isEmpty ? "—" : "\(h.osVersion) (\(h.build))")
            KV(k: "Up for", v: h.uptime)
        }
    }
}

private struct TopProcessesCard: View {
    let byCPU: Bool
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let list = Array((byCPU ? info.topCPU : info.topMemory).prefix(6))
        let maxMem = Double(info.topMemory.first?.rssBytes ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: byCPU ? "Top apps by CPU" : "Top apps by memory")
                .help("Your own processes, grouped by app. System processes are not readable without root.")
            if list.isEmpty {
                Text(byCPU ? "Nothing busy right now." : "Reading…").font(Theme.small).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(list) { p in
                HStack(spacing: 8) {
                    Text(p.name).font(Theme.small).lineLimit(1).truncationMode(.middle)
                    if p.count > 1 { Text("×\(p.count)").font(Theme.monoSmall).foregroundStyle(.tertiary) }
                    Spacer(minLength: 6)
                    if !byCPU { Bar(fraction: Double(p.rssBytes) / max(1, maxMem)).frame(width: 60) }
                    Text(byCPU ? String(format: "%.0f%%", p.cpu) : p.rssBytes.humanBytes)
                        .font(Theme.mono).frame(width: 70, alignment: .trailing)
                }
                .frame(height: 18)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

private struct AttentionList: View {
    private var model: OverviewModel { OverviewModel.shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Needs attention", trailing: "\(model.attention.count)")
            if model.attention.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.on).accessibilityHidden(true)
                    Text("Nothing stands out right now.").font(Theme.small).foregroundStyle(.secondary)
                    Spacer()
                }
                .card(padding: 12)
            }
            ForEach(model.attention) { AttentionRow(item: $0) }
        }
    }
}

private struct ManualList: View {
    private var model: OverviewModel { OverviewModel.shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Only you can do these", trailing: "\(model.manual.count)")
            if model.manual.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.on).accessibilityHidden(true)
                    Text("Nothing waiting on you.").font(Theme.small).foregroundStyle(.secondary)
                    Spacer()
                }
                .card(padding: 12)
            }
            ForEach(model.manual) { AttentionRow(item: $0) }
        }
    }
}

private struct AttentionRow: View {
    let item: AttentionItem
    @State private var hover = false
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.symbol).font(.system(size: 12)).foregroundStyle(item.severity == .info ? Color.secondary : item.color)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(item.detail).font(Theme.small).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let v = item.value { Text(v).font(Theme.mono).foregroundStyle(.secondary).lineLimit(1) }
            if let label = item.actionLabel, let action = item.action {
                Button(label) { Navigator.shared.perform(action) }.buttonStyle(KeelButtonStyle(small: true))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(hover && item.action != nil ? Theme.borderStrong.opacity(0.45) : Theme.border, lineWidth: 1))
        .overlay(alignment: .leading) {
            if item.severity != .info {
                RoundedRectangle(cornerRadius: 1).fill(item.color).frame(width: 2).padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let a = item.action { Navigator.shared.perform(a) } }
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }
}
