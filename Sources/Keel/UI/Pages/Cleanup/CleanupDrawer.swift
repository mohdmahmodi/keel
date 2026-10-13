import SwiftUI

struct CleanupDrawer: View {
    @Bindable var model: CleanupModel
    let item: CleanupItem
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text(item.group.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                }

                FlowLayout {
                    RiskChip(risk: item.risk)
                    Chip(text: item.deletable ? "DELETABLE" : "LIST ONLY")
                    if let s = item.sizeLabel { Chip(text: s) }
                    Chip(text: sizeSource)
                    if item.isParent { Chip(text: "\(item.children.count) ITEMS") }
                }

                if let o = item.owner {
                    HStack(spacing: 8) {
                        Image(systemName: model.isRunning(o) ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(model.isRunning(o) ? Theme.warn : Theme.on)
                        Text(model.isRunning(o) ? "\(o.name) is open. Keel skips this item until the app is quit." : "\(o.name) must be quit while this is cleaned. It is not running now.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if model.isRunning(o) {
                            Button(o.processPattern != nil ? "Stop" : "Quit \(o.name)") { Task { await model.quit(o) } }.controlSize(.small)
                        }
                    }
                    .card(padding: 10)
                }

                ForEach(item.warnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                        Text(w).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .card(padding: 10)
                }

                Text(LocalizedStringKey(item.explanation)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)

                SectionTitle(text: "Cost to get it back")
                Text(item.rebuildCost).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)

                if !item.paths.isEmpty {
                    SectionTitle(text: "Paths", trailing: item.paths.count > 1 ? "\(item.paths.count)" : nil)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.paths.prefix(40).enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .top, spacing: 6) {
                                Text((p as NSString).abbreviatingWithTildeInPath).font(Theme.monoSmall).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Button { reveal(p) } label: { Image(systemName: "arrow.right.circle").font(.system(size: 11)) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
                            }
                        }
                        if item.paths.count > 40 { Text("…and \(item.paths.count - 40) more").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                SectionTitle(text: item.deletable ? "Exactly what Keel runs" : "Keel runs")
                CommandBlock(lines: item.commandsPreview.isEmpty ? ["(nothing)"] : item.commandsPreview)

                if let d = item.detail, !d.isEmpty {
                    SectionTitle(text: "Details")
                    CommandBlock(lines: d.split(separator: "\n").map(String.init))
                }

                if item.isParent {
                    SectionTitle(text: "Items")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.children.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }.prefix(50)) { c in
                            HStack {
                                Text(c.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(c.sizeLabel ?? "—").font(Theme.monoSmall).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack {
                    if let p = item.paths.first { Button("Reveal in Finder") { reveal(p) }.controlSize(.small) }
                    if case .needsFullDiskAccess = item.kind {
                        Button("Open Full Disk Access settings") { CleanupPage.openFullDiskAccess() }.controlSize(.small)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    var sizeSource: String {
        if item.sizeFromCache { return "LAST SCAN" }
        switch item.sizeKind {
        case .measured: return item.unreadable ? "MEASURED, PARTLY UNREADABLE" : "MEASURED"
        case .upTo: return "UPPER BOUND"
        case .reported: return "REPORTED BY TOOL"
        case .logical: return "LOGICAL SIZE"
        }
    }

    func reveal(_ p: String) {
        let path = Shell.expand(p)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).deletingLastPathComponent))
        }
    }
}
