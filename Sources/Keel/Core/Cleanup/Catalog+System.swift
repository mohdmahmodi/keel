import Foundation

extension CleanupCatalog {
    static let system: Provider = { ctx in
        let h = ctx.home
        var items: [CleanupItem] = []

        // Trash: emptied through Finder (Keel never deletes ~/.Trash itself). Measured only with Full Disk Access,
        // because asking Finder for the size would show an Automation prompt during a scan.
        items.append(CleanupItem(id: "trash", name: "Trash", group: .system,
            summary: ctx.hasFDA ? "Emptied through Finder, the same as Finder › Empty Trash." : "Emptied through Finder. Click Measure Trash to ask Finder for its size.",
            explanation: "Files moved to the Trash still use disk space until the Trash is emptied. macOS protects ~/.Trash, so Keel asks Finder to empty it; the first time, macOS asks whether Keel may control Finder. Items emptied from the Trash cannot be recovered.",
            paths: ["\(h)/.Trash"], actions: [.emptyTrashViaFinder], risk: .low, defaultOn: false, rebuildCost: "The items cannot be recovered",
            measure: ctx.hasFDA ? .du : .none))

        let logs = "\(h)/Library/Logs"
        if FS.isDir(logs) {
            let keep = ["DiagnosticReports", "JetBrains"]
            let kids = FS.list(logs).filter { !keep.contains($0) }
            if !kids.isEmpty {
                items.append(CleanupItem(id: "user-logs", name: "App logs", group: .system, summary: "Log files apps write to ~/Library/Logs. Crash reports are listed separately.",
                    explanation: "Apps write text logs to ~/Library/Logs. macOS does not read them; they are only useful when investigating a problem with a specific app. Crash reports in DiagnosticReports are a separate item.",
                    paths: kids.map { "\(logs)/\($0)" }, actions: [.removeContents(logs, except: keep)], defaultOn: true, rebuildCost: "Nothing; apps start new logs"))
            }
            let diag = "\(logs)/DiagnosticReports"
            if FS.isDir(diag) {
                items.append(.folders(id: "diagnostic-reports", name: "Crash and hang reports", group: .system,
                    summary: "Crash and hang reports in ~/Library/Logs/DiagnosticReports. Not selected by default.",
                    explanation: "macOS writes a report (.ips file) each time an app crashes or hangs. Developers and Apple ask for these reports when a bug is reported, so they are not selected by default.",
                    paths: [diag], defaultOn: false, rebuildCost: "Old reports are gone"))
            }
        }

        let backups = "\(h)/Library/Application Support/MobileSync/Backup"
        if FS.exists(backups) || ctx.hasFDA {
            let readable = FS.readable(backups)
            items.append(CleanupItem(id: "ios-backups", name: "iPhone and iPad backups", group: .system,
                summary: readable ? "Backups of iPhone and iPad made by Finder. Delete them in Finder." : "Backups of iPhone and iPad. Full Disk Access is needed to measure them.",
                explanation: "Finder stores local backups of iPhone and iPad in ~/Library/Application Support/MobileSync/Backup. A backup may be the only copy of messages and photos, so Keel only measures them. To delete one, select the device in Finder and click Manage Backups.",
                paths: [backups], kind: readable ? .listOnly : .needsFullDiskAccess("measure local device backups"), risk: .medium, rebuildCost: "Cannot be recreated"))
        }

        let mail = "\(h)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        if ctx.hasFDA, FS.isDir(mail) {
            items.append(.folders(id: "mail-downloads", name: "Mail downloads", group: .system, summary: "Copies of attachments Mail saved when you opened them.",
                explanation: "Mail saves a copy of each attachment you open in its Mail Downloads folder. The original stays in the message on the mail server and is downloaded again when opened.",
                paths: [mail], defaultOn: false, rebuildCost: "Downloaded again from the mail server when opened", owner: OwningApp(name: "Mail", bundleIDs: ["com.apple.mail"])))
        } else if !ctx.hasFDA {
            items.append(CleanupItem(id: "mail-downloads", name: "Mail downloads", group: .system, summary: "Attachments Mail saved. Full Disk Access is needed to measure them.",
                explanation: "Mail saves a copy of each attachment you open. macOS protects Mail's folder, so Keel can only measure and clean it with Full Disk Access.",
                paths: [mail], kind: .needsFullDiskAccess("read Mail's attachment cache"), defaultOn: false, rebuildCost: "Downloaded again from the mail server when opened"))
        }
        return items
    }

    // MARK: Local snapshots

    static let snapshots: Provider = { _ in
        let snaps = await DiskSpace.localSnapshots()
        guard !snaps.isEmpty else { return [] }
        let space = DiskSpace.read()
        let own = Set(SnapshotHelper.ownSnapshots)
        let kids = snaps.map { s -> CleanupItem in
            if let date = s.tmDate {
                let isKeel = own.contains(date)
                let autoDelete = SnapshotHelper.date(of: date).map { $0.addingTimeInterval(SnapshotHelper.keepFor).formatted(date: .abbreviated, time: .shortened) }
                let name = isKeel ? "Keel safety snapshot (deleted automatically on \(autoDelete ?? "the following day"))" : s.name
                return CleanupItem(id: "snap-\(s.name)", name: name, group: .system,
                    summary: isKeel ? "Taken by Keel before it applied tweaks, at \(date)." : "Time Machine local snapshot taken at \(date).",
                    explanation: (isKeel ? "Keel took this snapshot before changing settings so the Mac could be restored to that point, and deletes it 24 hours after it was taken. " : "A Time Machine local snapshot of the Data volume, taken at \(date). ")
                        + "A snapshot keeps every block that existed when it was taken, including files deleted later, so deleting files frees space only after the snapshot is removed. Keel removes it with `tmutil deletelocalsnapshots \(date)`, which needs no administrator password.",
                    actions: [.run(CleanupCommand(executable: "/usr/bin/tmutil", args: ["deletelocalsnapshots", date]))],
                    risk: .low, defaultOn: false, rebuildCost: "This local restore point is removed", measure: .none, detail: s.name)
            }
            return CleanupItem(id: "snap-\(s.name)", name: s.name, group: .system,
                summary: s.isSystemUpdate ? "Snapshot made by a macOS update. macOS removes it." : "Snapshot made by another app. Manage it in that app.",
                explanation: "This snapshot was not made by Time Machine or Keel, so Keel does not delete it. Backup apps such as Carbon Copy Cloner manage their own snapshots, and macOS removes update snapshots itself.",
                kind: .listOnly, risk: .medium, rebuildCost: "Not deleted by Keel", measure: .none, detail: s.name)
        }
        let deletable = snaps.filter(\.isTimeMachine).count
        return [CleanupItem(id: "snapshots", name: "Local snapshots", group: .system,
            summary: "\(snaps.count) snapshot\(snaps.count == 1 ? "" : "s") on this disk. Deleted files keep using space until they are removed.",
            explanation: "An APFS snapshot keeps every block of the disk that existed when it was taken. While a snapshot exists, deleting files does not increase free space, because the snapshot still refers to their blocks. macOS counts this space as purgeable and removes Time Machine snapshots after 24 hours or when space runs low, but not always promptly. The size shown is the disk's purgeable space (available space in Finder minus actual free space), which is the most the snapshots can be holding.\n\n\(deletable) of \(snaps.count) can be deleted here.",
            rebuildCost: "Local restore points are removed", sizeBytes: space.purgeable, sizeKind: .upTo, measure: .preset, children: kids)]
    }

    // MARK: Old installers in Downloads (moved to the Trash, not deleted)

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    static let oldInstallers: Provider = { ctx in
        guard ctx.includeUserFolders else { return [] }
        let dl = "\(ctx.home)/Downloads"
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var kids: [CleanupItem] = []
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dl), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        for u in urls where installerExtensions.contains(u.pathExtension.lowercased()) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let added = v?.addedToDirectoryDate ?? v?.creationDate ?? v?.contentModificationDate ?? Date()
            guard added < cutoff else { continue }
            let days = Int(Date().timeIntervalSince(added) / 86_400)
            kids.append(CleanupItem(id: "dl-\(u.lastPathComponent)", name: u.lastPathComponent, group: .system,
                summary: "Added to Downloads \(days) days ago.",
                explanation: "Disk images and installer packages are rarely needed once the app is installed. Keel moves this file to the Trash, so it can be put back until the Trash is emptied.",
                paths: [u.path], actions: [.moveToTrash(u.path)], risk: .low, defaultOn: true, rebuildCost: "Download it again if it is needed"))
        }
        guard !kids.isEmpty else { return [] }
        return [CleanupItem(id: "old-installers", name: "Old installers in Downloads", group: .system,
            summary: ".dmg, .pkg and .xip files older than 30 days. Moved to the Trash.",
            explanation: "Installer files (.dmg, .pkg, .mpkg, .xip) added to Downloads more than 30 days ago. Keel moves them to the Trash the same way Finder does, so they can be put back. The space is freed when the Trash is emptied.",
            rebuildCost: "Download again if needed", children: kids)]
    }
}
