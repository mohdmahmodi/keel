import SwiftUI

struct CleanupConfirm: View {
    @Bindable var model: CleanupModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var targets: [CleanupItem] { model.selectedLeaves.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) } }
    var blocked: [CleanupItem] { targets.filter { model.isRunning($0.owner) } }
    var warnings: [String] { Array(Set(targets.flatMap(\.warnings))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean \(targets.count) item\(targets.count == 1 ? "" : "s") · \(model.selectedBytes.humanBytes)").font(.system(size: 15, weight: .semibold))
            Text("Exactly these steps run, in this order. Nothing in the list-only groups is touched.").font(.callout).foregroundStyle(.secondary)

            if !model.snapshots.isEmpty {
                notice("\(model.snapshots.count) local snapshot\(model.snapshots.count == 1 ? "" : "s") on this disk. Deleted files stay allocated until \(model.snapshots.count == 1 ? "it is" : "they are") thinned, so free space may not go up yet. Keel reports deleted bytes and the free-space change separately.")
            }
            if model.selectedTrashBytes > 0 {
                notice("\(model.selectedTrashBytes.humanBytes) is moved to the Trash, not deleted. That space returns when you empty the Trash.", color: Theme.neutral)
            }
            if !blocked.isEmpty {
                notice("Skipped while open: " + Set(blocked.compactMap { $0.owner?.name }).sorted().joined(separator: ", ") + ". Quit them first to include their items.")
            }
            ForEach(warnings, id: \.self) { notice($0) }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(targets) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(t.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                if model.isRunning(t.owner) { Chip(text: "SKIPPED: OPEN", color: Theme.warn) }
                                Spacer()
                                Text(t.sizeLabel ?? "—").font(Theme.monoSmall).foregroundStyle(.secondary)
                            }
                            CommandBlock(lines: Array(t.commandsPreview.prefix(6)))
                        }
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.keel).keyboardShortcut(.cancelAction)
                Button("Clean", action: onConfirm).buttonStyle(.keelDanger).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 580)
    }

    func notice(_ text: String, color: Color = Theme.warn) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: color == Theme.warn ? "exclamationmark.triangle" : "info.circle").foregroundStyle(color)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10)
    }
}

/// Per-item progress while cleaning, then the result.
struct CleanupProgressCard: View {
    @Bindable var model: CleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.cleaning ? (model.progressText ?? "Cleaning") : "Cleanup finished").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if !model.cleaning { Button("Dismiss") { model.dismissSummary() }.controlSize(.small) }
            }
            if model.cleaning {
                let done = model.steps.filter { if case .pending = $0.state { return false }; if case .running = $0.state { return false }; return true }.count
                ProgressView(value: Double(done), total: Double(max(1, model.steps.count))).tint(Theme.on)
            }
            if let s = model.summary { result(s) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.steps) { step in stepRow(step) }
            }
        }
        .card(padding: 12)
    }

    @ViewBuilder func result(_ s: CleanSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KV(k: "Deleted", v: s.deleted.humanBytes + (s.deletedReported > 0 ? "  (\(s.deletedMeasured.humanBytes) measured, \(s.deletedReported.humanBytes) reported)" : "  (measured)"))
            if s.movedToTrash > 0 { KV(k: "Moved to the Trash", v: s.movedToTrash.humanBytes) }
            KV(k: "Free space", v: "\(s.before.free.humanBytes) → \(s.after.free.humanBytes)  (\(s.freeDelta.signedHumanBytes))", color: s.freeDelta > 0 ? Theme.on : nil)
            KV(k: "Purgeable", v: "\(s.before.purgeable.humanBytes) → \(s.after.purgeable.humanBytes)")
        }
        if s.heldBack > 268_435_456 {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                Text(s.snapshotCount > 0
                     ? "\(s.heldBack.humanBytes) is deleted but still held by \(s.snapshotCount) local snapshot\(s.snapshotCount == 1 ? "" : "s"). It becomes free space when the snapshots are thinned."
                     : "\(s.heldBack.humanBytes) has not shown up as free space yet. macOS may still be releasing it. Measure again in a minute.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if s.snapshotCount > 0, model.items.contains(where: { $0.id == "snapshots" }) {
                    Button("Select snapshots") { model.selectSnapshots() }.controlSize(.small)
                }
            }
        }
    }

    func stepRow(_ step: CleanStep) -> some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle").foregroundStyle(Theme.on)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.warn)
                case .failed: Image(systemName: "xmark.circle").foregroundStyle(Theme.fail)
                }
            }
            .font(.system(size: 11)).frame(width: 14)
            Text(step.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(detail(step)).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .help(step.note ?? "")
    }

    func detail(_ step: CleanStep) -> String {
        switch step.state {
        case .pending: return ""
        case .running: return "running"
        case .done(let b, let measured): return b.humanBytes + (measured ? "" : " reported") + (step.note != nil ? " · check" : "")
        case .skipped(let why): return why
        case .failed(let e): return String(e.prefix(60))
        }
    }
}
