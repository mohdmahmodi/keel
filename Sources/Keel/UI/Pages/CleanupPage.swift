import SwiftUI

struct CleanupPage: View {
    @Bindable var model: CleanupModel
    @State private var confirm = false
    @State private var detailID: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PageHeader(title: "Cleanup", subtitle: subtitle) {
                    if model.scanning { ProgressView().controlSize(.small) }
                    Picker("", selection: $model.sortBySize) {
                        Text("Size").tag(true)
                        Text("Name").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 110).help("Sort items")
                    Button("Measure again") { Task { await model.scan() } }.disabled(model.scanning || model.cleaning)
                }
                if CleanupPage.headless {
                    // ImageRenderer draws ScrollView content blank; render the list directly for --screenshots.
                    Color.clear.overlay(alignment: .top) { list }.clipped()
                } else {
                    ScrollView { list }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                summaryBar
            }
            if let id = detailID, let item = find(id) {
                CleanupDrawer(model: model, item: item, close: { detailID = nil })
            }
        }
        .sheet(isPresented: $confirm) {
            CleanupConfirm(model: model, onConfirm: { confirm = false; Task { await model.cleanSelected() } }, onCancel: { confirm = false })
        }
        .task { await model.scanIfStale(); await model.refreshRunning() }
    }

    static let headless = CommandLine.arguments.contains("--screenshots")

    var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            banners
            if model.cleaning || model.summary != nil { CleanupProgressCard(model: model) }
            if model.items.isEmpty && model.scanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for caches…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            }
            ForEach(CleanupGroup.allCases) { g in
                if !model.items(in: g).isEmpty {
                    CleanupGroupSection(model: model, group: g, open: { detailID = $0 })
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 6)
    }

    var subtitle: String {
        if model.cleaning { return model.progressText ?? "Cleaning…" }
        if model.scanning {
            let n = model.measuring.count
            return n > 0 ? "Measuring \(n) item\(n == 1 ? "" : "s")…" : "Looking for caches…"
        }
        guard let d = model.lastScan else { return "Sizes are measured, not estimated" }
        let secs = Date().timeIntervalSince(d)
        let ago = secs < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
        return "Measured \(ago)" + (model.scanDuration > 0 ? " in \(String(format: "%.1f", model.scanDuration)) s" : "") + " · free \(model.space.free.humanBytes) of \(model.space.total.humanBytes)"
    }

    func find(_ id: String) -> CleanupItem? {
        for i in model.items {
            if i.id == id { return i }
            if let c = i.children.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    // MARK: Banners

    @ViewBuilder var banners: some View {
        if !model.snapshots.isEmpty {
            banner(symbol: "clock.arrow.circlepath", color: Theme.warn,
                   title: "\(model.snapshots.count) local snapshot\(model.snapshots.count == 1 ? "" : "s") on this disk",
                   text: "Files you delete stay allocated until the snapshots are thinned, so free space may not go up after cleaning. They may hold up to \(model.space.purgeable.humanBytes).") {
                if model.items.contains(where: { $0.id == "snapshots" && $0.deletable }) {
                    Button("Select snapshots") { model.selectSnapshots(); detailID = "snapshots" }.controlSize(.small)
                }
            }
        }
        if !model.includeUserFolders {
            banner(symbol: "folder", color: Theme.neutral, title: "Desktop, Documents, Downloads, Movies and Music are not measured",
                   text: "macOS asks once before an app reads these folders. Measuring them finds old installers, build folders in repositories and folder sizes.") {
                Button("Measure them") { model.includeUserFolders = true; Task { await model.scan() } }.controlSize(.small).disabled(model.scanning)
            }
        }
        if !model.hasFDA && model.lastScan != nil {
            banner(symbol: "lock.shield", color: Theme.neutral, title: "Some sizes need Full Disk Access",
                   text: "macOS protects the Trash, device backups, Mail and some app data. Without Full Disk Access, Keel does not read them, so they are not measured. Everything else works.") {
                Button("Open Settings") { CleanupPage.openFullDiskAccess() }.controlSize(.small)
            }
        }
    }

    func banner<A: View>(symbol: String, color: Color, title: String, text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .card(padding: 10)
    }

    static func openFullDiskAccess() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }

    // MARK: Summary bar

    var summaryBar: some View {
        HStack(spacing: 10) {
            let trash = model.selectedTrashBytes
            let blocked = model.selectedBlockedBytes
            let freed = model.selectedBytes - min(model.selectedBytes, trash + blocked)
            Text("\(model.selectedCount) selected").font(.system(size: 12))
            dot
            Text("\(freed.humanBytes) will be freed").font(.system(size: 12, weight: .semibold))
            if trash > 0 { dot; Text("\(trash.humanBytes) to the Trash").font(.system(size: 12)).foregroundStyle(.secondary) }
            if blocked > 0 {
                dot
                Text("\(blocked.humanBytes) waits for apps to quit").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            if !model.snapshots.isEmpty {
                dot
                Text("snapshots may hold \(model.space.purgeable.humanBytes)").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            Spacer()
            if model.lastFreed > 0, !model.cleaning { Chip(text: "LAST RUN +\(model.lastFreed.humanBytes.uppercased()) FREE", color: Theme.on) }
            Button("Clean selected…") { confirm = true }
                .buttonStyle(.keelPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedCount == 0 || model.cleaning || model.scanning)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    var dot: some View { Text("·").foregroundStyle(.tertiary) }
}
