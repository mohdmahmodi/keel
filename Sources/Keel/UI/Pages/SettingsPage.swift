import SwiftUI

struct SettingsPage: View {
    @Bindable var settings: AppSettings
    @State private var originals: Int? = nil
    @State private var restoring = false
    private var info: SystemInfo { SystemInfo.shared }
    private static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", subtitle: "Keel \(Self.version) · for Apple Silicon Macs on macOS 15 and later") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("General") {
                        loginRow
                        Divider()
                        row("Keep running in the menu bar", "Closing the window leaves Keel in the menu bar with live memory, CPU and disk numbers.",
                            $settings.keepInMenuBar)
                        Divider()
                        row("Confirm each change", "Shows the exact commands before anything changes. Off: single switches apply straight away. Batches are always confirmed.",
                            $settings.confirmChanges)
                        Divider()
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Offer a local snapshot before the first change").font(Theme.bodyStrong)
                                Text(settings.snapshotTaken ? "A snapshot was taken before your first change. Reset to be offered one again."
                                                            : "Runs tmutil localsnapshot once, so the whole disk can be rolled back with Time Machine.")
                                    .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            if settings.snapshotTaken {
                                Button("Reset") { settings.snapshotTaken = false }.buttonStyle(KeelButtonStyle(small: true))
                            }
                            Toggle("Offer a local snapshot", isOn: $settings.snapshotBeforeFirstChange).toggleStyle(FlatToggleStyle())
                        }
                    }

                    group("Permissions") {
                        HelperSection(helper: HelperManager.shared)
                        Divider()
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("Full Disk Access").font(Theme.bodyStrong)
                                    Chip(text: info.hasFullDiskAccess == nil ? "CHECKING" : (info.hasFullDiskAccess! ? "GRANTED" : "NOT GRANTED"), color: info.hasFullDiskAccess == true ? Theme.on : Theme.neutral, filled: info.hasFullDiskAccess == true)
                                }
                                Text("Optional. Lets Cleanup measure Mail downloads, iOS backups and the Trash. Keel works without it.")
                                    .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(KeelButtonStyle(small: true))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Updates")
                        UpdateSection()
                    }

                    group("Your data") {
                        pathRow("Recorded originals", AppPaths.backups, detail: originals.map { "\($0) tweak\($0 == 1 ? "" : "s") changed by Keel" } ?? "Counting…")
                        Divider()
                        pathRow("Activity log", AppPaths.support.appendingPathComponent("activity.jsonl"), detail: "\(ActivityLog.shared.entries.count) entries")
                        Divider()
                        pathRow("Benchmark runs", AppPaths.benchmarks, detail: nil)
                        Divider()
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Restore everything Keel changed").font(Theme.bodyStrong)
                                Text("Puts back every original Keel recorded. You see the full list and the commands first.")
                                    .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Button(restoring ? "Checking…" : "Restore everything…") { restoreAll() }
                                .buttonStyle(KeelButtonStyle(kind: .danger, small: true))
                                .disabled(restoring || originals == 0 || TweakStore.shared.running > 0)
                        }
                    }

                    group("About") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keel \(Self.version) for Apple Silicon Macs (laptops and desktops) on macOS 15, 26 and 27.").font(Theme.body)
                            Text("Every tweak checks the live state on this Mac, records the original before changing it, verifies the result, and restores from the recording.")
                                .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("Changes that need administrator rights run through Keel's helper when it is installed, or behind one macOS password prompt per batch. Keel never asks to turn off SIP, Gatekeeper or FileVault.")
                                .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Show the welcome screen") { Navigator.shared.showOnboarding = true }
                                .buttonStyle(KeelButtonStyle(small: true)).padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await settings.refreshLogin()
            originals = await Task.detached(priority: .utility) { Set(BackupStore.all().map(\.tweakID)).count }.value
        }
        .onChange(of: TweakStore.shared.running) { _, r in
            if r == 0 { Task { originals = await Task.detached(priority: .utility) { Set(BackupStore.all().map(\.tweakID)).count }.value } }
        }
    }

    private var loginRow: some View {
        let l = settings.login
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Start at login").font(Theme.bodyStrong)
                    if l.state == .needsApproval { Chip(text: "NEEDS APPROVAL", color: Theme.warn) }
                }
                Text(loginDetail(l)).font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if l.state == .needsApproval {
                Button("Open Login Items") { SMAppServiceOpener.open() }.buttonStyle(KeelButtonStyle(small: true))
            }
            if settings.loginBusy { ProgressView().controlSize(.mini) }
            Toggle("Start at login", isOn: Binding(get: { settings.startAtLogin }, set: { settings.setStartAtLogin($0) }))
                .toggleStyle(FlatToggleStyle())
                .disabled(settings.loginBusy)
        }
    }

    private func loginDetail(_ l: LoginItem.Status) -> String {
        switch (l.state, l.mechanism) {
        case (.on, .appService): return "On. Keel is listed in System Settings > General > Login Items."
        case (.on, .launchAgent): return "On, through ~/Library/LaunchAgents/\(LoginItem.label).plist. Opens Keel hidden in the menu bar."
        case (.needsApproval, _): return "Registered, but macOS needs you to allow it in Login Items."
        case (.off, .appService): return "Opens Keel hidden at login. Listed in Login Items so you can remove it there too."
        case (.off, .launchAgent): return "Opens Keel hidden at login through a user LaunchAgent (Keel is not in /Applications or not signed)."
        }
    }

    private func restoreAll() {
        restoring = true
        Task {
            let list = await ChangeCenter.shared.changedByKeel()
            restoring = false
            if list.isEmpty { ActivityLog.shared.info("Nothing to restore: no recorded originals for current tweaks"); originals = 0; return }
            ChangeCenter.shared.requestBatch(list, on: false, title: "Restore \(list.count) setting\(list.count == 1 ? "" : "s") Keel changed")
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title)
            VStack(alignment: .leading, spacing: 12) { content() }.card()
        }
    }

    private func row(_ title: String, _ sub: String, _ b: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.bodyStrong)
                Text(sub).font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: b).toggleStyle(FlatToggleStyle())
        }
    }

    private func pathRow(_ title: String, _ url: URL, detail: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(Theme.bodyStrong)
                    if let detail { Text(detail).font(Theme.small).foregroundStyle(.secondary) }
                }
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Theme.monoSmall).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(KeelButtonStyle(small: true))
                .accessibilityLabel("Reveal \(title) in Finder")
        }
    }
}

enum SMAppServiceOpener {
    static func open() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
}

struct HelperSection: View {
    @Bindable var helper: HelperManager
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Keel helper").font(Theme.bodyStrong)
                    Chip(text: helper.state.rawValue.uppercased(), color: helper.state == .enabled ? Theme.on : (helper.state == .needsApproval ? Theme.warn : Theme.neutral),
                         filled: helper.state == .enabled)
                }
                Text(helper.detail).font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Optional. It runs only Keel's allow-listed operations (pmset, a few sysctls, launchd plists, DNS, firewall, Time Machine exclusions), never arbitrary commands.")
                    .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch helper.state {
            case .notInstalled, .outdated: Button("Install") { helper.install() }.buttonStyle(KeelButtonStyle(small: true))
            case .needsApproval: Button("Open Login Items") { helper.install() }.buttonStyle(KeelButtonStyle(small: true))
            case .enabled: Button("Remove") { helper.uninstall() }.buttonStyle(KeelButtonStyle(small: true))
            case .unavailable: EmptyView()
            }
        }
    }
}
