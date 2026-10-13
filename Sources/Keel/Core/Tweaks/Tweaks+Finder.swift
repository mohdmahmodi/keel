import Foundation
import Darwin
import KeelShared

// Keys checked on macOS 27.0.1 in the Finder and screencaptureui binaries and the dyld shared cache.

extension TweakCatalog {
    static let finder: [Tweak] = [
        // MARK: Finder windows

        Tweak(id: "finder-show-extensions", name: "Show all filename extensions", category: .finder,
              summary: "Finder shows the full name of every file, including .pdf, .app or .zip at the end.",
              explanation: "Finder shows every file's extension, the part after the last dot that identifies its type. By default it hides extensions for many types, so a file named invoice.pdf.app looks like invoice.pdf. The setting is AppleShowAllExtensions in the global domain, the same as “Show all filename extensions” in Finder Settings > Advanced; Finder restarts to apply it. The key is present in Finder and AppKit on macOS 27.0.1.",
              risk: .safe, impact: .low, recommended: true,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "AppleShowAllExtensions", type: .bool, on: "1", off: nil)], post: .killFinder),
              sources: ["https://support.apple.com/guide/mac-help/show-or-hide-filename-extensions-on-mac-mchlp2304/mac", "https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the Finder binary and the dyld shared cache on macOS 27.0.1"],
              expectedBenefit: "You can see what kind of file something is, and spot files disguised with a double extension.",
              tradeoff: "File names are slightly longer in Finder and Open dialogs.",
              audience: [.everyone, .privacy]),

        Tweak(id: "finder-path-status-bars", name: "Finder path bar and status bar", category: .finder,
              summary: "Finder windows show the folder path at the bottom, plus item count and free space.",
              explanation: "Two thin bars appear at the bottom of every Finder window. The path bar shows where the current folder is and lets you drag files onto any parent folder; the status bar shows the number of items and the free space on the disk. Keel sets com.apple.finder ShowPathbar and ShowStatusBar to true (View > Show Path Bar and View > Show Status Bar) and restarts Finder.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([
                DefaultsSetting(domain: "com.apple.finder", key: "ShowPathbar", type: .bool, on: "1", off: nil),
                DefaultsSetting(domain: "com.apple.finder", key: "ShowStatusBar", type: .bool, on: "1", off: nil)
              ], post: .killFinder),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: both strings present in the Finder binary on macOS 27.0.1"],
              expectedBenefit: "You always see which folder you are in and how much disk space is left.",
              tradeoff: "Finder windows lose about two lines of height for file listings.",
              audience: [.everyone]),

        Tweak(id: "finder-new-window-home", name: "New Finder windows open your home folder", category: .finder,
              summary: "New Finder windows open your home folder instead of Recents.",
              explanation: "A new Finder window opens at your home folder. The default, Recents, is a saved Spotlight search that runs each time and lists recently used files from everywhere. Keel sets com.apple.finder NewWindowTarget to PfHm and NewWindowTargetPath to your home folder, the same as choosing your home folder for “New Finder windows show” in Finder Settings > General, and restarts Finder. Both keys are present in the Finder binary on macOS 27.0.1; the PfHm value is what Finder's own settings write, and Apple does not document it.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([
                DefaultsSetting(domain: "com.apple.finder", key: "NewWindowTarget", type: .string, on: "PfHm", off: nil),
                DefaultsSetting(domain: "com.apple.finder", key: "NewWindowTargetPath", type: .string, on: "file://\(NSHomeDirectory())/", off: nil)
              ], post: .killFinder),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: NewWindowTarget and NewWindowTargetPath present in the Finder binary on macOS 27.0.1"],
              confidence: .medium,
              expectedBenefit: "Each new Finder window opens at the same predictable place, without waiting for a Recents search.",
              tradeoff: "Recently used files are one click away in the sidebar instead of shown first.",
              audience: [.everyone]),

        Tweak(id: "finder-search-current-folder", name: "Finder searches the current folder", category: .finder,
              summary: "Searching from a Finder window looks in that folder instead of the whole Mac.",
              explanation: "Typing in a Finder window's search field searches the folder you are in. By default Finder searches the entire Mac, and you click the folder name to narrow it down. The key is com.apple.finder FXDefaultSearchScope, set to SCcf (“Search the Current Folder” in Finder Settings > Advanced); Finder restarts to apply it. The key is present in the Finder binary on macOS 27.0.1.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.finder", key: "FXDefaultSearchScope", type: .string, on: "SCcf", off: nil)], post: .killFinder),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the Finder binary on macOS 27.0.1"],
              expectedBenefit: "Searching inside a project or Downloads folder lists only matches from that folder.",
              tradeoff: "To search the whole Mac from a Finder window, click “This Mac” in the search bar.",
              audience: [.everyone]),

        Tweak(id: "finder-folders-first", name: "Folders on top when sorting by name", category: .finder,
              summary: "Finder lists folders before files when a window is sorted by name.",
              explanation: "In Finder windows sorted by name, folders are listed above files, as in Windows Explorer and most file managers. By default Finder mixes them alphabetically. Keel sets com.apple.finder _FXSortFoldersFirst to true (“Keep folders on top: In windows when sorting by name” in Finder Settings > Advanced) and restarts Finder. The change is cosmetic.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.finder", key: "_FXSortFoldersFirst", type: .bool, on: "1", off: nil)], post: .killFinder),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the Finder binary on macOS 27.0.1"],
              expectedBenefit: "Folders are always at the top of the list.",
              tradeoff: "Nothing noticeable.",
              audience: [.everyone]),

        Tweak(id: "finder-extension-warning-off", name: "Extension change warning: off", category: .finder,
              summary: "Renaming a file's extension no longer asks for confirmation.",
              explanation: "Finder stops asking for confirmation when you change the part of a file name after the dot, for example from .txt to .md. Keel sets com.apple.finder FXEnableExtensionChangeWarning to false (“Show warning before changing an extension” in Finder Settings > Advanced) and restarts Finder. The key is present in the Finder binary on macOS 27.0.1.",
              risk: .low, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.finder", key: "FXEnableExtensionChangeWarning", type: .bool, on: "0", off: nil)], post: .killFinder),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the Finder binary on macOS 27.0.1"],
              expectedBenefit: "Renaming files between formats takes one step instead of two.",
              tradeoff: "No safety prompt if you change an extension by mistake; the file may then open in the wrong app.",
              audience: [.developer, .creator]),

        Tweak(id: "finder-posix-path-title", name: "Full folder path in Finder title bars", category: .finder,
              summary: "Finder window titles show the full path, such as /Users/you/Projects/app.",
              explanation: "The Finder window title shows the complete path of the current folder instead of only its name. The key, com.apple.finder _FXShowPosixPathInTitle, is present in the Finder binary on macOS 27.0.1 but not documented by Apple; Finder restarts to apply it. On recent macOS versions the title may be shortened when the window is narrow.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", type: .bool, on: "1", off: nil)], post: .killFinder),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the Finder binary on macOS 27.0.1"],
              confidence: .medium,
              expectedBenefit: "You can tell folders with the same name apart, and match Finder windows to Terminal paths.",
              tradeoff: "Long paths make window titles crowded.",
              audience: [.developer]),

        Tweak(id: "finder-show-library", name: "Show the Library folder in your home", category: .finder,
              summary: "Your ~/Library folder becomes visible in Finder.",
              explanation: "The Library folder inside your home folder becomes visible in Finder. It holds app settings, caches, Application Support data and mail, and macOS hides it so it is not changed by accident. Keel clears the hidden flag (chflags nohidden) and the invisible bit in the folder's Finder information, recording both so they can be restored; no administrator password is needed. Without this change, hold Option while opening Finder's Go menu to reach the folder. A macOS update may hide it again.",
              risk: .low, impact: .cosmetic, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: { FinderSupport.libraryDetection() },
                apply: { _ in try FinderSupport.setLibraryVisible(true, restoring: [:]) },
                revert: { _, orig in _ = try FinderSupport.setLibraryVisible(false, restoring: orig) },
                applyCommands: ["chflags nohidden ~/Library", "clear the invisible bit in the com.apple.FinderInfo attribute of ~/Library"],
                revertCommands: ["chflags hidden ~/Library", "restore the recorded com.apple.FinderInfo attribute"],
                needsAdmin: false)),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "man chflags (macOS 27.0.1)", "Local check: ~/Library carries the hidden flag and FinderInfo invisible bit 0x4000 on macOS 27.0.1"],
              expectedBenefit: "~/Library is visible in your home folder like any other folder.",
              tradeoff: "Files that apps depend on are easier to move or delete by mistake.",
              audience: [.developer]),

        Tweak(id: "finder-show-hidden-files", name: "Show hidden files in Finder", category: .finder,
              summary: "Finder shows files and folders whose names start with a dot, dimmed.",
              explanation: "Hidden files such as .gitignore, .env and .zshrc appear in Finder windows, dimmed. Keel sets com.apple.finder AppleShowAllFiles to true and restarts Finder; Command-Shift-period switches the same view on and off for the current session. The key is present in the Finder binary on macOS 27.0.1. It is meant for people who work with configuration files.",
              risk: .low, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.finder", key: "AppleShowAllFiles", type: .bool, on: "1", off: nil)], post: .killFinder),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the Finder binary on macOS 27.0.1"],
              expectedBenefit: "Configuration files are visible in Finder without a keyboard shortcut.",
              tradeoff: "Folders show many extra files, including .DS_Store, and system files are easier to delete by mistake.",
              audience: [.developer]),

        // MARK: Save dialogs

        Tweak(id: "save-dialogs-expanded", name: "Save dialogs open expanded", category: .finder,
              summary: "Save dialogs show the full folder browser instead of the compact pop-up.",
              explanation: "Save dialogs open with the folder browser already shown. Most start in a compact form with a name field and a folder pop-up menu, and you click the arrow button to see folders. Keel sets NSNavPanelExpandedStateForSaveMode to true in the global domain. Apps that remember their own choice keep it; others pick it up after they are reopened. The key is present in AppKit on macOS 27.0.1.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode", type: .bool, on: "1", off: nil)], post: .relaunchApp),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the macOS 27.0.1 dyld shared cache (AppKit)"],
              confidence: .medium,
              expectedBenefit: "One click fewer each time you save somewhere other than the suggested folder.",
              tradeoff: "Save dialogs take more space on screen.",
              audience: [.everyone]),

        Tweak(id: "new-docs-save-local", name: "New documents save to this Mac by default", category: .finder,
              summary: "Save dialogs for new documents suggest a folder on this Mac instead of iCloud Drive.",
              explanation: "The first time you save a new document, the dialog suggests a folder on this Mac instead of iCloud Drive. Apps such as TextEdit, Preview and Pages suggest iCloud Drive by default; with NSDocumentSaveNewDocumentsToCloud set to false in the global domain they suggest a local folder, and iCloud Drive is still one click away. It suits people who keep work in local folders or have Optimize Mac Storage on. Apps pick it up after they are reopened; the key is present in AppKit on macOS 27.0.1.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSDocumentSaveNewDocumentsToCloud", type: .bool, on: "0", off: nil)], post: .relaunchApp),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the macOS 27.0.1 dyld shared cache (AppKit)"],
              confidence: .medium,
              expectedBenefit: "New files are saved to a local folder by default, not to iCloud Drive where they may later be offloaded.",
              tradeoff: "Saving a new document to iCloud Drive takes one extra click.",
              audience: [.everyone]),

        // MARK: Desktop

        Tweak(id: "click-wallpaper-reveal-off", name: "Click wallpaper to reveal desktop: off", category: .finder,
              summary: "Clicking an empty part of the desktop no longer moves every window aside.",
              explanation: "Clicking an empty part of the wallpaper no longer moves all windows off screen. macOS 14 added that behavior, and it is easy to trigger by accident. Keel sets com.apple.WindowManager EnableStandardClickToShowDesktop to false, the same as choosing “Only in Stage Manager” for “Click wallpaper to reveal desktop” in System Settings > Desktop & Dock. It takes effect immediately; the key is present in the macOS 27.0.1 dyld shared cache (WindowManager).",
              risk: .safe, impact: .low, recommended: true,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.WindowManager", key: "EnableStandardClickToShowDesktop", type: .bool, on: "0", off: nil)], post: .none),
              sources: ["https://9to5mac.com/2023/09/26/disable-click-wallpaper-reveal-desktop-macos-sonoma/", "https://mynixos.com/nix-darwin/option/system.defaults.WindowManager.EnableStandardClickToShowDesktop"],
              expectedBenefit: "Windows stay in place when you click the desktop by mistake.",
              tradeoff: "To show the desktop, use Mission Control's Show Desktop (F11 or a trackpad spread) instead.",
              audience: [.everyone]),

        Tweak(id: "desktop-widgets-hidden", name: "Widgets on the desktop: off", category: .finder,
              summary: "Desktop widgets are hidden unless Stage Manager is on.",
              explanation: "Widgets you placed on the desktop are hidden. Since macOS 14, widgets can sit on the desktop and update in the background; Keel sets com.apple.WindowManager StandardHideWidgets to true, the same as turning off “Show Widgets: On Desktop” in System Settings > Desktop & Dock. Widgets stay available in Notification Center. Any saving in background work has not been measured, so treat it as a tidiness setting.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.WindowManager", key: "StandardHideWidgets", type: .bool, on: "1", off: nil)], post: .none),
              sources: ["https://mynixos.com/nix-darwin/option/system.defaults.WindowManager.StandardHideWidgets", "Local check: string present in the macOS 27.0.1 dyld shared cache (WindowManager)"],
              requires: [.minMacOS(14)],
              confidence: .medium,
              expectedBenefit: "A clear desktop with no widgets behind your windows.",
              tradeoff: "Widgets are only visible in Notification Center.",
              audience: [.everyone]),

        // MARK: Screenshots

        Tweak(id: "screenshot-folder", name: "Screenshots go to a Screenshots folder", category: .finder,
              summary: "New screenshots are saved to Pictures/Screenshots instead of piling up on the desktop.",
              explanation: "Screenshots and screen recordings are saved to ~/Pictures/Screenshots instead of the desktop. Keel creates the folder if it does not exist and sets com.apple.screencapture location to it, the same as Options > Save to > Other Location in the Screenshot app (Command-Shift-5). The previous location is recorded and restored on revert, and existing screenshots are not moved. The key is a Swift string in screencaptureui on macOS 27.0.1, found by its inline bytes.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: { FinderSupport.screenshotFolderDetection() },
                apply: { ctx in
                    let orig = try FinderSupport.setScreenshotFolder()
                    ctx.post(.killSystemUIServer)
                    return orig
                },
                revert: { ctx, orig in
                    FinderSupport.restoreScreenshotFolder(orig)
                    ctx.post(.killSystemUIServer)
                },
                applyCommands: ["mkdir -p ~/Pictures/Screenshots", "defaults write com.apple.screencapture location -string ~/Pictures/Screenshots", "killall SystemUIServer"],
                revertCommands: ["defaults write com.apple.screencapture location <recorded original>  # or delete if it was unset", "killall SystemUIServer"],
                needsAdmin: false)),
              sources: ["https://support.apple.com/guide/mac-help/mh26782/mac", "https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: otool -tv screencaptureui shows the Swift small string \"location\" on macOS 27.0.1"],
              confidence: .medium,
              expectedBenefit: "The desktop stays clear and screenshots are in one folder.",
              tradeoff: "Screenshots are no longer visible on the desktop right after you take them.",
              audience: [.everyone, .creator]),

        Tweak(id: "screenshot-thumbnail-off", name: "Screenshots save immediately", category: .finder,
              summary: "No floating preview, so the screenshot file is written at once instead of about 5 s later.",
              explanation: "The small preview that appears in the screen corner after a screenshot is turned off. While it is shown, macOS holds back the file until the preview disappears about five seconds later, so dragging or uploading the screenshot straight away fails. Keel sets com.apple.screencapture show-thumbnail to false, the same as turning off “Show Floating Thumbnail” in the Screenshot app's Options menu. On macOS 27.0.1 the key is a Swift string inside screencaptureui, found by its inline bytes.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.screencapture", key: "show-thumbnail", type: .bool, on: "0", off: nil)], post: .none),
              sources: ["https://support.apple.com/guide/mac-help/mh26782/mac", "https://macmost.com/10-tips-and-tricks-for-taking-screenshots-on-your-mac.html", "https://maketecheasier.com/get-rid-floating-screenshot-preview-macos", "Local check: otool -tv screencaptureui shows the Swift small string \"show-thumbnail\" on macOS 27.0.1"],
              confidence: .medium,
              expectedBenefit: "The screenshot file exists as soon as you take it, ready to drag or attach.",
              tradeoff: "No quick Markup from the floating preview; open the file to annotate it.",
              audience: [.everyone, .creator]),

        Tweak(id: "screenshot-shadow-off", name: "Window screenshots without shadow", category: .finder,
              summary: "Screenshots of a single window no longer include the large drop shadow around it.",
              explanation: "A window captured with Command-Shift-4 then Space is saved without the drop shadow macOS normally adds. The shadow is a wide transparent border that makes the image larger and looks out of place in documents. Keel sets com.apple.screencapture disable-shadow to true and restarts SystemUIServer, the process behind the menu bar extras. The key is present in the macOS 27.0.1 dyld shared cache.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.screencapture", key: "disable-shadow", type: .bool, on: "1", off: nil)], post: .killSystemUIServer),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the macOS 27.0.1 dyld shared cache"],
              confidence: .medium,
              expectedBenefit: "Window screenshots are cropped to the window itself.",
              tradeoff: "Window screenshots look flat against a white page.",
              audience: [.creator, .developer]),

        Tweak(id: "screenshot-format-heic", name: "Screenshots saved as HEIC", category: .finder,
              summary: "Screenshots are saved as HEIC files, which are usually smaller than PNG.",
              explanation: "New screenshots are saved as HEIC instead of PNG. PNG is lossless and opens everywhere, but a full Retina screenshot is often several MB; HEIC compresses with little visible loss and is read by current macOS, iOS and most recent apps, though some websites and older Windows software cannot open it. Keel sets com.apple.screencapture type to heic. JPG is the other small format (the same key set to jpg) and opens almost anywhere, at the cost of blurrier text. The format string is present in screencaptureui on macOS 27.0.1; file sizes depend on content and were not measured by Keel.",
              risk: .low, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.screencapture", key: "type", type: .string, on: "heic", off: nil)], post: .killSystemUIServer),
              sources: ["man screencapture (macOS 27.0.1): -t format", "https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: \"heic\" present in screencaptureui on macOS 27.0.1"],
              confidence: .medium,
              expectedBenefit: "Screenshots take less disk and iCloud space and upload faster.",
              tradeoff: "Some websites, chat tools and Windows apps cannot open HEIC; you may need to convert before sharing.",
              audience: [.creator]),
    ]
}

// MARK: - Helpers (file-private)

private enum FinderSupport {
    static let home = NSHomeDirectory()
    static var library: String { "\(home)/Library" }
    static let finderInfo = "com.apple.FinderInfo"
    static let invisibleBit: UInt16 = 0x4000   // kIsInvisible in FileInfo.finderFlags (offset 8, big-endian)

    static func flags(_ path: String) -> UInt32? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_flags : nil
    }

    static func readFinderInfo(_ path: String) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = getxattr(path, finderInfo, &buf, 32, 0, XATTR_NOFOLLOW)
        return n == 32 ? buf : nil
    }

    static func invisible(_ info: [UInt8]?) -> Bool {
        guard let info else { return false }
        return (UInt16(info[8]) << 8 | UInt16(info[9])) & invisibleBit != 0
    }

    static func libraryDetection() -> Detection {
        guard let f = flags(library) else { return .na("~/Library not found") }
        let hidden = f & UInt32(UF_HIDDEN) != 0
        let inv = invisible(readFinderInfo(library))
        let values = [("hidden flag (chflags)", hidden ? "set" : "not set"), ("Finder invisible bit", inv ? "set" : "not set")]
        return Detection(state: !hidden && !inv ? .on : (hidden && inv ? .off : .partlyOn), values: values)
    }

    /// visible = true: clear both flags and return what was there. visible = false: restore `restoring` (or hide when empty).
    static func setLibraryVisible(_ visible: Bool, restoring: [String: String]) throws -> [String: String] {
        guard let f = flags(library) else { throw TweakEngine.EngineError(message: "~/Library not found") }
        if visible {
            let info = readFinderInfo(library)
            var rec: [String: String] = ["hidden": f & UInt32(UF_HIDDEN) != 0 ? "1" : "0"]
            if let info { rec["finderInfo"] = info.map { String(format: "%02x", $0) }.joined() }
            guard chflags(library, f & ~UInt32(UF_HIDDEN)) == 0 else { throw TweakEngine.EngineError(message: "chflags nohidden failed: \(String(cString: strerror(errno)))") }
            if var b = info, invisible(info) {
                b[8] &= ~UInt8(invisibleBit >> 8)
                _ = setxattr(library, finderInfo, &b, 32, 0, XATTR_NOFOLLOW)
            }
            ActivityLog.post(.command, "chflags nohidden ~/Library; cleared the FinderInfo invisible bit")
            return rec
        }
        let hide = restoring["hidden"].map { $0 == "1" } ?? true
        let newFlags = hide ? f | UInt32(UF_HIDDEN) : f & ~UInt32(UF_HIDDEN)
        guard chflags(library, newFlags) == 0 else { throw TweakEngine.EngineError(message: "chflags hidden failed: \(String(cString: strerror(errno)))") }
        if let hex = restoring["finderInfo"], hex.count == 64 {
            var bytes: [UInt8] = stride(from: 0, to: 64, by: 2).compactMap { i in
                let s = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)
            }
            if bytes.count == 32 { _ = setxattr(library, finderInfo, &bytes, 32, 0, XATTR_NOFOLLOW) }
        } else if restoring.isEmpty, var b = readFinderInfo(library) {
            b[8] |= UInt8(invisibleBit >> 8)
            _ = setxattr(library, finderInfo, &b, 32, 0, XATTR_NOFOLLOW)
        }
        ActivityLog.post(.command, "chflags \(hide ? "hidden" : "nohidden") ~/Library; restored FinderInfo")
        return [:]
    }

    // MARK: Screenshot folder

    static var screenshotFolder: String { "\(home)/Pictures/Screenshots" }
    static let shotDomain = "com.apple.screencapture"

    static func screenshotFolderDetection() -> Detection {
        let raw = Prefs.string(shotDomain, "location")
        let path = raw.map { ($0 as NSString).expandingTildeInPath }
        var isDir: ObjCBool = false
        let exists = path.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue } ?? false
        let desktop = path.map { ($0 as NSString).standardizingPath == "\(home)/Desktop" } ?? true
        let values = [("com.apple.screencapture location", raw ?? "(not set: Desktop)"), ("folder exists", path == nil ? "n/a" : (exists ? "yes" : "no"))]
        return Detection(state: path != nil && exists && !desktop ? .on : .off, values: values,
                         note: path != nil && !exists ? "The saved location does not exist; macOS falls back to the desktop." : nil)
    }

    static func setScreenshotFolder() throws -> [String: String] {
        var rec: [String: String] = [:]
        if let prev = Prefs.string(shotDomain, "location") { rec["previous"] = prev }
        if !FileManager.default.fileExists(atPath: screenshotFolder) {
            try FileManager.default.createDirectory(atPath: screenshotFolder, withIntermediateDirectories: true)
            rec["created"] = "1"
        }
        guard Prefs.write(shotDomain, "location", screenshotFolder, type: .string) else {
            throw TweakEngine.EngineError(message: "Could not write com.apple.screencapture location")
        }
        ActivityLog.post(.command, "defaults write com.apple.screencapture location -string \(shq(screenshotFolder))")
        return rec
    }

    static func restoreScreenshotFolder(_ orig: [String: String]) {
        if let prev = orig["previous"] { Prefs.write(shotDomain, "location", prev, type: .string) }
        else { Prefs.delete(shotDomain, "location") }
        // Remove the folder only if Keel created it and it is still empty.
        if orig["created"] == "1", let items = try? FileManager.default.contentsOfDirectory(atPath: screenshotFolder),
           items.filter({ $0 != ".DS_Store" }).isEmpty {
            try? FileManager.default.removeItem(atPath: screenshotFolder)
        }
        ActivityLog.post(.command, orig["previous"] != nil ? "defaults write com.apple.screencapture location -string \(shq(orig["previous"]!))" : "defaults delete com.apple.screencapture location")
    }
}
