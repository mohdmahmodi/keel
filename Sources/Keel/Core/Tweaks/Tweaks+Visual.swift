import Foundation
import AppKit
import CoreGraphics
import KeelShared

// Keys checked on macOS 27.0.1: Dock keys in the Dock binary (`strings`, or `otool -tv` for Swift small
// strings such as `mru-spaces`), AppKit and WindowManager keys in the dyld shared cache.

extension TweakCatalog {
    static let visual: [Tweak] = [
        // MARK: Dock

        Tweak(id: "dock-autohide-instant", name: "Dock appears instantly", category: .visual,
              summary: "The hidden Dock shows as soon as the pointer reaches the screen edge, with no slide.",
              explanation: "The hidden Dock appears as soon as the pointer reaches the screen edge, without the usual pause and slide-in. Keel sets the pause (com.apple.dock autohide-delay) and the slide duration (autohide-time-modifier) to 0 and restarts the Dock. Keel offers it only when Dock auto-hide is already on: it does not hide the Dock for you, because that changes your screen layout, and with auto-hide off the keys have no effect. Both keys are present in the Dock binary on macOS 27.0.1.",
              risk: .safe, impact: .low, recommended: true,
              mechanism: .defaults([
                DefaultsSetting(domain: "com.apple.dock", key: "autohide-delay", type: .float, on: "0", off: nil),
                DefaultsSetting(domain: "com.apple.dock", key: "autohide-time-modifier", type: .float, on: "0", off: nil)
              ], post: .killDock),
              sources: ["https://macos-defaults.com/dock/autohide-time-modifier.html", "https://macos-defaults.com/dock/autohide-delay.html"],
              requires: [.custom({
                  VisualSupport.bool("com.apple.dock", "autohide") == true ? nil : "Dock auto-hide is off. Turn on “Automatically hide and show the Dock” in Desktop & Dock first"
              })],
              expectedBenefit: "The Dock is there the moment the pointer reaches the edge, instead of after about half a second.",
              tradeoff: "No slide animation, and the Dock can appear when the pointer only brushes the edge.",
              audience: [.everyone]),

        Tweak(id: "dock-show-recents-off", name: "Recent apps in the Dock: off", category: .visual,
              summary: "Removes the Dock section that lists recently used apps.",
              explanation: "The Dock normally keeps up to three recently used apps in a separate section, so icons shift as you work. Keel sets com.apple.dock show-recents to false and restarts the Dock; this is the same switch as “Show suggested and recent apps in Dock” in System Settings > Desktop & Dock. The change is cosmetic.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dock", key: "show-recents", type: .bool, on: "0", off: "1")], post: .killDock),
              sources: ["Local check: show-recents present in the Dock binary on macOS 27.0.1"],
              expectedBenefit: "A shorter Dock whose icons stay where you put them.",
              tradeoff: "You lose the shortcut back to an app you recently quit.",
              audience: [.everyone]),

        Tweak(id: "dock-launchanim-off", name: "Dock icon bounce at launch: off", category: .visual,
              summary: "App icons no longer bounce in the Dock while the app opens.",
              explanation: "When an app opens, its Dock icon bounces until the app is ready. With com.apple.dock launchanim set to false (the Dock restarts to pick it up), the icon stays still. The app becomes usable at the same moment either way; only the motion is removed.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dock", key: "launchanim", type: .bool, on: "0", off: nil)], post: .killDock),
              sources: ["Local check: launchanim present in the Dock binary on macOS 27.0.1"],
              expectedBenefit: "Less movement in the Dock while apps start.",
              tradeoff: "No visual sign that an app is still starting, apart from the indicator dot.",
              audience: [.everyone]),

        Tweak(id: "dock-mineffect-scale", name: "Minimize effect: Scale", category: .visual,
              summary: "Windows shrink straight into the Dock instead of using the Genie effect.",
              explanation: "Windows shrink straight into the Dock when you minimize them, instead of bending with the Genie effect. Scale is the shorter and simpler of the two built-in effects. Keel sets com.apple.dock mineffect to scale, the same choice as the “Minimize windows using” menu in System Settings > Desktop & Dock. The change is cosmetic.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dock", key: "mineffect", type: .string, on: "scale", off: "genie")], post: .killDock),
              sources: ["https://eclecticlight.co/2026/04/27/the-minimise-easter-egg-lives-on/"],
              expectedBenefit: "Minimizing looks quicker and simpler.",
              tradeoff: "Nothing noticeable.",
              audience: [.everyone]),

        Tweak(id: "spaces-rearrange-off", name: "Keep Spaces in a fixed order", category: .visual,
              summary: "Mission Control stops reordering your desktops by most recent use.",
              explanation: "Your desktops (Spaces) stay in the order you set, instead of macOS moving the one you used most recently next to the current one. Without this, desktops change order and Control-arrow lands somewhere unexpected. Keel sets com.apple.dock mru-spaces to false, which is the “Automatically rearrange Spaces based on most recent use” switch in System Settings > Desktop & Dock, and restarts the Dock. On macOS 27.0.1 the key is stored as a Swift string inside the Dock binary and was found by its inline bytes.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dock", key: "mru-spaces", type: .bool, on: "0", off: nil)], post: .killDock),
              sources: ["https://www.macsparky.com/blog/2022/06/the-worst-default-setting-on-the-mac/", "https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: otool -tv Dock shows the Swift small string \"mru-spaces\" (3 sites) on macOS 27.0.1"],
              expectedBenefit: "Each desktop stays in the same position, so Control-number and Control-arrow always reach the same Space.",
              tradeoff: "The Space you used last is no longer moved next to the current one.",
              audience: [.everyone]),

        Tweak(id: "mission-control-group-apps", name: "Group windows by app in Mission Control", category: .visual,
              summary: "Mission Control stacks each app's windows together.",
              explanation: "Mission Control normally spreads every window out separately. With grouping on, windows from the same app sit together, which makes busy desktops easier to scan. The key is com.apple.dock expose-group-apps (the “Group windows by application” switch in System Settings > Desktop & Dock); the Dock restarts to apply it. The change is cosmetic.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dock", key: "expose-group-apps", type: .bool, on: "1", off: nil)], post: .killDock),
              sources: ["https://macos-defaults.com/mission-control/expose-group-apps.html", "Local check: expose-group-apps present in the Dock binary on macOS 27.0.1"],
              expectedBenefit: "With many windows open, the right one is easier to find in Mission Control.",
              tradeoff: "Windows are shown smaller and partly overlap each other.",
              audience: [.everyone]),

        // MARK: Windows (WindowManager, AppKit)

        Tweak(id: "tiled-window-margins-off", name: "Tiled windows without gaps", category: .visual,
              summary: "Windows snapped to halves or quarters fill the screen edge to edge.",
              explanation: "Windows snapped to half or a quarter of the screen lose the gap that macOS leaves around them. Tiling arrived in macOS 15: drag a window to a screen edge, or use Window > Move & Resize. Keel sets com.apple.WindowManager EnableTiledWindowMargins to false, the “Tiled windows have margins” switch in System Settings > Desktop & Dock. It takes effect immediately.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.WindowManager", key: "EnableTiledWindowMargins", type: .bool, on: "0", off: nil)], post: .none),
              sources: ["https://mynixos.com/nix-darwin/option/system.defaults.WindowManager.EnableTiledWindowMargins", "Local check: string present in the macOS 27.0.1 dyld shared cache (WindowManager)"],
              requires: [.minMacOS(15)],
              expectedBenefit: "More room for content when two or four windows are tiled.",
              tradeoff: "No visual separation between tiled windows.",
              audience: [.everyone]),

        Tweak(id: "stage-manager-off", name: "Stage Manager is off", category: .visual,
              summary: "Shows whether Stage Manager is on. Keel only reads this setting.",
              explanation: "Stage Manager shows live thumbnails of your other apps in a strip at the side of the screen and groups windows into sets. Some people rely on it; if it was turned on by accident, it moves windows around in ways that are hard to follow. Keel reads com.apple.WindowManager GloballyEnabled and opens System Settings > Desktop & Dock so you can choose. No speed difference has been measured, so this is a workflow choice.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let on = VisualSupport.bool("com.apple.WindowManager", "GloballyEnabled") == true
                  return Detection(state: on ? .off : .on, values: [("com.apple.WindowManager GloballyEnabled", on ? "1 (Stage Manager on)" : VisualSupport.raw("com.apple.WindowManager", "GloballyEnabled"))])
              }, settingsURL: "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
                 instructions: "System Settings > Desktop & Dock > Stage Manager (or Control Center > Stage Manager)")),
              sources: ["Local check: GloballyEnabled present in the macOS 27.0.1 dyld shared cache (WindowManager)"],
              confidence: .medium,
              expectedBenefit: "Windows stay where you put them, with no thumbnail strip at the screen edge.",
              tradeoff: "You lose Stage Manager's window sets if you used them.",
              audience: [.everyone]),

        Tweak(id: "window-drag-anywhere", name: "Move windows by dragging anywhere", category: .visual,
              summary: "Hold Control and Command and drag any part of a window to move it.",
              explanation: "With Control and Command held down, you can drag a window from any point inside it, not only by its title bar, which is thin or hidden in many current apps. The switch is NSWindowShouldDragOnGesture in the global domain, an AppKit option that Apple does not document; the key is present in the macOS 27.0.1 AppKit code. Apps read it when they open, so quit and reopen them, or log out.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSWindowShouldDragOnGesture", type: .bool, on: "1", off: nil)], post: .relaunchApp),
              sources: ["https://forums.macrumors.com/threads/drag-a-window-with-gesture.2351653/", "Local check: string present in the macOS 27.0.1 dyld shared cache (AppKit)"],
              confidence: .medium,
              expectedBenefit: "Windows can be moved from any point, including apps with no visible title bar.",
              tradeoff: "Control-Command-drag inside a window no longer reaches the app itself, which few apps use.",
              audience: [.everyone]),

        Tweak(id: "window-animations-off", name: "Window open animation: off", category: .visual,
              summary: "New windows and sheets appear at once instead of zooming in.",
              explanation: "New windows and dialog sheets appear in place instead of growing in with a short zoom. Keel sets NSAutomaticWindowAnimationsEnabled to false in the global domain; the key is present in AppKit on macOS 27.0.1, but its effect has not been retested on macOS 26 or later. Apps read it when they open, and logging out applies it everywhere. The zoom lasts roughly 0.2 s, so the Mac feels quicker without doing any more work.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", type: .bool, on: "0", off: nil)], post: .logout),
              sources: ["https://github.com/mathiasbynens/dotfiles/blob/main/.macos", "Local check (macOS 27.0): NSAutomaticWindowAnimationsEnabled present in AppKit"], confidence: .medium,
              expectedBenefit: "Windows and dialogs appear as soon as you open them.",
              tradeoff: "Less visual cue about where a new window came from.",
              audience: [.everyone]),

        Tweak(id: "window-resize-instant", name: "Instant sheet and zoom resizing", category: .visual,
              summary: "Windows that resize themselves do so in 1 ms instead of about 200 ms.",
              explanation: "When an app resizes a window by itself (a sheet sliding out, the green zoom button, a settings window changing tabs), the change happens at once instead of animating. AppKit spreads that animation over NSWindowResizeTime seconds, 0.2 by default; Keel sets it to 0.001 in the global domain. The key is present in AppKit on macOS 27.0.1. Apps read it when they open, and logging out applies it everywhere.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSWindowResizeTime", type: .float, on: "0.001", off: nil)], post: .logout),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos"], confidence: .medium,
              expectedBenefit: "Settings windows and sheets change size without animating.",
              tradeoff: "Nothing noticeable.",
              audience: [.everyone]),

        Tweak(id: "proxy-icon-instant", name: "Title bar document icon without delay", category: .visual,
              summary: "Hovering a window title shows the document icon immediately instead of after a pause.",
              explanation: "The small document icon next to a window title appears as soon as the pointer is over the title, instead of after a pause. That icon (the proxy icon) can be dragged to attach the file or Command-clicked to show the folder path; since macOS 11 it stays hidden until you hover. Keel sets NSToolbarTitleViewRolloverDelay to 0 in the global domain, and the short fade-in remains. Apps read it when they open; the key is present in AppKit on macOS 27.0.1.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSToolbarTitleViewRolloverDelay", type: .float, on: "0", off: nil)], post: .relaunchApp),
              sources: ["https://brettterpstra.com/2021/04/14/fixing-the-big-sur-proxy-icon-delay-globally/", "https://mjtsai.com/blog/2020/10/05/big-surs-hidden-document-proxy-icon", "Local check: string present in the macOS 27.0.1 dyld shared cache (AppKit)"],
              confidence: .medium,
              expectedBenefit: "The document icon is ready to drag or Command-click as soon as you point at the title.",
              tradeoff: "Title bars show the icon whenever the pointer passes over them.",
              audience: [.creator, .developer]),

        Tweak(id: "finder-animations-off", name: "Finder animations: off", category: .visual,
              summary: "Get Info windows and some Finder zooms appear without animation.",
              explanation: "Finder stops animating a few of its own windows, such as Get Info. The key is com.apple.finder DisableAllAnimations, present in the Finder binary on macOS 27.0.1; Finder restarts to apply it. The effect is small and only changes how quickly those windows appear.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.finder", key: "DisableAllAnimations", type: .bool, on: "1", off: nil)], post: .killFinder),
              sources: ["https://github.com/mathiasbynens/dotfiles/blob/main/.macos", "Local check (macOS 27.0): DisableAllAnimations present in Finder"], confidence: .medium,
              expectedBenefit: "Finder info windows open without the zoom.",
              tradeoff: "Nothing noticeable.",
              audience: [.everyone]),

        Tweak(id: "quicklook-animation-off", name: "Quick Look zoom animation: off", category: .visual,
              summary: "Space-bar previews skip the zoom animation, mainly when closing.",
              explanation: "Quick Look, the preview you get by pressing Space on a file, opens and closes without its zoom animation. Keel sets QLPanelAnimationDuration to 0 in the global domain and restarts Finder. The key is present in the macOS 27.0.1 Quick Look code, but user reports say it mostly shortens the closing animation. The effect is small and Keel has low confidence in it.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "QLPanelAnimationDuration", type: .float, on: "0", off: nil)], post: .killFinder),
              sources: ["https://github.com/mathiasbynens/dotfiles/blob/main/.macos", "Local check (macOS 27.0): QLPanelAnimationDuration present in the system frameworks"], confidence: .low,
              expectedBenefit: "Previews close slightly faster.",
              tradeoff: "Nothing noticeable.",
              audience: [.everyone]),

        Tweak(id: "desktop-tinting-off", name: "Wallpaper tinting in windows: off", category: .visual,
              summary: "Window backgrounds stop picking up a color tint from the wallpaper.",
              explanation: "Window backgrounds stay neutral instead of taking on a slight tint from the wallpaper behind them. Keel sets AppleReduceDesktopTinting to true in the global domain, the same as turning off wallpaper tinting in System Settings > Appearance. Any performance saving is tiny and has not been measured; treat it as a visual preference.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "AppleReduceDesktopTinting", type: .bool, on: "1", off: nil)], post: .none),
              sources: ["Local check: string present in the macOS 27.0.1 dyld shared cache (AppKit)"],
              expectedBenefit: "Neutral window backgrounds regardless of the wallpaper.",
              tradeoff: "Windows look slightly less integrated with the desktop.",
              audience: [.everyone]),

        // MARK: Accessibility (protected domain: deep link, never written)

        Tweak(id: "reduce-transparency", name: "Reduce transparency", category: .visual,
              summary: "Blurred, translucent panels become solid. Keel opens the setting for you.",
              explanation: "The menu bar, Dock, sidebars and menus become solid instead of translucent and blurred. It is an Accessibility setting stored in a protected preference file that other apps cannot write, so Keel opens System Settings > Accessibility > Display and reads the live value through NSWorkspace. It may reduce the blending work done by WindowServer, the process that draws the screen, but no controlled measurement has been published; compare WindowServer CPU in Activity Monitor before and after if you want a number. On macOS 26 and later it also overrides the Liquid Glass Clear/Tinted choice and adds contrast to controls.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let on = await MainActor.run { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
                  return Detection(state: on ? .on : .off, values: [("accessibilityDisplayShouldReduceTransparency", on ? "true" : "false")])
              }, settingsURL: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display",
                 instructions: "System Settings > Accessibility > Display > Reduce transparency")),
              sources: ["https://support.apple.com/guide/mac-help/change-display-settings-for-accessibility-unac089/mac"],
              confidence: .medium,
              expectedBenefit: "Flat, higher-contrast panels that are easier to read; possibly slightly less graphics work.",
              tradeoff: "The translucent look is gone and panels look flatter.",
              audience: [.everyone]),

        Tweak(id: "reduce-motion", name: "Reduce motion", category: .visual,
              summary: "Space switches and Mission Control fade instead of sliding and zooming.",
              explanation: "Switching Spaces, opening Mission Control and entering full screen use short fades instead of large slides and zooms. Like Reduce transparency, it lives in a protected preference file, so Keel opens the right pane (Accessibility > Motion on macOS 26 and later, Accessibility > Display on macOS 15) and reads the live value through NSWorkspace. The fade takes about as long as the slide; what changes is the amount of movement, not the time.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let on = await MainActor.run { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
                  return Detection(state: on ? .on : .off, values: [("accessibilityDisplayShouldReduceMotion", on ? "true" : "false")])
              }, settingsURL: VisualSupport.osMajor >= 26 ? "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Motion" : "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display",
                 instructions: VisualSupport.osMajor >= 26 ? "System Settings > Accessibility > Motion > Reduce motion" : "System Settings > Accessibility > Display > Reduce motion")),
              sources: ["https://support.apple.com/guide/mac-help/mchlc03f57a1/26/mac/26"],
              expectedBenefit: "Calmer transitions between Spaces and full-screen apps.",
              tradeoff: "Some transitions lose their sense of direction.",
              audience: [.everyone]),

        // MARK: Display and WindowServer

        Tweak(id: "display-60hz", name: "Fixed 60 Hz instead of ProMotion", category: .visual,
              summary: "Caps a ProMotion display at 60 Hz. Small battery gain, less smooth motion.",
              explanation: "The display stops redrawing faster than 60 times a second. ProMotion, the adaptive refresh on recent MacBook Pro screens, goes up to 120 Hz while things move and drops to about 24 Hz when nothing does. Fixing the rate at 60 Hz lowers the peak work for the graphics system, but because ProMotion already idles low, the battery saving is small and scrolling looks less smooth. Apple makes no battery claim either way. Keel reads the current mode of the main display and opens System Settings > Displays.",
              risk: .low, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let hz = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
                  return Detection(state: hz > 0 && hz <= 61 ? .on : .off,
                                   values: [("current refresh rate", hz > 0 ? String(format: "%.0f Hz", hz) : "unknown"),
                                            ("highest available", String(format: "%.0f Hz", Machine.current.mainDisplayMaxRefresh))])
              }, settingsURL: "x-apple.systempreferences:com.apple.Displays-Settings.extension",
                 instructions: "System Settings > Displays > Refresh Rate > 60 Hertz")),
              sources: ["https://support.apple.com/en-us/ht210742"],
              requires: [.custom({ Machine.current.hasProMotion ? nil : "The main display has no ProMotion (adaptive refresh above 60 Hz)" })],
              confidence: .medium,
              expectedBenefit: "Slightly longer battery life when a lot moves on screen.",
              tradeoff: "Scrolling and animations are visibly less smooth.",
              audience: [.laptop]),

        Tweak(id: "electron-windowserver-bug", name: "Electron apps include the WindowServer fix", category: .visual,
              summary: "Checks each Electron app for the release that fixed constant window-shadow redraws.",
              explanation: "Keel lists apps built on Electron (VS Code, Slack, Discord and many others) and marks those that predate the fix for a known macOS 26 slowdown. Electron releases before 36.9.2, 37.6.0 and 38.2.0 overrode a private AppKit method, which made WindowServer, the process that draws the screen, redraw window shadows continuously and slowed the whole Mac. Keel reads the bundled Electron Framework version of each app in /Applications, /Applications/Utilities and ~/Applications; the remedy is to update the app. Community reports say macOS 26.2 also added a system-side mitigation, which Apple has not confirmed, so the effect on current macOS may be smaller.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(detect: { VisualSupport.electronDetection() },
                 settingsURL: "", instructions: "Update every app marked “update” (usually the app menu > Check for Updates)")),
              sources: ["https://releases.electronjs.org/pr/48376", "https://www.theregister.com/2025/10/02/macos_26_electron_slowdown/"],
              requires: [.minMacOS(26)],
              confidence: .medium,
              expectedBenefit: "If an outdated app was the cause, WindowServer CPU use and lag drop once it is updated.",
              tradeoff: "Nothing noticeable.",
              audience: [.everyone, .developer]),
    ]
}

// MARK: - Helpers (file-private)

private enum VisualSupport {
    static let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    static func bool(_ domain: String, _ key: String) -> Bool? {
        guard let v = Prefs.value(domain, key) else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return nil
    }

    static func raw(_ domain: String, _ key: String) -> String { Prefs.string(domain, key) ?? "(not set)" }

    /// Electron versions that carry the `_cornerMask` fix (electron/electron PR #48376, 2025-09-27).
    static func electronFixed(_ version: String) -> Bool? {
        let p = version.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
        guard p.count >= 2 else { return nil }
        let (major, minor, patch) = (p[0], p[1], p.count > 2 ? p[2] : 0)
        switch major {
        case ..<36: return false
        case 36: return (minor, patch) >= (9, 2)
        case 37: return (minor, patch) >= (6, 0)
        case 38: return (minor, patch) >= (2, 0)
        default: return true
        }
    }

    static func electronDetection() -> Detection {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "\(NSHomeDirectory())/Applications"]
        var values: [(String, String)] = []
        var old = 0, total = 0
        for dir in dirs {
            let apps = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
            for app in apps {
                let plist = "\(dir)/\(app)/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"
                guard let d = NSDictionary(contentsOfFile: plist),
                      let v = (d["CFBundleVersion"] as? String) ?? (d["CFBundleShortVersionString"] as? String) else { continue }
                total += 1
                let fixed = electronFixed(v)
                if fixed == false { old += 1 }
                let label = (app as NSString).deletingPathExtension
                values.append((label, "Electron \(v)" + (fixed == false ? "  ← update" : (fixed == nil ? "  (version not recognized)" : ""))))
            }
        }
        if total == 0 { return .na("No Electron apps in /Applications or ~/Applications") }
        let state: TweakState = old == 0 ? .on : (old == total ? .off : .partlyOn)
        return Detection(state: state, values: values, note: old == 0 ? "All \(total) Electron apps include the fix." : "\(old) of \(total) Electron apps predate the fix.")
    }
}
