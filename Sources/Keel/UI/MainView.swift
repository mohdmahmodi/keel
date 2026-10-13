import SwiftUI
import AppKit

struct MainView: View {
    /// Set only by headless screenshot rendering; the app itself navigates through `Navigator`.
    private let forcedPage: Page?
    private let forcedTweak: String?
    @State private var nav = Navigator.shared
    @State private var center = ChangeCenter.shared
    @State private var settings = AppSettings.shared

    init(page: Page? = nil, selectedTweak: String? = nil) {
        forcedPage = page
        forcedTweak = selectedTweak
    }

    private var page: Page { forcedPage ?? nav.page }
    private var drawerID: String? { forcedPage != nil ? forcedTweak : nav.selectedTweak }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar(nav: nav, current: page)
                    .frame(width: 188)
                VLine()
                PageContent(page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                if let id = drawerID, let item = TweakStore.shared.item(id), page == .tweaks || page == .overview {
                    HStack(spacing: 0) {
                        VLine()
                        TweakDrawer(item: item, intent: center.intent(id), close: { nav.selectedTweak = nil })
                            .frame(width: 360)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Animate opening and closing only; switching tweaks with the drawer open must not animate the whole window.
            .animation(.easeOut(duration: 0.18), value: drawerID != nil)
            ActivityStrip(log: ActivityLog.shared) { nav.open(.activity) }
        }
        .allowsHitTesting(center.pending == nil)
        .frame(minWidth: 1120, minHeight: 692) // 720 pt window including the title bar area
        .background(Theme.bg)
        .tint(Color.primary)
        // The confirmation is an in-window overlay, not an AppKit sheet: AppKit runs the sheet's
        // open/close animation synchronously on the main thread (about 250 ms each way).
        .overlay {
            ZStack {
                if let p = center.pending {
                    ModalOverlay(onDismiss: { center.cancel() }) {
                        ConfirmSheet(change: p,
                                     onConfirm: { sel, snap in center.confirm(p, selected: sel, snapshot: snap) },
                                     onCancel: { center.cancel() })
                    }
                    .id(p.id)
                }
            }
            .animation(.easeOut(duration: 0.12), value: center.pending?.id)
        }
        .sheet(isPresented: $nav.showOnboarding) {
            OnboardingSheet { settings.onboardingDone = true; nav.showOnboarding = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            center.recheckManual()
            HelperManager.shared.refresh()
        }
        .task { await AppStartup.run() }
        .background(OpenWindowCapture())
    }

    static func initialPage() -> Page {
        if let i = CommandLine.arguments.firstIndex(of: "--page"), CommandLine.arguments.count > i + 1,
           let p = Page(rawValue: CommandLine.arguments[i + 1].capitalized) { return p }
        return .overview
    }
    static func initialTweak() -> String? {
        if let i = CommandLine.arguments.firstIndex(of: "--tweak"), CommandLine.arguments.count > i + 1 { return CommandLine.arguments[i + 1] }
        return nil
    }
}

/// One-time startup work, kept off the view body. Detection and the first system read run in parallel.
@MainActor
enum AppStartup {
    private static var done = false
    static func run() async {
        guard !done else { return }
        done = true
        TweakDigest.shared.start()
        OverviewModel.shared.start()
        _ = await Machine.profile()
        HelperManager.shared.refresh()
        Task.detached(priority: .utility) { _ = BackupStore.all() }
        if !AppSettings.shared.onboardingDone && !CommandLine.arguments.contains("--no-onboarding") {
            try? await Task.sleep(for: .milliseconds(400))
            Navigator.shared.showOnboarding = true
        }
        async let login: Void = AppSettings.shared.refreshLogin()
        async let detect: Void = TweakStore.shared.detectAll()
        async let info: Void = SystemInfo.shared.refresh()
        _ = await (login, detect, info)
        #if DEBUG
        if CommandLine.arguments.contains("--stress-ui") { Task { await DebugHarness.stress() } }
        if CommandLine.arguments.contains("--menu-preview") { DebugHarness.showMenuPreview() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), CommandLine.arguments.count > i + 1 {
            let dir = CommandLine.arguments[i + 1]
            Task { await DebugHarness.snapshots(dir: dir) }
        }
        // Nothing runs unless Apply is pressed.
        if CommandLine.arguments.contains("--preview-confirm") {
            let list = TweakStore.shared.items.filter { !$0.tweak.isManual && $0.isApplicable }.prefix(4).map(\.tweak)
            ChangeCenter.shared.requestBatch(Array(list), on: true, title: "Turn on \(list.count) recommended changes")
        }
        #endif
    }

    /// ⌘R: re-read the machine and re-detect every tweak.
    static func redetect() {
        Task {
            async let d: Void = TweakStore.shared.detectAll()
            async let r: Void = SystemInfo.shared.refresh()
            _ = await (d, r)
        }
    }
}

/// The page area. Pages are separate views so switching only builds the visible one.
private struct PageContent: View {
    let page: Page
    var body: some View {
        switch page {
        case .overview: OverviewPage()
        case .tweaks: TweaksPage()
        case .cleanup: CleanupHost()
        case .benchmark: BenchmarkPage(runner: BenchmarkRunner.shared)
        case .activity: ActivityPage(log: ActivityLog.shared)
        case .settings: SettingsPage(settings: AppSettings.shared)
        }
    }
}

/// Measures Cleanup the first time the page is opened instead of at launch.
private struct CleanupHost: View {
    @State private var model = CleanupModel.shared
    var body: some View {
        CleanupPage(model: model)
            .task { if model.lastScan == nil && !model.scanning { await model.scan() } }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let nav: Navigator
    let current: Page
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40) // traffic lights
            HStack(spacing: 8) {
                Image(systemName: "sailboat").font(.system(size: 14, weight: .semibold)).accessibilityHidden(true)
                Text("Keel").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
            VStack(spacing: 2) {
                ForEach(Page.allCases) { p in SidebarRow(page: p, selected: current == p) { nav.open(p) } }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 12)
            SidebarStats()
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .background {
            #if DEBUG
            if CommandLine.arguments.contains("--no-vibrancy") { Theme.sidebarBG } else { VisualEffect(material: .sidebar) }
            #else
            VisualEffect(material: .sidebar)
            #endif
        }
    }
}

private struct SidebarRow: View {
    let page: Page
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    private var digest: TweakDigest { TweakDigest.shared }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.symbol).font(.system(size: 12.5)).frame(width: 18).foregroundStyle(selected ? .primary : .secondary)
                Text(page.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if page == .tweaks, !digest.recommendedPending.isEmpty {
                    Text("\(digest.recommendedPending.count)").font(Theme.monoSmall).foregroundStyle(.secondary)
                        .help("\(digest.recommendedPending.count) recommended changes are off")
                }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(selected ? Theme.selection : (hover ? Theme.hover : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(page.rawValue) (⌘\(String(page.shortcut.character)))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Bottom of the sidebar. Its own view so live updates re-render only this.
private struct SidebarStats: View {
    private var info: SystemInfo { SystemInfo.shared }
    var body: some View {
        let m = info.memory, s = info.storage
        VStack(alignment: .leading, spacing: 7) {
            if m.totalBytes > 0 {
                HStack(spacing: 6) {
                    Dot(color: Theme.color(for: m.pressure), size: 6)
                    Text("Memory").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(m.usedFraction * 100))%").font(Theme.monoSmall).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if s.containerBytes > 0 {
                HStack(spacing: 6) {
                    Dot(color: s.availablePercent < 15 ? Theme.warn : Theme.on, size: 6)
                    Text("Disk free").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", s.availablePercent)).font(Theme.monoSmall).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.hardware.model.isEmpty ? " " : info.hardware.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text([info.hardware.chip.replacingOccurrences(of: "Apple ", with: ""), info.hardware.osVersion.isEmpty ? "" : "macOS \(info.hardware.osVersion)"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, 4)
        }
    }
}

/// System material for the sidebar, as in other Mac apps.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Registers SwiftUI's openWindow action for AppKit callers.
private struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Color.clear.onAppear { OpenWindowBridge.open = { id in openWindow(id: id) } } }
}

/// Dimmed backdrop plus a centred panel. Clicking outside cancels; Escape and Return work through
/// the panel's own keyboard shortcuts.
struct ModalOverlay<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .padding(24)
                .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity)
    }
}
