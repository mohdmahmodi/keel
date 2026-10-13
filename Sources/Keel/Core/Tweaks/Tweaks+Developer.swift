import Foundation
import KeelShared

extension TweakCatalog {
    static let developer: [Tweak] = DevCatalog.build()
}

private enum DevCatalog {
    static func build() -> [Tweak] {
        [xcodeBuildDuration(), xcodeIndexProgress(), xcodeCompileTasks(), xcodeOnDevicePredictions(),
         gitFSMonitor(), sshConnectionReuse(), terminalDeveloperTool(), crashReportsAsNotifications(), plainQuotesDashes(),
         brewNoAnalytics(), finderDSStore(),
         dockerResourceSaver(), dockerResourceCaps(), dockerNoAutostart(), dockerNoUsageStats(), spotlightRepos()]
    }

    /// Xcode is selected with xcode-select, or installed while the Command Line Tools are selected
    /// (its preferences still apply then).
    static let xcodeRequirement: Requirement = .custom({
        let m = Machine.current
        return m.hasXcode || (m.hasCommandLineTools && Machine.appInstalled("com.apple.dt.Xcode")) ? nil : "Xcode is not installed"
    })

    // MARK: Xcode

    static func xcodeBuildDuration() -> Tweak {
        Tweak(id: "xcode-build-duration", name: "Show build duration in Xcode", category: .developer,
              summary: "Each build's duration appears in Xcode's activity area, so build changes can be measured.",
              explanation: "Xcode shows how long each build took, next to \"Build Succeeded\" in the activity area at the top of the window. Keel sets ShowBuildOperationDuration in com.apple.dt.Xcode; the key is present in Xcode 27's IDEKit framework. It takes effect after Xcode relaunches. For a per-step breakdown, use Product > Perform Action > Build With Timing Summary.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dt.Xcode", key: "ShowBuildOperationDuration", type: .bool, on: "true", off: nil, onAliases: ["1", "YES"])], post: .none),
              sources: ["https://developer.apple.com/forums/thread/131372"],
              requires: [xcodeRequirement],
              confidence: .high,
              expectedBenefit: "Every build shows how many seconds it took, so you can tell whether a change made builds faster or slower.",
              tradeoff: "Nothing noticeable.")
    }

    static func xcodeIndexProgress() -> Tweak {
        Tweak(id: "xcode-index-progress-numbers", name: "Xcode indexing progress as numbers", category: .developer,
              summary: "Xcode shows how many files it has indexed out of the total, instead of only a progress bar.",
              explanation: "Xcode shows indexing progress as a count of files processed out of the total. Indexing is the background pass that powers code completion and jump to definition, so the count tells you how long until they work. Keel sets IDEIndexerActivityShowNumericProgress in com.apple.dt.Xcode, a key present in Xcode 27's IDEKit framework. It only changes what is displayed and takes effect after Xcode relaunches.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dt.Xcode", key: "IDEIndexerActivityShowNumericProgress", type: .bool, on: "true", off: nil, onAliases: ["1", "YES"])], post: .none),
              sources: ["Xcode 27 IDEKit.framework (strings: IDEIndexerActivityShowNumericProgress)"],
              requires: [xcodeRequirement],
              confidence: .high,
              expectedBenefit: "While a project indexes, the activity area shows a rising file count, so you can see how much is left.",
              tradeoff: "Nothing noticeable.")
    }

    static func xcodeOnDevicePredictions() -> Tweak {
        Tweak(id: "xcode-on-device-predictions-off", name: "Xcode on-device code predictions: off", category: .developer,
              summary: "Xcode stops loading its local machine-learning model for gray whole-line code suggestions.",
              explanation: "Xcode's predictive code completion, the gray whole-line suggestions produced by a machine-learning model that runs on the Mac itself, is turned off. Keel sets DVTEnableOnDeviceCodePredictions to false in com.apple.dt.Xcode; in Xcode 27 the key sits in the IDELanguageModelKit framework next to the \"Predictive code completion\" setting text (inferred from the binary, not documented by Apple). Apple offers the feature only on Macs with at least 16 GB of memory. Regular code completion and Xcode's chat assistant are unaffected, and the change applies after Xcode relaunches.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.dt.Xcode", key: "DVTEnableOnDeviceCodePredictions", type: .bool, on: "false", off: nil, onAliases: ["0", "NO"])], post: .none),
              sources: ["Local check (Xcode 27, macOS 27.0): IDELanguageModelKit contains DVTEnableOnDeviceCodePredictions and \"Predictive code completion\"; IDEXCStringsSupportCore says comment generation requires the on-device model", "https://developer.apple.com/documentation/xcode/writing-code-with-intelligence-in-xcode"],
              requires: [xcodeRequirement, .minMemoryGB(16)],
              confidence: .medium,
              expectedBenefit: "Xcode no longer loads the prediction model, which leaves more memory for simulators and builds. The amount saved was not measured.",
              tradeoff: "No gray whole-line suggestions while you type, and String Catalogs can no longer generate translator comments, which need the same model.")
    }

    static func xcodeCompileTasks() -> Tweak {
        let pCores = Sysctl.int("hw.perflevel0.physicalcpu") ?? 0
        let total = Sysctl.int("hw.ncpu") ?? 0
        return Tweak(id: "xcode-compile-tasks-pcores", name: pCores > 0 ? "Xcode: compile on the \(pCores) performance cores" : "Xcode: compile on the performance cores",
                     category: .developer,
                     summary: "Xcode compiles at most as many files at once as the Mac has performance cores.",
                     explanation: "Xcode compiles no more files at the same time than the Mac has performance cores, which leaves the efficiency cores for everything else. Keel sets IDEBuildOperationMaxNumberOfConcurrentCompileTasks to \(pCores); without it Xcode uses every core (\(total) on this Mac). Developer reports on Apple silicon show build times within noise either way, so the point is a responsive Mac during big builds, not faster builds. The setting also applies to xcodebuild unless -jobs is passed; measure with the build-duration setting before and after.",
                     risk: .low, impact: .low, recommended: false,
                     mechanism: .defaults([DefaultsSetting(domain: "com.apple.dt.Xcode", key: "IDEBuildOperationMaxNumberOfConcurrentCompileTasks", type: .int, on: String(max(pCores, 1)), off: nil)], post: .none),
                     sources: ["https://developer.apple.com/forums/thread/80073", "https://developer.apple.com/forums/thread/703986"],
                     requires: [xcodeRequirement, .custom({ pCores > 0 && total > pCores ? nil : "Could not read the performance-core count" })],
                     confidence: .medium,
                     expectedBenefit: "During big builds the rest of the Mac (scrolling, the simulator, your browser) stays responsive.",
                     tradeoff: "Very large clean builds can take slightly longer because the efficiency cores no longer compile.")
    }

    // MARK: Git

    static func gitFSMonitor() -> Tweak {
        Tweak(id: "git-fsmonitor", name: "Git: built-in file monitor and untracked cache", category: .developer,
              summary: "git status asks macOS what changed instead of rescanning every file; large repositories gain most.",
              explanation: "Git asks macOS which files changed instead of checking every file in the project each time you run git status. Keel sets core.fsmonitor and core.untrackedCache to true in your global Git config (~/.gitconfig), recording the previous values so they can be restored exactly. Git then starts its built-in fsmonitor daemon for each repository you use; it listens to macOS file-system events (FSEvents), and the untracked cache remembers which folders have no new files. The gain grows with repository size: small projects see little difference, repositories with tens of thousands of files see the most. Both are standard Git features (the built-in daemon arrived for macOS in Git 2.37, and Apple's Git on macOS 27.0.1 is 2.54); the daemon skips network volumes, and tools that bundle an older Git ignore the setting.",
              risk: .low, impact: .medium, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: {
                    guard let git = DevGit.path() else { return .na("Git is not installed (install Xcode or the Command Line Tools)") }
                    guard let info = await DevGit.buildInfo(git) else { return .na("Could not run \(git)") }
                    guard info.hasDaemon, info.version >= (2, 37) else {
                        return .na("\(info.versionString) has no built-in fsmonitor daemon (needs Git 2.37 or later)")
                    }
                    let fsm = await DevGit.get(git, "core.fsmonitor")
                    let uc = await DevGit.get(git, "core.untrackedcache")
                    let onCount = [DevGit.isTrue(fsm), DevGit.isTrue(uc)].filter { $0 }.count
                    return Detection(state: onCount == 2 ? .on : (onCount == 0 ? .off : .partlyOn),
                                     values: [("git", "\(git) (\(info.versionString))"),
                                              ("core.fsmonitor", fsm ?? "(not set)"),
                                              ("core.untrackedcache", uc ?? "(not set: Git keeps it off)")])
                },
                apply: { _ in
                    guard let git = DevGit.path() else { throw TweakEngine.EngineError(message: "Git is not installed") }
                    var rec: [String: String] = ["git": git]
                    for key in DevGit.keys { rec["prev.\(key)"] = await DevGit.get(git, key, cached: false) ?? DevGit.unset }
                    for key in DevGit.keys { try await DevGit.set(git, key, "true") }
                    return rec
                },
                revert: { _, rec in
                    guard let git = DevGit.path() else { throw TweakEngine.EngineError(message: "Git is not installed") }
                    for key in DevGit.keys {
                        let prev = rec["prev.\(key)"] ?? DevGit.unset
                        if prev == DevGit.unset { try await DevGit.unsetKey(git, key) } else { try await DevGit.set(git, key, prev) }
                    }
                },
                applyCommands: ["git config --global core.fsmonitor true", "git config --global core.untrackedcache true"],
                revertCommands: ["git config --global <key> <recorded value>  # or --unset when it was not set",
                                 "running daemons exit at logout, or run `git fsmonitor--daemon stop` inside a repository"],
                needsAdmin: false)),
              sources: ["https://git-scm.com/docs/git-fsmonitor--daemon", "https://git-scm.com/docs/git-config#Documentation/git-config.txt-corefsmonitor",
                        "https://git-scm.com/docs/git-update-index#_untracked_cache",
                        "https://github.blog/engineering/infrastructure/improve-git-monorepo-performance-with-a-file-system-monitor/"],
              confidence: .high,
              expectedBenefit: "git status, diff and add return sooner in large repositories, and editors that run git status in the background wait less.",
              tradeoff: "One small background fsmonitor daemon per repository you work in, until you log out.")
    }

    // MARK: Finder

    static func finderDSStore() -> Tweak {
        Tweak(id: "finder-no-ds-store-network", name: "No .DS_Store files on network shares", category: .developer,
              summary: "Finder no longer leaves .DS_Store files in folders on file servers and NAS shares.",
              explanation: "Finder no longer creates hidden .DS_Store files, which store each folder's icon positions and view settings, in folders on network shares. On file servers these files end up in other people's folders and shared repositories, and reading them for every folder slows browsing. Keel sets DSDontWriteNetworkStores to true in com.apple.desktopservices, a key Apple documents for SMB shares and that is present in macOS 27. Folders on your own disks are unaffected. The often-quoted DSDontWriteUSBStores key does not appear anywhere in macOS 27 (Finder and the system library cache were searched), so Keel does not set it.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([
                DefaultsSetting(domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", type: .bool, on: "true", off: nil, onAliases: ["1", "YES"])
              ], post: .killFinder),
              sources: ["https://support.apple.com/HT208209", "https://eclecticlight.co/2025/11/15/explainer-ds_store-files-2/", "Local check (macOS 27.0): dyld shared cache contains DSDontWriteNetworkStores; no binary contains DSDontWriteUSBStores"],
              confidence: .high,
              expectedBenefit: "No stray .DS_Store files appear on file servers, NAS shares or in colleagues' folders, and browsing big network folders is slightly quicker.",
              tradeoff: "Finder does not remember icon positions or view options for folders on network shares.")
    }

    // MARK: SSH, Terminal, crash dialogs, typing

    static func sshConnectionReuse() -> Tweak {
        Tweak(id: "ssh-connection-reuse", name: "SSH: reuse connections for 10 minutes", category: .developer,
              summary: "git push/pull and ssh to the same server skip the connection handshake after the first time.",
              explanation: "SSH keeps one connection to each server open for 10 minutes and sends later sessions through it, so repeated git fetch and push, scp or ssh to the same host skip the handshake and key exchange. Keel adds a marked Host * block with ControlMaster auto, ControlPath ~/.ssh/keel-cm-%C and ControlPersist 10m to the end of ~/.ssh/config; these are standard OpenSSH options documented in man ssh_config on macOS 27. Because ssh uses the first value it finds for each option, anything you already set for a host takes precedence over Keel's block. Restoring removes exactly that block.",
              risk: .low, impact: .medium, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: { await DevSSH.detect() },
                apply: { _ in try DevSSH.apply() },
                revert: { _, rec in try DevSSH.revert(rec) },
                applyCommands: ["append to ~/.ssh/config:\n\(DevSSH.block)"],
                revertCommands: ["remove the Keel block from ~/.ssh/config (delete the file if Keel created it)"],
                needsAdmin: false)),
              sources: ["man ssh_config (macOS 27): ControlMaster, ControlPath, ControlPersist", "https://man.openbsd.org/ssh_config#ControlMaster"],
              confidence: .high,
              expectedBenefit: "The second and later git push, pull or ssh to the same server within 10 minutes start without the usual connection delay, most visibly over slow or distant links.",
              tradeoff: "After a network change the first command may hang until the old connection times out (`ssh -O exit <host>` closes it at once); a shared connection stays open in the background for 10 minutes.")
    }

    static func terminalDeveloperTool() -> Tweak {
        Tweak(id: "terminal-developer-tool", name: "Terminal as a Developer Tool", category: .developer,
              summary: "Programs you build and run from Terminal skip macOS's security check on first launch.",
              explanation: "Once your terminal app is in the Developer Tools list in System Settings > Privacy & Security, programs started from it skip the Gatekeeper and XProtect malware checks when they first run. That check runs for every newly built executable and slows test runners and build tools that produce fresh binaries (Rust, Go, Swift, C++). The command spctl developer-mode enable-terminal, listed in spctl's usage on macOS 27, makes Terminal appear in the list; other terminals such as iTerm, Ghostty or VS Code can be added with +. Only you can turn it on, so Keel opens the pane. Keel cannot read the list without Full Disk Access and shows the state as unknown.",
              risk: .medium, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: { Detection(state: .unknown, values: [("Developer Tools list", "not readable without Full Disk Access")], note: "Check System Settings > Privacy & Security > Developer Tools") },
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_DevTools",
                instructions: "Run `spctl developer-mode enable-terminal` once in Terminal, then System Settings > Privacy & Security > Developer Tools: turn on Terminal (or add your terminal app with +)")),
              sources: ["spctl usage on macOS 27: \"developer-mode enable-terminal: Add Terminal as a developer tool\"", "https://notes.billmill.org/computer_usage/mac_os/Avoiding_gatekeeper_in_your_terminal.html"],
              confidence: .medium,
              expectedBenefit: "Freshly built binaries and test executables start without the first-launch pause. The size of the pause was not measured by Keel.",
              tradeoff: "Anything started from that terminal, including a downloaded script or binary, runs without Gatekeeper's malware check. Use it only for terminals you use for your own code.")
    }

    static func crashReportsAsNotifications() -> Tweak {
        Tweak(id: "crash-reports-as-notifications", name: "Crash reports as notifications, not dialogs", category: .developer,
              summary: "\"App quit unexpectedly\" appears as a notification instead of a window you must dismiss.",
              explanation: "The \"quit unexpectedly\" crash message appears as a notification banner instead of a dialog that takes focus, which helps when an app you are developing crashes repeatedly. Keel sets UseUNC to true in com.apple.CrashReporter. The key is present in macOS 27's ReportCrash, the process that shows crash messages; the notification behavior is described in long-standing community reports rather than by Apple, and Keel has not observed it on macOS 27. Crash reports are still written to ~/Library/Logs/DiagnosticReports.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "com.apple.CrashReporter", key: "UseUNC", type: .bool, on: "true", off: nil, onAliases: ["1", "YES"])], post: .none),
              sources: ["Local check (macOS 27.0): /System/Library/CoreServices/ReportCrash contains UseUNC and DialogType"],
              confidence: .medium,
              expectedBenefit: "When an app crashes, a notification slides in and your current window keeps focus.",
              tradeoff: "Crash messages are easier to miss if you have notifications silenced.")
    }

    static func plainQuotesDashes() -> Tweak {
        Tweak(id: "dev-plain-quotes-dashes", name: "Keep straight quotes and double hyphens", category: .developer,
              summary: "macOS no longer turns \" into “ ” and -- into — in Notes, Mail, Messages and other Mac apps.",
              explanation: "Straight quotes and double hyphens stay as you typed them, instead of becoming curly quotes and a dash that break commands and code pasted from Notes, Mail or Messages into a terminal. Keel sets NSAutomaticQuoteSubstitutionEnabled and NSAutomaticDashSubstitutionEnabled to false in the global preferences, the same setting as \"Use smart quotes and dashes\" in System Settings > Keyboard > Text Input > Edit; both keys are present in macOS 27. Apps pick up the change when they next open. Apps with their own text engines, such as Electron apps and web pages, are unaffected.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([
                DefaultsSetting(domain: "NSGlobalDomain", key: "NSAutomaticQuoteSubstitutionEnabled", type: .bool, on: "false", off: nil, onAliases: ["0", "NO"]),
                DefaultsSetting(domain: "NSGlobalDomain", key: "NSAutomaticDashSubstitutionEnabled", type: .bool, on: "false", off: nil, onAliases: ["0", "NO"])
              ], post: .none),
              sources: ["Local check (macOS 27.0): dyld shared cache contains NSAutomaticQuoteSubstitutionEnabled and NSAutomaticDashSubstitutionEnabled"],
              confidence: .high,
              expectedBenefit: "Shell commands and code written in Notes, Mail or Messages keep plain \" ' and -- and paste into a terminal unchanged.",
              tradeoff: "Prose in Mac apps gets straight quotes and hyphens instead of typographic ones.")
    }

    // MARK: Homebrew

    static func brewNoAnalytics() -> Tweak {
        Tweak(id: "brew-no-analytics", name: "Homebrew: no analytics", category: .developer,
              summary: "Homebrew stops sending anonymous install and usage events.",
              explanation: "Homebrew, the command-line package manager, stops sending anonymous usage events, such as which packages are installed and the macOS version, to its analytics server. Keel writes HOMEBREW_NO_ANALYTICS=1 to Homebrew's environment file (brew.env in Homebrew's etc/homebrew folder, or ~/.homebrew/brew.env if that folder is not writable), a mechanism documented in man brew. The file applies to every shell and to apps that run brew. Restoring puts back the previous value or removes the line; the other supported switch, brew analytics off, is detected too.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: { DevBrew.detect() },
                apply: { _ in try DevBrew.apply() },
                revert: { _, rec in try DevBrew.revert(rec) },
                applyCommands: ["echo 'HOMEBREW_NO_ANALYTICS=1' >> \"$(brew --prefix)/etc/homebrew/brew.env\""],
                revertCommands: ["remove HOMEBREW_NO_ANALYTICS from brew.env (or restore the recorded value)"],
                needsAdmin: false)),
              sources: ["man brew (Homebrew 7.0.9): ENVIRONMENT, brew.env, HOMEBREW_NO_ANALYTICS", "https://docs.brew.sh/Analytics"],
              requires: [.homebrew],
              confidence: .high,
              expectedBenefit: "Nothing changes on screen; brew stops sending analytics.",
              tradeoff: "Homebrew's maintainers get less data on which packages are used.")
    }

    // MARK: Docker Desktop

    static let dockerRequires: [Requirement] = [
        .app(bundleID: "com.docker.docker", name: "Docker Desktop"),
        .custom({ Shell.exists(TweakHelpers.dockerStore) ? nil : "Docker Desktop has not created its settings yet (open it once)" })
    ]
    static let dockerSources = ["https://docs.docker.com/desktop/settings-and-maintenance/settings/"]

    static func dockerResourceSaver() -> Tweak {
        Tweak(id: "docker-resource-saver", name: "Docker: Resource Saver after 2 minutes idle", category: .developer,
              summary: "Docker pauses its Linux VM after 2 minutes without running containers, instead of 5.",
              explanation: "Docker Desktop pauses its Linux virtual machine after 2 minutes with no containers running, instead of 5. Keel writes UseResourceSaver = true and AutoPauseTimeoutSeconds = 120 into Docker Desktop's settings-store.json; a missing key means Docker's default (on, 300 seconds). Docker documents that Resource Saver cuts Docker Desktop's memory use by 2 GB or more while it is paused. Keel edits the file only while Docker Desktop is quit and restores exactly the keys it changed.",
              risk: .safe, impact: .medium, recommended: true,
              mechanism: .custom(CustomMechanism(
                detect: {
                    guard let j = TweakHelpers.readJSON(TweakHelpers.dockerStore) else { return DevDocker.unreadable() }
                    let rs = j["UseResourceSaver"] as? Bool ?? true
                    let t = (j["AutoPauseTimeoutSeconds"] as? NSNumber)?.intValue ?? 300
                    var vals = [("UseResourceSaver", DevDocker.show(j, "UseResourceSaver", absent: "true")),
                                ("AutoPauseTimeoutSeconds", DevDocker.show(j, "AutoPauseTimeoutSeconds", absent: "300"))]
                    vals += await DevDocker.contextValues()
                    return Detection(state: rs && t <= 120 ? .on : .off, values: vals)
                },
                apply: { _ in
                    try await DevDocker.requireQuit()
                    let j = TweakHelpers.readJSON(TweakHelpers.dockerStore) ?? [:]
                    let t = (j["AutoPauseTimeoutSeconds"] as? NSNumber)?.intValue ?? 300
                    return try DevDocker.write(["UseResourceSaver": true, "AutoPauseTimeoutSeconds": max(30, min(t, 120))], tag: "docker-resource-saver")
                },
                revert: { _, rec in
                    try await DevDocker.requireQuit()
                    try DevDocker.restore(rec, keys: ["UseResourceSaver", "AutoPauseTimeoutSeconds"])
                },
                applyCommands: ["settings-store.json: UseResourceSaver = true, AutoPauseTimeoutSeconds = 120  (Docker Desktop must be quit)"],
                revertCommands: ["settings-store.json: put back the recorded UseResourceSaver and AutoPauseTimeoutSeconds (or remove them)"],
                needsAdmin: false)),
              sources: ["https://docs.docker.com/desktop/use-desktop/resource-saver/"],
              requires: dockerRequires, confidence: .high,
              expectedBenefit: "After you stop your containers, Docker's memory (2 GB or more, per Docker) is returned 3 minutes sooner.",
              tradeoff: "The first docker command after a pause waits 3 to 10 seconds while the VM resumes.")
    }

    static func dockerResourceCaps() -> Tweak {
        let caps = DevDocker.caps()
        return Tweak(id: "docker-resource-caps", name: "Docker: cap the VM at \(caps.cpus) CPUs and \(DevDocker.gb(caps.memMiB))", category: .developer,
                     summary: "Keeps container builds from starving Xcode, the simulator and the rest of the Mac.",
                     explanation: "Docker's Linux virtual machine can take only part of the Mac's processor and memory, leaving the rest for your other apps. Docker Desktop's VM defaults to every CPU and half of the Mac's memory. Keel sizes it for this Mac: about half the cores (\(caps.cpus) of \(caps.totalCores)) and the smaller of 8 GB and a third of memory (\(DevDocker.gb(caps.memMiB)) of \(DevDocker.gb(caps.hostMiB))), writing Cpus and MemoryMiB into settings-store.json. Values you already set lower are kept. Docker VMM (beta) needs at least 4 GB, which Keel respects. Docker Desktop must be quit; it uses the new size the next time it starts.",
                     risk: .low, impact: .medium, recommended: false,
                     mechanism: .custom(CustomMechanism(
                        detect: {
                            guard let j = TweakHelpers.readJSON(TweakHelpers.dockerStore) else { return DevDocker.unreadable() }
                            let c = DevDocker.caps(libkrun: j["UseLibkrun"] as? Bool ?? false)
                            let cpus = (j["Cpus"] as? NSNumber)?.intValue ?? c.totalCores
                            let mem = (j["MemoryMiB"] as? NSNumber)?.intValue ?? c.hostMiB / 2
                            let onCount = [cpus <= c.cpus, mem <= c.memMiB].filter { $0 }.count
                            var vals = [("Cpus", DevDocker.show(j, "Cpus", absent: "\(c.totalCores) (all cores)")),
                                        ("MemoryMiB", DevDocker.show(j, "MemoryMiB", absent: "\(c.hostMiB / 2) (half of memory)")),
                                        ("target", "\(c.cpus) CPUs, \(c.memMiB) MiB")]
                            vals += await DevDocker.contextValues()
                            return Detection(state: onCount == 2 ? .on : (onCount == 0 ? .off : .partlyOn), values: vals)
                        },
                        apply: { _ in
                            try await DevDocker.requireQuit()
                            let j = TweakHelpers.readJSON(TweakHelpers.dockerStore) ?? [:]
                            let c = DevDocker.caps(libkrun: j["UseLibkrun"] as? Bool ?? false)
                            let cpus = min((j["Cpus"] as? NSNumber)?.intValue ?? c.totalCores, c.cpus)
                            let mem = min((j["MemoryMiB"] as? NSNumber)?.intValue ?? c.hostMiB / 2, c.memMiB)
                            return try DevDocker.write(["Cpus": cpus, "MemoryMiB": mem], tag: "docker-resource-caps")
                        },
                        revert: { _, rec in
                            try await DevDocker.requireQuit()
                            try DevDocker.restore(rec, keys: ["Cpus", "MemoryMiB"])
                        },
                        applyCommands: ["settings-store.json: Cpus = \(caps.cpus), MemoryMiB = \(caps.memMiB)  (Docker Desktop must be quit)"],
                        revertCommands: ["settings-store.json: put back the recorded Cpus and MemoryMiB (or remove them = Docker defaults)"],
                        needsAdmin: false)),
                     sources: ["https://docs.docker.com/desktop/features/vmm/"],
                     requires: dockerRequires, confidence: .high,
                     expectedBenefit: "While containers run, Docker can take at most \(DevDocker.gb(caps.memMiB)) and \(caps.cpus) cores, so Xcode, browsers and simulators stay responsive (the default allows \(DevDocker.gb(caps.hostMiB / 2))).",
                     tradeoff: "Memory-hungry container stacks can hit the VM's limit, and containers that run out of memory are stopped (OOM-killed); builds inside Docker use fewer cores.")
    }

    static func dockerNoAutostart() -> Tweak {
        Tweak(id: "docker-no-autostart", name: "Docker: no start at login, no dashboard", category: .developer,
              summary: "Docker Desktop starts only when you open it, without the dashboard window.",
              explanation: "Docker Desktop no longer starts when you log in, and no longer opens its dashboard window when it does start. Keel writes AutoStart = false and OpenUIOnStartupDisabled = true into Docker Desktop's settings-store.json. With AutoStart off, Docker's login item does nothing at login, so the virtual machine and its helpers do not run until you open Docker. Docker Desktop must be quit while Keel edits the file, and restoring puts back exactly the keys it changed.",
              risk: .safe, impact: .low, recommended: true,
              mechanism: .custom(CustomMechanism(
                detect: {
                    guard let j = TweakHelpers.readJSON(TweakHelpers.dockerStore) else { return DevDocker.unreadable() }
                    let auto = j["AutoStart"] as? Bool ?? false
                    let ui = j["OpenUIOnStartupDisabled"] as? Bool ?? false
                    var vals = [("AutoStart", DevDocker.show(j, "AutoStart", absent: "false")),
                                ("OpenUIOnStartupDisabled", DevDocker.show(j, "OpenUIOnStartupDisabled", absent: "false"))]
                    vals += await DevDocker.contextValues()
                    return Detection(state: !auto && ui ? .on : (!auto ? .partlyOn : .off), values: vals)
                },
                apply: { _ in
                    try await DevDocker.requireQuit()
                    return try DevDocker.write(["AutoStart": false, "OpenUIOnStartupDisabled": true], tag: "docker-no-autostart")
                },
                revert: { _, rec in
                    try await DevDocker.requireQuit()
                    try DevDocker.restore(rec, keys: ["AutoStart", "OpenUIOnStartupDisabled"])
                },
                applyCommands: ["settings-store.json: AutoStart = false, OpenUIOnStartupDisabled = true  (Docker Desktop must be quit)"],
                revertCommands: ["settings-store.json: put back the recorded AutoStart and OpenUIOnStartupDisabled (or remove them)"],
                needsAdmin: false)),
              sources: ["https://docs.docker.com/desktop/settings-and-maintenance/settings/", "Local check: AutoStart and OpenUIOnStartupDisabled in Docker Desktop 4.93 settings-store.json"],
              requires: dockerRequires, confidence: .high,
              expectedBenefit: "Docker's virtual machine is not running after login, so its memory stays free until you open Docker.",
              tradeoff: "Open Docker Desktop before running docker commands.")
    }

    static func dockerNoUsageStats() -> Tweak {
        Tweak(id: "docker-no-usage-stats", name: "Docker: don't send usage statistics", category: .developer,
              summary: "Turns off Docker Desktop's \"Send usage statistics\", which is on by default.",
              explanation: "Docker Desktop stops sending usage statistics to Docker, the same as turning off \"Send usage statistics\" in Docker's Settings > General. Keel writes AnalyticsEnabled = false into settings-store.json; the key is present in Docker Desktop 4.93's backend, and a missing key means Docker's default, which is on. Docker Desktop must be quit while Keel edits the file, and restoring puts back exactly the key it changed.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: {
                    guard let j = TweakHelpers.readJSON(TweakHelpers.dockerStore) else { return DevDocker.unreadable() }
                    let on = j["AnalyticsEnabled"] as? Bool ?? true
                    var vals = [("AnalyticsEnabled", DevDocker.show(j, "AnalyticsEnabled", absent: "true"))]
                    vals += await DevDocker.contextValues()
                    return Detection(state: on ? .off : .on, values: vals)
                },
                apply: { _ in
                    try await DevDocker.requireQuit()
                    return try DevDocker.write(["AnalyticsEnabled": false], tag: "docker-no-usage-stats")
                },
                revert: { _, rec in
                    try await DevDocker.requireQuit()
                    try DevDocker.restore(rec, keys: ["AnalyticsEnabled"])
                },
                applyCommands: ["settings-store.json: AnalyticsEnabled = false  (Docker Desktop must be quit)"],
                revertCommands: ["settings-store.json: put back the recorded AnalyticsEnabled (or remove it)"],
                needsAdmin: false)),
              sources: ["Docker Desktop 4.93 com.docker.backend (strings: AnalyticsEnabled)", "https://docs.docker.com/desktop/settings-and-maintenance/settings/"],
              requires: dockerRequires, confidence: .high,
              expectedBenefit: "Nothing visible; Docker Desktop stops sending usage data.",
              tradeoff: "Nothing noticeable.")
    }

    // MARK: Spotlight

    static func spotlightRepos() -> Tweak {
        Tweak(id: "spotlight-exclude-repos", name: "Spotlight: stop indexing code dependencies", category: .developer,
              summary: "Shows which code folders Spotlight indexes, including node_modules, and how to exclude them.",
              explanation: "Keel shows which of your code folders Spotlight indexes, including dependency folders such as node_modules that are rewritten on every install or build. Keel asks Spotlight (mdfind) how many package.json files it has indexed inside node_modules and groups them by folder, for example ~/Developer, ~/Documents/GitHub, ~/Projects or ~/Code. macOS keeps the exclusion list in a protected system file, so you add the folders yourself under System Settings > Spotlight > Search Privacy. Excluded folders no longer appear in Spotlight or Finder search. Turning Spotlight off entirely is not a substitute: Finder search, Mail search and the app launcher depend on it.",
              risk: .low, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: { await DevSpotlight.detect() },
                settingsURL: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension",
                instructions: "System Settings > Spotlight > Search Privacy > + and add the folders listed in the detection note")),
              sources: ["https://support.apple.com/guide/mac-help/mchl1bb43b84/mac"],
              confidence: .medium,
              expectedBenefit: "Less Spotlight indexing activity (mds_stores) after every npm/pnpm/yarn install or build, and Spotlight results without thousands of dependency files.",
              tradeoff: "Files in excluded folders are not found by Spotlight or Finder search.")
    }
}

// MARK: - Git helpers

private enum DevGit {
    static let keys = ["core.fsmonitor", "core.untrackedcache"]
    static let unset = "<unset>"

    /// Homebrew's Git when present (it comes first on PATH), else Apple's. /usr/bin/git is a shim that opens the
    /// Command Line Tools installer when no developer tools are installed, so it is only used when they are.
    static func path() -> String? {
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        let m = Machine.current
        if m.hasCommandLineTools || m.hasXcode { return "/usr/bin/git" }
        return nil
    }

    struct BuildInfo { let version: (Int, Int); let versionString: String; let hasDaemon: Bool }

    static func buildInfo(_ git: String) async -> BuildInfo? {
        guard let r = await Shell.probe(git, ["version", "--build-options"], ttl: 60), r.ok else { return nil }
        let first = r.stdout.split(separator: "\n").first.map(String.init) ?? ""
        var v = (0, 0)
        if let rg = first.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression) {
            let parts = first[rg].split(separator: ".").compactMap { Int($0) }
            if parts.count == 2 { v = (parts[0], parts[1]) }
        }
        return BuildInfo(version: v, versionString: first.replacingOccurrences(of: "git version ", with: "Git "),
                         hasDaemon: r.stdout.contains("fsmonitor--daemon"))
    }

    static func get(_ git: String, _ key: String, cached: Bool = true) async -> String? {
        let args = ["config", "--global", "--get", key]
        let r = cached ? await Shell.probe(git, args) : (try? await Shell.run(git, args, timeout: 10))
        guard let r, r.ok else { return nil }
        return r.output
    }

    static func isTrue(_ v: String?) -> Bool { ["true", "yes", "on", "1"].contains(v?.lowercased() ?? "") }

    static func set(_ git: String, _ key: String, _ value: String) async throws {
        let r = try await Shell.run(git, ["config", "--global", key, value], timeout: 10)
        ActivityLog.post(r.ok ? .command : .error, "git config --global \(key) \(value)", detail: r.ok ? nil : r.combined)
        if !r.ok { throw TweakEngine.EngineError(message: "git config \(key) failed: \(r.combined)") }
    }

    static func unsetKey(_ git: String, _ key: String) async throws {
        let r = try await Shell.run(git, ["config", "--global", "--unset-all", key], timeout: 10)
        ActivityLog.post(.command, "git config --global --unset-all \(key)")
        // 5 = key was not set: nothing to do.
        if !r.ok && r.status != 5 { throw TweakEngine.EngineError(message: "git config --unset \(key) failed: \(r.combined)") }
    }
}

// MARK: - Docker helpers

private enum DevDocker {
    static let absentMarker = "<absent>"

    struct Caps { let cpus: Int; let memMiB: Int; let totalCores: Int; let hostMiB: Int }

    /// Why detection could not read Docker's settings: privacy protection, or a file Docker has not written yet.
    static func unreadable() -> Detection {
        if !Permissions.canRead(TweakHelpers.dockerStore) {
            return Detection(state: .unknown, values: [("settings-store.json", "protected by macOS")],
                             note: "Give Keel Full Disk Access to read Docker Desktop's settings")
        }
        return .na("Docker Desktop's settings file could not be read; open Docker Desktop once and try again")
    }

    /// About half the cores (at least 2); the smaller of 8 GB and a third of memory in 512 MiB steps, at least
    /// 2 GB (4 GB under Docker VMM). Uses the machine profile once loaded, so simulated hardware is respected.
    static func caps(libkrun: Bool = false) -> Caps {
        let m = Machine.current
        let cores = m.totalCores > 0 ? m.totalCores : (Sysctl.int("hw.ncpu") ?? ProcessInfo.processInfo.activeProcessorCount)
        let hostMiB = m.memoryBytes > 0 ? m.memoryMB : Int((Sysctl.int64("hw.memsize") ?? Int64(ProcessInfo.processInfo.physicalMemory)) / 1_048_576)
        var mem = min(8192, hostMiB / 3) / 512 * 512
        mem = max(mem, libkrun ? 4096 : 2048)
        return Caps(cpus: max(2, cores / 2), memMiB: mem, totalCores: cores, hostMiB: hostMiB)
    }

    static func gb(_ mib: Int) -> String {
        let g = Double(mib) / 1024
        return g == g.rounded() ? "\(Int(g)) GB" : String(format: "%.1f GB", g)
    }

    static func show(_ j: [String: Any], _ key: String, absent: String) -> String {
        guard let v = j[key] else { return "(absent = \(absent))" }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        return "\(v)"
    }

    static func requireQuit() async throws {
        if await TweakHelpers.isProcessRunning("com.docker.backend") {
            throw TweakEngine.EngineError(message: "Quit Docker Desktop first (whale menu > Quit Docker Desktop); Keel does not edit its settings while it runs")
        }
    }

    /// Docker context and OrbStack: the settings above only affect Docker Desktop.
    static func contextValues() async -> [(String, String)] {
        var vals: [(String, String)] = [("Docker Desktop", await TweakHelpers.isProcessRunning("com.docker.backend") ? "running" : "not running")]
        let ctx = TweakHelpers.readJSON("\(NSHomeDirectory())/.docker/config.json")?["currentContext"] as? String
        if Machine.appInstalled("dev.kdrag0n.MacVirt") {
            vals.append(("OrbStack", "installed\(ctx == "orbstack" ? "; the docker CLI uses OrbStack, so this only matters when you run Docker Desktop" : "")"))
        }
        if let ctx { vals.append(("docker context", ctx)) }
        return vals
    }

    private static func fragment(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? absentMarker
    }

    private static func save(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: TweakHelpers.dockerStore), options: .atomic)
    }

    /// Records each key's previous value (or absence), keeps a copy of the whole file, writes the new values.
    static func write(_ values: [String: Any], tag: String) throws -> [String: String] {
        guard let j = TweakHelpers.readJSON(TweakHelpers.dockerStore) else { throw TweakEngine.EngineError(message: "Could not read Docker's settings-store.json") }
        var rec: [String: String] = ["keys": values.keys.sorted().joined(separator: ",")]
        for k in values.keys { rec["prev.\(k)"] = j[k].map(fragment) ?? absentMarker }
        let file = try TweakHelpers.editJSON(TweakHelpers.dockerStore, tag: tag) { obj in for (k, v) in values { obj[k] = v } }
        rec["copy"] = file["file"]
        ActivityLog.post(.command, "settings-store.json: " + values.keys.sorted().map { "\($0) = \(fragment(values[$0]!))" }.joined(separator: ", "))
        return rec
    }

    /// Puts back exactly the recorded keys. Records from older Keel versions (whole-file copies) restore the file.
    static func restore(_ rec: [String: String], keys defaults: [String]) throws {
        if rec["keys"] == nil, rec["path"] != nil, rec["file"] != nil {
            try TweakHelpers.restoreFile(rec)
            ActivityLog.post(.command, "restored settings-store.json from \(rec["file"] ?? "backup")")
            return
        }
        guard var j = TweakHelpers.readJSON(TweakHelpers.dockerStore) else { throw TweakEngine.EngineError(message: "Could not read Docker's settings-store.json") }
        let keys = rec["keys"].map { $0.split(separator: ",").map(String.init) } ?? defaults
        for k in keys {
            let prev = rec["prev.\(k)"] ?? absentMarker
            if prev != absentMarker, let d = prev.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
                j[k] = v
            } else {
                j.removeValue(forKey: k)
            }
        }
        try save(j)
        ActivityLog.post(.command, "settings-store.json: restored " + keys.joined(separator: ", "))
    }
}

// MARK: - SSH helpers

private enum DevSSH {
    static let dir = "\(NSHomeDirectory())/.ssh"
    static let config = "\(dir)/config"
    static let begin = "# >>> Keel: reuse SSH connections (remove this block or restore in Keel to undo) >>>"
    static let end = "# <<< Keel <<<"
    static let block = """
    \(begin)
    Host *
        ControlMaster auto
        ControlPath ~/.ssh/keel-cm-%C
        ControlPersist 10m
    \(end)
    """

    static func read() -> String? { try? String(contentsOfFile: config, encoding: .utf8) }
    static func hasBlock(_ text: String?) -> Bool { text?.contains(begin) ?? false }

    static func detect() async -> Detection {
        let text = read()
        var vals: [(String, String)] = [("~/.ssh/config", text == nil ? "absent" : (hasBlock(text) ? "has Keel's block" : "present"))]
        // `ssh -G` prints the effective options without connecting. It would also run `Match exec` commands
        // from the user's config, so it is skipped when the config has any (or includes other files).
        var effectiveOn: Bool? = nil
        let hasExec = text?.range(of: #"(?im)^\s*(match\s.*\bexec\b|include\s)"#, options: .regularExpression) != nil
        if !hasExec, let r = await Shell.probe("/usr/bin/ssh", ["-G", "github.com"]), r.ok {
            var opts: [String: String] = [:]
            for line in r.stdout.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { opts[parts[0]] = parts[1] }
            }
            let master = opts["controlmaster"] ?? "false", persist = opts["controlpersist"] ?? "no"
            vals.append(("effective ControlMaster (github.com)", master))
            vals.append(("effective ControlPersist", persist))
            effectiveOn = ["auto", "autoask", "true", "yes"].contains(master) && persist != "no" && persist != "false"
        }
        let on = effectiveOn ?? hasBlock(text)
        return Detection(state: on ? .on : .off, values: vals)
    }

    static func apply() throws -> [String: String] {
        let fm = FileManager.default
        let existing = read()
        if hasBlock(existing) { return ["created": "0"] }
        if !fm.fileExists(atPath: dir) { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var text = existing ?? ""
        let addedNewline = !text.isEmpty && !text.hasSuffix("\n")
        if addedNewline { text += "\n" }
        text += (text.isEmpty ? "" : "\n") + block + "\n"
        try text.write(toFile: config, atomically: true, encoding: .utf8)
        if existing == nil { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config) }
        ActivityLog.post(.command, "appended Keel's ControlMaster block to ~/.ssh/config")
        return ["created": existing == nil ? "1" : "0", "addedNewline": addedNewline ? "1" : "0"]
    }

    static func revert(_ rec: [String: String]) throws {
        guard var text = read() else { return }
        if let a = text.range(of: begin), let b = text.range(of: end, range: a.upperBound..<text.endIndex) {
            var upper = b.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            var lower = a.lowerBound
            // Also drop the blank line Keel inserted before the block.
            if lower > text.startIndex {
                let prev = text.index(before: lower)
                if text[prev] == "\n", prev > text.startIndex, text[text.index(before: prev)] == "\n" { lower = prev }
            }
            text.removeSubrange(lower..<upper)
            if rec["addedNewline"] == "1", text.hasSuffix("\n") { text.removeLast() }
        }
        if rec["created"] == "1" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(atPath: config)
            ActivityLog.post(.command, "removed ~/.ssh/config (Keel had created it)")
        } else {
            try text.write(toFile: config, atomically: true, encoding: .utf8)
            ActivityLog.post(.command, "removed Keel's block from ~/.ssh/config")
        }
    }
}

// MARK: - Homebrew helpers

private enum DevBrew {
    static let key = "HOMEBREW_NO_ANALYTICS"
    static var userEnv: String { "\(NSHomeDirectory())/.homebrew/brew.env" }
    static func prefixEnv(_ prefix: String) -> String { "\(prefix)/etc/homebrew/brew.env" }

    /// The file Keel writes: the prefix-specific one (it applies whatever $XDG_CONFIG_HOME is), else the user one.
    static func target() -> String? {
        guard let prefix = Machine.current.brewPrefix else { return nil }
        return FileManager.default.isWritableFile(atPath: "\(prefix)/etc") ? prefixEnv(prefix) : userEnv
    }

    static func detect() -> Detection {
        guard let prefix = Machine.current.brewPrefix else { return .na("Homebrew is not installed") }
        var vals: [(String, String)] = []
        var on = false
        for f in ["/etc/homebrew/brew.env", prefixEnv(prefix), userEnv] where FileManager.default.fileExists(atPath: f) {
            let v = TweakHelpers.readEnvFile(f)[key]
            vals.append((f.replacingOccurrences(of: NSHomeDirectory(), with: "~"), v.map { "\(key)=\($0)" } ?? "no \(key)"))
            if let v, !v.isEmpty { on = true }
        }
        let repoConfig = (try? String(contentsOfFile: "\(prefix)/.git/config", encoding: .utf8)) ?? ""
        let viaCommand = repoConfig.range(of: #"(?m)^\s*analyticsdisabled\s*=\s*true"#, options: .regularExpression) != nil
        vals.append(("brew analytics off", viaCommand ? "yes" : "no"))
        if vals.count == 1 { vals.insert(("brew.env", "none"), at: 0) }
        return Detection(state: on || viaCommand ? .on : .off, values: vals)
    }

    static func apply() throws -> [String: String] {
        guard let file = target() else { throw TweakEngine.EngineError(message: "Homebrew is not installed") }
        let prev = try TweakHelpers.setEnv(file, key: key, value: "1")
        ActivityLog.post(.command, "\(key)=1 → \(file)")
        return ["file": file, "previous": prev]
    }

    static func revert(_ rec: [String: String]) throws {
        let file = rec["file"] ?? target() ?? userEnv
        let prev = rec["previous"] ?? ""
        _ = try TweakHelpers.setEnv(file, key: key, value: prev.isEmpty ? nil : prev)
        ActivityLog.post(.command, prev.isEmpty ? "removed \(key) from \(file)" : "\(key)=\(prev) → \(file)")
    }
}

// MARK: - Spotlight helpers

private enum DevSpotlight {
    static let home = NSHomeDirectory()
    /// Common code folders. ~/Documents is privacy-protected, so its existence is inferred from Spotlight results only.
    static let knownRoots = ["Developer", "Documents/GitHub", "Projects", "Code", "src", "repos", "workspace", "dev", "GitHub", "git"].map { "\(home)/\($0)" }
    static let unprotectedRoots = knownRoots.filter { !$0.hasPrefix("\(home)/Documents/") }

    static func detect() async -> Detection {
        guard let r = try? await Shell.run("/usr/bin/mdfind", ["-onlyin", home, "kMDItemFSName == 'package.json'"], timeout: 30), r.ok else {
            return .unknown
        }
        let paths = r.stdout.split(separator: "\n").map(String.init)
        var inside: [String: Int] = [:]     // folder to add → indexed package.json files inside node_modules
        var total = 0
        for p in paths {
            guard let rg = p.range(of: "/node_modules/") else { continue }
            total += 1
            let repo = String(p[..<rg.lowerBound])
            let folder = knownRoots.first { repo == $0 || repo.hasPrefix($0 + "/") } ?? repo
            inside[folder, default: 0] += 1
        }
        let existing = unprotectedRoots.filter { FileManager.default.fileExists(atPath: $0) }
        if total == 0 && existing.isEmpty && !paths.contains(where: { p in knownRoots.contains { p.hasPrefix($0 + "/") } }) {
            return .na("No code folders found in your home folder")
        }
        let tilde: (String) -> String = { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        let top = inside.sorted { $0.value > $1.value }.prefix(8)
        var vals: [(String, String)] = [("package.json indexed inside node_modules", "\(total)"), ("package.json indexed in total", "\(paths.count)")]
        for (f, n) in top { vals.append((tilde(f), "\(n) inside node_modules")) }
        if total == 0 {
            return Detection(state: .on, values: vals, note: "Spotlight is not indexing any dependency trees.")
        }
        return Detection(state: .off, values: vals, note: "Add to Search Privacy: " + top.map { tilde($0.key) }.joined(separator: ", "))
    }
}
