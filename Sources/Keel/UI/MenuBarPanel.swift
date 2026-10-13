import SwiftUI

/// Compact live stats in the menu bar. Samples only while the panel is open.
struct MenuBarPanel: View {
    private var info: SystemInfo { SystemInfo.shared }
    private var digest: TweakDigest { TweakDigest.shared }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let m = info.memory, s = info.storage, c = info.cpu
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "sailboat").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
                Text("Keel").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text([Machine.current.chip.replacingOccurrences(of: "Apple ", with: ""), Machine.current.memoryGB > 0 ? "\(Machine.current.memoryGB) GB" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 10) {
                stat("Memory", value: m.totalBytes == 0 ? "—" : "\(m.usedBytes.gb) of \(m.totalBytes.gb)", fraction: m.usedFraction) {
                    Chip(text: m.pressure.label, color: Theme.color(for: m.pressure), filled: true)
                }
                stat("CPU", value: "\(Int((c.usage * 100).rounded()))%", fraction: c.usage) {
                    if c.thermal == .serious || c.thermal == .critical { Chip(text: c.thermalLabel.uppercased(), color: Theme.warn) }
                }
                stat("Disk", value: s.containerBytes == 0 ? "—" : "\(max(s.freeBytes, s.importantAvailableBytes).humanBytes) available", fraction: s.usedFraction) {
                    if s.containerBytes > 0 && s.availablePercent < 15 { Chip(text: "LOW", color: Theme.warn) }
                }
            }
            .padding(10)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))

            if info.simulatorProcesses > 0, let sim = TweakStore.shared.item("simulators-shutdown"), sim.isApplicable {
                HStack(spacing: 8) {
                    Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(Theme.warn).accessibilityHidden(true)
                    Text("\(info.simulatorProcesses) simulator device\(info.simulatorProcesses == 1 ? "" : "s") booted").font(Theme.small)
                    Spacer()
                    Button("Shut down") {
                        AppDelegate.showMain()
                        ChangeCenter.shared.request(sim.tweak, on: true)
                    }
                    .buttonStyle(KeelButtonStyle(small: true))
                    .disabled(sim.isBusy)
                }
            }
            if !digest.recommendedPending.isEmpty {
                Button {
                    AppDelegate.showMain(); Navigator.shared.showTweaks(.recommended)
                } label: {
                    HStack {
                        Text("\(digest.recommendedPending.count) recommended change\(digest.recommendedPending.count == 1 ? " is" : "s are") off").font(Theme.small)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HLine()
            HStack(spacing: 6) {
                Button("Open Keel") { AppDelegate.showMain() }.buttonStyle(.keelPrimary)
                Button { AppStartup.redetect() } label: { Label("Re-detect", systemImage: "arrow.clockwise") }
                    .buttonStyle(.keel)
                    .disabled(TweakStore.shared.detecting)
                Spacer()
                Button("Quit") { AppDelegate.quit() }.buttonStyle(.keelGhost)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.raisedBG)
        .tint(Color.primary)
        .onAppear {
            OpenWindowBridge.open = { id in openWindow(id: id) }
            info.startLive("menubar")
            Task { await info.refreshLight() }
        }
        .onDisappear { info.stopLive("menubar") }
    }

    private func stat<C: View>(_ label: String, value: String, fraction: Double, @ViewBuilder chip: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label).font(Theme.small).foregroundStyle(.secondary)
                Spacer()
                chip()
                Text(value).font(Theme.mono).contentTransition(.numericText())
            }
            Bar(fraction: fraction)
        }
        .accessibilityElement(children: .combine)
    }
}
