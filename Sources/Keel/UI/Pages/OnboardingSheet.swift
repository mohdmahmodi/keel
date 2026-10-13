import SwiftUI

/// First-run sheet: what Keel does and does not do, and the two optional permissions.
struct OnboardingSheet: View {
    let done: () -> Void
    @Bindable private var helper = HelperManager.shared
    private var info: SystemInfo { SystemInfo.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sailboat").font(.system(size: 18, weight: .semibold)).accessibilityHidden(true)
                    Text("Welcome to Keel").font(.system(size: 20, weight: .semibold))
                }
                Text("Keel checks how this Mac is set up and offers changes that are explained, verified after they are made, and reversible.")
                    .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            HLine()
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    column("What it does", symbol: "checkmark.circle", tint: Theme.on, lines: [
                        "Reads live state: memory, storage, power, network and every tweak.",
                        "Shows the exact command behind each change.",
                        "Records the original value before changing anything.",
                        "Verifies each change and restores anything that does not stick.",
                    ])
                    column("What it does not do", symbol: "xmark.circle", tint: Theme.fail, lines: [
                        "Change anything without your confirmation.",
                        "Send any data off this Mac.",
                        "Ask you to turn off SIP, Gatekeeper or FileVault.",
                        "Promise speed-ups it cannot show. Cosmetic tweaks are labelled.",
                    ])
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "stopwatch").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start with a benchmark").font(Theme.bodyStrong)
                        Text("Run one before you change anything. It becomes your baseline, so you can compare after each change and see what actually improved.")
                            .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Run benchmark") { done(); Navigator.shared.open(.benchmark) }.buttonStyle(KeelButtonStyle(small: true))
                }
                .card(padding: 12)
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Optional")
                    permission(symbol: "person.badge.shield.checkmark", title: "Keel helper",
                               detail: helper.state == .unavailable
                                   ? "Changes that need admin rights ask for your password once per batch."
                                   : "Lets admin changes run without a password prompt. It runs only Keel's allow-listed operations.",
                               chip: helper.state.rawValue.uppercased(), chipColor: helper.state == .enabled ? Theme.on : (helper.state == .needsApproval ? Theme.warn : Theme.neutral)) {
                        switch helper.state {
                        case .notInstalled, .outdated: Button("Install") { helper.install() }.buttonStyle(KeelButtonStyle(small: true))
                        case .needsApproval: Button("Open Login Items") { helper.install() }.buttonStyle(KeelButtonStyle(small: true))
                        default: EmptyView()
                        }
                    }
                    permission(symbol: "lock.shield", title: "Full Disk Access",
                               detail: "Lets Cleanup measure Mail downloads, iOS backups and the Trash. Everything else works without it.",
                               chip: info.hasFullDiskAccess == true ? "GRANTED" : "NOT GRANTED", chipColor: info.hasFullDiskAccess == true ? Theme.on : Theme.neutral) {
                        if info.hasFullDiskAccess != true {
                            Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(KeelButtonStyle(small: true))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Recorded originals are kept in").font(Theme.small).foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.backups])
                    } label: {
                        Text("~/Library/Application Support/Keel/backups").font(Theme.monoSmall).underline()
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
            .padding(22)
            HLine()
            HStack {
                Text("Nothing has been changed.").font(Theme.small).foregroundStyle(.secondary)
                Spacer()
                Button("Get started", action: done).buttonStyle(.keelPrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 640)
        .background(Theme.raisedBG)
        .onAppear { helper.refresh() }
    }

    private func column(_ title: String, symbol: String, tint: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            ForEach(lines, id: \.self) { Bullet(text: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 12)
    }

    private func permission<A: View>(symbol: String, title: String, detail: String, chip: String, chipColor: Color, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.bodyStrong)
                    Chip(text: chip, color: chipColor, filled: chipColor != Theme.neutral)
                }
                Text(detail).font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .card(padding: 12)
    }
}
