import SwiftUI
import AppKit

@main
struct KeelMain {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--machine") { await CLI.machine(); exit(0) }
        if args.contains("--validate-ops") { await CLI.validateOps(); exit(0) }
        if args.contains("--engine-test") { await CLI.engineTest(); exit(0) }
        if args.contains("--permissions") { CLI.permissions(); exit(0) }
        if args.contains("--lint") { exit(await CLI.lint()) }
        if args.contains("--selftest-defaults") { await CLI.selfTestDefaults(); exit(0) }
        if args.contains("--selftest-custom") { await CLI.selfTestCustom(); exit(0) }
        if args.contains("--selftest-launchd") { await CLI.selfTestLaunchd(); exit(0) }
        if args.contains("--helper-test") { await CLI.helperTest(); exit(0) }
        if args.contains("--simulate") { await CLI.simulate(); exit(0) }
        if args.contains("--detect") { await CLI.detect(); exit(0) }
        if args.contains("--cleanup-scan") { await CLI.cleanupScan(); exit(0) }
        if args.contains("--cleanup-selftest") { exit(await CLI.cleanupSelfTest()) }
        if args.contains("--screenshots") { await CLI.screenshots(); exit(0) }
        if args.contains("--selftest") { await CLI.selfTest(); exit(0) }
        if args.contains("--benchmark") { await CLI.benchmark(); exit(0) }
        KeelApp.main()
    }
}

struct KeelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var settings = AppSettings.shared

    var body: some Scene {
        Window("Keel", id: "main") {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        .commands { KeelCommands() }

        MenuBarExtra(isInserted: $settings.keepInMenuBar) {
            MenuBarPanel()
        } label: {
            Image(systemName: "sailboat")
                .accessibilityLabel("Keel")
        }
        .menuBarExtraStyle(.window)
    }
}

struct KeelCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { go(.settings) }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(before: .toolbar) {
            Button("Re-detect") { AppStartup.redetect() }.keyboardShortcut("r", modifiers: .command)
            Divider()
        }
        CommandMenu("Go") {
            ForEach(Page.allCases) { p in
                Button(p.rawValue) { go(p) }.keyboardShortcut(p.shortcut, modifiers: .command)
            }
            Divider()
            Button("Search Tweaks") { AppDelegate.showMain(); Navigator.shared.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Turn On Recommended…") {
                AppDelegate.showMain()
                let list = TweakDigest.shared.recommendedPendingTweaks
                ChangeCenter.shared.requestBatch(list, on: true, title: "Turn on \(list.count) recommended change\(list.count == 1 ? "" : "s")")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(TweakDigest.shared.recommendedPending.isEmpty)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Keel") { AppDelegate.showMain(); Navigator.shared.showOnboarding = true }
        }
    }

    @MainActor private func go(_ p: Page) {
        AppDelegate.showMain()
        Navigator.shared.open(p)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            Navigator.shared.page = MainView.initialPage()
            if let t = MainView.initialTweak() { Navigator.shared.openTweak(t) }
            ActivityLog.shared.info("Keel started")
            UpdateChecker.shared.startAutomaticChecks()
            #if DEBUG
            // --window-size WxH, for screenshots.
            if let i = CommandLine.arguments.firstIndex(of: "--window-size"), CommandLine.arguments.count > i + 1 {
                let p = CommandLine.arguments[i + 1].split(separator: "x").compactMap { Double($0) }
                if p.count == 2 {
                    try? await Task.sleep(for: .milliseconds(1500))
                    if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: p[0], height: p[1]), display: true)
                    }
                }
            }
            #endif
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppSettings.shared.keepInMenuBar }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppDelegate.showMain() } }
        return true
    }
    @MainActor static func showMain() {
        NSApp.setActivationPolicy(.regular)
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain && ($0.identifier?.rawValue.contains("main") == true || $0.title == "Keel") }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            OpenWindowBridge.open?("main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Lets AppKit code reopen the main window; SwiftUI owns window creation.
@MainActor
enum OpenWindowBridge {
    static var open: ((String) -> Void)? = nil
}
