import Foundation

extension CleanupCatalog {
    static let gradleDaemon = OwningApp(name: "Gradle daemon", processPattern: "org.gradle.launcher.daemon.bootstrap.GradleDaemon")

    static let packages: Provider = { ctx in
        let h = ctx.home
        var items: [CleanupItem] = []
        func add(_ i: CleanupItem) { items.append(i) }

        // npm: content cache through npm itself, npx cache and logs as folders.
        if FS.isDir("\(h)/.npm") {
            let cacache = "\(h)/.npm/_cacache", npx = "\(h)/.npm/_npx", logs = "\(h)/.npm/_logs"
            var actions: [CleanupAction] = []
            if FS.isDir(cacache) {
                if let npm = Tools.find("npm") { actions.append(.run(Tools.command(npm, ["cache", "clean", "--force"]))) }
                else { actions.append(.removeContents(cacache, except: [])) }
            }
            for p in [npx, logs] where FS.isDir(p) { actions.append(.removeContents(p, except: [])) }
            if !actions.isEmpty {
                add(CleanupItem(id: "npm", name: "npm cache", group: .packages,
                    summary: "Downloaded packages, packages run with npx, and npm logs.",
                    explanation: "npm keeps a copy of every package it downloads in ~/.npm/_cacache so later installs are faster; `npm cache clean --force` empties it. ~/.npm/_npx holds every package run with npx. The node_modules folders of your projects are not touched.",
                    paths: FS.existing([cacache, npx, logs]), actions: actions, defaultOn: true, rebuildCost: "The next npm install or npx run downloads packages again"))
            }
        }

        if let store = FS.existing(["\(h)/Library/pnpm/store", "\(h)/.local/share/pnpm/store", "\(h)/.pnpm-store"]).first {
            let pnpm = Tools.find("pnpm")
            add(CleanupItem(id: "pnpm", name: "pnpm store", group: .packages,
                summary: pnpm != nil ? "Packages no project uses, removed with pnpm store prune." : "pnpm is not installed. The store can be emptied.",
                explanation: "pnpm keeps one copy of every package in a shared store and links it into projects. `pnpm store prune` removes only packages no project refers to and does not change projects. The size shown is the whole store, so the space freed is usually smaller.",
                paths: [store], actions: pnpm.map { [.run(Tools.command($0, ["store", "prune"]))] } ?? [.removeContents(store, except: [])],
                defaultOn: pnpm != nil, rebuildCost: "Removed packages download again if a project needs them", sizeKind: pnpm != nil ? .upTo : .measured))
        }

        let yarn = Tools.find("yarn")
        if FS.isDir("\(h)/Library/Caches/Yarn") {
            add(CleanupItem(id: "yarn", name: "Yarn cache", group: .packages, summary: "Yarn 1 global package cache.",
                explanation: "Yarn 1 keeps downloaded packages in ~/Library/Caches/Yarn so later installs are faster. Keel empties it with `yarn cache clean` when Yarn is installed, or deletes the folder contents otherwise.",
                paths: ["\(h)/Library/Caches/Yarn"], actions: yarn.map { [.run(Tools.command($0, ["cache", "clean"]))] } ?? [.removeContents("\(h)/Library/Caches/Yarn", except: [])],
                defaultOn: true, rebuildCost: "The next yarn install downloads packages again"))
        }
        if FS.isDir("\(h)/.yarn/berry/cache") {
            add(.folders(id: "yarn-berry", name: "Yarn Berry global cache", group: .packages, summary: "Yarn 2 and later: shared package mirror.",
                explanation: "Yarn 2 and later copy packages into projects from a shared mirror in ~/.yarn/berry/cache. Projects that commit their own .yarn/cache (zero-installs) are not affected.",
                paths: ["\(h)/.yarn/berry/cache"], rebuildCost: "The next install downloads packages again"))
        }

        if FS.isDir("\(h)/.bun/install/cache") {
            let bun = Tools.find("bun")
            add(CleanupItem(id: "bun", name: "Bun cache", group: .packages, summary: "Bun's global package cache.",
                explanation: "Bun keeps downloaded packages in ~/.bun/install/cache. Keel runs `bun pm cache rm`, which deletes the whole global cache, or deletes the folder contents when Bun is not installed.",
                paths: ["\(h)/.bun/install/cache"], actions: bun.map { [.run(Tools.command($0, ["pm", "cache", "rm"]))] } ?? [.removeContents("\(h)/.bun/install/cache", except: [])],
                defaultOn: true, rebuildCost: "The next bun install downloads packages again"))
        }

        if FS.isDir("\(h)/Library/Caches/pip") {
            add(.folders(id: "pip", name: "pip cache", group: .packages, summary: "Downloaded Python packages (wheels) and pip's HTTP cache.",
                explanation: "pip keeps downloaded and built packages in ~/Library/Caches/pip; this is the folder `pip cache purge` empties. pip downloads packages again when they are needed.",
                paths: ["\(h)/Library/Caches/pip"], rebuildCost: "The next pip install downloads packages again"))
        }
        if let uvDir = FS.existing(["\(h)/.cache/uv", "\(h)/Library/Caches/uv"]).first {
            let uv = Tools.find("uv")
            add(CleanupItem(id: "uv", name: "uv cache", group: .packages, summary: "Packages uv downloaded or built.",
                explanation: "uv keeps downloaded and built Python packages in its cache. uv's documentation says the cache should only be changed with uv itself, so Keel runs `uv cache clean`. When uv is no longer installed, Keel deletes the folder contents.",
                paths: [uvDir], actions: uv.map { [.run(Tools.command($0, ["cache", "clean"]))] } ?? [.removeContents(uvDir, except: [])],
                defaultOn: true, rebuildCost: "Next install downloads or builds again"))
        }
        let pipx = FS.existing(["\(h)/.local/pipx/.cache", "\(h)/Library/Caches/pipx"])
        if !pipx.isEmpty {
            add(.folders(id: "pipx", name: "pipx cache", group: .packages, summary: "Temporary environments created by pipx run.",
                explanation: "pipx keeps the environments it creates for `pipx run` in a cache. Apps installed with pipx are stored elsewhere and are not touched.",
                paths: pipx, rebuildCost: "The next pipx run recreates its environment"))
        }
        let poetry = FS.existing(["\(h)/Library/Caches/pypoetry/cache", "\(h)/Library/Caches/pypoetry/artifacts"])
        if !poetry.isEmpty {
            add(.folders(id: "poetry", name: "Poetry cache", group: .packages, summary: "Downloaded packages and built artifacts. Virtual environments are kept.",
                explanation: "Poetry keeps downloaded packages and built artifacts in ~/Library/Caches/pypoetry/cache and artifacts. The virtualenvs folder next to them holds your project environments and is not touched.",
                paths: poetry, rebuildCost: "The next poetry install downloads packages again"))
        }
        // conda and mamba caches are cleaned by conda itself.
        let condaRoots = ["\(h)/miniconda3", "\(h)/anaconda3", "\(h)/miniforge3", "\(h)/mambaforge", "\(h)/opt/anaconda3", "\(h)/opt/miniconda3",
                          "/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base", "/opt/homebrew/anaconda3", "/opt/miniconda3"]
        for root in condaRoots where FS.isDir("\(root)/pkgs") {
            let conda = FS.existing(["\(root)/bin/conda", "\(root)/bin/mamba"]).first
            let label = (root as NSString).lastPathComponent == "base" ? ((root as NSString).deletingLastPathComponent as NSString).lastPathComponent : (root as NSString).lastPathComponent
            add(CleanupItem(id: "conda-\(label)", name: "conda packages (\(label))", group: .packages,
                summary: "Package archives and unused packages, removed with conda clean.",
                explanation: "conda keeps every package archive and unpacked package it installed in \(root)/pkgs. `conda clean --all --yes` removes the archives, the index cache and packages that no environment uses; environments are not touched. The size shown is the whole pkgs folder, so the space freed is usually smaller.",
                paths: ["\(root)/pkgs"], actions: conda.map { [.run(Tools.command($0, ["clean", "--all", "--yes"]))] } ?? [],
                kind: conda != nil ? .clean : .listOnly, defaultOn: conda != nil, rebuildCost: "Packages download again when an environment needs them",
                sizeKind: .upTo))
        }

        let cargo = FS.existing(["\(h)/.cargo/registry/cache", "\(h)/.cargo/registry/src", "\(h)/.cargo/git/checkouts"])
        if !cargo.isEmpty {
            add(.folders(id: "cargo", name: "Cargo registry cache", group: .packages, summary: "Downloaded Rust crates and git checkouts.",
                explanation: "Cargo keeps downloaded crates (~/.cargo/registry/cache), their unpacked sources (registry/src) and git checkouts, and recreates them from the registry index when needed. Installed programs in ~/.cargo/bin are not touched.",
                paths: cargo, rebuildCost: "The next build downloads crates again"))
        }

        // Go: only through the go tool (module cache files are read-only on purpose).
        if let go = Tools.find("go") {
            let env = (try? await Shell.run(go, ["env", "GOMODCACHE", "GOCACHE"], timeout: 15))?.stdout.split(separator: "\n").map(String.init) ?? []
            let mod = env.first ?? "\(h)/go/pkg/mod", build = env.count > 1 ? env[1] : "\(h)/Library/Caches/go-build"
            if FS.isDir(build) {
                add(CleanupItem(id: "go-build", name: "Go build cache", group: .packages, summary: "Compiled Go packages and test results.",
                    explanation: "Go keeps compiled packages and test results so builds are faster. Keel runs `go clean -cache`; Go rebuilds what it needs on the next build.",
                    paths: [build], actions: [.run(Tools.command(go, ["clean", "-cache"]))], defaultOn: true, rebuildCost: "The next build takes longer"))
            }
            if FS.isDir(mod) {
                add(CleanupItem(id: "go-mod", name: "Go module cache", group: .packages, summary: "Downloaded Go modules. Not selected by default because offline builds need them.",
                    explanation: "Go keeps the source of every module it downloaded. The files are read-only on purpose, so Keel uses `go clean -modcache` rather than deleting them.",
                    paths: [mod], actions: [.run(Tools.command(go, ["clean", "-modcache"]))], risk: .low, defaultOn: false, rebuildCost: "Modules download again on the next build"))
            }
        }

        // Gradle: daemons must be stopped first.
        let gradleCaches = FS.existing(["\(h)/.gradle/caches", "\(h)/.gradle/daemon"])
        if !gradleCaches.isEmpty {
            var actions: [CleanupAction] = []
            if let g = Tools.find("gradle") { actions.append(.run(Tools.command(g, ["--stop"]))) }
            actions += gradleCaches.map { .removeContents($0, except: []) }
            add(CleanupItem(id: "gradle", name: "Gradle caches", group: .packages,
                summary: "Downloaded dependencies and build caches. Gradle daemons must be stopped first.",
                explanation: "Gradle keeps downloaded dependencies, transformed artifacts and its build cache in ~/.gradle/caches, and daemon logs in ~/.gradle/daemon. Deleting them while a Gradle daemon runs can corrupt entries, so Keel skips this item while one is running. Wrapper distributions, JDKs and gradle.properties are not touched.",
                paths: gradleCaches, actions: actions, risk: .low, defaultOn: false,
                rebuildCost: "The next build downloads all dependencies again, and offline builds fail until then", owner: gradleDaemon))
        }
        let dists = "\(h)/.gradle/wrapper/dists"
        if FS.isDir(dists) {
            let kids = FS.list(dists).filter { FS.isDir("\(dists)/\($0)") }.map { v in
                CleanupItem(id: "gradle-dist-\(v)", name: v, group: .packages, summary: "A Gradle version downloaded by a project's wrapper.",
                    explanation: "The Gradle wrapper downloads this Gradle version again (about 150 MB) the next time a project that uses it builds.",
                    paths: ["\(dists)/\(v)"], actions: [.removePath("\(dists)/\(v)")], defaultOn: false, rebuildCost: "Downloaded again by the wrapper", owner: gradleDaemon)
            }
            if !kids.isEmpty {
                add(CleanupItem(id: "gradle-dists", name: "Gradle wrapper distributions", group: .packages,
                    summary: "One folder per Gradle version. Not selected by default.", explanation: "Gradle removes wrapper versions that were not used for 30 days. Delete versions here that no project uses any more.",
                    paths: [dists], rebuildCost: "Downloaded again by the wrapper", children: kids))
            }
        }
        if FS.isDir("\(h)/.m2/repository") {
            add(.listOnly(id: "maven", name: "Maven repository", group: .packages, summary: "Maven's local repository. Listed only.",
                explanation: "Maven keeps every dependency it downloads in ~/.m2/repository. It can also contain artifacts installed locally with `mvn install` that cannot be downloaded again, so Keel does not delete it. Remove old versions per project with `mvn dependency:purge-local-repository`.",
                paths: ["\(h)/.m2/repository"], risk: .low))
        }

        if FS.isDir("\(h)/Library/Caches/CocoaPods") {
            let pod = Tools.find("pod")
            add(CleanupItem(id: "cocoapods", name: "CocoaPods cache", group: .packages, summary: "Downloaded pod sources and specifications.",
                explanation: "CocoaPods keeps downloaded pods in ~/Library/Caches/CocoaPods. Keel runs `pod cache clean --all`, or deletes the folder contents when CocoaPods is not installed. The specs repository in ~/.cocoapods is not touched.",
                paths: ["\(h)/Library/Caches/CocoaPods"], actions: pod.map { [.run(Tools.command($0, ["cache", "clean", "--all"]))] } ?? [.removeContents("\(h)/Library/Caches/CocoaPods", except: [])],
                defaultOn: true, rebuildCost: "The next pod install downloads pods again"))
        }
        if FS.isDir("\(h)/Library/Caches/org.swift.swiftpm") {
            add(.folders(id: "swiftpm", name: "Swift Package Manager cache", group: .packages, summary: "Copies of package repositories and their manifests.",
                explanation: "Swift Package Manager keeps copies of package repositories in ~/Library/Caches/org.swift.swiftpm. This is what `swift package purge-cache` and Xcode › File › Packages › Reset Package Caches clear. Settings in ~/Library/org.swift.swiftpm are not touched.",
                paths: ["\(h)/Library/Caches/org.swift.swiftpm"], rebuildCost: "Packages are downloaded again on the next resolve", owner: xcodeApp))
        }
        if FS.isDir("\(h)/Library/Caches/org.carthage.CarthageKit") {
            add(.folders(id: "carthage", name: "Carthage cache", group: .packages, summary: "Downloaded Carthage dependencies and binaries.",
                explanation: "Carthage keeps downloaded dependencies in ~/Library/Caches/org.carthage.CarthageKit and fetches them again on the next bootstrap.",
                paths: ["\(h)/Library/Caches/org.carthage.CarthageKit"], rebuildCost: "The next carthage bootstrap downloads dependencies again"))
        }

        // Dart / Flutter: `pub cache gc` (Dart 3.11+) keeps what projects use.
        if FS.isDir("\(h)/.pub-cache") {
            let dart = Tools.find("dart")
            let version = dart.flatMap(dartVersion) ?? []
            let gc = compare(version, [3, 11]) >= 0
            let summary = dart == nil ? "Dart is not installed. Listed only." : gc ? "Packages no project uses, removed with dart pub cache gc." : "Emptied with dart pub cache clean. Not selected by default."
            add(CleanupItem(id: "pub", name: "Dart and Flutter pub cache", group: .packages, summary: summary,
                explanation: "Dart and Flutter keep every package version they downloaded in ~/.pub-cache. Dart 3.11 and later have `dart pub cache gc`, which removes only packages that no known project uses. Earlier versions can only empty the whole cache, after which every project needs `pub get`. Packages activated with `dart pub global activate` are stored here too. The size shown is the whole cache.",
                paths: ["\(h)/.pub-cache"],
                actions: dart.map { [.run(Tools.command($0, gc ? ["pub", "cache", "gc", "--force"] : ["pub", "cache", "clean", "--force"]))] } ?? [],
                kind: dart != nil ? .clean : .listOnly, risk: gc ? .safe : .low, defaultOn: dart != nil && gc,
                rebuildCost: gc ? "Unused packages download again if a project needs them" : "`pub get` in every Flutter/Dart project",
                sizeKind: .upTo, detail: dart.map { "dart \($0)\(version.isEmpty ? "" : " (\(version.map(String.init).joined(separator: ".")))")" }))
        }

        if let deno = FS.existing(["\(h)/Library/Caches/deno", "\(h)/.cache/deno"]).first {
            add(.folders(id: "deno", name: "Deno cache", group: .packages, summary: "Downloaded modules and compiled code.",
                explanation: "Deno keeps downloaded modules and compiled code in its cache folder (DENO_DIR), which `deno clean` empties. Deno downloads modules again on the next run.",
                paths: [deno], rebuildCost: "The next run downloads modules again"))
        }
        return items
    }

    /// Reads the Dart SDK version from its `version` file, without running the (possibly self-updating) wrapper.
    static func dartVersion(_ dart: String) -> [Int]? {
        let dir = (dart as NSString).deletingLastPathComponent
        let real = ((try? FileManager.default.destinationOfSymbolicLink(atPath: dart)).map { $0.hasPrefix("/") ? $0 : "\(dir)/\($0)" } ?? dart)
        let realDir = (real as NSString).deletingLastPathComponent
        for f in ["\(dir)/cache/dart-sdk/version", "\(realDir)/../version", "\(realDir)/../libexec/version", "\(dir)/../libexec/version"] {
            if let s = try? String(contentsOfFile: (f as NSString).standardizingPath, encoding: .utf8) {
                let v = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-").first.map(String.init) ?? ""
                let parts = v.split(separator: ".").compactMap { Int($0) }
                if parts.count >= 2 { return parts }
            }
        }
        return nil
    }

    // MARK: Homebrew (separate provider: the dry run takes a second or two)

    static let homebrew: Provider = { ctx in
        guard let prefix = ctx.brewPrefix, FileManager.default.isExecutableFile(atPath: "\(prefix)/bin/brew") else { return [] }
        let brew = "\(prefix)/bin/brew"
        let env = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
        let autoremove = (try? await Shell.run(brew, ["autoremove", "--dry-run"], timeout: 60, env: env))?.stdout ?? ""
        let removable = autoremove.split(separator: "\n").filter { !$0.hasPrefix("==>") && !$0.isEmpty }.map(String.init)
        let cache = FS.existing(["\(ctx.home)/Library/Caches/Homebrew"])
        return [CleanupItem(id: "brew", name: "Homebrew downloads and old versions", group: .packages,
            summary: "Downloaded packages and old versions" + (removable.isEmpty ? "." : ", plus \(removable.count) formula\(removable.count == 1 ? "" : "e") nothing depends on."),
            explanation: "Homebrew keeps downloaded packages and older versions of installed formulae. `brew cleanup --prune=all` removes them, and `brew autoremove` uninstalls formulae that were only installed as dependencies and are no longer needed. The size is what `brew cleanup --dry-run` reports.\n\n" + (removable.isEmpty ? "" : "Would be uninstalled by autoremove:\n" + removable.joined(separator: "\n")),
            paths: cache,
            actions: [.run(CleanupCommand(executable: brew, args: ["cleanup", "--prune=all"], env: env))] + (removable.isEmpty ? [] : [.run(CleanupCommand(executable: brew, args: ["autoremove"], env: env))]),
            defaultOn: true, rebuildCost: "Packages download again on the next install or downgrade",
            sizeKind: .reported,
            measure: .custom {
                guard let r = try? await Shell.run(brew, ["cleanup", "--prune=all", "--dry-run"], timeout: 120, env: env) else { return nil }
                return parseBrewFree(r.stdout + "\n" + r.stderr)
            })]
    }

    /// "This operation would free approximately 103.9MB of disk space." → bytes (0 when nothing to free).
    static func parseBrewFree(_ s: String) -> UInt64 {
        guard let r = s.range(of: "approximately ([0-9.]+)\\s*([KMGT]?B)", options: .regularExpression) else { return 0 }
        let m = String(s[r]).replacingOccurrences(of: "approximately", with: "").trimmingCharacters(in: .whitespaces)
        let num = Double(m.prefix { "0123456789.".contains($0) }) ?? 0
        let unit = m.drop { "0123456789. ".contains($0) }
        // Homebrew's disk_usage_readable uses binary units.
        let mult: Double = unit.hasPrefix("K") ? 1_024 : unit.hasPrefix("M") ? 1_048_576 : unit.hasPrefix("G") ? 1_073_741_824 : unit.hasPrefix("T") ? 1_099_511_627_776 : 1
        return UInt64(num * mult)
    }
}
