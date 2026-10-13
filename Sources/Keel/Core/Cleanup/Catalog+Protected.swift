import Foundation

/// Large things Keel shows but never deletes: models, VMs, media, your code, big files.
extension CleanupCatalog {
    static let protected: Provider = { ctx in
        let h = ctx.home
        var items: [CleanupItem] = []
        func folder(_ id: String, _ name: String, _ paths: [String], _ summary: String, _ explanation: String, risk: Risk = .medium) {
            let existing = FS.existing(paths)
            guard !existing.isEmpty else { return }
            items.append(.listOnly(id: id, name: name, summary: summary, explanation: explanation, paths: existing, risk: risk))
        }

        folder("ollama-models", "Ollama models", ["\(h)/.ollama/models"], "Models downloaded by Ollama. Remove them with ollama rm.",
               "Ollama stores downloaded language models here; each is several GB and takes minutes to download again. List them with `ollama list` and remove unused ones with `ollama rm <name>`, which keeps Ollama's index consistent.")
        folder("lmstudio-models", "LM Studio models", ["\(h)/.lmstudio/models", "\(h)/.cache/lm-studio/models"], "Models downloaded by LM Studio. Remove them in LM Studio.",
               "LM Studio stores downloaded language models here. Remove unused models in LM Studio's My Models view so its index stays consistent.")
        folder("hf-cache", "Hugging Face cache", [ProcessInfo.processInfo.environment["HF_HOME"].map { "\($0)/hub" } ?? "\(h)/.cache/huggingface"], "Models and datasets downloaded from Hugging Face.",
               "Python libraries from Hugging Face store downloaded models and datasets in this cache. `hf cache scan` lists its contents and `hf cache delete` removes selected revisions.")

        let dockerRaw = "\(h)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        if FS.containerExists("com.docker.docker", home: h) {
            var item = CleanupItem.listOnly(id: "docker-vm", name: "Docker Desktop disk image", summary: "The disk image that holds Docker's images, containers and volumes.",
                explanation: "Docker Desktop keeps images, containers and volumes in one disk image, Docker.raw. It is a sparse file: Finder shows its maximum size, while Keel shows the space it actually uses. Free space inside it with `docker system prune -a` (add `--volumes` only if no volume is needed), and Docker returns the space to macOS.",
                paths: [dockerRaw])
            item.measure = .preset
            if !ctx.hasFDA {
                item.kind = .needsFullDiskAccess("measure Docker's disk image")
                items.append(item)
            } else if let size = FS.allocatedSize(dockerRaw) {
                item.sizeBytes = size
                items.append(item)
            }
        }
        if FS.isDir("\(h)/.orbstack") {
            let data = "\(h)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"
            var item = CleanupItem.listOnly(id: "orbstack", name: "OrbStack data", summary: "Containers, images and Linux machines. Manage them in OrbStack.",
                explanation: "OrbStack keeps containers, images and Linux machines in one disk image. Removing images and machines in OrbStack, or with `docker system prune`, returns the space to macOS automatically.",
                paths: [data])
            if !ctx.hasFDA { item.kind = .needsFullDiskAccess("measure OrbStack's container"); item.measure = .none }
            items.append(item)
        }
        let utm = "\(h)/Library/Containers/com.utmapp.UTM/Data/Documents"
        if FS.containerExists("com.utmapp.UTM", home: h) {
            var item = CleanupItem.listOnly(id: "utm", name: "UTM virtual machines", summary: "Virtual machines. Delete them in UTM.", explanation: "Each .utm bundle is one virtual machine with its disks. Delete virtual machines in UTM.", paths: [utm])
            if !ctx.hasFDA { item.kind = .needsFullDiskAccess("measure UTM's sandboxed container"); item.measure = .none }
            items.append(item)
        }
        folder("parallels", "Parallels virtual machines", ["\(h)/Parallels", "\(h)/Library/Parallels"], "Virtual machines and downloaded installers. Remove virtual machines in Parallels.",
               "~/Parallels holds virtual machines (.pvm), and ~/Library/Parallels holds downloaded operating system installers, often several GB of .iso files that are not needed once a virtual machine is set up. Remove virtual machines in Parallels Control Center so it can update its list.")
        folder("vmware", "VMware Fusion virtual machines", ["\(h)/Virtual Machines.localized"] + (ctx.includeUserFolders ? ["\(h)/Documents/Virtual Machines.localized"] : []),
               "Virtual machines. Delete them in VMware Fusion.", "Each .vmwarevm bundle is one virtual machine with its disks. Delete virtual machines in VMware Fusion so it can update its library.")
        folder("android-sdk", "Android SDK", ["\(h)/Library/Android/sdk"], "Android build tools, NDKs, system images and the emulator.",
               "The Android SDK holds build tools, NDKs, platform files and emulator system images. Deleting its folders by hand breaks Android Studio's package list, so uninstall packages in Android Studio › SDK Manager or with `sdkmanager --uninstall <package>`. Remove a system image only when no emulator uses it.", risk: .low)
        folder("android-avd", "Android emulators", ["\(h)/.android/avd"], "Android emulator disks. Delete emulators in Android Studio.",
               "Each Android emulator (AVD) keeps its own disk with installed apps and data. Delete unused emulators in Android Studio › Device Manager or with `avdmanager delete avd -n <name>`.", risk: .low)
        folder("flutter-sdk", "Flutter SDK", ["\(h)/flutter", "\(h)/development/flutter", "\(h)/fvm/versions"], "The Flutter SDK and the tools it downloaded.",
               "The Flutter SDK, including bin/cache with the engine and Dart SDK it downloaded. The flutter command downloads bin/cache again on its next run, so deleting it frees space only briefly.", risk: .low)

        let photos = "\(h)/Pictures/Photos Library.photoslibrary"
        if FS.exists(photos) {
            var item = CleanupItem.listOnly(id: "photos-library", name: "Photos library", summary: "Your photo library. Manage its size in Photos.",
                explanation: "The Photos library is a package that only Photos should change. With iCloud Photos, Photos › Settings › iCloud › Optimize Mac Storage keeps smaller versions on the Mac and the originals in iCloud. Photos in Recently Deleted are removed after 30 days.", paths: [photos])
            if !ctx.hasFDA { item.kind = .needsFullDiskAccess("measure the Photos library"); item.measure = .none }
            items.append(item)
        }
        // Movies and Music: only with consent, and never inside the Apple TV and Music libraries, which macOS
        // protects separately (reading them waits for a privacy prompt).
        let mediaLibraries: Set<String> = ["TV", "Music", "Photos Library.photoslibrary"]
        func mediaFolder(_ name: String) -> [String] {
            guard ctx.includeUserFolders else { return [] }
            return FS.list("\(h)/\(name)").filter { !mediaLibraries.contains($0) && !$0.hasSuffix(".musiclibrary") && !$0.hasSuffix(".tvlibrary") }.map { "\(h)/\(name)/\($0)" }
        }
        folder("movies", "Movies", mediaFolder("Movies"), "Your videos and video projects.", "Your Movies folder, including Final Cut Pro and iMovie libraries. The Apple TV app library is not measured, because macOS asks for permission before an app reads it. Final Cut Pro can remove render files it can recreate with File › Delete Generated Library Files.")
        folder("music", "Music", mediaFolder("Music"), "Files in your Music folder outside the Music app library.", "Files in your Music folder. The Music app library is not measured, because macOS asks for permission before an app reads it; remove downloads in the Music app so its library stays consistent.")
        if ctx.includeUserFolders {
            folder("downloads", "Downloads", ["\(h)/Downloads"], "Everything in Downloads. Old installers are listed under System.", "Your Downloads folder. Keel measures it and only offers to move old installer files to the Trash.")
        }
        return items
    }

    // MARK: Build folders in your repositories (list only)

    static func repoRoots(_ ctx: CatalogContext) -> [String] {
        let h = ctx.home
        let candidates = ["\(h)/Developer", "\(h)/Projects", "\(h)/projects", "\(h)/Code", "\(h)/code", "\(h)/src", "\(h)/dev", "\(h)/repos", "\(h)/Repos",
                          "\(h)/GitHub", "\(h)/git", "\(h)/workspace", "\(h)/Sites",
                          "\(h)/Documents/GitHub", "\(h)/Documents/Projects", "\(h)/Documents/Code", "\(h)/Documents/Developer", "\(h)/Desktop/Projects"]
        var seen = Set<String>()
        return candidates.filter { p in
            guard ctx.includeUserFolders || !ctx.isUserFolder(p), FS.isDir(p) else { return false }
            let real = (p as NSString).resolvingSymlinksInPath.lowercased()   // case-insensitive volumes: Code == code
            return seen.insert(real).inserted
        }
    }

    static let repoBuildFolders: Provider = { ctx in
        let roots = repoRoots(ctx)
        guard !roots.isEmpty else { return [] }
        var items: [CleanupItem] = []
        for r in roots {
            items.append(.listOnly(id: "repo-root-\(r)", name: (r as NSString).abbreviatingWithTildeInPath, summary: "A folder of code repositories. Listed only.",
                explanation: "A folder that contains code repositories. Keel measures it and never deletes anything in it. Build folders inside it are listed separately.", paths: [r], risk: .medium))
        }
        // node_modules (package.json next to it), target (Cargo.toml), .build (Package.swift). Pruned so nested ones are not walked.
        let args = roots + ["-maxdepth", "5", "(", "-name", ".git", "-prune", ")", "-o", "-type", "d", "(", "-name", "node_modules", "-o", "-name", "target", "-o", "-name", ".build", ")", "-prune", "-print"]
        guard let out = try? await Shell.run("/usr/bin/find", args, timeout: 120) else { return items }
        var kids: [CleanupItem] = []
        for line in out.stdout.split(separator: "\n") {
            let p = String(line)
            let parent = (p as NSString).deletingLastPathComponent
            let leaf = (p as NSString).lastPathComponent
            let marker: String, rebuild: String
            switch leaf {
            case "node_modules": marker = "package.json"; rebuild = "`npm install` (or pnpm/yarn) in that project"
            case "target": marker = "Cargo.toml"; rebuild = "`cargo build` in that project"
            default: marker = "Package.swift"; rebuild = "`swift build` in that project"
            }
            guard FS.exists("\(parent)/\(marker)") else { continue }
            let project = (parent as NSString).abbreviatingWithTildeInPath
            let age = FS.modified(parent).map { "Project changed \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
            kids.append(CleanupItem(id: "build-\(p)", name: "\(project)/\(leaf)", group: .protected, summary: age,
                explanation: "Dependencies or build output that the project's tools can recreate. Keel lists it so you can see where space goes and does not delete it. Deleting it for a project you are working on stops that project from building until its dependencies are installed again.",
                paths: [p], kind: .listOnly, risk: .low, rebuildCost: rebuild))
        }
        if !kids.isEmpty {
            items.append(CleanupItem(id: "repo-build-folders", name: "Build folders in your repositories", group: .protected,
                summary: "\(kids.count) node_modules, target and .build folders. Listed only.",
                explanation: "Found under \(roots.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")), up to five levels deep. Each can be recreated by the project's package manager or build tool.",
                kind: .listOnly, risk: .low, rebuildCost: "Reinstall or rebuild per project", children: kids))
        }
        return items
    }

    // MARK: Files over 1 GB anywhere in your home folder (Spotlight)

    static let largeFiles: Provider = { ctx in
        let h = ctx.home
        guard let r = try? await Shell.run("/usr/bin/mdfind", ["-onlyin", h, "-attr", "kMDItemFSSize", "kMDItemFSSize > 1073741824"], timeout: 30) else { return [] }
        var files: [(String, UInt64)] = []
        for line in r.stdout.split(separator: "\n") {
            guard let range = line.range(of: "   kMDItemFSSize = ", options: .backwards) else { continue }
            let path = String(line[..<range.lowerBound])
            guard let size = UInt64(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) else { continue }
            // Without Full Disk Access, files in app containers can't be checked for sparseness, so their logical
            // size misleads (Docker.raw reports its 460 GB maximum). Those apps have their own rows.
            if !Permissions.canRead(path) { continue }
            files.append((path, size))
        }
        files.sort { $0.1 > $1.1 }
        let kids = files.prefix(60).map { (path, logical) -> CleanupItem in
            var item = CleanupItem.listOnly(id: "large-\(path)", name: (path as NSString).lastPathComponent, group: .largeFiles,
                summary: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                explanation: "A file larger than 1 GB found by Spotlight. The size shown is the file's full length; sparse files such as virtual machine disks can use less space. Keel does not delete it; use Reveal in Finder to decide.",
                paths: [path], risk: .low, rebuildCost: "Not deleted by Keel")
            item.measure = .preset
            item.sizeBytes = logical
            item.sizeKind = .logical
            // Real allocation, when reading the file's metadata cannot trigger a folder prompt.
            if ctx.includeUserFolders || !ctx.isUserFolder(path), let alloc = FS.allocatedSize(path), alloc + 64 * 1_048_576 < logical {
                item.sizeBytes = alloc
                item.sizeKind = .measured
                item.summary += " · sparse, \(logical.humanBytes) logical"
            }
            return item
        }
        guard !kids.isEmpty else { return [] }
        return [CleanupItem(id: "large-files", name: "Files over 1 GB", group: .largeFiles,
            summary: "\(kids.count) file\(kids.count == 1 ? "" : "s") Spotlight found in your home folder. Listed only.",
            explanation: "Files larger than 1 GB in your home folder, found with the Spotlight query `kMDItemFSSize > 1073741824`. Folders that Spotlight does not index, such as hidden folders and Search Privacy exclusions, are not included.",
            kind: .listOnly, risk: .low, rebuildCost: "Not deleted by Keel", measure: .none, children: Array(kids))]
    }
}
