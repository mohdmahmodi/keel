# Keel

Keel is a native macOS app (Swift and SwiftUI, no Electron) that tunes and cleans an Apple Silicon Mac, carefully.
It shows what each setting is now, explains what a change does and what you give up, records the original value
before changing anything, checks the result, and puts the original back when you turn the change off.

Website: [keel.mohdmahmodi.com](https://keel.mohdmahmodi.com)

![Keel showing the Tweaks page with the detail panel open](docs/screenshots/tweaks-drawer-1280-dark.png)

## What Keel does

- **Tweaks.** About 150 settings in 12 areas: performance, memory, storage, background apps, network, developer
  tools, local AI tools, battery and power, privacy and security, visual responsiveness, Finder and desktop, and
  keyboard, trackpad and sound. Each one shows its live state (on, off, partly on, or N/A on your Mac and why), its
  risk, an honest impact rating, who it is for, and the sources it is based on. Hardware-specific tweaks adapt to the
  Mac they run on: battery settings only appear on laptops, the GPU memory limit is sized from your memory, and so on.
  A small set is marked *recommended*; everything else is opt-in. Before anything changes, a confirmation sheet
  lists the exact commands.
- **Cleanup.** Measures (not estimates) caches and leftovers such as developer caches, old simulator data and the
  Trash, and deletes only what you select. A protected group (virtual machines, models, repositories, browser
  profiles, Downloads) is never deleted.
- **Benchmark.** CPU, GPU, memory bandwidth and latency, SSD, network latency and responsiveness, DNS and (if
  installed) Ollama tests, with before/after comparison against a noise band, so you can check a change instead of
  trusting claims.
- **Activity.** A plain-language log of everything Keel did.

## What Keel does not do

- It never asks you to turn off System Integrity Protection, Gatekeeper or FileVault.
- It does not run anything at login or in the background unless you turn that on.
- It does not "free RAM", purge memory, or apply the network and kernel tweaks that do not help on Apple Silicon.
  The full list, with reasons, is in [docs/NOT-INCLUDED.md](docs/NOT-INCLUDED.md).
- It has no account, no analytics and no telemetry. See [Privacy](docs/PRIVACY.md).
- It does not update itself. It can tell you that a new version exists; you download it yourself.

## Requirements

- A Mac with Apple silicon (M1 or later). Intel Macs are not supported.
- macOS 15 Sequoia or later.

## Install

1. Download **Keel-x.y.z.dmg** from the [latest release](https://github.com/mohdmahmodi/keel/releases/latest).
2. Open the disk image and drag **Keel** onto **Applications**.
3. Eject the disk image and open Keel from Applications, Launchpad or Spotlight.

Keel is signed with a Developer ID and notarized by Apple, so it opens normally. macOS asks once whether you want to
open an app downloaded from the internet; click **Open**. To check a download yourself before opening it, see
[Verify a download](docs/RELEASING.md#verify-a-download).

## First launch

Keel starts by reading the state of every tweak. Nothing changes until you switch something on and confirm.

Closing the window leaves Keel in the menu bar (sailboat icon). Quit from there, or turn off *Keep running in the menu
bar* in Settings.

macOS may ask for these permissions. Each one is optional.

| Prompt | When | Why |
|---|---|---|
| Administrator password | Applying or reverting a tweak that needs root (for example energy settings, the firewall, DNS) | One prompt per batch. Turning on several tweaks at once asks once. Not needed if the helper is installed. |
| "Keel wants to control Finder" | Cleanup measures or empties the Trash | The Trash is protected; Keel asks Finder, exactly like the Finder menu command. |
| "Keel would like to find devices on your local network" | Running the network benchmark | Pings your router and times your network's DNS server. |

### The optional helper

Privileged changes normally use the macOS administrator prompt. If you prefer not to type your password each
time, install Keel's helper:

1. Open **Settings** in Keel and click **Install** next to *Keel helper*.
2. macOS opens **System Settings › General › Login Items & Extensions**. Under *Allow in the Background*, turn
   **Keel** on and confirm with your password or Touch ID.
3. Back in Keel, the helper shows **Enabled**.

The helper is a small root daemon that ships inside Keel.app. It accepts requests only from Keel signed by the same
developer, and it can only run Keel's allow-listed operations: specific pmset keys, two sysctls (the GPU memory limit and
Time Machine I/O throttling), moving launchd property lists in and out of Keel's backups, DNS servers, the firewall,
Time Machine exclusions, a few named root preference keys, and the StartupMute NVRAM variable. The full list is the
`PrivOp` enum in `Sources/KeelShared/PrivOp.swift`. It never runs arbitrary commands. Remove it at any time with **Remove** in Keel's
Settings or by turning Keel off in Login Items & Extensions.

### Full Disk Access (optional)

Without Full Disk Access Keel still works. With it, Cleanup can also measure the Trash, Mail downloads and iOS device
backups, which macOS otherwise hides from apps. Grant it in
**System Settings › Privacy & Security › Full Disk Access**: click **+**, choose Keel in Applications, and turn it on.
Remove it the same way.

## Undo

- **One tweak:** switch it off. Keel restores the value it recorded before the change (not a guessed default) and
  verifies it.
- **Everything:** on the Tweaks page, switch off every tweak that shows **ON**. Do this before uninstalling.
- **Cleanup** cannot be undone: deleted caches are rebuilt by the apps that own them, and the Trash is emptied for
  good. Each item says what it costs to rebuild.

Recorded originals live in `~/Library/Application Support/Keel/backups/`. Keep that folder until every tweak is off.

## Uninstall completely

1. **Turn off every tweak** in Keel (see *Undo*). Some tweaks move launchd property lists into Keel's backups
   folder; turning them off moves them back.
2. In Keel's **Settings**, click **Remove** next to *Keel helper* (if installed) and turn off **Start at login**.
3. Quit Keel from the menu bar icon, then drag **/Applications/Keel.app** to the Trash.
4. Remove Keel's data and preferences in Terminal:

   ```bash
   rm -rf ~/Library/Application\ Support/Keel
   defaults delete com.mohdmahmodi.keel 2>/dev/null
   rm -rf ~/Library/Caches/com.mohdmahmodi.keel ~/Library/HTTPStorages/com.mohdmahmodi.keel \
          ~/Library/Saved\ Application\ State/com.mohdmahmodi.keel.savedState
   ```

5. If you skipped step 2, remove what it would have removed:

   ```bash
   # Start-at-login agent
   launchctl bootout gui/$(id -u)/com.keel.app 2>/dev/null
   rm -f ~/Library/LaunchAgents/com.keel.app.plist

   # Helper daemon (normally removed by the Remove button, or turn Keel off in Login Items & Extensions)
   sudo launchctl bootout system/com.mohdmahmodi.keel.helper 2>/dev/null
   ```

6. Tweaks that persist a sysctl across restarts install a boot-time daemon named `com.keel.sysctl.<name>`. Turning the
   tweak off removes it. If one is left behind:

   ```bash
   ls /Library/LaunchDaemons/com.keel.sysctl.*        # see what is there
   for p in /Library/LaunchDaemons/com.keel.sysctl.*.plist; do
     sudo launchctl bootout system/$(basename "$p" .plist) 2>/dev/null
     sudo rm "$p"
   done
   ```

7. If you granted Full Disk Access or Automation, remove Keel from those lists in **System Settings › Privacy &
   Security**.

## Updates

Keel checks GitHub once a day for a newer release (turn this off in Settings). When one exists, Settings shows the
version, an excerpt of the release notes and a **Download** button that opens the disk image in your browser.
To update, quit Keel and drag the new version to Applications, replacing the old one. Your settings and recorded
originals are kept.

## Build from source

Requires an Apple Silicon Mac with Xcode 16 or later (or the Command Line Tools with Swift 6).

```bash
git clone https://github.com/mohdmahmodi/keel.git
cd keel
scripts/build-app.sh release      # builds dist.noindex/Keel.app (arm64, ad-hoc signed)
open dist.noindex/Keel.app
scripts/install.sh                # or: build and copy to /Applications
scripts/verify-bundle.sh          # checks the bundle layout, plists, architecture and signatures
```

An ad-hoc signed build works on the Mac that built it. The helper daemon needs a Developer ID signature, so in
such builds privileged steps always use the administrator prompt. `KEEL_SIGN_IDENTITY=auto scripts/build-app.sh`
signs with your own Developer ID (not notarized). Releases are made with `scripts/release.sh`; see
[docs/RELEASING.md](docs/RELEASING.md).

### Tests

```bash
scripts/test.sh          # allow-list, engine, catalog lint, simulated hardware, cleanup delete paths (sandboxed)
scripts/test.sh --live   # also applies and restores every user-level tweak on this Mac and checks the originals
                         # come back byte for byte (the Dock and Finder restart; nothing is left changed)
```

Headless modes, useful for checking what the app sees:

```bash
.build/debug/Keel --machine        # the hardware profile Keel reads
.build/debug/Keel --detect         # state table for every tweak
.build/debug/Keel --simulate       # detection under simulated Macs (desktop, 8 GB, macOS 15, no Xcode…)
.build/debug/Keel --cleanup-scan   # measured cleanup sizes
.build/debug/Keel --benchmark "label"
.build/debug/Keel --helper-test    # registers the helper (Developer ID builds), waits for approval, makes one call
```

### Where things live

| What | Path |
|---|---|
| Recorded originals | `~/Library/Application Support/Keel/backups/` (`index.json` plus copied files) |
| Activity log | `~/Library/Application Support/Keel/activity.jsonl` |
| Benchmark runs | `~/Library/Application Support/Keel/benchmarks/*.json` |
| Preferences | `~/Library/Preferences/com.mohdmahmodi.keel.plist` |
| Start-at-login agent | `~/Library/LaunchAgents/com.keel.app.plist` |
| Helper daemon | `Keel.app/Contents/Library/LaunchDaemons/com.mohdmahmodi.keel.helper.plist` (registered with `SMAppService`) |
| Persisted sysctl daemons | `/Library/LaunchDaemons/com.keel.sysctl.*.plist` |

### Code layout

```
Sources/KeelShared      allow-listed privileged operations (PrivOp) and their executor, shared with the helper
Sources/KeelHelper      root helper: SMAppService daemon (--xpc) or one-shot through the administrator prompt
Sources/Keel/App        entry point, menu bar extra, headless CLI modes
Sources/Keel/Core       engine, machine profile, backups, activity log, updates, tweaks, cleanup, benchmark
Sources/Keel/UI         theme, components, pages
docs/                   architecture, releasing, privacy
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before writing code.

## License

MIT. See [LICENSE](LICENSE).
