import AppKit
import Darwin

/// Offers to move Keel into /Applications when it was opened from the disk image or another folder,
/// then ejects the disk image, moves it to the Trash and reopens Keel from Applications.
@MainActor
enum AppMover {
    private static let declinedKey = "keelDeclinedMoveToApplications"
    /// Test hook: move into this folder without asking, and don't reopen. Used by scripts/test-install.sh.
    private static var testFolder: String? { ProcessInfo.processInfo.environment["KEEL_MOVE_TEST_DIR"] }

    enum Origin: Equatable { case diskImage(mount: String), folder }

    /// Where the running bundle really lives. Gatekeeper runs quarantined apps from a randomized
    /// read-only copy (App Translocation), so ask Security for the original path.
    static func originalURL(of url: URL) -> URL {
        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else { return url }
        defer { dlclose(lib) }
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let isSym = dlsym(lib, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil) != 0, translocated,
              let original = unsafeBitCast(origSym, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }

    static func isInApplications(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Development builds run from the build folders and are left alone.
    static func isDevelopmentBuild(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/.build/") || path.contains("/dist.noindex/") || path.contains("/DerivedData/")
    }

    static func origin(of url: URL) -> Origin {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            let mount = "/Volumes/" + parts[2]
            if diskImagePath(mountedAt: mount) != nil { return .diskImage(mount: mount) }
        }
        return .folder
    }

    /// The .dmg file behind a mounted volume, from `hdiutil info`.
    static func diskImagePath(mountedAt mount: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info", "-plist"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        for image in images {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            if entities.contains(where: { ($0["mount-point"] as? String) == mount }) { return image["image-path"] as? String }
        }
        return nil
    }

    static func offerIfNeeded() {
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let source = originalURL(of: running)
        let from = origin(of: source)
        if let dir = testFolder {
            do { try move(from: source, origin: from, into: URL(fileURLWithPath: dir, isDirectory: true)) }
            catch { FileHandle.standardError.write("move failed: \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }
            return
        }
        guard !isInApplications(source), !isDevelopmentBuild(source),
              !UserDefaults.standard.bool(forKey: declinedKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Move Keel to the Applications folder?"
        alert.informativeText = from == .folder
            ? "Keel is running from \(source.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). In Applications it can install its helper and receive updates."
            : "Keel is running from the disk image. In Applications it can install its helper and receive updates. The disk image is ejected and moved to the Trash afterwards."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
        guard response == .alertFirstButtonReturn else { return }

        do {
            try move(from: source, origin: from, into: URL(fileURLWithPath: "/Applications", isDirectory: true))
        } catch {
            ActivityLog.shared.info("Could not move Keel to Applications: \(error.localizedDescription)")
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "Keel could not be moved"
            failed.informativeText = "\(error.localizedDescription)\n\nDrag Keel to the Applications folder in Finder instead."
            failed.runModal()
        }
    }

    private static func clearQuarantine(_ bundle: URL) {
        removexattr(bundle.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let item as String in items {
            removexattr(bundle.appendingPathComponent(item).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func move(from source: URL, origin: Origin, into applications: URL) throws {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: applications.path) else {
            throw NSError(domain: "Keel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Your account can't write to the Applications folder."])
        }
        let destination = applications.appendingPathComponent(source.lastPathComponent)

        // Replace an older copy: quit it if it is running, then move it to the Trash.
        if fm.fileExists(atPath: destination.path) {
            let me = ProcessInfo.processInfo.processIdentifier
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.processIdentifier != me && app.bundleURL?.standardizedFileURL == destination.standardizedFileURL {
                app.terminate()
                for _ in 0..<50 where !app.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
                if !app.isTerminated { app.forceTerminate() }
            }
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        // Gatekeeper has already approved this copy. Without the download flag it opens from
        // Applications directly instead of from a translocated copy.
        clearQuarantine(destination)

        var mount = ""
        switch origin {
        case .diskImage(let m):
            mount = m
            if let image = diskImagePath(mountedAt: m) { try? fm.trashItem(at: URL(fileURLWithPath: image), resultingItemURL: nil) }
        case .folder:
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
        if testFolder == nil { ActivityLog.shared.info("Moved Keel to \(destination.path)") }

        // After this process exits: eject the disk image and open the copy in Applications.
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        [ -n "$1" ] && /usr/bin/hdiutil detach -quiet "$1" || true
        [ "$3" = test ] || /usr/bin/open "$2"
        """
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script, "keel-relaunch", mount, destination.path, testFolder == nil ? "" : "test"]
        try relaunch.run()
        NSApp.terminate(nil)
    }
}
