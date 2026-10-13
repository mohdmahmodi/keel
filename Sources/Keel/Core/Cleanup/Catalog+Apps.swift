import Foundation

extension CleanupCatalog {
    /// Cache folder names under ~/Library/Caches that have their own row, or that belong to macOS
    /// without a com.apple prefix. "Other app caches" skips all of these.
    static let coveredCacheFolders: Set<String> = [
        "Google", "Homebrew", "pip", "CocoaPods", "org.swift.swiftpm", "org.carthage.CarthageKit", "Yarn", "pypoetry", "pipx",
        "deno", "go-build", "uv", "com.microsoft.VSCode", "com.microsoft.VSCode.ShipIt", "com.microsoft.VSCodeInsiders",
        "com.microsoft.VSCodeInsiders.ShipIt",
        "com.github.GitHubClient.ShipIt", "com.todesktop.230313mzl4w4u92.ShipIt", "JetBrains", "us.zoom.xos", "com.spotify.client",
        "Firefox", "Arc", "Vivaldi", "Microsoft Edge", "BraveSoftware", "Chromium", "com.operasoftware.Opera", "Adobe",
        "Keel", "com.mohdmahmodi.keel",
        // macOS daemons that do not use a com.apple prefix.
        "CloudKit", "GeoServices", "PassKit", "SiriTTS", "FamilyCircle", "familycircled", "GameKit", "Animoji", "EnergyKit",
        "AMSDataMigratorTool", "askpermissiond", "icloudmailagent", "mbuseragent", "ssu", "Metal", "ColorSync", "storeassetd",
        "Maps", "MobileSync", "Safari", "Mail", "Music", "Photos", "TV", "Podcasts", "Books", "News", "Stocks", "Weather",
        "SharedImageCache", "SpeechRecognitionCore", "VoiceTrigger", "AppleMediaServices", "CrashReporter", "DiagnosticReports",
    ]

    struct ChromiumBrowser { let id: String; let name: String; let bundleIDs: [String]; let cacheRoot: String; let dataRoot: String }

    static func chromiumBrowsers(_ h: String) -> [ChromiumBrowser] {
        let c = "\(h)/Library/Caches", a = "\(h)/Library/Application Support"
        return [
            ChromiumBrowser(id: "chrome", name: "Google Chrome", bundleIDs: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"], cacheRoot: "\(c)/Google/Chrome", dataRoot: "\(a)/Google/Chrome"),
            ChromiumBrowser(id: "edge", name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev"], cacheRoot: "\(c)/Microsoft Edge", dataRoot: "\(a)/Microsoft Edge"),
            ChromiumBrowser(id: "brave", name: "Brave", bundleIDs: ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"], cacheRoot: "\(c)/BraveSoftware/Brave-Browser", dataRoot: "\(a)/BraveSoftware/Brave-Browser"),
            ChromiumBrowser(id: "arc", name: "Arc", bundleIDs: ["company.thebrowser.Browser"], cacheRoot: "\(c)/Arc/User Data", dataRoot: "\(a)/Arc/User Data"),
            ChromiumBrowser(id: "vivaldi", name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], cacheRoot: "\(c)/Vivaldi", dataRoot: "\(a)/Vivaldi"),
            ChromiumBrowser(id: "chromium", name: "Chromium", bundleIDs: ["org.chromium.Chromium"], cacheRoot: "\(c)/Chromium", dataRoot: "\(a)/Chromium"),
            ChromiumBrowser(id: "opera", name: "Opera", bundleIDs: ["com.operasoftware.Opera"], cacheRoot: "\(c)/com.operasoftware.Opera", dataRoot: "\(a)/com.operasoftware.Opera"),
        ]
    }

    static let chromiumProfileCaches = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
    static let chromiumRootCaches = ["GrShaderCache", "ShaderCache", "GraphiteDawnCache", "component_crx_cache"]

    static func isProfileDir(_ n: String) -> Bool { n == "Default" || n.hasPrefix("Profile ") || n == "Guest Profile" || n == "System Profile" }

    /// Cache folders of one Chromium-style data root (profiles plus root-level shader caches).
    static func chromiumCachePaths(_ root: String) -> (paths: [String], readable: Bool) {
        guard FS.isDir(root) else { return ([], true) }
        guard FS.readable(root) else { return ([], false) }
        var out: [String] = []
        for p in FS.list(root) where isProfileDir(p) { for s in chromiumProfileCaches where FS.isDir("\(root)/\(p)/\(s)") { out.append("\(root)/\(p)/\(s)") } }
        for s in chromiumRootCaches where FS.isDir("\(root)/\(s)") { out.append("\(root)/\(s)") }
        return (out, true)
    }

    struct ElectronApp { let id: String; let name: String; let bundleIDs: [String]; let dataDir: String; var extra: [String] = []; var caches: [String] = [] }

    static func electronApps(_ h: String) -> [ElectronApp] {
        let a = "\(h)/Library/Application Support", c = "\(h)/Library/Caches"
        let codeExtras = ["CachedData", "CachedExtensionVSIXs", "CachedProfilesData", "logs"]
        return [
            ElectronApp(id: "vscode", name: "VS Code", bundleIDs: ["com.microsoft.VSCode"], dataDir: "\(a)/Code", extra: codeExtras, caches: ["\(c)/com.microsoft.VSCode.ShipIt", "\(c)/com.microsoft.VSCode"]),
            ElectronApp(id: "vscode-insiders", name: "VS Code Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"], dataDir: "\(a)/Code - Insiders", extra: codeExtras, caches: ["\(c)/com.microsoft.VSCodeInsiders.ShipIt", "\(c)/com.microsoft.VSCodeInsiders"]),
            ElectronApp(id: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], dataDir: "\(a)/Cursor", extra: codeExtras, caches: ["\(c)/com.todesktop.230313mzl4w4u92.ShipIt"]),
            ElectronApp(id: "windsurf", name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"], dataDir: "\(a)/Windsurf", extra: codeExtras),
            ElectronApp(id: "slack", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"], dataDir: "\(a)/Slack", extra: ["logs"]),
            ElectronApp(id: "discord", name: "Discord", bundleIDs: ["com.hnc.Discord"], dataDir: "\(a)/discord"),
            ElectronApp(id: "teams-classic", name: "Microsoft Teams (classic)", bundleIDs: ["com.microsoft.teams"], dataDir: "\(a)/Microsoft/Teams", extra: ["logs"]),
            ElectronApp(id: "github-desktop", name: "GitHub Desktop", bundleIDs: ["com.github.GitHubClient"], dataDir: "\(a)/GitHub Desktop", caches: ["\(c)/com.github.GitHubClient.ShipIt"]),
            ElectronApp(id: "notion", name: "Notion", bundleIDs: ["notion.id"], dataDir: "\(a)/Notion"),
            ElectronApp(id: "obsidian", name: "Obsidian", bundleIDs: ["md.obsidian"], dataDir: "\(a)/obsidian"),
            ElectronApp(id: "postman", name: "Postman", bundleIDs: ["com.postmanlabs.mac"], dataDir: "\(a)/Postman"),
            ElectronApp(id: "figma", name: "Figma", bundleIDs: ["com.figma.Desktop"], dataDir: "\(a)/Figma"),
        ]
    }

    static let appCaches: Provider = { ctx in
        let h = ctx.home
        var items: [CleanupItem] = []

        for b in chromiumBrowsers(h) {
            let owner = OwningApp(name: b.name, bundleIDs: b.bundleIDs)
            let cache = chromiumCachePaths(b.cacheRoot), data = chromiumCachePaths(b.dataRoot)
            let paths = Array(Set(cache.paths + data.paths)).sorted()
            guard !paths.isEmpty else { continue }
            let partial = !cache.readable || !data.readable
            var item = CleanupItem.folders(id: "\(b.id)-cache", name: "\(b.name) caches", group: .apps,
                summary: "Web, script and graphics caches of every profile. History, passwords and extensions are not touched.",
                explanation: "The browser stores copies of web pages, compiled scripts and graphics data so pages load faster. Keel empties only the cache folders inside each profile (\(chromiumProfileCaches.prefix(6).joined(separator: ", "))) and the shared shader caches. Cookies, passwords, history, bookmarks and extensions are stored in other files and are not touched. Quit \(b.name) first; it rebuilds the caches as you browse.",
                paths: paths, rebuildCost: "Pages and web apps load more slowly the first time", owner: owner)
            if partial { item.warnings.append("macOS protects part of \(b.name)'s data folder, so Keel did not read it. Only the caches Keel can read are listed. Granting Full Disk Access includes the rest.") }
            items.append(item)
        }

        // Firefox: cache2 per profile, under Caches.
        let ff = "\(h)/Library/Caches/Firefox/Profiles"
        let ffPaths = FS.list(ff).flatMap { p in ["cache2", "startupCache", "thumbnails"].map { "\(ff)/\(p)/\($0)" } }.filter(FS.isDir)
        if !ffPaths.isEmpty {
            items.append(.folders(id: "firefox-cache", name: "Firefox caches", group: .apps, summary: "Web cache of every profile. Profile data is not touched.",
                explanation: "Firefox stores copies of web pages in ~/Library/Caches/Firefox/Profiles/<profile>/cache2, the same data Settings › Privacy › Clear Data › Cached Web Content removes. The profile itself is stored in Application Support and is not touched.",
                paths: ffPaths, rebuildCost: "Pages load more slowly the first time", owner: OwningApp(name: "Firefox", bundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"])))
        }

        for app in electronApps(h) {
            var paths: [String] = []
            if FS.readable(app.dataDir) {
                for s in chromiumProfileCaches + app.extra where FS.isDir("\(app.dataDir)/\(s)") { paths.append("\(app.dataDir)/\(s)") }
            }
            paths += app.caches.filter(FS.isDir)
            guard !paths.isEmpty else { continue }
            items.append(.folders(id: "\(app.id)-cache", name: "\(app.name) caches", group: .apps,
                summary: "Caches, downloaded updates and logs. Settings and data are not touched.",
                explanation: "\(app.name) is built on Electron, which uses the same caches as a web browser. Keel empties only its cache folders (Cache, Code Cache, GPUCache, Dawn caches, service worker caches\(app.extra.isEmpty ? "" : ", " + app.extra.joined(separator: ", "))) and its update staging folder. Settings, sign-in state, local storage and extensions are not touched.",
                paths: paths, rebuildCost: "Rebuilt when the app next opens", owner: OwningApp(name: app.name, bundleIDs: app.bundleIDs)))
        }

        for (id, name, bundle, folder, note) in [
            ("zoom", "Zoom", "us.zoom.xos", "us.zoom.xos", "Zoom's cache. Meeting recordings are saved in Documents/Zoom and are not touched."),
            ("spotify", "Spotify", "com.spotify.client", "com.spotify.client", "Cached streamed music. Songs downloaded for offline listening are stored elsewhere and are not touched."),
        ] {
            let p = "\(h)/Library/Caches/\(folder)"
            guard FS.isDir(p) else { continue }
            items.append(.folders(id: "\(id)-cache", name: "\(name) cache", group: .apps, summary: note,
                explanation: "The app's cache folder, ~/Library/Caches/\(folder). \(note)", paths: [p], rebuildCost: "Rebuilt as the app is used",
                owner: OwningApp(name: name, bundleIDs: [bundle])))
        }

        // JetBrains IDEs and Android Studio: one child per product version.
        var jb: [CleanupItem] = []
        let jbOwner = OwningApp(name: "JetBrains IDEs", bundlePrefixes: ["com.jetbrains.", "com.google.android.studio"])
        for (cacheRoot, logRoot, prefix) in [("\(h)/Library/Caches/JetBrains", "\(h)/Library/Logs/JetBrains", ""), ("\(h)/Library/Caches/Google", "\(h)/Library/Logs/Google", "AndroidStudio")] {
            for product in FS.list(cacheRoot) where prefix.isEmpty || product.hasPrefix(prefix) {
                let paths = FS.existing(["\(cacheRoot)/\(product)", "\(logRoot)/\(product)"])
                jb.append(.folders(id: "jetbrains-\(product)", name: product, group: .apps, summary: "Indexes, caches and logs of this IDE version.",
                    explanation: "Caches, project indexes and logs of \(product). The IDE indexes open projects again on its next start, which can take several minutes for large projects. Settings and plugins in Application Support/JetBrains are not touched. Folders of IDE versions that are no longer installed can be deleted without any cost.",
                    paths: paths, defaultOn: false, rebuildCost: "Projects are indexed again on next start (minutes)", owner: jbOwner))
            }
        }
        if !jb.isEmpty {
            items.append(CleanupItem(id: "jetbrains", name: "JetBrains and Android Studio caches", group: .apps,
                summary: "One row per IDE version. Not selected by default because indexing again takes time.", explanation: "JetBrains IDEs and Android Studio keep a cache folder and a log folder for each version, including versions that are no longer installed.",
                rebuildCost: "Projects are indexed again on next start", children: jb, owner: jbOwner))
        }

        let adobe = FS.existing(["\(h)/Library/Application Support/Adobe/Common/Media Cache Files", "\(h)/Library/Application Support/Adobe/Common/Media Cache", "\(h)/Library/Caches/Adobe"])
        if !adobe.isEmpty {
            items.append(.folders(id: "adobe-media-cache", name: "Adobe media cache", group: .apps,
                summary: "Audio and preview files that Premiere Pro, After Effects and Audition generate.",
                explanation: "Adobe video and audio apps convert imported media into cache files (Media Cache Files) and track them in a database (Media Cache). The apps create them again when a project is opened, which can take a while for long projects. Project files and media are not touched.",
                paths: adobe, rebuildCost: "Media is processed again when a project is opened", owner: OwningApp(name: "Adobe apps", bundlePrefixes: ["com.adobe."])))
        }

        let dockerInstall = "\(h)/Library/Application Support/com.docker.install"
        if FS.isDir(dockerInstall) {
            items.append(.folders(id: "docker-install", name: "Docker Desktop installer leftovers", group: .apps,
                summary: "Installer files kept after Docker Desktop updates.",
                explanation: "Docker Desktop keeps downloaded installer files in ~/Library/Application Support/com.docker.install after it updates. Containers, images and volumes are stored in Docker's disk image and are not touched.",
                paths: [dockerInstall], rebuildCost: "Nothing", owner: OwningApp(name: "Docker Desktop", bundleIDs: ["com.docker.docker"])))
        }
        let codex = "\(h)/.cache/codex-runtimes"
        if FS.isDir(codex) {
            items.append(.folders(id: "codex-runtimes", name: "Codex runtimes", group: .apps, summary: "Language runtimes the Codex app downloads when needed.",
                explanation: "The Codex app downloads language runtimes for its sandbox into ~/.cache/codex-runtimes. They are downloaded again when needed.",
                paths: [codex], risk: .low, defaultOn: false, rebuildCost: "Downloaded again on next use", owner: OwningApp(name: "Codex", bundleIDs: ["com.openai.codex"])))
        }
        return items
    }

    // Everything else in ~/Library/Caches, one row per app.

    static let otherCaches: Provider = { ctx in
        let root = "\(ctx.home)/Library/Caches"
        let me = Bundle.main.bundleIdentifier ?? ""
        var kids: [CleanupItem] = []
        for f in FS.list(root) where !f.hasPrefix("com.apple.") && !coveredCacheFolders.contains(f) && f != me
            && FS.isDir("\(root)/\(f)") && Permissions.canRead("\(root)/\(f)") {
            let r = AppNames.resolve(f)
            if r.isApple { continue }
            kids.append(.folders(id: "cache-\(f)", name: r.name == f ? f : "\(r.name)", group: .apps,
                summary: "~/Library/Caches/\(f)",
                explanation: "Cache folder of \(r.name). Apps are required to be able to recreate anything in ~/Library/Caches, so the cost is a slower first launch or a new download. Keel empties the folder but keeps it, and skips it while the app is open.",
                paths: ["\(root)/\(f)"], risk: .low, defaultOn: false, rebuildCost: "The app's first launch is slower",
                owner: r.bundleID.map { OwningApp(name: r.name, bundleIDs: [$0]) }))
        }
        guard !kids.isEmpty else { return [] }
        return [CleanupItem(id: "user-caches", name: "Other app caches", group: .apps,
            summary: "Other folders in ~/Library/Caches, one per app. Not selected by default.",
            explanation: "Every other folder in ~/Library/Caches, named after the app it belongs to. Keel never empties ~/Library/Caches as a whole: macOS keeps iCloud sync state, Apple Account tokens, Safari's Safe Browsing list and Siri voices there, and deleting them causes long re-syncs or sign-in prompts. Folders starting with com.apple., CloudKit and other system folders are skipped.",
            paths: [root], rebuildCost: "Each app's first launch is slower", children: kids)]
    }
}
