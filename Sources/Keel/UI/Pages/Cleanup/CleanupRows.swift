import SwiftUI

/// Checkbox used for selection: green when on, dash when partly on.
struct SelectBox: View {
    let state: Bool?          // true, false, nil = mixed
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == true ? "checkmark.square.fill" : (state == nil ? "minus.square.fill" : "square"))
                .font(.system(size: 14))
                .foregroundStyle(state == false ? Color.secondary : Theme.on)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(state == true ? "Deselect" : "Select")
    }
}

/// Size in mono, with how it was obtained.
struct SizeText: View {
    let item: CleanupItem
    let measuring: Bool
    var body: some View {
        HStack(spacing: 4) {
            if measuring && (item.sizeBytes == nil || item.sizeFromCache) { ProgressView().controlSize(.mini) }
            Text(label)
                .font(Theme.mono)
                .foregroundStyle(item.sizeBytes == nil || item.sizeFromCache ? .secondary : .primary)
                .lineLimit(1)
        }
        .frame(width: 96, alignment: .trailing)
        .help(help)
    }
    var label: String {
        if let l = item.sizeLabel { return l }
        if case .needsFullDiskAccess = item.kind { return "—" }
        return measuring ? "" : "—"
    }
    var help: String {
        if item.sizeFromCache { return "From the last scan, re-measuring" }
        switch item.sizeKind {
        case .measured: return item.unreadable ? "Measured with du; some files could not be read" : "Measured with du"
        case .upTo: return "Upper bound: the tool may keep part of it"
        case .reported: return "Reported by the owning tool"
        case .logical: return "Logical size reported by Spotlight"
        }
    }
}

struct CleanupGroupSection: View {
    @Bindable var model: CleanupModel
    let group: CleanupGroup
    let open: (String) -> Void

    var all: [CleanupItem] { model.items(in: group) }
    /// Rows measured at exactly 0 B are hidden (they exist but there is nothing to free).
    var items: [CleanupItem] { sorted(all.filter { $0.sizeBytes != 0 }) }
    var collapsed: Bool { model.collapsedGroups.contains(group.rawValue) }
    var total: UInt64 { items.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
    var selectable: [CleanupItem] { items.filter(\.deletable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !collapsed {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        CleanupItemRow(model: model, item: item, child: false, open: open)
                        if item.isParent && model.expanded.contains(item.id) {
                            let kids = sorted(item.children.filter { $0.sizeBytes != 0 })
                            ForEach(kids) { c in CleanupItemRow(model: model, item: c, child: true, parentOwner: item.owner, open: open) }
                            let hidden = item.children.count - kids.count
                            if hidden > 0 {
                                Text("\(hidden) empty item\(hidden == 1 ? "" : "s") hidden").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
                            }
                        }
                    }
                    let empty = all.count - items.count
                    if empty > 0 {
                        Text("\(empty) empty: " + all.filter { $0.sizeBytes == 0 }.map(\.name).sorted().joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
                    }
                }
            }
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Button {
                if collapsed { model.collapsedGroups.remove(group.rawValue) } else { model.collapsedGroups.insert(group.rawValue) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    Image(systemName: group.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(group.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.6)
                    Text("\(items.count)").font(Theme.monoSmall).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if !selectable.isEmpty {
                let state = groupState
                Button(state == true ? "Select none" : "Select all") {
                    for i in selectable { model.setSelected(i, state != true) }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .disabled(model.cleaning)
            }
            Text(total.humanBytes).font(Theme.monoSmall).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.top, 4)
    }

    var groupState: Bool? {
        let states = selectable.map { model.selectionState($0) }
        if states.allSatisfy({ $0 == true }) { return true }
        if states.allSatisfy({ $0 == false }) { return false }
        return nil
    }

    func sorted(_ list: [CleanupItem]) -> [CleanupItem] {
        if model.sortBySize {
            return list.sorted { a, b in
                switch (a.sizeBytes, b.sizeBytes) {
                case let (x?, y?): return x == y ? a.name < b.name : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct CleanupItemRow: View {
    @Bindable var model: CleanupModel
    let item: CleanupItem
    let child: Bool
    var parentOwner: OwningApp? = nil
    let open: (String) -> Void

    var measuring: Bool {
        item.isParent ? item.children.contains { model.measuring.contains($0.id) } : model.measuring.contains(item.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: child ? 12 : 12.5, weight: child ? .regular : .semibold)).lineLimit(1).truncationMode(.middle)
                    chips
                }
                Text(LocalizedStringKey(item.summary)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let o = item.owner, model.isRunning(o), item.deletable, !child || parentOwner != o {
                Button(o.processPattern != nil ? "Stop" : "Quit \(o.name)") { Task { await model.quit(o) } }
                    .controlSize(.small).disabled(model.cleaning)
            }
            if item.id == "trash", item.sizeBytes == nil {
                Button(model.measuringTrash ? "Measuring…" : "Measure Trash") { Task { await model.measureTrashViaFinder() } }
                    .controlSize(.small).disabled(model.measuringTrash || model.cleaning)
                    .help("Asks Finder for the size. macOS may ask whether Keel can control Finder.")
            }
            SizeText(item: item, measuring: measuring)
            Button { open(item.id) } label: { Image(systemName: "info.circle").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Details")
        }
        .frame(minHeight: child ? 24 : 32)
        .card(padding: child ? 7 : 9)
        .contentShape(Rectangle())
        .onTapGesture { open(item.id) }
        .padding(.leading, child ? 28 : 0)
    }

    @ViewBuilder var leading: some View {
        HStack(spacing: 6) {
            if item.isParent {
                Button {
                    if model.expanded.contains(item.id) { model.expanded.remove(item.id) } else { model.expanded.insert(item.id) }
                } label: {
                    Image(systemName: model.expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("\(item.children.count) items")
            } else if !child {
                Color.clear.frame(width: 14, height: 18)
            }
            if item.deletable {
                let state = item.isParent ? model.selectionState(item) : model.selected.contains(item.id)
                SelectBox(state: state, enabled: !model.cleaning && (item.isParent || model.canSelect(item))) {
                    model.setSelected(item, state != true)
                }
            } else {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                    .help("Listed only. Keel never deletes this.")
            }
        }
    }

    @ViewBuilder var chips: some View {
        if !child && item.risk != .safe { RiskChip(risk: item.risk) }
        if child && item.risk == .medium && item.deletable { RiskChip(risk: item.risk) }
        if let o = item.owner, model.isRunning(o), item.deletable { Chip(text: "\(o.name.uppercased()) IS OPEN", color: Theme.warn) }
        if case .needsFullDiskAccess = item.kind { Chip(text: "NEEDS FULL DISK ACCESS", color: Theme.warn) }
        if item.unreadable { Chip(text: "PARTLY UNREADABLE") }
        if !item.warnings.isEmpty { Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.warn).help(item.warnings.joined(separator: "\n")) }
        if item.isParent { Text("\(item.children.count)").font(Theme.monoSmall).foregroundStyle(.tertiary) }
    }
}
