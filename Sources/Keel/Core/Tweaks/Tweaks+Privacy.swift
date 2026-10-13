import Foundation
import AppKit
import KeelShared

// Security posture items are never offered in the weakening direction. Browser prefs are refused while the
// browser runs and never read without permission (macOS 27 protects other apps' data).

extension TweakCatalog {
    static let privacy: [Tweak] = [
        prvPersonalizedAds, prvAnalytics, prvSiriSharing, prvLookupSuggestions, prvSpotlightSuggestions, prvLocationServices,
        prvNotificationPreviews, prvTerminalSecureInput,
        prvFirewall, prvGuestAccount, prvLoginNamePassword, prvSharingAudit, prvScreenLock, prvAutoLogin, prvAccessories,
        prvFileVault, prvSIP, prvGatekeeper, prvSecurityUpdates, prvLockdownMode,
        prvChromeURLCollection, prvChromeSafeBrowsing, prvChromeMetrics,
    ]
}

// MARK: - Apple privacy switches

private extension TweakCatalog {

    static let prvPersonalizedAds = Tweak(
        id: "personalized-ads-off", name: "Apple personalized ads off", category: .privacy,
        summary: "App Store, Apple News and Stocks stop choosing ads from your account information.",
        explanation: """
        Apple stops using what it knows about your account to choose the ads you see in the App Store, Apple News and Stocks. Keel sets com.apple.AdLib allowApplePersonalizedAdvertising to false, the switch behind System Settings > Privacy & Security > Apple Advertising > Personalized Ads; the key is present in macOS 27.0.1. You still see ads in those apps, chosen without your profile. No logout is needed.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .defaults([DefaultsSetting(domain: "com.apple.AdLib", key: "allowApplePersonalizedAdvertising", type: .bool, on: "false", off: "true", onAliases: ["0", "NO"])], post: .none),
        sources: ["Local check: allowApplePersonalizedAdvertising present in the macOS 27.0.1 shared cache"],
        confidence: .high,
        expectedBenefit: "Ads in Apple's apps no longer reflect your account's interest segments.",
        tradeoff: "Those ads become less relevant to you.")

    static let prvAnalytics = Tweak(
        id: "analytics-off", name: "Mac and app analytics off", category: .privacy,
        summary: "The Mac stops sending crash and usage reports to Apple and to app developers.",
        explanation: """
        Crash and usage reports are no longer sent to Apple or to the developers of your apps. Keel sets AutoSubmit and ThirdPartyDataSubmit to false in /Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist, the same values that System Settings > Privacy & Security > Analytics & Improvements writes and the CIS benchmark checks. Writing the file needs an administrator password. The LastFullSubmission dates in the file keep changing with sharing off; that is a daily check, not an upload.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .custom(CustomMechanism(
            detect: {
                guard FileManager.default.fileExists(atPath: crashReporterPlist) else { return .na("No analytics settings file on this Mac") }
                let a = Prefs.value(crashReporterPlist, "AutoSubmit").map(Prefs.render)
                let t = Prefs.value(crashReporterPlist, "ThirdPartyDataSubmit").map(Prefs.render)
                let off = [a, t].filter { $0 == nil || $0 == "0" }.count
                return Detection(state: off == 2 ? .on : (off == 0 ? .off : .partlyOn),
                                 values: [("AutoSubmit", a ?? "(not set)"), ("ThirdPartyDataSubmit", t ?? "(not set)")])
            },
            apply: { ctx in
                let a = Prefs.value(crashReporterPlist, "AutoSubmit").map(Prefs.render) ?? ""
                let t = Prefs.value(crashReporterPlist, "ThirdPartyDataSubmit").map(Prefs.render) ?? ""
                ctx.privileged(.crashReporter(autoSubmit: false, thirdParty: false))
                return ["AutoSubmit": a, "ThirdPartyDataSubmit": t]
            },
            revert: { ctx, rec in
                // An unset original cannot be deleted through the helper; it stays false in that case.
                let a = rec["AutoSubmit"].flatMap { $0.isEmpty ? nil : $0 == "1" }
                let t = rec["ThirdPartyDataSubmit"].flatMap { $0.isEmpty ? nil : $0 == "1" }
                if a == nil && t == nil { return }
                ctx.privileged(.crashReporter(autoSubmit: a, thirdParty: t))
            },
            applyCommands: ["sudo defaults write '\(crashReporterPlist)' AutoSubmit -bool false",
                            "sudo defaults write '\(crashReporterPlist)' ThirdPartyDataSubmit -bool false"],
            revertCommands: ["sudo defaults write '\(crashReporterPlist)' AutoSubmit -bool <recorded>",
                             "sudo defaults write '\(crashReporterPlist)' ThirdPartyDataSubmit -bool <recorded>"],
            needsAdmin: true)),
        sources: ["Local check (macOS 27.0): AutoSubmit and ThirdPartyDataSubmit in /Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"],
        confidence: .high,
        expectedBenefit: "No diagnostic or usage reports leave the Mac automatically.",
        tradeoff: "Apple and app developers get no crash reports from you to fix bugs with.")

    static let prvSiriSharing = Tweak(
        id: "siri-data-sharing-optout", name: "Siri and Dictation recordings: not shared", category: .privacy,
        summary: "Apple does not keep your Siri and Dictation audio for review by staff.",
        explanation: """
        Apple no longer keeps your Siri and Dictation recordings for staff to listen to. Keel sets com.apple.assistant.support "Siri Data Sharing Opt-In Status" to 2, the opted-out value required by the DISA STIG for macOS 26; the key is present in macOS 27.0.1. Other values are undocumented, so turning this off restores the recorded value or removes the key. The same choice is in System Settings > Privacy & Security > Analytics & Improvements > Improve Siri & Dictation.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .defaults([DefaultsSetting(domain: "com.apple.assistant.support", key: "Siri Data Sharing Opt-In Status", type: .int, on: "2", off: nil)], post: .none),
        sources: ["https://www.stigviewer.com/stigs/apple_macos_26_tahoe/2026-02-11/finding/V-277135"],
        confidence: .medium,
        expectedBenefit: "Your voice requests are not stored for human grading.",
        tradeoff: "Nothing noticeable.")

    static let prvLookupSuggestions = Tweak(
        id: "lookup-suggestions-off", name: "Look Up suggestions off", category: .privacy,
        summary: "Look Up stops sending the word you clicked to Apple for web and Siri Knowledge results.",
        explanation: """
        Look Up (Force Click or three-finger tap on a word) stops fetching web and Siri Knowledge results about the word you clicked. Keel sets com.apple.lookup.shared LookupSuggestionsDisabled to true. In macOS 27.0.1 the key and domain sit next to each other in the Look Up code of the shared cache, so the pair is real, but the change in the Look Up panel was not observed, hence low confidence. Dictionary and thesaurus results keep working. Turning this item off removes the key again.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .defaults([DefaultsSetting(domain: "com.apple.lookup.shared", key: "LookupSuggestionsDisabled", type: .bool, on: "true", off: nil, onAliases: ["1", "YES"])], post: .none),
        sources: ["Local check: LookupSuggestionsDisabled next to com.apple.lookup.shared in the macOS 27.0.1 shared cache"],
        confidence: .low,
        expectedBenefit: "Words you look up stay on the Mac.",
        tradeoff: "No web or Siri Knowledge results in the Look Up panel.")

    static let prvSpotlightSuggestions = Tweak(
        id: "spotlight-suggestions", name: "Spotlight: Siri Suggestions off", category: .privacy,
        summary: "Spotlight stops sending what you type to Apple. Keel opens the setting; it cannot read it.",
        explanation: """
        With Siri Suggestions off, Spotlight no longer sends what you type to Apple to fetch web suggestions; Apple's guide says it then searches only the contents of your Mac. The old com.apple.Spotlight keys (orderedItems, MENU_WEBSEARCH) date from macOS 12. On macOS 26 and 27 the domain holds only window state, so there is nothing reliable to read or write, and Keel opens System Settings > Spotlight instead.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: { Detection(state: .unknown, values: [("detect", "no readable key on macOS 26 or 27")]) },
            settingsURL: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension",
            instructions: "System Settings > Spotlight: turn off Siri Suggestions and Show Related Content")),
        sources: ["https://support.apple.com/guide/mac-help/mchl54d95e8a/mac"],
        confidence: .medium,
        expectedBenefit: "Spotlight searches stay on the Mac.",
        tradeoff: "No web, Wikipedia or Siri suggestions in Spotlight results.")

    static let prvLocationServices = Tweak(
        id: "location-system-services", name: "Location: Significant Locations off", category: .privacy,
        summary: "The Mac stops keeping a history of places you visit. Keel opens the setting; it cannot read it.",
        explanation: """
        The Mac stops keeping a history of places you go and using your location for suggestions. The switches are in System Settings > Privacy & Security > Location Services > System Services > Details. locationd, the location service, keeps them in a root-only database with no command-line interface (Howard Oakley, 2026), so Keel cannot read them.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: { Detection(state: .unknown, values: [("detect", "locationd database is root-only")]) },
            settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            instructions: "System Settings > Privacy & Security > Location Services > System Services > Details")),
        sources: ["https://eclecticlight.co/2026/06/01/what-location-services-do-in-macos/"],
        confidence: .medium,
        expectedBenefit: "No record of places you visit is kept on the Mac.",
        tradeoff: "Fewer location-aware suggestions in Maps, Calendar and Siri.")

    static let prvNotificationPreviews = Tweak(
        id: "notification-previews-private", name: "Notification previews hidden on lock screen", category: .privacy,
        summary: "Message text stays hidden while the Mac is locked. Keel checks the setting and opens it.",
        explanation: """
        The text of messages and emails stays off the screen while the Mac is locked; banners still appear, without their content. Keel reads the global content_visibility value in com.apple.ncprefs. On macOS 27.0.1, system alerts that always show their text are stored as 3, so Keel reads 3 as Always (previews on the lock screen) and 1 or 2 as the two private options; that mapping is inferred from stored values, not documented. Keel opens System Settings > Notifications rather than writing the value, because it has not verified that the notification service applies a changed value without a restart.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .manual(ManualMechanism(
            detect: {
                let v = Prefs.value("com.apple.ncprefs", "content_visibility").map(Prefs.render)
                let label: String
                switch v { case nil: label = "(not set: When Unlocked)"; case "1": label = "1 (Never)"; case "2": label = "2 (When Unlocked)"; case "3": label = "3 (Always)"; default: label = v ?? "" }
                let state: TweakState = v == "3" ? .off : ([nil, "1", "2"].contains(v) ? .on : .unknown)
                return Detection(state: state, values: [("com.apple.ncprefs content_visibility", label)])
            },
            settingsURL: "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            instructions: "System Settings > Notifications > Show previews: When Unlocked (or Never)")),
        sources: ["https://support.apple.com/guide/mac-help/mh40583/mac", "Local check: com.apple.ncprefs on macOS 27.0.1 (global 2; system alerts 3)"],
        confidence: .medium,
        expectedBenefit: "Someone looking at your locked Mac sees who wrote, not what they wrote.",
        tradeoff: "You sign in to the Mac to read a notification's text.")

    static let prvTerminalSecureInput = Tweak(
        id: "terminal-secure-keyboard", name: "Terminal: Secure Keyboard Entry", category: .privacy,
        summary: "Other apps cannot read what you type in Terminal, including sudo and ssh passwords.",
        explanation: """
        Other apps can no longer see the keys you type while a Terminal window is in front, so a keylogger or an over-curious utility cannot capture sudo, ssh or database passwords. It is the Terminal > Secure Keyboard Entry menu item, stored as com.apple.Terminal SecureKeyboardEntry; the key is in Terminal's binary on macOS 27.0.1. It takes effect the next time Terminal opens. It covers Apple's Terminal only; iTerm2 and other terminals have their own setting.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .defaults([DefaultsSetting(domain: "com.apple.Terminal", key: "SecureKeyboardEntry", type: .bool, on: "true", off: "false", onAliases: ["1", "YES"])], post: .none),
        sources: ["https://support.apple.com/guide/terminal/trml109/mac", "Local check: strings Terminal on macOS 27.0.1 contains SecureKeyboardEntry"],
        confidence: .high,
        expectedBenefit: "Passwords typed in Terminal are out of reach of other apps.",
        tradeoff: "While Terminal is in front, text expanders and global keyboard tools cannot see your typing.",
        audience: [.developer, .privacy])
}

// MARK: - Security posture

private extension TweakCatalog {
    static let crashReporterPlist = "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
    static let socketFilter = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    static let loginWindowPrefs = "/Library/Preferences/com.apple.loginwindow"
    static let softwareUpdatePrefs = "/Library/Preferences/com.apple.SoftwareUpdate"

    static let prvFirewall = Tweak(
        id: "firewall-stealth", name: "Firewall on, stealth mode on", category: .privacy,
        summary: "Blocks unrequested incoming connections and stops the Mac answering scans. No speed cost.",
        explanation: """
        Other computers cannot connect to apps on your Mac unless you allow them, and the Mac ignores ping and probes of closed ports (stealth mode). Keel turns both on with socketfilterfw, which needs an administrator password; the firewall filters incoming connections only, so it has no effect on downloads or latency. Signed apps stay allowed, so AirDrop, AirPlay and Bonjour keep working, while apps that accept connections (dev servers, Docker, OBS) may ask once. If the firewall is already set to block all incoming connections, Keel keeps that stricter mode and only adds stealth. A configuration profile from your organization overrides this.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .custom(CustomMechanism(
            detect: {
                guard let g = await Shell.probe(socketFilter, ["--getglobalstate"]), let s = await Shell.probe(socketFilter, ["--getstealthmode"]) else { return .unknown }
                let gOn = prvFirewallGlobalLevel(g.output) > 0, sOn = prvStealthOn(s.output)
                var values = [("socketfilterfw --getglobalstate", g.output), ("socketfilterfw --getstealthmode", s.output)]
                if FileManager.default.fileExists(atPath: "/Library/Managed Preferences/com.apple.security.firewall.plist") { values.append(("profile", "managed by a configuration profile")) }
                return Detection(state: gOn && sOn ? .on : (gOn || sOn ? .partlyOn : .off), values: values)
            },
            apply: { ctx in
                let g = await Shell.probe(socketFilter, ["--getglobalstate"])?.output ?? ""
                let s = await Shell.probe(socketFilter, ["--getstealthmode"])?.output ?? ""
                let gOn = prvFirewallGlobalLevel(g) > 0, sOn = prvStealthOn(s)
                ctx.privileged(.firewall(globalOn: gOn ? nil : true, stealthOn: sOn ? nil : true))
                return ["globalstate": gOn ? "on" : "off", "stealth": sOn ? "on" : "off"]
            },
            revert: { ctx, rec in
                if rec.isEmpty { ctx.privileged(.firewall(globalOn: false, stealthOn: false)); return }
                let g: Bool? = rec["globalstate"] == "off" ? false : nil
                let s: Bool? = rec["stealth"] == "off" ? false : nil
                if g != nil || s != nil { ctx.privileged(.firewall(globalOn: g, stealthOn: s)) }
            },
            applyCommands: ["sudo \(socketFilter) --setglobalstate on   # skipped if already on or set to block all",
                            "sudo \(socketFilter) --setstealthmode on"],
            revertCommands: ["sudo \(socketFilter) --setglobalstate <recorded>", "sudo \(socketFilter) --setstealthmode <recorded>"],
            needsAdmin: true)),
        sources: ["https://support.apple.com/guide/mac-help/mh11783/mac", "https://support.apple.com/guide/mac-help/mh34041/mac"],
        confidence: .high,
        expectedBenefit: "On public networks nothing can connect to this Mac unasked, and it does not answer network scans.",
        tradeoff: "Apps that accept connections ask once to be allowed, and the Mac no longer answers ping.",
        audience: [.everyone, .privacy])

    static let prvGuestAccount = Tweak(
        id: "guest-account-off", name: "Guest user off", category: .privacy,
        summary: "Removes the Guest User from the login window.",
        explanation: """
        The Guest User disappears from the login window, so nobody can use the Mac without an account. Keel sets GuestEnabled to false in /Library/Preferences/com.apple.loginwindow, which needs an administrator password; this is the CIS benchmark remediation, and System Settings > Users & Groups > Guest User shows the same switch. Off is the default on new Macs, and an unset key reads as off. With Find My on, a guest session lets someone who finds a lost Mac go online so it can be located; leave the guest on if you rely on that.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .custom(CustomMechanism(
            detect: {
                let v = Prefs.value(loginWindowPrefs, "GuestEnabled").map(Prefs.render)
                return Detection(state: v == "1" ? .off : .on, values: [("GuestEnabled", v ?? "(not set: off)")])
            },
            apply: { ctx in
                let prev = Prefs.value(loginWindowPrefs, "GuestEnabled").map(Prefs.render) ?? ""
                ctx.privileged(.rootDefaults(domain: loginWindowPrefs, key: "GuestEnabled", value: false))
                return ["previous": prev]
            },
            revert: { ctx, rec in
                let prev = rec["previous"] ?? "1"
                ctx.privileged(.rootDefaults(domain: loginWindowPrefs, key: "GuestEnabled", value: prev.isEmpty ? nil : prev == "1"))
            },
            applyCommands: ["sudo defaults write /Library/Preferences/com.apple.loginwindow GuestEnabled -bool false"],
            revertCommands: ["sudo defaults write /Library/Preferences/com.apple.loginwindow GuestEnabled -bool <recorded>"],
            needsAdmin: true)),
        sources: ["CIS Apple macOS benchmark: Ensure Guest Account Is Disabled", "Local check: GuestEnabled in /Library/Preferences/com.apple.loginwindow on macOS 27.0.1"],
        confidence: .medium,
        expectedBenefit: "Nobody can log in to this Mac without an account of their own.",
        tradeoff: "No guest session for visitors or for someone returning a lost Mac.",
        audience: [.everyone, .privacy])

    static let prvLoginNamePassword = Tweak(
        id: "login-name-and-password", name: "Login window asks for name and password", category: .privacy,
        summary: "The login window shows empty name and password fields instead of a list of users.",
        explanation: """
        The login window asks for both a user name and a password instead of showing pictures of every account, so a passer-by does not learn who uses the Mac. Keel sets SHOWFULLNAME to true in /Library/Preferences/com.apple.loginwindow, which needs an administrator password; this is the CIS benchmark remediation, and System Settings > Users & Groups > Login Window Options shows the same choice. With FileVault on, the first screen after a restart is the FileVault sign-in screen, which still lists users; this setting applies to the login window you see after logging out.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .custom(CustomMechanism(
            detect: {
                let v = Prefs.value(loginWindowPrefs, "SHOWFULLNAME").map(Prefs.render)
                return Detection(state: v == "1" ? .on : .off, values: [("SHOWFULLNAME", v ?? "(not set: list of users)")])
            },
            apply: { ctx in
                let prev = Prefs.value(loginWindowPrefs, "SHOWFULLNAME").map(Prefs.render) ?? ""
                ctx.privileged(.rootDefaults(domain: loginWindowPrefs, key: "SHOWFULLNAME", value: true))
                return ["previous": prev]
            },
            revert: { ctx, rec in
                let prev = rec["previous"] ?? ""
                ctx.privileged(.rootDefaults(domain: loginWindowPrefs, key: "SHOWFULLNAME", value: prev.isEmpty ? nil : prev == "1"))
            },
            applyCommands: ["sudo defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool true"],
            revertCommands: ["sudo defaults delete /Library/Preferences/com.apple.loginwindow SHOWFULLNAME  # or the recorded value"],
            needsAdmin: true)),
        sources: ["CIS Apple macOS benchmark: Ensure Login Window Displays as Name and Password Is Enabled",
                  "Local check: /Library/Preferences/com.apple.loginwindow is world-readable on macOS 27.0.1"],
        confidence: .medium,
        expectedBenefit: "After you log out, the login window no longer shows account names and pictures.",
        tradeoff: "You type your account name as well as your password at that window.")

    static let prvSharingAudit = Tweak(
        id: "remote-access-audit", name: "Sharing services off when unused", category: .privacy,
        summary: "Lists the Sharing services that let other computers reach this Mac. Keel only reads them.",
        explanation: """
        Keel checks whether any service that lets other computers log in to, control, browse or use this Mac's connection is turned on. Keel reads network listeners with netstat (22 Remote Login, 5900 Screen Sharing, 3031 Remote Apple Events, 445 File Sharing, 631 Printer Sharing, ignoring listeners bound to this Mac only), checks for the ARDAgent and InternetSharing processes, and reads Media Sharing's home-sharing and public-sharing keys. Keel does not turn these off itself: Apple documents that `systemsetup -setremotelogin` needs Full Disk Access for the calling process even as root, and the others have no supported command. If you use one on purpose, such as SSH into a Mac mini, leave it on.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let r = await Shell.probe("/usr/sbin/netstat", ["-anp", "tcp"]) else { return .unknown }
                let ports = prvListeningPorts(r.stdout)
                var rows: [(String, Bool, String)] = [("Remote Login (SSH)", 22), ("Screen Sharing", 5900), ("Remote Apple Events", 3031),
                                                      ("File Sharing (SMB)", 445), ("Printer Sharing", 631)].map { ($0.0, ports.contains($0.1), "port \($0.1)") }
                rows.append(("Remote Management", await prvProcessRunning("ARDAgent"), "ARDAgent"))
                rows.append(("Internet Sharing", await prvProcessRunning("InternetSharing"), "InternetSharing"))
                let media = ["home-sharing-enabled", "public-sharing-enabled"].contains { Prefs.string("com.apple.amp.mediasharingd", $0) == "1" }
                rows.append(("Media Sharing", media, "com.apple.amp.mediasharingd"))
                let open = rows.filter(\.1)
                return Detection(state: open.isEmpty ? .on : .off,
                                 values: rows.map { ($0.0, $0.1 ? "on (\($0.2))" : "off") },
                                 note: open.isEmpty ? nil : "Turn off what you do not use in System Settings > General > Sharing.")
            },
            settingsURL: "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
            instructions: "System Settings > General > Sharing: turn off the services you do not use")),
        sources: ["https://support.apple.com/en-us/HT210595", "https://www.tenable.com/audits/items/CIS_Apple_macOS_14.0_Sonoma_v1.0.0_L1.audit:fbb885a1157c90759a28f2f515b441e3",
                  "Local check: netstat -anp tcp lists root-owned listeners without admin on macOS 27.0.1"],
        confidence: .high,
        expectedBenefit: "You see at a glance which ways into this Mac are open on the network.",
        tradeoff: "Services you turn off can no longer be reached from other computers.",
        audience: [.everyone, .privacy])

    static let prvScreenLock = Tweak(
        id: "screen-lock-immediate", name: "Password right after sleep or screen saver", category: .privacy,
        summary: "Checks that the Mac asks for a password within 5 seconds of the display sleeping. Keel opens the setting.",
        explanation: """
        The Mac should ask for your password as soon as the display sleeps or the screen saver starts, instead of leaving a grace period that anyone at your desk can use. Keel reads `sysadminctl -screenLock status`, which needs no administrator rights on macOS 27.0.1. Changing it from the command line requires typing your login password into sysadminctl, so Keel opens System Settings > Lock Screen instead. The CIS benchmark asks for 5 seconds or less.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let r = await Shell.probe("/usr/sbin/sysadminctl", ["-screenLock", "status"]) else { return .unknown }
                guard let line = r.combined.split(separator: "\n").first(where: { $0.contains("screenLock") }) else { return .unknown }
                let l = line.lowercased()
                let shown = String(line[(line.range(of: "screenLock")?.lowerBound ?? line.startIndex)...])
                var state: TweakState = .unknown
                if l.contains("immediate") { state = .on }
                else if l.contains("is off") { state = .off }
                else if let rg = l.range(of: "[0-9]+ seconds", options: .regularExpression), let n = Int(l[rg].split(separator: " ")[0]) { state = n <= 5 ? .on : .off }
                return Detection(state: state, values: [("sysadminctl -screenLock status", shown)])
            },
            settingsURL: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
            instructions: "System Settings > Lock Screen > Require password after screen saver begins or display is turned off: Immediately")),
        sources: ["CIS Apple macOS 26 benchmark: Require a password after the screen saver begins or the display turns off (5 seconds or less)",
                  "Local check: sysadminctl -screenLock status on macOS 27.0.1"],
        confidence: .high,
        expectedBenefit: "Letting the display sleep locks the Mac at once.",
        tradeoff: "You authenticate (password, Touch ID or Apple Watch) every time the display wakes.",
        audience: [.everyone, .privacy])

    static let prvAutoLogin = Tweak(
        id: "auto-login-off", name: "Automatic login off", category: .privacy,
        summary: "Checks that the Mac asks for a password at startup instead of logging in by itself.",
        explanation: """
        With automatic login, anyone who turns the Mac on lands in your account without a password; Keel checks that it is off. It reads autoLoginUser in /Library/Preferences/com.apple.loginwindow and looks for /etc/kcpassword, the stored auto-login password; both are absent when automatic login is off. FileVault prevents automatic login, so on most Macs this check already passes.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .manual(ManualMechanism(
            detect: {
                let user = Prefs.value(loginWindowPrefs, "autoLoginUser") as? String
                let kc = FileManager.default.fileExists(atPath: "/etc/kcpassword")
                return Detection(state: user == nil && !kc ? .on : .off,
                                 values: [("autoLoginUser", user ?? "(not set)"), ("/etc/kcpassword", kc ? "present" : "absent")])
            },
            settingsURL: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
            instructions: "System Settings > Users & Groups > Automatically log in as: Off")),
        sources: ["CIS Apple macOS benchmark: Ensure Automatic Login Is Disabled",
                  "Local check: strings UsersGroups.appex on macOS 27.0.1 contains autoLoginUser and kcpasswordFileExists"],
        confidence: .high,
        expectedBenefit: "Nobody reaches your files by turning the Mac on.",
        tradeoff: "You type your password at startup.",
        audience: [.everyone, .privacy])

    static let prvAccessories = Tweak(
        id: "accessories-ask", name: "Allow accessories to connect: ask", category: .privacy,
        summary: "New USB and Thunderbolt devices need your approval before they can reach your data.",
        explanation: """
        On Mac laptops with Apple silicon, a new USB or Thunderbolt device or SD card cannot exchange data until you approve it, and approval needs the Mac to be signed in and not locked; charging works either way. Apple's default is Ask for New Accessories, and Always Ask is stricter for laptops that are often plugged into public charging points. Keel found no readable key for this setting on macOS 27.0.1, so it only opens the setting.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: { Detection(state: .unknown, values: [("detect", "no readable key on macOS 27")]) },
            settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security",
            instructions: "System Settings > Privacy & Security > Accessories > Allow accessories to connect: Ask for New Accessories or Always Ask")),
        sources: ["https://support.apple.com/102282"],
        requires: [.laptop],
        confidence: .high,
        expectedBenefit: "A charging station or unknown cable cannot read from or talk to the Mac without your approval.",
        tradeoff: "With Always Ask, you approve your own docks and drives each time you connect them.",
        audience: [.laptop, .privacy])

    static let prvFileVault = Tweak(
        id: "filevault-on", name: "FileVault on", category: .privacy,
        summary: "Checks that the data on the disk can only be read with your password.",
        explanation: """
        FileVault makes the data on the Mac's disk unreadable without your login password. On Apple silicon the internal SSD is always hardware-encrypted; FileVault ties the key to your password, so a lost or stolen Mac's data stays private. It has no measurable performance cost, so turning it off is never a speed tweak. Keel reads `fdesetup status`.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let r = await Shell.probe("/usr/bin/fdesetup", ["status"]) else { return .unknown }
                let o = r.output
                let state: TweakState = o.contains("FileVault is On") ? (o.contains("progress") ? .partlyOn : .on) : (o.contains("FileVault is Off") ? .off : .unknown)
                return Detection(state: state, values: [("fdesetup status", o.split(separator: "\n").first.map(String.init) ?? o)])
            },
            settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault",
            instructions: "System Settings > Privacy & Security > FileVault > Turn On")),
        sources: ["https://support.apple.com/guide/security/volume-encryption-with-filevault-sec4c6dc1b6e/web"],
        confidence: .high,
        expectedBenefit: "Data on a lost or stolen Mac cannot be read without your password.",
        tradeoff: "If you lose both your password and the recovery key, the data cannot be recovered.",
        audience: [.everyone, .privacy])

    static let prvSIP = Tweak(
        id: "sip-on", name: "System Integrity Protection on", category: .privacy,
        summary: "Checks that System Integrity Protection is on. Turning it off never speeds anything up.",
        explanation: """
        System Integrity Protection (SIP) stops any program, even one you gave your administrator password, from changing macOS itself. Turning it off requires Permissive Security, which also disables features such as Apple Pay, and it has no performance effect. Keel reads `csrutil status`. Once off, SIP can only be turned back on from Recovery.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let r = await Shell.probe("/usr/bin/csrutil", ["status"]) else { return .unknown }
                let o = r.output.lowercased()
                let state: TweakState = o.contains("status: enabled") ? .on : (o.contains("status: disabled") ? .off : (o.contains("custom") ? .partlyOn : .unknown))
                return Detection(state: state, values: [("csrutil status", r.output.split(separator: "\n").first.map(String.init) ?? r.output)])
            },
            settingsURL: "",
            instructions: "Shut down, hold the power button until startup options appear, choose Options > Utilities > Terminal, run `csrutil enable`, then restart")),
        sources: ["https://support.apple.com/en-us/102149"],
        confidence: .high,
        expectedBenefit: "Malware cannot modify the operating system, even with your password.",
        tradeoff: "Nothing noticeable.",
        audience: [.everyone, .privacy])

    static let prvGatekeeper = Tweak(
        id: "gatekeeper-on", name: "Gatekeeper on", category: .privacy,
        summary: "Checks that apps must be signed and notarized by Apple before they open.",
        explanation: """
        Gatekeeper only lets apps open if they are signed by an identified developer and checked by Apple (notarized). Turning it off with `spctl --global-disable` lowers security and changes nothing about speed. Keel reads `spctl --status`. To turn it back on, run `sudo spctl --global-enable` or choose App Store & Known Developers in System Settings > Privacy & Security > Security.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let r = await Shell.probe("/usr/sbin/spctl", ["--status"]) else { return .unknown }
                let o = r.output
                let state: TweakState = o.contains("assessments enabled") ? .on : (o.contains("assessments disabled") ? .off : .unknown)
                return Detection(state: state, values: [("spctl --status", o)])
            },
            settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security",
            instructions: "System Settings > Privacy & Security > Security > Allow applications from: App Store & Known Developers (or `sudo spctl --global-enable`)")),
        sources: ["https://developer.apple.com/news/?id=saqachfa"],
        confidence: .high,
        expectedBenefit: "Unsigned or tampered apps are stopped before they run.",
        tradeoff: "Unsigned apps need a one-time approval in Privacy & Security.",
        audience: [.everyone, .privacy])

    static let prvSecurityUpdates = Tweak(
        id: "security-updates-on", name: "Security responses and system files: on", category: .privacy,
        summary: "Checks that urgent security fixes and malware definitions install by themselves.",
        explanation: """
        macOS should install urgent security fixes (Background Security Improvements, formerly Rapid Security Responses) and XProtect malware definitions in the background, without waiting for a full update. Keel reads CriticalUpdateInstall and ConfigDataInstall in /Library/Preferences/com.apple.SoftwareUpdate; both keys are present in macOS 27.0.1 and unset means on. They are the "Install Security Responses and system files" switch under System Settings > General > Software Update > Automatic Updates. Keel never offers to turn them off; when they are off it opens the pane. Installing full macOS updates automatically is a separate choice.
        """,
        risk: .safe, impact: .low, recommended: true,
        mechanism: .manual(ManualMechanism(
            detect: {
                let keys = ["CriticalUpdateInstall", "ConfigDataInstall"]
                let vals = keys.map { Prefs.value(softwareUpdatePrefs, $0).map(Prefs.render) }
                let off = vals.filter { $0 == "0" }.count
                var values = zip(keys, vals).map { ($0.0, $0.1 ?? "(not set: on)") }
                if FileManager.default.fileExists(atPath: "/Library/Managed Preferences/com.apple.SoftwareUpdate.plist") { values.append(("profile", "managed by a configuration profile")) }
                return Detection(state: off == 0 ? .on : (off == keys.count ? .off : .partlyOn), values: values)
            },
            settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
            instructions: "System Settings > General > Software Update > Automatic Updates (i): turn on Install Security Responses and system files")),
        sources: ["https://support.apple.com/en-us/102657", "Local check: CriticalUpdateInstall and ConfigDataInstall in the macOS 27.0.1 shared cache and SoftwareUpdate plist"],
        confidence: .high,
        expectedBenefit: "Malware definitions and urgent fixes arrive within hours instead of with the next macOS release.",
        tradeoff: "An urgent fix can occasionally ask for a restart.",
        audience: [.everyone, .privacy])

    static let prvLockdownMode = Tweak(
        id: "lockdown-mode-status", name: "Lockdown Mode", category: .privacy,
        summary: "Shows whether Lockdown Mode is on. It is meant for people at risk of targeted attacks.",
        explanation: """
        Lockdown Mode is an optional, extreme protection for the few people who may be personally targeted by sophisticated spyware; it blocks most message attachments, some web technologies, unknown FaceTime calls and wired accessories while the Mac is locked. Keel reads LDMGlobalEnabled in /Library/Preferences/.GlobalPreferences.plist and your own global preferences, the keys the Lockdown Mode code checks on macOS 27.0.1. Most people should leave it off; it is listed so you can confirm its state. It is turned on or off in System Settings > Privacy & Security and needs a restart.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: {
                let system = Prefs.value("/Library/Preferences/.GlobalPreferences", "LDMGlobalEnabled").map(Prefs.render)
                let user = Prefs.string("NSGlobalDomain", "LDMGlobalEnabled")
                let on = system == "1" || user == "1"
                return Detection(state: on ? .on : .off,
                                 values: [("LDMGlobalEnabled (system)", system ?? "(not set)"), ("LDMGlobalEnabled (user)", user ?? "(not set)")])
            },
            settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security",
            instructions: "System Settings > Privacy & Security > Lockdown Mode")),
        sources: ["https://support.apple.com/en-us/105120", "Local check: LDMGlobalEnabled and /Library/LockdownMode/state.plist in the macOS 27.0.1 shared cache"],
        confidence: .medium,
        expectedBenefit: "For people at risk of targeted attacks, a much smaller attack surface.",
        tradeoff: "Many attachments, link previews, web fonts and some websites stop working.",
        audience: [.privacy])
}

// MARK: - Chromium-family browsers

private struct ChromiumBrowser: Sendable {
    let name: String
    let bundleID: String
    let dir: String     // under ~/Library/Application Support
}

private struct ChromiumTarget: Sendable {
    let browser: ChromiumBrowser
    let label: String
    let path: String
    let readable: Bool
}

private let chromiumBrowsers: [ChromiumBrowser] = [
    ChromiumBrowser(name: "Google Chrome", bundleID: "com.google.Chrome", dir: "Google/Chrome"),
    ChromiumBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", dir: "Microsoft Edge"),
    ChromiumBrowser(name: "Brave", bundleID: "com.brave.Browser", dir: "BraveSoftware/Brave-Browser"),
    ChromiumBrowser(name: "Arc", bundleID: "company.thebrowser.Browser", dir: "Arc/User Data"),
    ChromiumBrowser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", dir: "Vivaldi"),
    ChromiumBrowser(name: "Chromium", bundleID: "org.chromium.Chromium", dir: "Chromium"),
]

private extension TweakCatalog {
    enum ChromiumFile { case profilePrefs, localState }

    static let chromiumNote = "It applies to every profile of each installed Chromium-based browser (Chrome, Edge, Brave, Arc, Vivaldi, Chromium), only to files that hold the value, and each file is copied to Keel's backups first. The browser must be quit, because it rewrites these files when it exits; on macOS 27 Keel also needs Full Disk Access to read them."

    static let prvChromeURLCollection = chromiumTweak(
        id: "chrome-url-collection-off", name: "Chromium-based browsers: URL sharing off",
        summary: "The browser stops sending the addresses you visit to its maker. Quit the browser first.",
        explanation: """
        Chromium-based browsers stop sending the addresses of pages you visit to Google or Microsoft to improve suggestions. Keel sets url_keyed_anonymized_data_collection.enabled = false in each profile's Preferences, the setting shown as "Make searches and browsing better" in Chrome; unset means off, and Brave and Vivaldi ship with it off. \(chromiumNote)
        """,
        keyPath: "url_keyed_anonymized_data_collection.enabled", file: .profilePrefs, risk: .safe, recommended: false,
        sources: ["https://chromium.googlesource.com/chromium/src/+/main/components/unified_consent/pref_names.cc"],
        confidence: .high, benefit: "Visited addresses are no longer sent to Google or Microsoft for suggestions.",
        tradeoff: "Address-bar suggestions are slightly less tailored.")

    static let prvChromeSafeBrowsing = chromiumTweak(
        id: "chrome-safe-browsing-standard", name: "Chromium-based browsers: Standard Safe Browsing",
        summary: "Keeps malicious-site protection without real-time upload of visited addresses. Quit the browser first.",
        explanation: """
        The browser's malicious-site protection stays on, but it checks pages against a downloaded list instead of sending addresses to Google as you browse. Keel sets safebrowsing.enhanced = false in each profile where it is true; Standard protection stays on. Edge uses Microsoft SmartScreen instead, so this rarely finds anything there. \(chromiumNote)
        """,
        keyPath: "safebrowsing.enhanced", file: .profilePrefs, risk: .low, recommended: false,
        sources: ["https://support.google.com/chrome/answer/9890866"],
        confidence: .high, benefit: "Addresses you visit and files you download are no longer sent to Google for real-time checks.",
        tradeoff: "Slower protection against brand-new phishing and malware sites than Enhanced protection.")

    static let prvChromeMetrics = chromiumTweak(
        id: "chrome-metrics-off", name: "Chromium-based browsers: usage statistics off",
        summary: "The browser stops uploading usage statistics and crash reports. Quit the browser first.",
        explanation: """
        Chromium-based browsers stop sending usage statistics and crash reports to their maker. Keel sets user_experience_metrics.reporting_enabled = false in each browser's Local State, the setting Chrome calls "Help improve Chrome's features and performance" and Brave calls "Automatically send diagnostic reports"; unset means not reporting. \(chromiumNote)
        """,
        keyPath: "user_experience_metrics.reporting_enabled", file: .localState, risk: .safe, recommended: false,
        sources: ["https://chromium.googlesource.com/chromium/src/+/main/components/metrics/metrics_pref_names.cc"],
        confidence: .medium, benefit: "No usage statistics or crash reports leave the browser.",
        tradeoff: "The browser maker gets no crash data from you.")

    /// A tweak that sets a boolean Chromium pref to false wherever it is true.
    static func chromiumTweak(id: String, name: String, summary: String, explanation: String, keyPath: String, file: ChromiumFile,
                              risk: Risk, recommended: Bool, sources: [String], confidence: Confidence, benefit: String, tradeoff: String) -> Tweak {
        Tweak(id: id, name: name, category: .privacy, summary: summary, explanation: explanation, risk: risk, impact: .low, recommended: recommended,
              mechanism: .custom(CustomMechanism(
                detect: {
                    let targets = chromiumTargets(file)
                    if targets.isEmpty { return .na("No Chromium-based browser installed (Chrome, Edge, Brave, Arc, Vivaldi, Chromium)") }
                    var values: [(String, String)] = []
                    var on = 0, off = 0
                    for t in targets {
                        guard t.readable, let j = TweakHelpers.readJSON(t.path) else { values.append((t.label, "(protected: needs Full Disk Access)")); continue }
                        let v = TweakHelpers.nested(j, keyPath)
                        if (v as? Bool) == true { off += 1; values.append((t.label, "\(keyPath) = true")) }
                        else { on += 1; values.append((t.label, v.map { "\(keyPath) = \($0)" } ?? "(unset = false)")) }
                    }
                    if on + off == 0 {
                        return Detection(state: .unknown, values: values,
                                         note: Machine.current.osMajor >= 27 ? "macOS 27 protects other apps' data. Give Keel Full Disk Access (System Settings > Privacy & Security > Full Disk Access) so it can read and change browser settings." : "Could not read the browser files.")
                    }
                    return Detection(state: off == 0 ? .on : (on == 0 ? .off : .partlyOn), values: values)
                },
                apply: { _ in
                    let all = chromiumTargets(file)
                    let targets = all.filter { $0.readable && (TweakHelpers.nested(TweakHelpers.readJSON($0.path), keyPath) as? Bool) == true }
                    if targets.isEmpty {
                        throw TweakEngine.EngineError(message: all.contains { !$0.readable } ? "Give Keel Full Disk Access so it can read the browser's settings" : "Nothing to change")
                    }
                    try await chromiumRequireQuit(targets.map(\.browser))
                    var rec: [String: String] = [:]
                    var done: [[String: String]] = []
                    do {
                        for (i, t) in targets.enumerated() {
                            let r = try TweakHelpers.editJSON(t.path, tag: "\(id)-\(i)") { TweakHelpers.setNested(&$0, keyPath, false) }
                            done.append(r)
                            rec["\(i).path"] = t.path; rec["\(i).file"] = r["file"] ?? ""; rec["\(i).bundle"] = t.browser.bundleID
                        }
                    } catch {
                        for r in done { try? TweakHelpers.restoreFile(r) }
                        throw error
                    }
                    rec["count"] = String(targets.count)
                    return rec
                },
                revert: { _, rec in
                    // Older Keel builds recorded a single {path, file}.
                    var paths: [(String, String?)] = []
                    if let n = Int(rec["count"] ?? "") { for i in 0..<n { if let p = rec["\(i).path"] { paths.append((p, rec["\(i).bundle"])) } } }
                    else if let p = rec["path"] { paths.append((p, "com.google.Chrome")) }
                    if paths.isEmpty { throw TweakEngine.EngineError(message: "Nothing recorded; change it in the browser's settings") }
                    let browsers = chromiumBrowsers.filter { b in paths.contains { $0.1 == b.bundleID } }
                    try await chromiumRequireQuit(browsers)
                    for (p, _) in paths where Permissions.canRead(p) && FileManager.default.fileExists(atPath: p) {
                        guard var obj = TweakHelpers.readJSON(p) else { continue }
                        TweakHelpers.setNested(&obj, keyPath, true)
                        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
                        try data.write(to: URL(fileURLWithPath: p), options: .atomic)
                    }
                },
                applyCommands: ["Each profile's \(file == .localState ? "Local State" : "Preferences"): \(keyPath) = false  (browser quit; file copied to backups first)"],
                revertCommands: ["Set \(keyPath) back to true in the files Keel changed (browser quit)"],
                needsAdmin: false)),
              sources: sources, confidence: confidence, expectedBenefit: benefit, tradeoff: tradeoff, audience: [.privacy])
    }

    /// Profile Preferences (Default and "Profile N") or Local State of each installed Chromium browser.
    /// Protected folders are never opened (that could prompt); they come back as unreadable targets.
    static func chromiumTargets(_ file: ChromiumFile) -> [ChromiumTarget] {
        let fm = FileManager.default
        var out: [ChromiumTarget] = []
        for b in chromiumBrowsers where Machine.appInstalled(b.bundleID) {
            let root = "\(NSHomeDirectory())/Library/Application Support/\(b.dir)"
            let localState = "\(root)/Local State"
            guard Permissions.canRead(root) else {
                out.append(ChromiumTarget(browser: b, label: b.name, path: file == .localState ? localState : "\(root)/Default/Preferences", readable: false))
                continue
            }
            switch file {
            case .localState:
                if fm.fileExists(atPath: localState) { out.append(ChromiumTarget(browser: b, label: b.name, path: localState, readable: Permissions.canRead(localState))) }
            case .profilePrefs:
                let names = (TweakHelpers.nested(TweakHelpers.readJSON(localState), "profile.info_cache") as? [String: Any]) ?? [:]
                let dirs = ((try? fm.contentsOfDirectory(atPath: root)) ?? ["Default"]).filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
                for d in dirs where fm.fileExists(atPath: "\(root)/\(d)/Preferences") {
                    let display = (names[d] as? [String: Any])?["name"] as? String ?? d
                    let path = "\(root)/\(d)/Preferences"
                    out.append(ChromiumTarget(browser: b, label: "\(b.name) · \(display)", path: path, readable: Permissions.canRead(path)))
                }
            }
        }
        return out
    }

    static func chromiumRequireQuit(_ browsers: [ChromiumBrowser]) async throws {
        var seen = Set<String>()
        let running = browsers.filter { seen.insert($0.bundleID).inserted && !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
        if !running.isEmpty {
            throw TweakEngine.EngineError(message: "Quit \(running.map(\.name).joined(separator: ", ")) first: it rewrites its settings when it quits")
        }
    }

    // MARK: Parsers and probes

    /// socketfilterfw --getglobalstate: "Firewall is enabled. (State = 1)"; 2 = block all incoming.
    static func prvFirewallGlobalLevel(_ s: String) -> Int {
        if let rg = s.range(of: "State = [0-9]", options: .regularExpression), let n = Int(String(s[rg].last!)) { return n }
        let l = s.lowercased()
        return l.contains("enabled") && !l.contains("disabled") ? 1 : 0
    }

    /// "Firewall stealth mode is on" (macOS 27) or "Stealth mode enabled" (macOS 15).
    static func prvStealthOn(_ s: String) -> Bool {
        let l = s.lowercased()
        if l.contains(" is on") { return true }
        if l.contains(" is off") || l.contains("disabled") { return false }
        return l.contains("enabled")
    }

    /// TCP ports listening on a non-loopback address, from `netstat -anp tcp` ("tcp4 0 0 *.22 *.* LISTEN").
    static func prvListeningPorts(_ out: String) -> Set<Int> {
        var ports = Set<Int>()
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 6, cols[5] == "LISTEN", !cols[3].hasPrefix("127."), !cols[3].hasPrefix("::1."),
                  let dot = cols[3].lastIndex(of: "."), let p = Int(cols[3][cols[3].index(after: dot)...]) else { continue }
            ports.insert(p)
        }
        return ports
    }

    static func prvProcessRunning(_ name: String) async -> Bool {
        await Shell.probe("/usr/bin/pgrep", ["-x", name])?.ok ?? false
    }
}
