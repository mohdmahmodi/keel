import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Saved runs: pick A and B, rename, export, delete.
struct BenchmarkRunsList: View {
    @Bindable var runner: BenchmarkRunner
    @State private var renaming: BenchmarkRun? = nil
    @State private var renameText = ""
    @State private var deleting: BenchmarkRun? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Runs", trailing: runner.runs.isEmpty ? nil : "A = before, B = after")
            if runner.runs.isEmpty {
                Text("No runs yet. Run once before a change and once after, then compare.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            }
            VStack(spacing: 6) {
                ForEach(runner.runs) { r in row(r) }
            }
        }
        .alert("Rename run", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Label", text: $renameText)
            Button("Rename") { if let r = renaming { runner.rename(r, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.label ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let r = deleting { runner.delete(r) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The saved results file is removed. This cannot be undone.")
        }
    }

    @ViewBuilder
    func row(_ r: BenchmarkRun) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    FlowLayout(spacing: 4) { chips(r) }
                }
                Text(subtitle(r)).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            ChipButton(text: "A", selected: runner.compareA == r.id) {
                runner.compareA = runner.compareA == r.id ? nil : r.id
                if runner.compareB == r.id { runner.compareB = nil }
            }
            ChipButton(text: "B", selected: runner.compareB == r.id) {
                runner.compareB = runner.compareB == r.id ? nil : r.id
                if runner.compareA == r.id { runner.compareA = nil }
            }
            Menu {
                Button("Rename…") { renameText = r.label; renaming = r }
                Button("Copy as Markdown") { copy(BenchmarkExport.markdown(r)) }
                Button("Export Markdown…") { save(BenchmarkExport.markdown(r).data(using: .utf8), name: r.label, ext: "md", type: .plainText) }
                Button("Export JSON…") { save(BenchmarkExport.json(r), name: r.label, ext: "json", type: .json) }
                Divider()
                Button("Delete…", role: .destructive) { deleting = r }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .disabled(runner.running)
        }
        .card(padding: 10)
    }

    @ViewBuilder
    func chips(_ r: BenchmarkRun) -> some View {
        if r.afterReboot { Chip(text: "FRESH BOOT", color: Theme.on) }
        if r.onAC { Chip(text: "AC") } else { Chip(text: "BATTERY", color: Theme.warn) }
        Chip(text: PowerModeName.name(r.powerMode).uppercased(), color: r.powerMode == "1" ? Theme.warn : Theme.neutral)
        if let m = r.meta {
            if m.buildConfig == "debug" { Chip(text: "DEBUG BUILD", color: Theme.warn) }
            if m.thermalBefore != "nominal" { Chip(text: "THERMAL \(m.thermalBefore.uppercased())", color: Theme.warn) }
            if let p = m.pressureBefore, p >= 2 { Chip(text: "MEMORY PRESSURE", color: Theme.warn) }
        } else {
            Chip(text: "OLDER FORMAT")
        }
    }

    func subtitle(_ r: BenchmarkRun) -> String {
        var parts = [r.date.formatted(date: .abbreviated, time: .shortened)]
        let valid = r.results.filter(\.isValid).count
        parts.append("\(valid)/\(r.results.count) tests")
        parts.append("\(r.minutesSinceBoot) min after boot")
        if let m = r.meta {
            parts.append("macOS \(m.osVersion) (\(m.osBuild))")
            if let d = m.durationSeconds { parts.append(String(format: "%.0f s", d)) }
        }
        return parts.joined(separator: " · ")
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func save(_ data: Data?, name: String, ext: String, type: UTType) {
        guard let data else { return }
        let panel = NSSavePanel()
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Keel benchmark - \(safe).\(ext)"
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.begin { resp in
            if resp == .OK, let url = panel.url { try? data.write(to: url, options: .atomic) }
        }
    }
}
