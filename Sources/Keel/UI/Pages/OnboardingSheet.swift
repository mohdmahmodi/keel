import SwiftUI

/// First-run welcome in three steps: what Keel does, optional access, and a baseline benchmark.
/// The current step is saved, so the sheet resumes where it was if macOS quits and reopens Keel
/// after a permission is granted.
struct OnboardingSheet: View {
    let done: () -> Void
    @AppStorage("onboardingStep") private var step = 0
    @Bindable private var helper = HelperManager.shared
    @State private var fullDiskAccess = Permissions.hasFullDiskAccess

    private let steps = ["Welcome", "Access", "Baseline"]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: access
                default: baseline
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(28)
            .frame(height: 340, alignment: .top)
            .id(step)
            .transition(.opacity)

            HLine()
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { i in
                        Capsule().fill(i == step ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .accessibilityElement().accessibilityLabel("Step \(step + 1) of \(steps.count)")
                Spacer()
                if step > 0 {
                    Button("Back") { go(step - 1) }.buttonStyle(.keelGhost)
                }
                switch step {
                case 0: Button("Continue") { go(1) }.buttonStyle(.keelPrimary).keyboardShortcut(.defaultAction)
                case 1: Button("Continue") { go(2) }.buttonStyle(.keelPrimary).keyboardShortcut(.defaultAction)
                default:
                    Button("Skip for now") { finish() }.buttonStyle(.keelGhost)
                    Button("Run baseline") { runBaseline() }.buttonStyle(.keelPrimary).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 600)
        .background(Theme.raisedBG)
        .animation(.easeOut(duration: 0.2), value: step)
        .onAppear { helper.refresh() }
        .task(id: step) {
            // Keep the access step current while the user is in System Settings.
            guard step == 1 else { return }
            while !Task.isCancelled {
                Permissions.recheckFullDiskAccess()
                fullDiskAccess = await Task.detached { Permissions.hasFullDiskAccess }.value
                helper.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Keel").font(.system(size: 22, weight: .semibold))
                    Text("Tune macOS with changes you can always undo.").font(Theme.body).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                point("eye", "Reads before it changes", "Every setting is read and recorded before Keel touches it.")
                point("arrow.uturn.backward", "Undo any setting", "Switch a tweak off and the original value comes back exactly.")
                point("hand.raised", "Nothing without you", "No change is made until you review it and confirm.")
                point("lock", "Stays on your Mac", "No account, no analytics. Nothing is sent anywhere.")
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Optional access").font(.system(size: 22, weight: .semibold))
                Text("Keel works without these. Each one makes a part of it smoother.").font(Theme.body).foregroundStyle(.secondary)
            }
            permission(symbol: "person.badge.shield.checkmark", title: "Keel helper",
                       detail: helper.state == .unavailable
                           ? "This build can't install the helper. Changes that need admin rights ask for your password once per batch."
                           : "Admin changes run without a password prompt. It runs only Keel's allow-listed operations.",
                       granted: helper.state == .enabled,
                       status: helper.state == .needsApproval ? "Waiting for approval" : nil) {
                switch helper.state {
                case .notInstalled, .outdated: Button("Install") { helper.install() }.buttonStyle(KeelButtonStyle(small: true))
                case .needsApproval: Button("Open Login Items") { helper.install() }.buttonStyle(KeelButtonStyle(small: true))
                default: EmptyView()
                }
            }
            permission(symbol: "lock.shield", title: "Full Disk Access",
                       detail: "Cleanup can also measure the Trash, Mail downloads and device backups.",
                       granted: fullDiskAccess, status: nil) {
                if !fullDiskAccess {
                    Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.buttonStyle(KeelButtonStyle(small: true))
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("If macOS offers to quit and reopen Keel after you allow access, choose Quit & Reopen. Keel comes back to this step.")
                    .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var baseline: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Measure your Mac first").font(.system(size: 22, weight: .semibold))
                Text("A baseline makes every later change measurable.").font(Theme.body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                point("stopwatch", "About a minute", "CPU, GPU, memory, SSD, network and DNS. Keep other apps quiet while it runs.")
                point("arrow.left.arrow.right", "Compare after changes", "Run it again after turning tweaks on, and Keel shows what changed beyond normal noise.")
                point("internaldrive", "Saved on this Mac", "Results stay in Keel's folder. The network tests contact your router and public DNS servers.")
            }
        }
    }

    // MARK: Parts

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 22, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodyStrong)
                Text(detail).font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permission<A: View>(symbol: String, title: String, detail: String, granted: Bool, status: String?, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.bodyStrong)
                    if granted { Chip(text: "ON", color: Theme.on, filled: true) }
                    else if let status { Chip(text: status.uppercased(), color: Theme.warn, filled: true) }
                }
                Text(detail).font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.on).accessibilityLabel("Allowed")
            } else {
                action()
            }
        }
        .card(padding: 12)
    }

    // MARK: Actions

    private func go(_ s: Int) { step = max(0, min(s, steps.count - 1)) }

    private func finish() {
        step = 0
        done()
    }

    private func runBaseline() {
        finish()
        Navigator.shared.open(.benchmark)
        Task { await BenchmarkRunner.shared.run(label: "Baseline") }
    }
}
