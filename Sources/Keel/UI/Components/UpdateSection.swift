import SwiftUI

/// Settings card for the update check. Download opens the DMG in the browser; nothing is installed.
struct UpdateSection: View {
    @Bindable var checker: UpdateChecker = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Keel \(UpdateChecker.currentVersionString)").font(Theme.bodyStrong)
                        chip
                    }
                    Text(detail).font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if checker.status == .checking { ProgressView().controlSize(.mini) }
                    if case .available(let r) = checker.status {
                        Button("Download") { checker.openDownload(r) }.buttonStyle(KeelButtonStyle(kind: .primary, small: true))
                    }
                    Button("Check now") { Task { await checker.check() } }
                        .buttonStyle(KeelButtonStyle(small: true))
                        .disabled(checker.status == .checking || checker.status == .notConfigured)
                }
            }

            if case .available(let r) = checker.status {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.name).font(.system(size: 12.5, weight: .semibold))
                        if let d = r.publishedAt { Text(d.formatted(date: .abbreviated, time: .omitted)).font(Theme.monoSmall).foregroundStyle(.secondary) }
                        if let s = r.dmgSize { Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)).font(Theme.monoSmall).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Release notes") { checker.openReleasePage(r) }.buttonStyle(KeelButtonStyle(kind: .ghost, small: true))
                    }
                    if !r.notesExcerpt.isEmpty {
                        Text(r.notesExcerpt).font(Theme.small).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Text("Download opens the disk image in your browser. Quit Keel, then drag the new version to Applications to replace this one. Your settings and recorded originals are kept.")
                        .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            }

            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check for updates once a day").font(Theme.bodyStrong)
                    Text("One anonymous request to api.github.com for the latest release of \(checker.repo ?? "Keel"). Nothing is downloaded or installed automatically.")
                        .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Check for updates once a day", isOn: $checker.automatic).toggleStyle(FlatToggleStyle()).disabled(checker.repo == nil)
            }
        }
        .card()
        .onAppear { checker.startAutomaticChecks() }
    }

    private var chip: some View {
        switch checker.status {
        case .upToDate: return Chip(text: "UP TO DATE", color: Theme.on, filled: true)
        case .available(let r): return Chip(text: "\(r.version?.description ?? r.tag) AVAILABLE", color: Theme.warn)
        case .checking: return Chip(text: "CHECKING")
        case .failed: return Chip(text: "CHECK FAILED", color: Theme.fail)
        case .noReleases: return Chip(text: "NO RELEASES")
        case .notConfigured: return Chip(text: "OFF IN THIS BUILD")
        case .idle: return Chip(text: checker.lastChecked == nil ? "NOT CHECKED" : "CHECKED")
        }
    }

    private var detail: String {
        let last = checker.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Not checked yet."
        switch checker.status {
        case .upToDate: return "You have the latest version. \(last)"
        case .available(let r): return "Version \(r.version?.description ?? r.tag) is available. \(last)"
        case .checking: return "Asking GitHub for the latest release…"
        case .failed(let why): return "\(why) \(last)"
        case .noReleases: return "No public release was found on GitHub. \(last)"
        case .notConfigured: return "This build has no update source (KeelUpdateRepo is not set)."
        case .idle: return last
        }
    }
}
