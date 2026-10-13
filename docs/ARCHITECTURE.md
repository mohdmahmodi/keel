# Keel architecture (read this before writing code)

Keel targets **every Apple Silicon Mac on macOS 15, 26 and 27**: laptops and desktops, base/Pro/Max/Ultra chips,
8 GB to 512 GB of memory. Nothing may assume the author's machine. Every value that depends on hardware or on
installed software is read at runtime.

## Targets

| Target | Purpose |
|---|---|
| `KeelShared` | `PrivOp` (every root operation, allow-listed and validated), `PrivExecutor` (runs them, no shell), constants |
| `KeelHelper` | Root helper. `--xpc` as an SMAppService daemon (Developer ID builds), `run <base64>` one-shot via the admin prompt |
| `Keel` | The app |

## Core API

- `Machine.profile() async -> MachineProfile` and `Machine.current` (after first load). Fields: OS version,
  chip, perf/eff cores, memory, Metal working set, `hasBattery`, `powerSources`, `pmsetCapabilities`, Wi-Fi
  device/service, primary device/service, display max refresh, Xcode/CLT, Homebrew prefix, home, uid.
- `Requirement` (on `Tweak.requires`): `.laptop`, `.desktop`, `.xcode`, `.homebrew`, `.minMemoryGB(n)`,
  `.minMacOS(n)`, `.maxMacOS(n)`, `.pmsetCapability("highpowermode")`, `.app(bundleID:name:)`,
  `.anyPath([paths], name:)`, `.custom { await … -> String? }`. The first unmet one is the N/A reason shown to the user.
- `Prefs.value/string/write/delete(domain, key, currentHost:)`: in-process CFPreferences. Use instead of spawning `defaults`.
- `Sysctl.int/int64/string(name)`, `NetIf.isUp("awdl0")`: in-process.
- `Shell.run(path, args)` for commands with side effects; `Shell.probe(path, args)` for read-only commands
  (de-duplicated and cached for a few seconds across a detection pass). Always absolute executable paths.
- `Pmset.current()`: parsed `pmset -g custom`.
- `TweakHelpers`: JSON read/edit with backup (`editJSON`, `restoreFile`), `isProcessRunning`, Chrome/Docker paths,
  Ollama env-file helpers.
- `ActivityLog.post(level, message, detail:)` from any context.

## Writing a tweak

```swift
Tweak(id: "stable-id",                 // NEVER rename an existing id: users have recorded originals under it
      name: "Short name",
      category: .network,
      summary: "One line, plain, no hype.",
      explanation: "Long text for the drawer: what it changes, why, measured effect, caveats.",
      risk: .safe | .low | .medium,
      impact: .high | .medium | .low | .cosmetic,   // be honest: most animation keys are .cosmetic
      recommended: true | false,                    // recommended = safe for almost everyone, real benefit
      mechanism: …,
      sources: ["https://support.apple.com/…", "Local check (macOS 27.0): what you verified"],
      requires: [.laptop],
      confidence: .high | .medium | .low,
      expectedBenefit: "…", tradeoff: "What you give up")
```

Mechanisms (the engine records the original, applies, verifies, and auto-restores on mismatch):

- `.defaults([DefaultsSetting], post: .killDock)`: user preference keys. `off: nil` means "delete key" when no
  original was recorded. `currentHost: true` for ByHost domains. Never target protected domains
  (`com.apple.universalaccess`, sandboxed app containers like Safari/Mail): use `.manual` with a deep link.
- `.pmset([PmsetSetting(key:on:off:scope:)])`: scope `.battery` tweaks are automatically N/A on desktops.
- `.sysctl(name:, value: { machine in Int }, persist: Bool)`: value computed per machine.
- `.launchd([LaunchdItem(label:plistPath:domain:)])`: `.user` (~/Library/LaunchAgents), `.globalAgent`
  (/Library/LaunchAgents), `.system` (/Library/LaunchDaemons). Reversible: plists go to Keel's backups.
- `.custom(CustomMechanism(detect:apply:revert:applyCommands:revertCommands:needsAdmin:))`:
  `apply` receives an `ApplyContext`: record whatever you need to undo (return it as `[String: String]`), make
  user-level changes directly, and queue root work with `ctx.privileged(PrivOp…)` — it runs together with the
  rest of the batch under one prompt. `ctx.afterPrivileged { }` for user steps that must follow root steps.
  `ctx.post(.killDock)` to request one restart. `revert(ctx, recorded)` gets the dictionary back (empty if
  nothing was recorded: then restore the documented default). Detection must be fast and side-effect free.
- `.manual(ManualMechanism(detect:settingsURL:instructions:))`: only the user can change it; detect live and deep-link.

Root work is only possible through `PrivOp` cases in `Sources/KeelShared/PrivOp.swift`. If you need one that does
not exist, do not add it: say so in your report and use `.manual` meanwhile.

## Rules

- Detection is read-only, fast (prefer in-process reads and `Shell.probe`), and never prompts (no `sfltool`,
  nothing that triggers TCC or an admin dialog).
- Copy is short, plain and specific. No hype words. Numbers only when measured, with the source.
- Never rename a tweak ID: users may have recorded originals under it, and restoring needs the same ID.
- macOS 27 is the machine you can test on. Guard anything version-specific with `.minMacOS`/`.maxMacOS`.
