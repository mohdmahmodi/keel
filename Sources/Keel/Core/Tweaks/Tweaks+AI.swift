import Foundation
import KeelShared

extension TweakCatalog {
    static let ai: [Tweak] = [gpuWiredLimit] + ollama + [lmStudio, llamaCppKV, modelsOnExternalDrive]

    private typealias H = TweakHelpers

    // MARK: - GPU wired memory limit

    private static var gpuWiredLimit: Tweak {
        let mem = H.memsizeNow
        let target = H.wiredTargetMiB(memoryBytes: mem)
        let reserve = H.wiredReserveGiB(memoryBytes: mem)
        let estDefaultMiB = Int(Double(mem) * (mem >= 36 * H.gib ? 0.75 : 0.74) / 1_048_576)
        let name = H.wiredLimitSysctl
        return Tweak(
            id: "gpu-wired-limit",
            name: "GPU memory for local AI: \(target / 1024) GiB",
            category: .ai,
            summary: "Lets Ollama, LM Studio and MLX keep up to \(target / 1024) GiB of a model on the GPU, leaving \(reserve) GiB to macOS.",
            explanation: """
            The GPU may keep more of this Mac's memory for AI models, so a model slightly too large for the default budget \
            runs entirely on the GPU instead of partly on the much slower CPU. Metal reports the GPU's budget as \
            recommendedMaxWorkingSetSize (about 74 % of memory below 36 GB, 75 % above), and Ollama, llama.cpp, LM Studio and \
            MLX all treat it as the GPU's memory. Keel raises it to \(target) MiB with the iogpu.wired_limit_mb sysctl, leaving \
            one eighth of memory and at least 4 GiB to macOS; because the sysctl resets at restart, Keel also installs a \
            LaunchDaemon (a small system job) that sets it again at boot, and replaces any daemon left by Keel v1. It only \
            matters for models whose weights plus context fall between the two budgets, such as a 27–32B model at 4-bit on a \
            24 GB Mac, and it is the only way to give MLX more, since mx.set_wired_limit cannot go above it. Wired memory \
            cannot be swapped, and reports on macOS 26 describe kernel panics at limits that left 3 GB or less, so watch memory \
            pressure while a large model is loaded. Keel restarts Ollama after a change; restart LM Studio yourself.
            """,
            risk: .medium, impact: .medium, recommended: false,
            mechanism: .custom(CustomMechanism(
                detect: {
                    let m = await Machine.profile()
                    guard let live = Sysctl.int(name) else { return .na("\(name) does not exist on this macOS") }
                    let target = H.wiredTargetMiB(memoryBytes: m.memoryBytes)
                    let fm = FileManager.default
                    let newExists = fm.fileExists(atPath: H.wiredDaemonPath)
                    let legacyExists = fm.fileExists(atPath: H.legacyWiredDaemonPath)
                    let daemonValue = newExists ? H.daemonWiredValue(H.wiredDaemonPath) : (legacyExists ? H.daemonWiredValue(H.legacyWiredDaemonPath) : nil)
                    let persisted = newExists || legacyExists
                    let defaultBytes = H.defaultGPUBudgetBytes(m)
                    let defaultMiB = Int(defaultBytes / 1_048_576)
                    if live == 0 && !persisted {
                        if m.memoryGB < 16 { return .na("Needs at least 16 GB of memory (this Mac has \(m.memoryGB) GB); models that fit in less gain nothing") }
                        if target - defaultMiB < 1024 {
                            return .na("Leaving \(H.wiredReserveGiB(memoryBytes: m.memoryBytes)) GiB to macOS allows \(H.gibString(mib: target)), only \(target - defaultMiB) MiB more than the default \(H.gibString(defaultBytes))")
                        }
                    }
                    let pressure = H.memoryPressure()
                    var daemon = "none (resets at restart)"
                    if newExists { daemon = "\(H.wiredDaemonLabel) → \(daemonValue.map(String.init) ?? "?")" }
                    else if legacyExists { daemon = "\(H.legacyWiredDaemonLabel) (Keel v1) → \(daemonValue.map(String.init) ?? "?")" }
                    let values: [(String, String)] = [
                        (name, live == 0 ? "0 (kernel default)" : "\(live) MiB"),
                        ("Keel target", "\(target) MiB = \(H.gibString(mib: target)), leaves \(H.wiredReserveGiB(memoryBytes: m.memoryBytes)) GiB"),
                        ("GPU budget now (Metal)", H.gibString(H.currentGPUBudgetBytes(m))),
                        ("default budget", "\(H.gibString(defaultBytes))\(live == 0 ? "" : " (estimated)")"),
                        ("gain at target", "+\(H.gibString(mib: max(0, target - defaultMiB)))"),
                        ("boot LaunchDaemon", daemon),
                        ("memory pressure", pressure.summary),
                        ("MLX", H.mlxInstallLocation() ?? "not installed"),
                    ]
                    var notes: [String] = []
                    if !pressure.isNormal && pressure.level != 0 {
                        notes.append("Memory pressure is \(pressure.label) now: apps already need more memory than is free. A higher GPU limit lets a model take more, so quit apps before loading a large model\(pressure.level == 4 ? ". Keel does not raise the limit while pressure is critical" : "").")
                    }
                    if legacyExists && !newExists { notes.append("The boot daemon was installed by Keel v1. Turning this off removes it; turning it on again installs the current one.") }
                    if live != 0 && live != target && live != daemonValue { notes.append("Set to \(live) MiB by something other than Keel.") }
                    if live != 0 && !persisted { notes.append("Not persisted: the limit returns to the default at the next restart.") }
                    let state: TweakState
                    if live == target && persisted && (daemonValue == nil || daemonValue == target) { state = .on }
                    else if live == 0 && !persisted { state = .off }
                    else { state = .partlyOn }
                    return Detection(state: state, values: values, note: notes.isEmpty ? nil : notes.joined(separator: " "))
                },
                apply: { ctx in
                    let m = ctx.machine
                    let target = H.wiredTargetMiB(memoryBytes: m.memoryBytes)
                    guard m.memoryGB >= 16, target >= 2048, target <= m.memoryMB - 2048 else { throw TweakEngine.EngineError(message: "No safe GPU limit for \(m.memoryGB) GB") }
                    if H.memoryPressure().level == 4 { throw TweakEngine.EngineError(message: "Memory pressure is critical. Quit some apps and try again.") }
                    let fm = FileManager.default
                    let newExists = fm.fileExists(atPath: H.wiredDaemonPath), legacyExists = fm.fileExists(atPath: H.legacyWiredDaemonPath)
                    let rec: [String: String] = [
                        "name": name, "value": String(Sysctl.int(name) ?? 0), "target": String(target),
                        "daemonExisted": newExists ? "1" : "0",
                        "legacyDaemonExisted": legacyExists ? "1" : "0",
                        "daemonValue": (newExists ? H.daemonWiredValue(H.wiredDaemonPath) : legacyExists ? H.daemonWiredValue(H.legacyWiredDaemonPath) : nil).map(String.init) ?? "",
                    ]
                    ctx.privileged(.sysctl(name: name, value: target))
                    if legacyExists {
                        ctx.privileged([.launchctl(verb: "bootout", domain: "system", target: H.legacyWiredDaemonLabel), .removeFile(path: H.legacyWiredDaemonPath)])
                    }
                    ctx.privileged(.installSysctlDaemon(name: name, value: target))
                    ctx.afterPrivileged { await H.restartOllamaIfRunning() }
                    return rec
                },
                revert: { ctx, orig in
                    let mem = ctx.machine.memoryMB
                    let raw = Int(orig["value"] ?? "") ?? SysctlDefaults.value(for: name)
                    let prev = (raw == 0 || (raw >= 2048 && raw <= mem - 2048)) ? raw : 0
                    ctx.privileged(.sysctl(name: name, value: prev))
                    // Records from older Keel releases refer to the legacy label; either way a daemon existed before Keel changed it.
                    let wasPersisted = orig["daemonExisted"] == "1" || orig["legacyDaemonExisted"] == "1"
                    if wasPersisted && prev != 0 { ctx.privileged(.installSysctlDaemon(name: name, value: prev)) }
                    else { ctx.privileged(.removeSysctlDaemon(name: name)) }
                    if FileManager.default.fileExists(atPath: H.legacyWiredDaemonPath) {
                        ctx.privileged([.launchctl(verb: "bootout", domain: "system", target: H.legacyWiredDaemonLabel), .removeFile(path: H.legacyWiredDaemonPath)])
                    }
                    ctx.afterPrivileged { await H.restartOllamaIfRunning() }
                },
                applyCommands: [
                    "sudo sysctl -w \(name)=\(target)",
                    "sudo launchctl bootout system/\(H.legacyWiredDaemonLabel); sudo rm \(H.legacyWiredDaemonPath)  # only if Keel v1's daemon exists",
                    "sudo install /Library/LaunchDaemons/\(H.wiredDaemonLabel).plist  # runs sysctl -w \(name)=\(target) at boot",
                    "brew services restart ollama / reopen Ollama.app  # only if running",
                ],
                revertCommands: [
                    "sudo sysctl -w \(name)=<recorded original, 0 = default>",
                    "sudo launchctl bootout system/\(H.wiredDaemonLabel); sudo rm /Library/LaunchDaemons/\(H.wiredDaemonLabel).plist",
                    "sudo launchctl bootout system/\(H.legacyWiredDaemonLabel); sudo rm \(H.legacyWiredDaemonPath)  # if present",
                ],
                needsAdmin: true)),
            sources: ["Local check: macOS 27.0.1 (26A434), 24 GB M4 Pro: iogpu.wired_limit_mb read live; Metal budget 17.76 GiB at 0, 20.00 GiB at 20480",
                      "https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize",
                      "https://github.com/ggml-org/llama.cpp/discussions/2182",
                      "https://github.com/ggml-org/llama.cpp/issues/19825",
                      "https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.set_wired_limit.html"],
            confidence: .high,
            expectedBenefit: "About \(H.gibString(mib: max(0, target - estDefaultMiB))) more room for models on the GPU. A model that was split between CPU and GPU loads fully on the GPU and can generate several times faster; models that already fit run the same.",
            tradeoff: "While a large model is loaded, only \(reserve) GiB is left for macOS and your apps; with many apps open the Mac starts to swap.")
    }

    // MARK: - Ollama

    private static let ollamaSources = ["https://docs.ollama.com/faq", "https://github.com/ollama/ollama/blob/main/envconfig/config.go"]

    private static var ollama: [Tweak] {
        let ctxTarget = H.memsizeNow < 15 * H.gib ? 8192 : 16384
        return [
            H.ollamaEnvTweak(
                id: "ollama-flash-attention-kv", name: "Ollama: flash attention + q8_0 KV cache",
                summary: "Halves the memory Ollama needs for a conversation's context. Homebrew's service already sets both.",
                explanation: """
                Ollama stores each conversation's working memory (the KV cache) in 8 bits instead of 16, which halves the \
                memory it takes. Keel sets OLLAMA_KV_CACHE_TYPE=q8_0 and OLLAMA_FLASH_ATTENTION=1, which q8_0 requires; Ollama's \
                FAQ describes the precision loss as very small. Homebrew's ollama formula already sets both for its service, so a \
                Homebrew install usually shows this as on. For Ollama.app, Keel uses launchctl setenv plus a login agent \
                (com.keel.ollama-env) that repeats it at each login, because launchctl values are cleared at logout. Models that \
                cannot use flash attention keep a 16-bit cache; q4_0 counts as on but Keel never sets it, because its loss shows at long context.
                """,
                risk: .safe, impact: .medium, recommended: true,
                benefit: "Longer conversations or a larger model fit in memory, because the context cache takes half the space.",
                tradeoff: "A very small loss of precision in the cache. Nothing noticeable in normal use.",
                sources: ollamaSources + ["https://github.com/Homebrew/homebrew-core/blob/master/Formula/o/ollama.rb"],
                values: { _ in [("OLLAMA_FLASH_ATTENTION", "1"), ("OLLAMA_KV_CACHE_TYPE", "q8_0")] },
                matches: { key, target, cur in
                    guard let cur = cur?.lowercased() else { return false }
                    if key == "OLLAMA_FLASH_ATTENTION" { return ["1", "true"].contains(cur) }
                    if key == "OLLAMA_KV_CACHE_TYPE" { return cur == "q8_0" || cur == "q4_0" }
                    return cur == target
                }),

            H.ollamaEnvTweak(
                id: "ollama-context-16k", name: "Ollama: \(ctxTarget / 1024)K default context",
                summary: "Ollama reads up to \(ctxTarget) tokens by default instead of 4096, so long prompts are no longer cut without warning.",
                explanation: """
                Ollama reads up to \(ctxTarget) tokens of a conversation by default instead of 4096. Ollama sizes its default \
                from the GPU budget (4096 tokens below 23 GiB, 32768 from 23 GiB, 262144 from 47 GiB, per server/routes.go) and \
                drops the oldest part of a longer prompt without an error. Keel sets OLLAMA_CONTEXT_LENGTH in \
                ~/.homebrew/services/ollama.env, which survives brew upgrades, and through launchctl for Ollama.app. Where Ollama \
                already defaults higher this does not apply, because an explicit value turns off Ollama's automatic reduction when \
                a model does not fit. Once you move Ollama.app's Settings > Context length slider, that setting overrides this one, and a request's num_ctx still wins.
                """,
                risk: .low, recommended: false, confidence: .high,
                benefit: "Long prompts, files and chat histories up to \(ctxTarget) tokens are no longer cut off without warning.",
                tradeoff: "Each loaded model uses more memory for its context, about 1 GB for an 8B model at 16K with the 8-bit cache.",
                sources: ollamaSources + ["https://docs.ollama.com/context-length", "https://github.com/ollama/ollama/blob/main/server/routes.go",
                                          "https://github.com/ollama/ollama/blob/main/server/sched.go", "https://github.com/ollama/ollama/blob/main/app/server/server.go"],
                appBlocked: {
                    if let s = await H.ollamaAppSettings(), s.contextLength > 0 {
                        return "Ollama.app's Settings > Context length is set to \(s.contextLength), which overrides the environment. Change it there."
                    }
                    return nil
                },
                values: { m in [("OLLAMA_CONTEXT_LENGTH", String(m.memoryBytes < 15 * H.gib ? 8192 : 16384))] },
                applicability: { m in
                    let overhead = UInt64(H.ollamaEffectiveEnv()["OLLAMA_GPU_OVERHEAD"] ?? "") ?? 0
                    let budget = H.currentGPUBudgetBytes(m)
                    let auto = H.ollamaAutoContext(budgetBytes: budget, overheadBytes: overhead)
                    let target = m.memoryBytes < 15 * H.gib ? 8192 : 16384
                    if auto >= target { return "Ollama already defaults to \(auto) tokens here (GPU budget \(H.gibString(budget))) and lowers it when a model does not fit" }
                    return nil
                },
                extraValues: { m in
                    let overhead = UInt64(H.ollamaEffectiveEnv()["OLLAMA_GPU_OVERHEAD"] ?? "") ?? 0
                    let budget = H.currentGPUBudgetBytes(m)
                    return [("Ollama's automatic default", "\(H.ollamaAutoContext(budgetBytes: budget, overheadBytes: overhead)) tokens (GPU budget \(H.gibString(budget)))")]
                }),

            H.ollamaEnvTweak(
                id: "ollama-keep-alive-30m", name: "Ollama: keep model loaded 30 min",
                summary: "Ollama keeps the last model loaded for 30 minutes instead of 5, so the next prompt does not wait for a reload.",
                explanation: """
                The last model you used stays in memory for 30 minutes instead of 5, so the next prompt starts without a load. \
                Loading takes from about a second to tens of seconds, depending on the model's size and the disk. Keel sets \
                OLLAMA_KEEP_ALIVE=30m; a request's keep_alive still overrides it, and `ollama stop <model>` unloads a model at once.
                """,
                risk: .low, recommended: false,
                benefit: "No loading pause when your prompts are less than 30 minutes apart.",
                tradeoff: "The model's memory stays in use for 30 minutes after you stop using it.",
                sources: ollamaSources + [],
                values: { _ in [("OLLAMA_KEEP_ALIVE", "30m")] },
                applicability: { m in m.memoryGB < 16 ? "With \(m.memoryGB) GB, holding an idle model for 30 minutes leaves too little memory for apps" : nil }),

            H.ollamaEnvTweak(
                id: "ollama-gpu-overhead", name: "Ollama: keep 1 GiB of the GPU budget free",
                summary: "After the GPU memory limit is raised, Ollama leaves its last GiB free when deciding how much of a model fits.",
                explanation: """
                Ollama leaves 1 GiB of the GPU memory budget unused when it decides how much of a model fits. Keel sets \
                OLLAMA_GPU_OVERHEAD to 1 GiB in bytes; Ollama subtracts it in that fit check and when it picks its default \
                context. After the GPU memory limit is raised, the budget Ollama sees is close to all of memory, and this keeps a \
                margin for WindowServer and your apps. At the default limit it adds nothing, since about a quarter of memory is \
                already left to macOS.
                """,
                risk: .safe, recommended: false, confidence: .medium,
                benefit: "The Mac stays responsive when a model nearly fills the raised GPU limit.",
                tradeoff: "Ollama plans with 1 GiB less, so a model that barely fit may run partly on the CPU.",
                sources: ollamaSources + [],
                values: { _ in [("OLLAMA_GPU_OVERHEAD", "1073741824")] },
                applicability: { _ in (Sysctl.int(H.wiredLimitSysctl) ?? 0) == 0 ? "Only useful after the GPU memory limit is raised (it is at the default)" : nil },
                extraValues: { _ in [(H.wiredLimitSysctl, String(Sysctl.int(H.wiredLimitSysctl) ?? 0))] }),

            H.ollamaEnvTweak(
                id: "ollama-max-loaded-models-1", name: "Ollama: one model in memory at a time",
                summary: "Ollama holds one model in memory instead of up to 3, so switching models frees memory at once.",
                explanation: """
                Ollama keeps only one model in memory at a time. OLLAMA_MAX_LOADED_MODELS defaults to 3 per GPU, and Ollama \
                already unloads a model when the next one does not fit (server/sched.go), so this does not make generation faster. \
                What changes is that a model you switch away from is unloaded at once instead of when its keep-alive ends, which \
                returns that memory to other apps on Macs with 32 GB or less. Leave it off if a tool uses two models together, \
                such as an embedding model and a chat model.
                """,
                risk: .low, recommended: false, confidence: .medium,
                benefit: "Switching models frees the old model's memory immediately instead of minutes later.",
                tradeoff: "Tools that use two models together (embeddings plus chat) reload a model on every switch.",
                sources: ollamaSources + ["https://github.com/ollama/ollama/blob/main/server/sched.go"],
                values: { _ in [("OLLAMA_MAX_LOADED_MODELS", "1")] },
                applicability: { m in m.memoryGB > 32 ? "With \(m.memoryGB) GB, Ollama's default (up to 3 models, unloaded when they do not fit) is fine" : nil }),

            H.ollamaEnvTweak(
                id: "ollama-localhost-only", name: "Ollama: reachable only from this Mac",
                summary: "Ollama accepts connections only from this Mac. It has no password, so on the network anyone could use your models.",
                explanation: """
                The Ollama server accepts connections only from this Mac. Ollama's API has no authentication, so any device that \
                can reach port 11434 can run prompts and download or delete models. OLLAMA_HOST is unset by default, which means \
                127.0.0.1, so this usually shows as on; it shows as off when OLLAMA_HOST was set to 0.0.0.0 or a network address. \
                Turning it on sets 127.0.0.1:11434, turning it off restores the recorded value, and Keel also shows the address the \
                server is actually listening on. Ollama.app's Settings > Expose Ollama to the network overrides the environment and \
                has to be turned off there.
                """,
                risk: .safe, impact: .low, recommended: false, confidence: .high,
                benefit: "Other devices on your network can no longer use or change your local models.",
                tradeoff: "Using Ollama from another device, such as a phone or a second computer, stops working.",
                sources: ollamaSources + ["https://github.com/ollama/ollama/blob/main/app/server/server.go"],
                appBlocked: {
                    if let s = await H.ollamaAppSettings(), s.expose {
                        return "Ollama.app's Settings > Expose Ollama to the network is on, so it listens on all addresses. Turn it off there."
                    }
                    return nil
                },
                values: { _ in [("OLLAMA_HOST", "127.0.0.1:11434")] },
                matches: { _, _, cur in H.isLoopbackHost(cur) },
                extraValues: { _ in
                    let addrs = await H.ollamaListenAddresses()
                    var v: [(String, String)] = [("listening on", addrs.isEmpty ? "nothing (Ollama not running)" : addrs.joined(separator: ", "))]
                    var origins = H.hasBrewOllama() ? H.ollamaEffectiveEnv()["OLLAMA_ORIGINS"] : nil
                    if origins == nil { origins = await H.launchdGetenv("OLLAMA_ORIGINS") }
                    if let origins { v.append(("OLLAMA_ORIGINS", origins + (origins.contains("*") ? " (any website you visit can call Ollama)" : ""))) }
                    return v
                }),

            ollamaNoCloud,
            ollamaServiceOnDemand,
        ]
    }

    /// ~/.ollama/server.json {"disable_ollama_cloud": true}: read by the server (envconfig NoCloud) and by Ollama.app.
    private static var ollamaNoCloud: Tweak {
        let key = "disable_ollama_cloud"
        return Tweak(
            id: "ollama-no-cloud", name: "Ollama: local only, no cloud models", category: .ai,
            summary: "Ollama refuses its cloud models and web search on ollama.com, so every prompt stays on this Mac.",
            explanation: """
            Ollama refuses cloud models and web search, so prompts stay on this Mac. Since version 0.12 Ollama can run \
            models tagged "cloud" on ollama.com servers and offers web search, and both appear alongside local models in the CLI \
            and in apps that use Ollama. Keel sets "disable_ollama_cloud": true in ~/.ollama/server.json, which the server \
            (envconfig.NoCloud) and Ollama.app both read, so it covers the Homebrew service, Ollama.app and `ollama serve` in a \
            terminal. Turning it off restores the file's previous value, and Ollama is restarted if it is running.
            """,
            risk: .safe, impact: .low, recommended: false,
            mechanism: .custom(CustomMechanism(
                detect: {
                    guard H.hasBrewOllama() || H.hasOllamaApp() || Shell.exists("\(H.home)/.ollama") else { return .na("Ollama is not installed") }
                    let cfg = H.readJSON(H.ollamaServerConfig)
                    let flag = cfg?[key] as? Bool ?? false
                    let envNoCloud = H.ollamaEffectiveEnv()["OLLAMA_NO_CLOUD"].map { ["1", "true"].contains($0.lowercased()) } ?? false
                    var vals: [(String, String)] = [("~/.ollama/server.json \(key)", cfg == nil ? "(no file: cloud allowed)" : String(flag))]
                    if envNoCloud { vals.append(("OLLAMA_NO_CLOUD (brew service)", "1")) }
                    return Detection(state: flag ? .on : (envNoCloud ? .partlyOn : .off), values: vals,
                                     note: envNoCloud && !flag ? "Only the Homebrew service has OLLAMA_NO_CLOUD. Ollama.app and a terminal `ollama serve` still allow cloud models." : nil)
                },
                apply: { _ in
                    let path = H.ollamaServerConfig
                    var cfg: [String: Any] = H.readJSON(path) ?? [:]
                    let existed = Shell.exists(path)
                    let prev = cfg[key].map { "\($0 as? Bool ?? false)" } ?? ""
                    cfg[key] = true
                    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
                    ActivityLog.post(.command, "set \(key)=true in \(path)")
                    await H.restartOllamaIfRunning()
                    return ["existed": existed ? "1" : "0", "previous": prev]
                },
                revert: { _, orig in
                    let path = H.ollamaServerConfig
                    var cfg: [String: Any] = H.readJSON(path) ?? [:]
                    switch orig["previous"] ?? "" {
                    case "true": cfg[key] = true
                    case "false": cfg[key] = false
                    default: cfg.removeValue(forKey: key)
                    }
                    if cfg.isEmpty && orig["existed"] != "1" {
                        if Shell.exists(path) { try FileManager.default.removeItem(atPath: path) }
                        ActivityLog.post(.command, "rm \(path)")
                    } else {
                        try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
                        ActivityLog.post(.command, "restored \(key) in \(path)")
                    }
                    await H.restartOllamaIfRunning()
                },
                applyCommands: ["set \"\(key)\": true in ~/.ollama/server.json", "restart Ollama if it is running"],
                revertCommands: ["restore \(key) in ~/.ollama/server.json (remove the file if Keel created it)", "restart Ollama if it is running"],
                needsAdmin: false)),
            sources: ["https://github.com/ollama/ollama/blob/main/envconfig/config.go", "https://github.com/ollama/ollama/blob/main/app/store/cloud_config.go",
                      "Local check: the Ollama 0.24.0 binary (Homebrew) contains the disable_ollama_cloud JSON key",
                      "https://docs.ollama.com/faq"],
            confidence: .high,
            expectedBenefit: "Nothing you type into Ollama is sent to ollama.com, even by a tool that picks a cloud model.",
            tradeoff: "Cloud models and Ollama's web search stop working.")
    }

    private static var ollamaServiceOnDemand: Tweak {
        Tweak(id: "ollama-service-on-demand", name: "Ollama service: start it only when needed", category: .ai,
              summary: "Homebrew's Ollama service no longer starts at login or restarts itself; start it when you need it.",
              explanation: """
              Homebrew's Ollama server no longer starts at login, so it runs only when you start it. `brew services start \
              ollama` loads a LaunchAgent (a per-user background job) with RunAtLoad and KeepAlive, so `ollama serve` starts at \
              login and restarts if it quits. Idle, it uses little CPU, but a loaded model stays in memory until its keep-alive \
              ends. Turning this on runs `brew services stop ollama`; turning it off runs `brew services start ollama`.
              """,
              risk: .safe, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: {
                    guard H.hasBrewOllama() else { return .na("Ollama (Homebrew) is not installed") }
                    let loaded = await H.ollamaBrewServiceLoaded()
                    let running = await H.isProcessRunning("ollama")
                    let models = await H.ollamaModelCount()
                    return Detection(state: loaded ? .off : .on,
                                     values: [("launchd agent \(H.ollamaBrewLabel)", loaded ? "loaded (starts at login, KeepAlive)" : "not loaded"),
                                              ("ollama process", running ? "running" : "not running"),
                                              ("models", "\(models.count) (\(models.source))")],
                                     note: !loaded && running ? "An ollama process is running outside the Homebrew service (Ollama.app or a terminal)." : nil)
                },
                apply: { _ in
                    let r = try await Shell.run("\(H.brewOllamaPrefix)/bin/brew", ["services", "stop", "ollama"], timeout: 60)
                    ActivityLog.post(.command, "brew services stop ollama", detail: r.combined)
                    await ProbeCache.shared.invalidate()
                    return ["was": "loaded"]
                },
                revert: { _, _ in
                    let r = try await Shell.run("\(H.brewOllamaPrefix)/bin/brew", ["services", "start", "ollama"], timeout: 60)
                    ActivityLog.post(.command, "brew services start ollama", detail: r.combined)
                    await ProbeCache.shared.invalidate()
                },
                applyCommands: ["brew services stop ollama"], revertCommands: ["brew services start ollama"], needsAdmin: false)),
              sources: ["https://docs.brew.sh/Manpage", "https://github.com/ollama/ollama/blob/main/docs/faq.md"],
              expectedBenefit: "No Ollama server runs in the background when you are not using local models.",
              tradeoff: "Apps that call Ollama at localhost:11434 fail until you run `brew services start ollama`.")
    }

    // MARK: - LM Studio

    private static var lmStudio: Tweak {
        let gb = Double(H.memsizeNow) / Double(H.gib)
        let ctx = gb <= 16.5 ? 8192 : (gb <= 32.5 ? 16384 : 32768)
        return Tweak(
            id: "lmstudio-settings", name: "LM Studio load settings for this Mac", category: .ai,
            summary: "Lists the LM Studio load settings that suit this Mac: full GPU offload, flash attention, 8-bit cache, context size.",
            explanation: """
            Keel lists the LM Studio load settings that run models fully on this Mac's GPU with the least memory. LM Studio \
            stores them per model (My Models > gear icon) and uses them in the app, for `lms load` and for its API; Keel reads the \
            install, the models folder from settings.json and the models in it, but does not change load settings. Set GPU \
            Offload to max, because memory is shared and layers kept on the CPU only run slower, then turn Flash Attention On \
            and set K and V cache quantization to Q8_0, which halves cache memory. Use a context length of \(ctx) and prefer MLX \
            builds (mlx-community) where one exists; third-party benchmarks usually find them faster than GGUF on Apple silicon. \
            Keep "Auto unload unused JIT models" on in Developer > Server Settings, and restart LM Studio after changing the GPU memory limit.
            """,
            risk: .safe, recommended: false,
            mechanism: .manual(ManualMechanism(
                detect: {
                    let app = H.lmStudioAppURL()
                    let lmHome = H.lmStudioHome()
                    guard app != nil || lmHome != nil else { return .na("LM Studio is not installed") }
                    let m = await Machine.profile()
                    var vals: [(String, String)] = []
                    if let app {
                        let v = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
                        vals.append(("LM Studio.app", "\(app.path)\(v.map { " (\($0))" } ?? "")"))
                    } else { vals.append(("LM Studio.app", "not found (CLI or headless install)")) }
                    var notes: [String] = []
                    if let lmHome {
                        vals.append(("data folder", lmHome))
                        vals.append(("lms CLI", FileManager.default.isExecutableFile(atPath: "\(lmHome)/bin/lms") ? "\(lmHome)/bin/lms" : "not installed"))
                        let models = H.lmStudioModels(lmHome)
                        vals.append(("models in \(H.lmStudioModelsFolder(lmHome))", "\(models.total) (MLX \(models.mlx), GGUF \(models.gguf)), \(H.gibString(models.bytes))"))
                        if models.gguf > 0 && models.mlx == 0 { notes.append("All your models are GGUF. An MLX build of the same model is usually faster on Apple silicon.") }
                        let presets = (try? FileManager.default.contentsOfDirectory(atPath: "\(lmHome)/config-presets"))?.filter { $0.hasSuffix(".json") }.count ?? 0
                        vals.append(("presets", "\(presets)"))
                    }
                    vals.append(("running", H.lmStudioRunning() ? "yes" : "no"))
                    vals.append(("GPU budget now (Metal)", H.gibString(H.currentGPUBudgetBytes(m))))
                    let c = m.memoryGB <= 16 ? 8192 : (m.memoryGB <= 32 ? 16384 : 32768)
                    notes.insert("Check each model's load settings in LM Studio: GPU offload max, Flash Attention On, K/V cache Q8_0, context \(c).", at: 0)
                    return Detection(state: .unknown, values: vals, note: notes.joined(separator: " "))
                },
                settingsURL: H.lmStudioAppURL()?.absoluteString ?? "",
                instructions: """
                LM Studio > My Models > gear icon next to each model: GPU Offload = max, Flash Attention = On, \
                K Cache and V Cache Quantization = Q8_0, Context Length = \(ctx). Prefer MLX builds. \
                CLI: lms load <model> --gpu max --context-length \(ctx) --ttl 1800
                """)),
            sources: ["https://lmstudio.ai/docs/app/advanced/per-model",
                      "https://github.com/lmstudio-ai/lmstudio-js/blob/main/packages/lms-common-server/src/findLMStudioHome.ts",
                      "https://github.com/lmstudio-ai/lms/blob/main/src/subcommands/importCmd.ts",
                      "https://lmstudio.ai/docs/app/api/ttl-and-auto-evict", "https://lmstudio.ai/docs/cli", "https://lmstudio.ai/blog/lmstudio-v0.3.4"],
            confidence: .medium,
            expectedBenefit: "Models run entirely on the GPU and their context takes half the memory, so larger models and longer chats fit.",
            tradeoff: "The 8-bit cache loses a very small amount of precision. Nothing noticeable in normal use.")
    }

    // MARK: - llama.cpp

    private static var llamaCppKV: Tweak {
        Tweak(
            id: "llamacpp-kv-cache-q8", name: "llama.cpp server: 8-bit KV cache", category: .ai,
            summary: "llama-server keeps conversation context in 16-bit by default. Two options halve that memory.",
            explanation: """
            Storing the KV cache in 8 bits halves the memory llama.cpp's server uses for conversation context. llama-server \
            uses f16 by default; -ctk q8_0 -ctv q8_0 (or the environment variables LLAMA_ARG_CACHE_TYPE_K and \
            LLAMA_ARG_CACHE_TYPE_V) change that, and flash attention, which the V setting needs, is on automatically where \
            supported (-fa auto). Recent builds already fit context and GPU layers to memory (--fit, on by default), so -ngl and \
            -c rarely need setting on Apple silicon. These are launch options, so Keel detects the install and shows them; it \
            does not change how you start the server.
            """,
            risk: .safe, recommended: false,
            mechanism: .manual(ManualMechanism(
                detect: {
                    guard let bin = H.llamaServerPath() else { return .na("llama.cpp (llama-server) is not installed") }
                    return Detection(state: .unknown, values: [("llama-server", bin)],
                                     note: "Start it with: llama-server -m <model.gguf> -ctk q8_0 -ctv q8_0")
                },
                settingsURL: "",
                instructions: "llama-server -m <model.gguf> -ctk q8_0 -ctv q8_0   (or export LLAMA_ARG_CACHE_TYPE_K=q8_0 LLAMA_ARG_CACHE_TYPE_V=q8_0)")),
            sources: ["https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md"],
            confidence: .high,
            expectedBenefit: "The same model fits a context about twice as long, or leaves more memory for other apps.",
            tradeoff: "A very small loss of precision in the cache. Nothing noticeable in normal use.")
    }

    // MARK: - Model storage

    private static var modelsOnExternalDrive: Tweak {
        Tweak(
            id: "ai-models-external-ssd", name: "Keep large local models on an external SSD", category: .ai,
            summary: "Local models can take tens of GB of the internal disk. Ollama, LM Studio and MLX can load them from an SSD.",
            explanation: """
            Downloaded AI models can live on an external SSD instead of the internal disk; Keel shows how much space they take \
            and where each app looks for them. Ollama reads the folder from OLLAMA_MODELS \
            (in ~/.homebrew/services/ollama.env, or Settings > Model location in Ollama.app), LM Studio from My Models > Change, \
            and Hugging Face tools such as mlx-lm and transformers from HF_HOME, set in your shell profile \
            (default ~/.cache/huggingface). Generation speed does not change once a model is loaded; loading reads from the \
            drive, so a slow USB drive makes loads slower. The drive has to be connected before the server starts, or Ollama \
            lists no models.
            """,
            risk: .safe, impact: .low, recommended: false,
            mechanism: .manual(ManualMechanism(
                detect: {
                    var dirs: [(String, String)] = []
                    let fm = FileManager.default
                    let ollamaDir = await H.ollamaModelsDir()
                    if fm.fileExists(atPath: ollamaDir) { dirs.append(("Ollama models", ollamaDir)) }
                    if let lm = H.lmStudioHome() {
                        let f = H.lmStudioModelsFolder(lm)
                        if fm.fileExists(atPath: f) { dirs.append(("LM Studio models", f)) }
                    }
                    let hf = "\(H.home)/.cache/huggingface/hub"
                    if fm.fileExists(atPath: hf) { dirs.append(("Hugging Face cache", hf)) }
                    guard !dirs.isEmpty else { return .na("No local model folders found") }
                    var total: UInt64 = 0
                    var onInternal: UInt64 = 0
                    var vals: [(String, String)] = []
                    for (label, path) in dirs {
                        let size = H.directorySize(path)
                        total += size
                        let external = URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix("/Volumes/")
                        if !external { onInternal += size }
                        vals.append((label, "\(path): \(H.gibString(size))\(external ? " (external)" : "")"))
                    }
                    let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
                    vals.append(("internal disk free", H.gibString(UInt64(max(0, free)))))
                    if total < 20 * H.gib { return Detection(state: .notApplicable, values: vals, note: "Local models take \(H.gibString(total)); moving them saves little.") }
                    return Detection(state: onInternal == 0 ? .on : .off, values: vals)
                },
                settingsURL: URL(fileURLWithPath: "\(H.home)/.ollama/models").absoluteString,
                instructions: "Move the models folder to an APFS SSD, then point the app at it: OLLAMA_MODELS in ~/.homebrew/services/ollama.env or Settings > Model location (Ollama.app); My Models > Change (LM Studio); export HF_HOME=/Volumes/<drive>/huggingface in ~/.zshrc (Hugging Face, MLX).")),
            sources: ["https://docs.ollama.com/faq", "https://lmstudio.ai/docs/app/advanced/import-model",
                      "https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables"],
            confidence: .high,
            expectedBenefit: "Frees the internal disk space your models use, often tens of gigabytes.",
            tradeoff: "Models are available only while the drive is connected, and they load as fast as the drive reads.")
    }
}
