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
        if args.contains("--catalog-json") { await CLI.catalogJSON(); exit(0) }
        if args.contains("--move-check") { await CLI.moveCheck(); exit(0) }
        #if DEBUG
        if let i = args.firstIndex(of: "--render-onboarding"), args.count > i + 1 { await MainActor.run { DebugHarness.renderOnboarding(dir: args[i + 1]) }; exit(0) }
        #endif
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
        // AppKit refuses a quit request while a sheet is open, which breaks macOS's "Quit & Reopen"
        // after a permission is granted. Handle the request here: close sheets, then quit.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            Navigator.shared.page = MainView.initialPage()
            if let t = MainView.initialTweak() { Navigator.shared.openTweak(t) }
            if ProcessInfo.processInfo.environment["KEEL_MOVE_TEST_DIR"] == nil { ActivityLog.shared.info("Keel started") }
            UpdateChecker.shared.startAutomaticChecks()
            try? await Task.sleep(for: .milliseconds(400))
            AppMover.offerIfNeeded()
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
    @objc func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { AppDelegate.quit() }
    }

    /// Closes any open sheet and quits. Used for quit requests from macOS and the menu bar.
    @MainActor static func quit() {
        Navigator.shared.showOnboarding = false
        ChangeCenter.shared.cancel()
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        if NSApp.modalWindow != nil { NSApp.stopModal() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.terminate(nil)
        }
    }

    /// Changes and cleanups that are running finish first, so quitting never interrupts them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let busy = { TweakStore.shared.running > 0 || CleanupModel.shared.cleaning }
            guard busy() else { return .terminateNow }
            ActivityLog.shared.info("Quitting after the current changes finish")
            Task { @MainActor in
                while busy() { try? await Task.sleep(for: .milliseconds(200)) }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
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
