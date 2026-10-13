#if DEBUG
import SwiftUI
import AppKit
import QuartzCore

/// Launch-argument tooling for debug builds. Never changes system settings.
@MainActor
enum DebugHarness {
    /// `--stress-ui`: runs every navigation and prints how long the main queue stays busy after each.
    static func stress() async {
        let store = TweakStore.shared, nav = Navigator.shared, center = ChangeCenter.shared
        while store.detecting || store.lastDetect == nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(1))
        var stats: [String: [Double]] = [:]
        func hop() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
        func step(_ name: String, _ f: () -> Void) async {
            let t0 = CACurrentMediaTime()
            f()
            await hop(); await hop()
            stats[name, default: []].append((CACurrentMediaTime() - t0) * 1000)
            try? await Task.sleep(for: .milliseconds(25))
        }
        let ids = store.items.map(\.id)
        let sheetOnly = CommandLine.arguments.contains("--stress-sheet")
        for _ in 0..<(sheetOnly || CommandLine.arguments.contains("--stress-drawer") ? 6 : 3) {
            if sheetOnly {
                let batch = store.items.filter { !$0.tweak.isManual && $0.isApplicable }.prefix(20).map(\.tweak)
                await step("sheet open (\(batch.count))") { center.requestBatch(Array(batch), on: true, title: "Stress test") }
                try? await Task.sleep(for: .milliseconds(500))
                await step("sheet cancel") { center.cancel() }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            if CommandLine.arguments.contains("--stress-drawer") {
                await step("page Tweaks") { nav.open(.tweaks) }
                let visible = TweakSections.build(states: TweakDigest.shared.states, busy: [], filter: .all, category: nil, audience: nil, search: "").first?.ids.prefix(4) ?? []
                for _ in 0..<5 { for id in visible { await step("drawer switch (visible)") { nav.selectedTweak = id } } }
                for id in stride(from: 0, to: ids.count, by: max(1, ids.count / 20)).map({ ids[$0] }) { await step("drawer+scroll") { nav.selectedTweak = id } }
                await step("drawer close") { nav.selectedTweak = nil }
                continue
            }
            for p in Page.allCases { await step("page \(p.rawValue)") { nav.open(p) } }
            await step("page Tweaks") { nav.open(.tweaks) }
            for f in TweakFilter.allCases { await step("filter") { nav.filter = f } }
            await step("filter") { nav.filter = .all }
            for c in TweakCategory.allCases { await step("category") { nav.category = c } }
            await step("category") { nav.category = nil }
            for a in Audience.allCases { await step("audience") { nav.audience = a } }
            await step("audience") { nav.audience = nil }
            for q in ["d", "do", "doc", "dock", "", "p", "po", "pow", "power", "", "xyz", ""] { await step("search") { nav.search = q } }
            for id in stride(from: 0, to: ids.count, by: max(1, ids.count / 25)).map({ ids[$0] }) { await step("drawer+scroll") { nav.selectedTweak = id } }
            await step("drawer close") { nav.selectedTweak = nil }
            let batch = store.items.filter { !$0.tweak.isManual && $0.isApplicable }.prefix(20).map(\.tweak)
            await step("sheet open (\(batch.count))") { center.requestBatch(Array(batch), on: true, title: "Stress test") }
            try? await Task.sleep(for: .milliseconds(400))
            await step("sheet cancel") { center.cancel() }
            try? await Task.sleep(for: .milliseconds(400))
        }
        var out = "UI stress (ms, main thread busy after each change)\n"
        for (k, v) in stats.sorted(by: { $0.key < $1.key }) {
            let avg = v.reduce(0, +) / Double(v.count)
            let p90 = v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.9))]
            out += "\(k.padding(toLength: 26, withPad: " ", startingAt: 0)) n=\(v.count)  avg \(String(format: "%.1f", avg))  p90 \(String(format: "%.1f", p90))  max \(String(format: "%.1f", v.max() ?? 0))\n"
        }
        FileHandle.standardError.write(out.data(using: .utf8)!)
        nav.open(.tweaks)
    }

    /// `--snapshots <dir>`: renders every page, sheet and the menu panel to PNGs in both appearances.
    static func snapshots(dir: String) async {
        let store = TweakStore.shared, nav = Navigator.shared, center = ChangeCenter.shared
        while store.detecting || store.lastDetect == nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Wait for the cleanup scan so no page is captured mid-measurement.
        let cleanup = CleanupModel.shared
        if cleanup.lastScan == nil && !cleanup.scanning { Task { await cleanup.scan() } }
        for _ in 0..<600 where cleanup.lastScan == nil || cleanup.scanning || !cleanup.measuring.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(1))
        guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { return }
        func save(_ view: NSView, _ name: String) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) }
        }
        func settle(_ s: Double = 1.2) async { try? await Task.sleep(for: .seconds(s)) }
        let drawerID = CommandLine.arguments.firstIndex(of: "--tweak").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil } ?? store.items.first?.id
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (tag, size) in [("1280", NSSize(width: 1280, height: 820)), ("min", NSSize(width: 1120, height: 720))] {
                win.setFrame(NSRect(origin: win.frame.origin, size: size), display: true)
                for p in Page.allCases {
                    nav.selectedTweak = nil
                    nav.open(p)
                    await settle(p == .overview ? 2.5 : 1.2)
                    for _ in 0..<240 where cleanup.scanning || !cleanup.measuring.isEmpty {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    if p == .cleanup { await settle(0.6) }
                    save(win.contentView!, "\(p.rawValue.lowercased())-\(tag)-\(theme)")
                }
                nav.open(.tweaks); nav.selectedTweak = drawerID
                await settle()
                save(win.contentView!, "tweaks-drawer-\(tag)-\(theme)")
                nav.selectedTweak = nil
            }
            win.setFrame(NSRect(origin: win.frame.origin, size: NSSize(width: 1280, height: 820)), display: true)
            nav.open(.tweaks)
            let batch = TweakDigest.shared.recommendedPendingTweaks.isEmpty
                ? Array(store.items.filter { !$0.tweak.isManual && $0.isApplicable }.prefix(4).map(\.tweak))
                : TweakDigest.shared.recommendedPendingTweaks
            center.requestBatch(batch, on: true, title: "Turn on \(batch.count) recommended changes")
            await settle()
            save(win.contentView!, "confirm-\(theme)")
            center.cancel()
            nav.showOnboarding = true
            await settle(1.5)
            if let sheet = win.attachedSheet ?? NSApp.windows.first(where: { $0.isSheet }) { save(sheet.contentView!, "onboarding-\(theme)") }
            nav.showOnboarding = false
            await settle(0.8)
            showMenuPreview()
            await settle(1.5)
            if let p = preview { save(p.contentView!, "menubar-\(theme)"); p.close(); preview = nil }
        }
        FileHandle.standardError.write("snapshots written to \(dir)\n".data(using: .utf8)!)
        NSApp.terminate(nil)
    }

    /// `--menu-preview`: shows the menu bar panel in a normal window so it can be captured.
    static func showMenuPreview() {
        let host = NSHostingView(rootView: MenuBarPanel())
        let w = NSWindow(contentRect: NSRect(x: 80, y: 200, width: 320, height: 300), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Keel menu preview"
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        preview = w
    }
    private static var preview: NSWindow?
}
#endif
