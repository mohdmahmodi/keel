import Foundation
import KeelShared

// Cards are generated only for vendors with something installed, or with a backup record so a vendor Keel
// already disabled can still be restored. Tweak IDs are stable per vendor.

extension TweakCatalog {
    static let background: [Tweak] = BGCatalog.build()
}

// MARK: - Launchd folder scan

private struct BGPlist: Sendable {
    let label: String
    let path: String
    let domain: LaunchdDomain
    /// `Program` or `ProgramArguments[0]`.
    let program: String?
    /// Regular file (not a symlink): only those can be moved by the privileged helper.
    let isRegularFile: Bool
    let watchPaths: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let startInterval: Int?

    var fileName: String { (path as NSString).lastPathComponent }
}

private enum BGScan {
    static let home = NSHomeDirectory()

    static var folders: [(String, LaunchdDomain)] {
        [("\(home)/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .globalAgent), ("/Library/LaunchDaemons", .system)]
    }

    /// Labels Keel must never offer: Apple's own and Keel's own jobs.
    static func isProtected(_ label: String, file: String) -> Bool {
        let l = label.lowercased(), f = file.lowercased()
        return ["com.apple.", "com.keel.", "com.mohdmahmodi.keel"].contains { l.hasPrefix($0) || f.hasPrefix($0) }
    }

    /// `brew services` owns these plists; touching them with launchctl fights Homebrew.
    static func isHomebrew(_ label: String) -> Bool { label.hasPrefix("homebrew.") }

    /// Labels the helper's allow-list accepts for `launchctl` (see PrivOp.validate).
    static func validLabel(_ label: String) -> Bool {
        label.range(of: "^[A-Za-z0-9._-]{1,200}$", options: .regularExpression) != nil
    }

    /// A plist that cannot be parsed (or is root-only) is still listed, labelled by its file name.
    static func scan() -> [BGPlist] {
        var out: [BGPlist] = []
        let fm = FileManager.default
        for (dir, domain) in folders {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files.sorted() where f.hasSuffix(".plist") && !f.hasPrefix(".") {
                let path = "\(dir)/\(f)"
                let stem = String(f.dropLast(6))
                let dict = NSDictionary(contentsOfFile: path) as? [String: Any] ?? [:]
                let label = (dict["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
                if isProtected(label, file: f) { continue }
                var program = dict["Program"] as? String
                if program == nil, let args = dict["ProgramArguments"] as? [String], let first = args.first { program = first }
                var st = stat()
                let regular = lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
                let watch = (dict["WatchPaths"] as? [String]) ?? []
                let keepAlive = (dict["KeepAlive"] as? Bool) ?? (dict["KeepAlive"] is [String: Any])
                out.append(BGPlist(label: label, path: path, domain: domain, program: program, isRegularFile: regular,
                                   watchPaths: watch, runAtLoad: (dict["RunAtLoad"] as? Bool) ?? false, keepAlive: keepAlive,
                                   startInterval: (dict["StartInterval"] as? NSNumber)?.intValue))
            }
        }
        return out
    }

    /// Paths Keel never judges: other users' homes, removable and network volumes, and folders whose
    /// check could raise a privacy prompt.
    static func isUncheckable(_ p: String) -> Bool {
        if p.hasPrefix("/Volumes/") || p.hasPrefix("/Network/") || p.hasPrefix("/net/") { return true }
        if p.hasPrefix("/Users/") {
            guard p.hasPrefix(home + "/") else { return true }
            let sensitive = ["/Desktop/", "/Documents/", "/Downloads/", "/Pictures/", "/Movies/", "/Music/",
                             "/Library/Containers/", "/Library/Group Containers/", "/Library/Mobile Documents/", "/Library/CloudStorage/"]
            if sensitive.contains(where: { p.contains($0) }) { return true }
            return Permissions.isProtected(p)
        }
        return false
    }

    /// System executables (shells, interpreters, `open`): the job's real target is in its arguments,
    /// which Keel does not parse, so such jobs are never called orphaned.
    static func isSystemExecutable(_ p: String) -> Bool {
        ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/", "/Library/Apple/"].contains { p.hasPrefix($0) }
    }

    /// True only when the path is definitely gone (ENOENT/ENOTDIR). A folder Keel may not read
    /// (EACCES) never counts as missing.
    static func isMissing(_ path: String) -> Bool {
        var st = stat()
        if stat(path, &st) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// True when the plist runs an absolute, checkable, non-system program that no longer exists.
    static func isOrphan(_ p: BGPlist) -> Bool {
        guard let prog = p.program, prog.hasPrefix("/"), !isSystemExecutable(prog), !isUncheckable(prog) else { return false }
        return isMissing(prog)
    }

    /// Items Keel already moved for this tweak (from the newest backup record), so a disabled vendor
    /// keeps its card and can be restored.
    static func recordedItems(_ tweakID: String) -> [LaunchdItem] {
        guard let rec = BackupStore.latest(for: tweakID), rec.kind == .plistMoved else { return [] }
        let n = Int(rec.original["count"] ?? "0") ?? 0
        return (0..<n).compactMap { i in
            guard let label = rec.original["\(i).label"], let path = rec.original["\(i).path"],
                  let domain = LaunchdDomain(rawValue: rec.original["\(i).domain"] ?? "") else { return nil }
            return LaunchdItem(label: label, plistPath: path, domain: domain)
        }
    }

    static func describe(_ p: BGPlist) -> String {
        var parts: [String] = []
        if p.runAtLoad { parts.append("starts at login") }
        if p.keepAlive { parts.append("kept running") }
        if let s = p.startInterval { parts.append(s % 3600 == 0 ? "every \(s / 3600) h" : "every \(s) s") }
        if !p.watchPaths.isEmpty { parts.append("watches \(p.watchPaths.count) path\(p.watchPaths.count == 1 ? "" : "s")") }
        if isOrphan(p) { parts.append("program missing") }
        return parts.isEmpty ? "on demand" : parts.joined(separator: ", ")
    }

    static func domainName(_ d: LaunchdDomain) -> String {
        switch d {
        case .user: return "~/Library/LaunchAgents"
        case .globalAgent: return "/Library/LaunchAgents"
        case .system: return "/Library/LaunchDaemons"
        }
    }
}

// MARK: - Known vendor table

/// A vendor's background items. `patterns` are case-insensitive regular expressions on the launchd label
/// (or the file name when the plist has no Label).
private struct BGVendor {
    let id: String
    let name: String
    let vendor: String
    let patterns: [String]
    var domains: Set<LaunchdDomain> = [.user, .globalAgent, .system]
    /// Card line: what changes for the user.
    let summary: String
    /// First sentence of the explanation.
    let plain: String
    /// One or two sentences on what the items are and do.
    let what: String
    let tradeoff: String
    let benefit: String
    var risk: Risk = .low
    var recommended = false
    var confidence: Confidence = .high
    var audience: Set<Audience> = [.everyone]
    /// The supported switch inside the vendor's own app, if there is one.
    var inAppAlternative: String? = nil
    /// The vendor re-installs the items (on app launch or update).
    var reinstalls: String? = nil
    /// The job only reacts to WatchPaths; when none of them exist it can never do anything.
    var deadWhenWatchPathsMissing = false
    var sources: [String] = []

    func matches(_ p: BGPlist) -> Bool {
        guard domains.contains(p.domain) else { return false }
        let stem = String(p.fileName.dropLast(6))
        return patterns.contains { pat in
            p.label.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil
                || stem.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

private enum BGVendors {
    static let agentsOnly: Set<LaunchdDomain> = [.user, .globalAgent]
    /// Apple's table of known third-party background items, read on macOS 27.0.
    static let attributions = "Local check (macOS 27.0): label listed in /System/Library/PrivateFrameworks/BackgroundTaskManagement.framework/Resources/attributions.plist"
    static let updaterPlain = "This updater no longer runs in the background; the app itself keeps working."

    /// Order matters: the first vendor whose pattern matches owns the plist.
    static let table: [BGVendor] = [
        // Browsers and Microsoft
        BGVendor(id: "google-updater-agent", name: "Google Updater background agent", vendor: "Google",
                 patterns: [#"^com\.google\.GoogleUpdater\."#, #"^com\.google\.keystone\."#],
                 summary: "Chrome's updater stops waking up every hour. Chrome still checks for updates when you open it.",
                 plain: "Google's updater no longer wakes up every hour to look for Chrome updates while Chrome is closed.",
                 what: "Google Updater (formerly Keystone) is installed by Chrome and other Google apps; its com.google.GoogleUpdater.wake job runs once an hour (StartInterval 3600). The com.google.keystone.* files are often empty placeholders that load nothing.",
                 tradeoff: "Chrome updates only while it is open, and Google apps you rarely open stay on older versions until you do.",
                 benefit: "One fewer job waking the Mac every hour. Nothing changes on screen.",
                 recommended: true,
                 inAppAlternative: "Turning off \"Google LLC\" in System Settings > General > Login Items & Extensions also blocks the agent, even after Chrome re-creates it.",
                 reinstalls: "Chrome contains the updater and usually re-registers the agent the next time it starts; Keel's card then shows it as off again.",
                 sources: ["https://chromium.googlesource.com/chromium/src/+/main/docs/updater/functional_spec.md", attributions]),
        BGVendor(id: "bg-microsoft-edge-updater", name: "Microsoft Edge updater", vendor: "Microsoft",
                 patterns: [#"^com\.microsoft\.EdgeUpdater\."#],
                 summary: "Edge's updater stops running in the background. Edge still checks for updates when you open it.",
                 plain: "Edge's updater no longer wakes up in the background to look for updates while Edge is closed.",
                 what: "Since Edge 113, Edge uses EdgeUpdater, which installs a periodic wake job and an update job (com.microsoft.EdgeUpdater.*).",
                 tradeoff: "Edge updates only while it is open.",
                 benefit: "The periodic wake and update jobs stop running while Edge is closed.",
                 recommended: true,
                 reinstalls: "Edge re-registers its updater the next time it starts.",
                 sources: ["https://learn.microsoft.com/en-us/deployedge/edge-learnmore-edgeupdater-for-macos", attributions]),
        BGVendor(id: "bg-microsoft-autoupdate", name: "Microsoft AutoUpdate (MAU)", vendor: "Microsoft",
                 patterns: [#"^com\.microsoft\.update\.agent$"#, #"^com\.microsoft\.autoupdate\."#],
                 summary: "The updater for Office, Teams and Defender stops running. App Store copies of Office do not use it.",
                 plain: "Microsoft AutoUpdate (MAU), the shared updater for Microsoft's Mac apps, no longer runs in the background.",
                 what: "MAU has a per-user agent (com.microsoft.update.agent) and an administrator helper (com.microsoft.autoupdate.helper) that install updates for Word, Excel, PowerPoint, Outlook, OneNote, Teams and Defender downloaded from Microsoft.",
                 tradeoff: "Microsoft apps stop receiving updates, including security fixes, until you restore this or run a Microsoft installer.",
                 benefit: "A background agent and a helper running with administrator rights are gone.",
                 risk: .medium,
                 inAppAlternative: "Microsoft AutoUpdate's own settings can turn off automatic download and install while keeping manual checks.",
                 reinstalls: "Any Office installer or update re-installs MAU.",
                 sources: ["https://support.microsoft.com/en-us/office/update-office-for-mac-automatically-bfd1e497-c24d-4754-92ab-910a4074d7c1", attributions]),
        BGVendor(id: "bg-microsoft-onedrive-updater", name: "OneDrive standalone updater", vendor: "Microsoft",
                 patterns: [#"^com\.microsoft\.OneDriveStandaloneUpdater"#, #"^com\.microsoft\.OneDriveUpdaterDaemon$"#],
                 summary: "The downloaded OneDrive stops checking for new versions in the background. Syncing is unaffected.",
                 plain: updaterPlain,
                 what: "The OneDrive downloaded from Microsoft (not the App Store version) installs an updater agent and an updater daemon. File syncing runs in OneDrive itself and is not touched.",
                 tradeoff: "OneDrive stays on its current version until you reinstall it; very old versions eventually stop syncing.",
                 benefit: "Fewer background jobs, and one fewer daemon running with administrator rights.",
                 confidence: .medium,
                 reinstalls: "Reinstalling OneDrive re-creates them.",
                 sources: ["https://learn.microsoft.com/sharepoint/deploy-and-configure-on-macos", attributions]),
        BGVendor(id: "bg-microsoft-teams-updater", name: "Microsoft Teams updater daemon", vendor: "Microsoft",
                 patterns: [#"^com\.microsoft\.teams\.TeamsUpdaterDaemon$"#],
                 summary: "Removes the service Teams runs with administrator rights to update itself in the background.",
                 plain: "Teams loses the service it installs, with administrator rights, so it can update itself without asking for a password.",
                 what: "Teams installs a LaunchDaemon (com.microsoft.teams.TeamsUpdaterDaemon) that runs with administrator rights to install its updates.",
                 tradeoff: "Teams stops updating itself; Microsoft blocks sign-in on very old versions.",
                 benefit: "One fewer service running with administrator rights; Teams itself works as before.",
                 confidence: .medium,
                 reinstalls: "The next Teams install or update re-creates it.",
                 sources: ["https://community.jamf.com/t5/jamf-pro/preventing-ms-teams-from-autoupdating/td-p/301185", attributions]),

        // Adobe
        BGVendor(id: "bg-adobe-creative-cloud", name: "Adobe Creative Cloud at login", vendor: "Adobe",
                 patterns: [#"^com\.adobe\.AdobeCreativeCloud$"#, #"^com\.adobe\.ccxprocess$"#, #"^com\.adobe\.AAM\.(Updater|Scheduler)"#],
                 summary: "The Creative Cloud app and its sync process no longer open at every login.",
                 plain: "The Creative Cloud desktop app and its background sync process no longer open every time you log in.",
                 what: "com.adobe.AdobeCreativeCloud opens the Creative Cloud app at login and com.adobe.ccxprocess starts CCXProcess, a Node.js process for Libraries and templates. com.adobe.AAM.* are older Application Manager update jobs.",
                 tradeoff: "Adobe Fonts, Libraries and Creative Cloud file sync stop until you open Creative Cloud, and app updates wait until then.",
                 benefit: "One app and one Node.js process fewer at login until you open Creative Cloud.",
                 audience: [.creator],
                 inAppAlternative: "Creative Cloud > Settings > General > \"Launch Creative Cloud at login\" is Adobe's own switch for the app.",
                 reinstalls: "Creative Cloud re-installs these with its next update.",
                 sources: ["https://community.adobe.com/t5/download-install-discussions/do-i-need-adobe-launch-agents-and-daemons/m-p/10990582", attributions]),
        BGVendor(id: "bg-adobe-genuine", name: "Adobe Genuine Service", vendor: "Adobe",
                 patterns: [#"^com\.adobe\.agsservice$"#, #"^com\.adobe\.GC\."#, #"^Adobe_Genuine_Software_Integrity_Service$"#, #"^com\.adobe\.AdobeGenuine"#],
                 summary: "Adobe's background license checks (AGS and the GC agents) stop running.",
                 plain: "Adobe's background service that checks whether installed Adobe apps are genuine no longer runs.",
                 what: "Adobe Genuine Service (com.adobe.agsservice and Adobe_Genuine_Software_Integrity_Service, both run as administrator) and the com.adobe.GC.* agents periodically validate installed Adobe apps.",
                 tradeoff: "No effect on licensed apps has been reported; Adobe may re-install the service with an app update.",
                 benefit: "Fewer periodic checks, and one fewer service running with administrator rights.",
                 confidence: .medium, audience: [.creator],
                 reinstalls: "Adobe app updates usually re-install it.",
                 sources: ["https://community.adobe.com/questions-617/do-i-need-adobe-launch-agents-and-daemons-451482", attributions]),
        BGVendor(id: "bg-adobe-acrobat-updater", name: "Adobe Acrobat and Reader updater", vendor: "Adobe",
                 patterns: [#"^com\.adobe\.ARMDC"#, #"^com\.adobe\.ARMDCHelper\."#],
                 summary: "Acrobat and Reader no longer install updates in the background.",
                 plain: "Adobe's updater for Acrobat and Acrobat Reader no longer runs in the background.",
                 what: "Adobe Reader Manager installs com.adobe.ARMDC.Communicator and com.adobe.ARMDC.SMJobBlessHelper (helpers with administrator rights) and an ARMDCHelper agent, which download and install Acrobat updates.",
                 tradeoff: "Acrobat and Reader stop receiving security fixes automatically. PDF readers are a common attack target, so use Help > Check for Updates regularly.",
                 benefit: "Fewer background jobs, and no Adobe helper running with administrator rights.",
                 risk: .medium, confidence: .medium,
                 reinstalls: "Acrobat re-installs it with its next update.",
                 sources: ["https://community.adobe.com/questions-617/do-i-need-adobe-launch-agents-and-daemons-451482", attributions]),
        BGVendor(id: "bg-adobe-elements", name: "Adobe Elements Auto Creations and updater", vendor: "Adobe",
                 patterns: [#"^com\.adobe\.ElementsAutoCreator-"#, #"^com\.adobe\.ElementsAutoUpdate-"#, #"^com\.adobe\.eus[0-9]+\."#],
                 summary: "Elements stops analyzing your photos at login and checking for updates in the background.",
                 plain: "Photoshop and Premiere Elements stop analyzing your photo catalog in the background and checking for updates at login.",
                 what: "Elements installs Elements Auto Creations (com.adobe.ElementsAutoCreator-*), which starts at login and works through the Organizer catalog to suggest slideshows and collages, and an Elements Update Service.",
                 tradeoff: "No Auto Creations suggestions in the Organizer, and Elements updates only from Help > Updates.",
                 benefit: "One fewer app at login, and no photo analysis while Elements is closed.",
                 confidence: .medium, audience: [.creator],
                 inAppAlternative: "Elements Organizer > Preferences > Auto Creations can turn the feature off.",
                 sources: [attributions]),

        // Meetings and remote access
        BGVendor(id: "zoom-updater-agents", name: "Zoom updater agents", vendor: "Zoom",
                 patterns: [#"^us\.zoom\.updater$"#, #"^us\.zoom\.updater\.login\.check$"#],
                 summary: "Zoom stops checking for updates at login and twice a day. Update from the app instead.",
                 plain: "Zoom no longer checks for updates at every login and twice a day in the background.",
                 what: "us.zoom.updater runs ZoomUpdater at 00:40 and 12:40, and us.zoom.updater.login.check runs it at every login.",
                 tradeoff: "Zoom updates only when you choose Check for Updates in the app, which asks for an administrator password.",
                 benefit: "No update check at login and no scheduled update runs.",
                 recommended: false,
                 inAppAlternative: "Zoom > Settings > General > uncheck \"Automatically keep Zoom desktop client up to date\", otherwise Zoom may re-install them.",
                 reinstalls: "Zoom re-installs them when you accept an in-app update.",
                 sources: ["https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060716"]),
        BGVendor(id: "zoom-daemon", name: "Zoom privileged helper", vendor: "Zoom",
                 patterns: [#"^us\.zoom\.ZoomDaemon$"#],
                 summary: "Removes the helper Zoom keeps installed, with root rights, for updates. Less to attack, not less CPU use.",
                 plain: "Zoom loses the helper it keeps installed, with root rights, so it can update itself without asking for a password.",
                 what: "us.zoom.ZoomDaemon is an on-demand service running as root. It was the route of a local privilege-escalation bug fixed in Zoom 5.11.5 (2022).",
                 tradeoff: "In-app updates fail with error 10008 until Zoom re-installs the helper, which asks for an administrator password.",
                 benefit: "One fewer service running as root; meetings work as before.",
                 risk: .medium,
                 reinstalls: "Zoom re-installs it, with a password prompt, on its next in-app update.",
                 sources: ["https://community.zoom.com/t5/Zoom-Meetings/can-t-update-zoom-for-mac-error-code-10008/m-p/64299", attributions]),
        BGVendor(id: "bg-gotomeeting", name: "GoToMeeting updater and uploader", vendor: "GoTo",
                 patterns: [#"^com\.logmein\.GoToMeeting\.(G2MUpdate|G2MAIRUploader)$"#],
                 summary: "GoToMeeting stops updating itself and uploading its reports in the background.",
                 plain: updaterPlain,
                 what: "GoToMeeting installs G2MUpdate, which updates the app in the background, and G2MAIRUploader, which uploads GoToMeeting's own logs and reports.",
                 tradeoff: "GoToMeeting updates when you start it instead of in the background.",
                 benefit: "Two background jobs fewer; meetings work as before.",
                 confidence: .medium,
                 sources: [attributions]),
        BGVendor(id: "bg-teamviewer", name: "TeamViewer background service", vendor: "TeamViewer",
                 patterns: [#"^com\.teamviewer\."#],
                 summary: "Removes the always-on service that lets others connect to this Mac with TeamViewer.",
                 plain: "TeamViewer's background service no longer runs, so this Mac can no longer be reached remotely through TeamViewer.",
                 what: "TeamViewer installs a service with administrator rights (com.teamviewer.service), a helper and per-user agents so the Mac accepts incoming sessions at any time.",
                 tradeoff: "Nobody can connect to this Mac with TeamViewer, and the TeamViewer app may not work until you restore this. Leave it on if you rely on unattended access.",
                 benefit: "An always-on remote-access service no longer runs.",
                 risk: .medium, confidence: .medium,
                 reinstalls: "Reinstalling or updating TeamViewer re-creates them.",
                 sources: [attributions]),
        BGVendor(id: "bg-citrix-updater", name: "Citrix Workspace updater", vendor: "Citrix",
                 patterns: [#"^com\.citrix\.ctxworkspaceupdater$"#],
                 summary: "Citrix Workspace stops updating itself in the background; the app keeps working.",
                 plain: updaterPlain,
                 what: "com.citrix.ctxworkspaceupdater downloads and installs Citrix Workspace updates. If your employer manages this Mac, check with them first.",
                 tradeoff: "Citrix Workspace stays on its current version, and some company servers require a recent one.",
                 benefit: "One fewer background job; Citrix Workspace works as before.",
                 confidence: .medium,
                 sources: [attributions]),

        // Storage, cloud and utilities
        BGVendor(id: "bg-dropbox-updater", name: "Dropbox updater", vendor: "Dropbox",
                 patterns: [#"^com\.dropbox\.DropboxMacUpdate"#],
                 summary: "Dropbox's separate updater stops running in the background. Syncing is unaffected.",
                 plain: updaterPlain,
                 what: "com.dropbox.DropboxMacUpdate.agent checks for new Dropbox versions. File syncing runs in Dropbox itself and is not touched.",
                 tradeoff: "Dropbox updates when it updates itself while running or when you reinstall it; very old versions are eventually forced to update.",
                 benefit: "One fewer periodic background job; syncing works as before.",
                 confidence: .medium,
                 reinstalls: "Dropbox re-creates it with its next update.",
                 sources: [attributions]),
        BGVendor(id: "bg-box-updater", name: "Box Drive updater", vendor: "Box",
                 patterns: [#"^com\.box\.desktop\.autoupdater$"#],
                 summary: "Box Drive stops updating itself in the background. Syncing is unaffected.",
                 plain: updaterPlain,
                 what: "com.box.desktop.autoupdater checks for and installs new Box Drive versions. The Box Drive app and its sync are separate jobs.",
                 tradeoff: "Box Drive stays on its current version until you update it; old versions eventually lose support.",
                 benefit: "One fewer background job; syncing works as before.",
                 confidence: .medium,
                 sources: [attributions]),
        BGVendor(id: "bg-setapp-updater", name: "Setapp updater", vendor: "Setapp",
                 patterns: [#"^com\.setapp\.DesktopClient\.SetappUpdater$"#],
                 summary: "The Setapp client stops updating itself in the background. Setapp's other agents are left alone.",
                 plain: updaterPlain,
                 what: "com.setapp.DesktopClient.SetappUpdater updates the Setapp client. Setapp's agent, which manages apps installed through it, is not touched.",
                 tradeoff: "The Setapp client updates when you open Setapp.",
                 benefit: "One fewer background job; apps installed through Setapp are not affected.",
                 confidence: .medium,
                 sources: [attributions]),
        BGVendor(id: "bg-cleanmymac", name: "CleanMyMac menu agent and updater", vendor: "MacPaw",
                 patterns: [#"^com\.macpaw\.CleanMyMac[A-Za-z0-9]*\.(Agent|Updater)$"#],
                 summary: "CleanMyMac's always-running menu bar monitor and its updater stop.",
                 plain: "CleanMyMac's menu bar monitor, which runs all the time, and its background updater stop.",
                 what: "CleanMyMac keeps an agent running for its menu bar monitor and alerts (memory, disk space, Trash, malware notifications), plus an updater job.",
                 tradeoff: "No CleanMyMac menu bar monitor or alerts, and the app updates when you open it.",
                 benefit: "One fewer process running all the time.",
                 confidence: .medium,
                 inAppAlternative: "CleanMyMac's settings can turn the menu bar app off.",
                 sources: [attributions]),
        BGVendor(id: "bg-java-updater", name: "Oracle Java updater", vendor: "Oracle",
                 patterns: [#"^com\.oracle\.java\.Java-Updater$"#, #"^com\.oracle\.java\.Helper-Tool$"#, #"^com\.oracle\.java\.JavaUpdateHelper$"#],
                 summary: "The Java 8 updater agent and helper tool that come with Oracle's Java installer stop running.",
                 plain: "The updater that Oracle's Java 8 installer adds, which checks for Java updates in the background, no longer runs.",
                 what: "The Oracle Java (JRE 8) installer adds a Java Updater agent and a helper tool with administrator rights. Most Macs no longer need Oracle's Java at all.",
                 tradeoff: "Java stops prompting for updates, and an outdated Java is a security risk. If no app needs Java, uninstall it instead.",
                 benefit: "Fewer background jobs, and one fewer helper with administrator rights.",
                 confidence: .medium,
                 inAppAlternative: "System Settings > Java > Update > turn off \"Check for Updates Automatically\". These plists are often symbolic links into the Java plug-in, which Keel does not move.",
                 sources: ["https://community.jamf.com/t5/jamf-pro/java-7-preferences/m-p/125952", "https://bugs.openjdk.org/browse/JDK-8029309", attributions]),
        BGVendor(id: "bg-gpgtools-updater", name: "GPG Suite updater", vendor: "GPGTools",
                 patterns: [#"^org\.gpgtools\.updater$"#],
                 summary: "GPG Suite stops checking for updates in the background. Encryption keeps working.",
                 plain: updaterPlain,
                 what: "org.gpgtools.updater checks for new GPG Suite releases. The gpg-agent and Mail plug-in jobs are separate.",
                 tradeoff: "No update prompts for an encryption tool; check for GPG Suite updates yourself.",
                 benefit: "One fewer background job; encryption and signing work as before.",
                 confidence: .medium, audience: [.developer, .privacy],
                 sources: [attributions]),

        // Developer
        BGVendor(id: "bg-docker-vmnetd", name: "Docker privileged helper (vmnetd)", vendor: "Docker",
                 patterns: [#"^com\.docker\.vmnetd$"#, #"^com\.docker\.socket$"#],
                 summary: "Removes a root helper left by older Docker Desktop installs; current versions do not need it by default.",
                 plain: "A Docker helper that runs as root, and that current Docker Desktop versions no longer need by default, is removed.",
                 what: "Docker Desktop 4.88 and earlier installed com.docker.vmnetd (and com.docker.socket) for container ports below 1024 and the /var/run/docker.sock link. Since 4.89 Docker runs without them unless \"Allow privileged port mapping\" or the default Docker socket is turned on in Settings > Advanced, but upgrades leave them in place.",
                 tradeoff: "Container ports below 1024 and /var/run/docker.sock stop working; Docker offers to re-install the helper, with a password prompt, if you turn those settings on.",
                 benefit: "One fewer service running as root; containers run as before unless you use the settings above.",
                 audience: [.developer],
                 sources: ["https://docs.docker.com/desktop/setup/install/mac-permission-requirements/", attributions]),

        // Peripherals
        BGVendor(id: "bg-logitech-updaters", name: "Logitech updaters", vendor: "Logitech",
                 patterns: [#"^com\.logi\.(optionsplus|ghub)\.updater"#, #"^com\.logitech\..*updater"#],
                 summary: "Logi Options+ and G HUB stop checking for app and firmware updates in the background.",
                 plain: updaterPlain,
                 what: "Logitech installs updater jobs next to Logi Options+ (com.logi.optionsplus.updater) and G HUB (com.logi.ghub.updater, a daemon with administrator rights). They check for app and device firmware updates.",
                 tradeoff: "Logitech apps and device firmware update only when you check from inside the app.",
                 benefit: "Fewer background jobs; your mouse and keyboard settings keep working.",
                 audience: [.everyone, .gamer],
                 reinstalls: "Reinstalling or updating the Logitech app re-creates them.",
                 sources: ["https://support.logi.com/hc/en-ca/articles/19370070128407-Logitech-G-HUB-will-not-install-on-Mac", attributions]),
        BGVendor(id: "bg-logitech-login", name: "Logitech Options+ and G HUB at login", vendor: "Logitech",
                 patterns: [#"^com\.logi\.ghub$"#, #"^com\.logi\.optionsplus$"#, #"^com\.logi\.cp-dev-mgr$"#, #"^com\.logitech\.manager\.daemon$"#],
                 domains: agentsOnly,
                 summary: "The Logitech process that applies button, gesture and lighting settings no longer starts at login.",
                 plain: "The Logitech background process that applies your mouse and keyboard customizations no longer starts at login.",
                 what: "These agents (com.logi.cp-dev-mgr for Options+, com.logi.ghub for G HUB, com.logitech.manager.daemon for the older Logi Options) start Logitech's background process at every login.",
                 tradeoff: "Custom buttons, gestures, profiles and lighting stop working until you open the Logitech app. Keep this if you use them daily.",
                 benefit: "One fewer process running all the time when you do not use the customizations.",
                 audience: [.everyone, .gamer],
                 reinstalls: "App updates re-create it.",
                 sources: ["https://support.logi.com/hc/en-ca/articles/19370070128407-Logitech-G-HUB-will-not-install-on-Mac", attributions]),
        BGVendor(id: "steelseries-agent", name: "SteelSeries GG at login", vendor: "SteelSeries",
                 patterns: [#"^com\.steelseries\."#],
                 domains: agentsOnly,
                 summary: "The SteelSeries GG app no longer opens by itself at login.",
                 plain: "The SteelSeries GG app no longer opens by itself at every login.",
                 what: "/Library/LaunchAgents/com.steelseries.SSENext.plist starts SteelSeries GG, a full Electron app, at login.",
                 tradeoff: "Settings that GG applies (EQ, lighting, macros) are not applied until you open GG. Settings stored on the device keep working.",
                 benefit: "One fewer Electron app at login; apps of this kind usually run several processes and use hundreds of MB.",
                 audience: [.gamer],
                 inAppAlternative: "GG Settings > turn off \"Launch at startup\".",
                 reinstalls: "GG updates may re-create it.",
                 sources: ["man launchctl (bootout, disable)", attributions]),
        BGVendor(id: "bg-razer", name: "Razer Synapse agents", vendor: "Razer",
                 patterns: [#"^com\.razer\."#, #"^com\.razerzone\."#],
                 domains: agentsOnly,
                 summary: "Razer's updater and device engine no longer start at login.",
                 plain: "Razer Synapse's updater and device engine no longer start at every login.",
                 what: "Razer Synapse for Mac installs com.razer.rzupdater, reported to use a full CPU core while offline, and com.razerzone.rzdeviceengine. Razer no longer develops Synapse for Mac.",
                 tradeoff: "Razer device customizations stop until you open Synapse, and Synapse no longer updates itself.",
                 benefit: "Fewer processes at login, and no updater spinning the CPU while offline.",
                 audience: [.gamer],
                 sources: ["https://macpaw.com/how-to/uninstall-razer-synapse-mac", "https://www.igorkromin.net/index.php/2017/02/01/stopping-the-rzupdater-from-launching-and-consuming-high-cpu-percentage", attributions]),
        BGVendor(id: "bg-corsair", name: "Corsair iCUE agents", vendor: "Corsair",
                 patterns: [#"^com\.corsair\."#],
                 domains: agentsOnly,
                 summary: "Corsair iCUE's background agents no longer start at login.",
                 plain: "Corsair iCUE's background agents no longer start at every login.",
                 what: "Corsair iCUE installs launch agents that start its service at login to apply lighting and device profiles. The label names were not confirmed from a primary source; Keel matches any com.corsair.* agent.",
                 tradeoff: "Lighting and device profiles that need iCUE are not applied until you open it.",
                 benefit: "One fewer process started at login.",
                 confidence: .low, audience: [.gamer],
                 sources: ["https://discussions.apple.com/thread/254539555"]),
        BGVendor(id: "bg-wacom-updater", name: "Wacom driver update helper", vendor: "Wacom",
                 patterns: [#"^com\.wacom\.UpdateHelper$"#],
                 summary: "Wacom stops checking for driver updates in the background. The tablet driver is untouched.",
                 plain: updaterPlain,
                 what: "com.wacom.UpdateHelper looks for new Wacom driver versions. The tablet driver, IOManager and data-store jobs are separate and keep running.",
                 tradeoff: "The driver updates only through Wacom Center or a manual download.",
                 benefit: "One fewer background job; the tablet works as before.",
                 confidence: .medium, audience: [.creator],
                 sources: [attributions]),
        BGVendor(id: "bg-plantronics-updater", name: "Poly (Plantronics) Hub update service", vendor: "Plantronics",
                 patterns: [#"^com\.PlantronicsUpdateService$"#],
                 summary: "Plantronics Hub stops checking for app and headset firmware updates in the background.",
                 plain: updaterPlain,
                 what: "com.PlantronicsUpdateService checks for Plantronics Hub and headset firmware updates.",
                 tradeoff: "Hub and headset firmware update only when you check in Plantronics Hub.",
                 benefit: "One fewer background job; the headset works as before.",
                 confidence: .medium,
                 sources: [attributions]),
        BGVendor(id: "bg-epson-scan-agents", name: "Epson scanner button agents", vendor: "Epson",
                 patterns: [#"^com\.epson\.(eventmanager\.agent|scannermonitor|esua\.launcher)$"#],
                 domains: agentsOnly,
                 summary: "Epson's agents that wait for the scanner's Scan button no longer start at login.",
                 plain: "The Epson agents that wait for you to press the Scan button on an Epson scanner or printer no longer start at login.",
                 what: "Epson Event Manager starts agents at login (com.epson.eventmanager.agent, com.epson.scannermonitor) that react to the device's Scan and Start buttons.",
                 tradeoff: "Pressing the button on the device no longer opens Epson's software. Scanning from Epson Scan, Image Capture or Preview still works.",
                 benefit: "Fewer processes running all the time if you never use the device buttons.",
                 confidence: .medium,
                 sources: [attributions]),
        BGVendor(id: "bg-blackmagic-updater", name: "Blackmagic Desktop Video updater", vendor: "Blackmagic Design",
                 patterns: [#"^com\.blackmagic-design\.DesktopVideoUpdater$"#],
                 summary: "Desktop Video stops checking for driver and firmware updates in the background.",
                 plain: updaterPlain,
                 what: "com.blackmagic-design.DesktopVideoUpdater checks for new Desktop Video software and card firmware. The driver and helper jobs are separate and keep running.",
                 tradeoff: "Desktop Video and card firmware update only when you run the installer or Desktop Video Setup.",
                 benefit: "One fewer background job; capture and playback work as before.",
                 confidence: .medium, audience: [.creator],
                 sources: [attributions]),
        BGVendor(id: "bg-arturia-agent", name: "Arturia Software Center agent", vendor: "Arturia",
                 patterns: [#"^com\.Arturia\.ArturiaSoftwareCenterAgent$"#],
                 summary: "Arturia Software Center's background agent no longer runs; installed instruments keep working.",
                 plain: "Arturia Software Center's agent, which stays in the background for update and license checks, no longer runs.",
                 what: "com.Arturia.ArturiaSoftwareCenterAgent keeps a helper running for Arturia Software Center. What exactly it does in the background is not documented by Arturia.",
                 tradeoff: "Update notices and license sync wait until you open Arturia Software Center.",
                 benefit: "One fewer process running all the time.",
                 confidence: .low, audience: [.creator],
                 sources: [attributions]),

        // Games and media
        BGVendor(id: "bg-epic-games", name: "Epic Games Launcher agents", vendor: "Epic Games",
                 patterns: [#"^com\.epicgames\."#],
                 domains: agentsOnly,
                 summary: "The Epic Games Launcher no longer starts by itself at login.",
                 plain: "The Epic Games Launcher no longer starts by itself at login.",
                 what: "The Epic Games Launcher installs a launch agent (com.epicgames.launcher).",
                 tradeoff: "The launcher does not update games in the background; open it when you want to play.",
                 benefit: "One fewer app at login.",
                 confidence: .medium, audience: [.gamer],
                 sources: [attributions]),
        BGVendor(id: "bg-steam", name: "Steam helper agents", vendor: "Valve",
                 patterns: [#"^com\.valvesoftware\."#],
                 domains: agentsOnly,
                 summary: "Steam's login-time helpers (steamclean) no longer run at login.",
                 plain: "Steam's clean-up helper no longer runs every time you log in.",
                 what: "Steam installs ~/Library/LaunchAgents/com.valvesoftware.steamclean.plist, which runs at login, and sometimes com.valvesoftware.steam.ipctool. Deleting Steam often leaves them behind.",
                 tradeoff: "Steam does its clean-up when you open it instead.",
                 benefit: "One fewer job at login.",
                 confidence: .medium, audience: [.gamer],
                 sources: ["https://steamcommunity.com/discussions/forum/2/2299597907722405816", attributions]),
        BGVendor(id: "bg-ea-origin", name: "EA Origin helpers", vendor: "Electronic Arts",
                 patterns: [#"^com\.ea\.origin\."#],
                 summary: "Removes helpers from EA's Origin launcher, which EA has replaced with the EA app.",
                 plain: "Background helpers from EA's Origin launcher are removed.",
                 what: "com.ea.origin.ESHelper and com.ea.origin.WebHelper belong to Origin. EA has moved to the EA app, so on most Macs these are leftovers.",
                 tradeoff: "If you still use Origin, it may ask to re-install its helper.",
                 benefit: "Fewer leftover background items from a launcher you probably no longer use.",
                 confidence: .medium, audience: [.gamer],
                 sources: [attributions]),
        BGVendor(id: "bg-spotify", name: "Spotify launch agents", vendor: "Spotify",
                 patterns: [#"^com\.spotify\."#],
                 domains: agentsOnly,
                 summary: "Removes leftover Spotify helper agents such as the retired web helper.",
                 plain: "Spotify helper agents that current versions of Spotify no longer use are removed.",
                 what: "Current Spotify starts at login through Login Items, not a plist. A com.spotify.* plist here is usually the retired SpotifyWebHelper or another leftover.",
                 tradeoff: "Nothing noticeable with current Spotify versions.",
                 benefit: "One fewer job at login.",
                 confidence: .medium),
        BGVendor(id: "bluestacks-daemon", name: "BlueStacks clean-up daemon", vendor: "BlueStacks (now.gg)",
                 patterns: [#"^com\.now\.gg\.BlueStacks\.cleanup$"#],
                 summary: "Removes a BlueStacks job that runs as root and watches /Applications/BlueStacks.app.",
                 plain: "Removes a BlueStacks clean-up job that waits for an app folder which, on most Macs, does not exist.",
                 what: "com.now.gg.BlueStacks.cleanup runs as root when /Applications/BlueStacks.app changes. Newer BlueStacks versions install BlueStacksMIM.app instead, so the watched path is often missing and the job never runs.",
                 tradeoff: "If BlueStacks.app is installed, its clean-up after an uninstall does not run.",
                 benefit: "One fewer root job, and the \"now.gg, Inc.\" row leaves Login Items & Extensions.",
                 risk: .safe, audience: [.gamer],
                 deadWhenWatchPathsMissing: true,
                 sources: ["man launchd.plist (WatchPaths, Program)", attributions]),
    ]
}

// MARK: - Catalog

private enum BGCatalog {
    static let orphanID = "bg-orphaned-launch-items"

    static func build() -> [Tweak] {
        let scanned = BGScan.scan()
        var owned = Set<String>()   // plist paths owned by a vendor card
        var tweaks: [Tweak] = []

        for v in BGVendors.table {
            let found = scanned.filter { p in !owned.contains(p.path) && v.matches(p) }
            found.forEach { owned.insert($0.path) }
            let movable = found.filter { $0.isRegularFile && ($0.domain == .user || BGScan.validLabel($0.label)) }
            var items = movable.map { LaunchdItem(label: $0.label, plistPath: $0.path, domain: $0.domain) }
            for r in BGScan.recordedItems(v.id) where !items.contains(where: { $0.plistPath == r.plistPath }) { items.append(r) }
            if !items.isEmpty {
                tweaks.append(vendorTweak(v, found: found, items: items))
            } else if !found.isEmpty {
                tweaks.append(vendorManualTweak(v, found: found))
            }
        }

        if let t = orphanTweak(scanned.filter { !owned.contains($0.path) }) { tweaks.append(t) }
        tweaks.append(reviewTweak())
        tweaks.append(reopenWindowsTweak())
        tweaks.append(spotifyLoginTweak())
        return tweaks
    }

    private static func foundList(_ found: [BGPlist]) -> String {
        "On this Mac: " + found.map { "\($0.label) in \(BGScan.domainName($0.domain)) (\(BGScan.describe($0)))" }.joined(separator: "; ") + "."
    }

    private static func mechanismText(_ items: [LaunchdItem]) -> String {
        "Keel stops each job, moves its plist into Keel's backups and marks the label disabled so a copy put back by the vendor does not load; restoring reverses this"
            + (items.contains { $0.domain != .user } ? ", and items in /Library need an administrator password." : ".")
    }

    static func vendorTweak(_ v: BGVendor, found: [BGPlist], items: [LaunchdItem]) -> Tweak {
        let dead = !found.isEmpty && found.allSatisfy { p in
            BGScan.isOrphan(p) || (v.deadWhenWatchPathsMissing && !p.watchPaths.isEmpty
                && p.watchPaths.allSatisfy { !BGScan.isUncheckable($0) && BGScan.isMissing($0) })
        }
        var parts = [v.plain, v.what]
        if dead { parts.append("On this Mac the program or folder these jobs depend on no longer exists, so they do nothing.") }
        parts.append(mechanismText(items))
        if let alt = v.inAppAlternative { parts.append("Alternative: \(alt)") }
        if let r = v.reinstalls { parts.append(r) }
        var text = parts.joined(separator: " ")
        text += "\n\n" + (found.isEmpty ? "Keel has already moved these plists; restoring puts them back." : foundList(found))
        let skipped = found.filter { p in !items.contains { $0.plistPath == p.path } }
        if !skipped.isEmpty { text += " Not moved (symbolic link or a label launchctl rejects): " + skipped.map(\.label).joined(separator: ", ") + "." }
        return Tweak(id: v.id, name: v.name, category: .background,
                     summary: dead ? "Left behind by an uninstall: the program or folder this job uses is gone." : v.summary,
                     explanation: text,
                     risk: dead ? .safe : v.risk, impact: .low,
                     recommended: v.recommended || dead,
                     mechanism: .launchd(items),
                     sources: v.sources,
                     confidence: v.confidence,
                     expectedBenefit: v.benefit,
                     tradeoff: dead ? "Nothing noticeable: the job has nothing to run." : v.tradeoff,
                     audience: v.audience)
    }

    static func vendorManualTweak(_ v: BGVendor, found: [BGPlist]) -> Tweak {
        let paths = found.map(\.path)
        return Tweak(id: v.id, name: v.name, category: .background, summary: v.summary,
                     explanation: "\(v.plain) \(v.what) Keel cannot move these plists (they are symbolic links or have labels launchctl rejects), so the change has to be made in the app or in System Settings.\n\n" + foundList(found),
                     risk: v.risk, impact: .low, recommended: false,
                     mechanism: .manual(ManualMechanism(
                        detect: {
                            let present = paths.filter { !BGScan.isMissing($0) }
                            return Detection(state: present.isEmpty ? .on : .off, values: present.map { (($0 as NSString).lastPathComponent, "installed") },
                                             note: present.isEmpty ? "No longer installed" : nil)
                        },
                        settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                        instructions: v.inAppAlternative ?? "Turn off \(v.vendor) in System Settings > General > Login Items & Extensions, or turn off its background updates in the app")),
                     sources: v.sources, confidence: v.confidence, expectedBenefit: v.benefit, tradeoff: v.tradeoff,
                     audience: v.audience)
    }

    static func orphanTweak(_ candidates: [BGPlist]) -> Tweak? {
        let orphans = candidates.filter { p in
            !BGScan.isHomebrew(p.label) && p.isRegularFile && (p.domain == .user || BGScan.validLabel(p.label)) && BGScan.isOrphan(p)
        }
        var items = orphans.map { LaunchdItem(label: $0.label, plistPath: $0.path, domain: $0.domain) }
        for r in BGScan.recordedItems(orphanID) where !items.contains(where: { $0.plistPath == r.plistPath }) { items.append(r) }
        guard !items.isEmpty else { return nil }
        var text = "Background jobs left behind when an app was deleted are removed. Each one is a LaunchAgent or LaunchDaemon (a plist that tells macOS to start a program) whose program, named by Program or ProgramArguments[0], no longer exists. macOS still loads these plists; jobs set to start at login or stay running fail and are retried, which leaves repeated errors in the system log. Keel never judges jobs that run a shell or interpreter, Homebrew services, Apple's or Keel's own jobs, or programs on external volumes, in other users' folders or in privacy-protected folders. Plists are moved into Keel's backups, not deleted\(items.contains { $0.domain != .user } ? ", and items in /Library need an administrator password" : "")."
        if !orphans.isEmpty { text += "\n\nOn this Mac: " + orphans.map { "\($0.label) (\(BGScan.domainName($0.domain))) runs \($0.program ?? "?"), which is missing" }.joined(separator: "; ") + "." }
        return Tweak(id: orphanID, name: "Launch items whose app is gone", category: .background,
                     summary: orphans.isEmpty ? "Restores launchd jobs Keel removed because their program no longer existed."
                                              : "\(orphans.count) background job\(orphans.count == 1 ? "" : "s") still point\(orphans.count == 1 ? "s" : "") at a program that no longer exists.",
                     explanation: text, risk: .safe, impact: .low, recommended: true,
                     mechanism: .launchd(items),
                     sources: ["man launchd.plist (Program, ProgramArguments)"],
                     confidence: .high,
                     expectedBenefit: "No failed launch attempts at login, and the leftover entries leave Login Items & Extensions after macOS next tidies that list.",
                     tradeoff: "Nothing noticeable: the jobs have nothing to run. Reinstalling the app re-creates its plist.",
                     audience: [.everyone])
    }

    static func reviewTweak() -> Tweak {
        Tweak(id: "login-items-review", name: "Review Login Items & Extensions", category: .background,
              summary: "Lists the third-party jobs macOS starts in the background and which ones Keel has a card for.",
              explanation: "Keel lists every third-party program macOS starts in the background, so you can see what runs without you opening it. Keel reads ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons and labels each item as a known updater or helper (with its own card), a job whose program is missing, a Homebrew service, or something installed on purpose. Apps that register through Login Items (SMAppService), such as Docker, Spotify or VS Code helpers, do not appear in these folders and are turned on or off in System Settings > General > Login Items & Extensions. Keel does not call sfltool, the tool that dumps that list, because it raises an administrator prompt.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: {
                    let all = BGScan.scan()
                    var vals: [(String, String)] = []
                    var flagged = 0
                    for p in all {
                        let kind: String
                        if let v = BGVendors.table.first(where: { $0.matches(p) }) { kind = "\(v.vendor): see “\(v.name)”"; flagged += 1 }
                        else if BGScan.isHomebrew(p.label) { kind = "Homebrew service (manage with brew services)" }
                        else if BGScan.isOrphan(p) { kind = "program missing: see “Launch items whose app is gone”"; flagged += 1 }
                        else { kind = "installed by you or an app; \(BGScan.describe(p))" }
                        vals.append(("\(p.label) [\(p.domain == .user ? "user agent" : p.domain == .globalAgent ? "agent for all users" : "daemon")]", kind))
                    }
                    let note = "\(all.count) third-party launchd item\(all.count == 1 ? "" : "s") on disk, \(flagged) with a Keel card. Login Items registered by apps are listed only in System Settings."
                    return Detection(state: flagged == 0 ? .on : .off, values: vals, note: note)
                },
                settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                instructions: "System Settings > General > Login Items & Extensions: remove apps under Open at Login and turn off items under Allow in the Background")),
              sources: ["https://developer.apple.com/documentation/servicemanagement/smappservice"],
              confidence: .high,
              expectedBenefit: "A list of what starts in the background, with a pointer to the card for each item Keel can turn off.",
              tradeoff: "Nothing noticeable: Keel only reads these folders.")
    }

    static func reopenWindowsTweak() -> Tweak {
        Tweak(id: "login-reopen-apps-off", name: "Don't reopen apps after a restart", category: .background,
              summary: "The restart dialog starts with \"Reopen windows when logging back in\" turned off.",
              explanation: "The restart and shut-down dialogs start with \"Reopen windows when logging back in\" turned off, so macOS does not relaunch every app that was open. loginwindow keeps the checkbox state as TALLogoutSavesState in com.apple.loginwindow and shows whatever was saved last; Keel saves \"off\" (key confirmed in the macOS 27.0 loginwindow binary). You can still select the checkbox for one restart, and macOS then remembers that choice. Apps listed under Open at Login still open.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.loginwindow", key: "TALLogoutSavesState", type: .bool, on: "false", off: nil, onAliases: ["0", "NO"])], post: .none),
              sources: ["Local check (macOS 27.0): /System/Library/CoreServices/loginwindow.app contains TALLogoutSavesState; the key is in ~/Library/Preferences/com.apple.loginwindow.plist"],
              confidence: .high,
              expectedBenefit: "After a restart only your login items open, so the Mac is ready sooner and forgotten apps stay closed.",
              tradeoff: "Open apps and windows are not restored after a restart unless you select the checkbox in the dialog.",
              audience: [.everyone])
    }

    static func spotifyLoginTweak() -> Tweak {
        let prefs = "\(BGScan.home)/Library/Application Support/Spotify/prefs"
        return Tweak(id: "bg-spotify-login", name: "Spotify at login", category: .background,
                     summary: "Spotify opens itself at every login unless this is turned off in Spotify's settings.",
                     explanation: "Spotify no longer opens by itself every time you log in. Spotify registers a login item from inside its app, so there is no plist for Keel to move. Spotify stores the choice in its prefs file as app.autostart-mode (\"off\", \"minimized\" or \"normal\"); the key name comes from Spotify community reports, not Spotify documentation. Keel only reads it; change it in Spotify > Settings > Startup and window behaviour, or remove Spotify under System Settings > General > Login Items & Extensions.",
                     risk: .safe, impact: .low, recommended: false,
                     mechanism: .manual(ManualMechanism(
                        detect: {
                            guard Permissions.canRead(prefs) else {
                                return Detection(state: .unknown, values: [("prefs", "protected by macOS; Keel needs Full Disk Access to read it")])
                            }
                            guard let text = try? String(contentsOfFile: prefs, encoding: .utf8) else {
                                return Detection(state: .unknown, values: [("prefs", "not found (Spotify has not been opened yet)")])
                            }
                            var mode: String? = nil
                            for line in text.split(separator: "\n") where line.hasPrefix("app.autostart-mode=") {
                                mode = String(line.dropFirst("app.autostart-mode=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            }
                            return Detection(state: mode == "off" ? .on : .off, values: [("app.autostart-mode", mode ?? "(not set: Spotify opens at login by default)")])
                        },
                        settingsURL: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                        instructions: "Spotify > Settings > Startup and window behaviour > Open Spotify automatically after you log into the computer: No")),
                     sources: ["https://community.spotify.com/t5/Desktop-Mac/Can-t-Prevent-Autostarting/td-p/1126020"],
                     requires: [.app(bundleID: "com.spotify.client", name: "Spotify")],
                     confidence: .medium,
                     expectedBenefit: "Spotify no longer appears after you log in.",
                     tradeoff: "Open Spotify yourself when you want it.",
                     audience: [.everyone])
    }
}
