import Foundation
import IOKit
import Darwin
import KeelShared

// pmset writes need root and go through the helper (`PrivOp.pmset`, `.pmsetRepeat`, `.pmsetRepeatCancel`).

extension TweakCatalog {
    static let power: [Tweak] = [
        // MARK: Energy mode (powermode: 0 Automatic, 1 Low Power, 2 High Power, per Apple's pmset.m)

        energyModeTweak(
            id: "power-battery-automatic", name: "No High Power Mode on battery", category: .power,
            summary: "On battery the Mac uses Automatic instead of High Power, which mainly runs the fans harder.",
            explanation: """
            On battery, the energy mode changes from High Power to Automatic, so the fans stay quieter when the Mac is \
            unplugged. macOS keeps a separate energy mode for battery and power adapter (pmset powermode: 0 Automatic, \
            1 Low Power, 2 High Power, per Apple's pmset source). High Power Mode lets the fans spin faster so long, heavy \
            jobs slow down less as the chip heats up; in Eclectic Light's M4 Pro tests it was 0–5 % faster than Automatic \
            for loads under about 15 minutes. A Low Power setting on battery counts as on and is not changed. Keel reads \
            pmset rather than System Information, which misreports this value, and needs an administrator password to change it.
            """,
            risk: .safe, impact: .low, recommended: true,
            source: battery, requireHighPower: true, target: 0, isOn: { $0 != 2 }, fallbackOff: 2,
            sources: ["https://support.apple.com/101613",
                      "https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m",
                      "https://eclecticlight.co/2025/01/22/m4-pro-full-on-when-cpu-and-gpu-draw-over-50-w-and-how-low-power-mode-changes-that/",
                      "Local check: pmset -g custom on macOS 27.0.1"],
            confidence: .high, audience: [.laptop],
            benefit: "Quieter fans and somewhat longer battery life when unplugged. Everyday work runs the same.",
            tradeoff: "Heavy jobs that run on battery for longer than about 15 minutes may finish somewhat later."),

        energyModeTweak(
            id: "power-ac-high", name: "High Power Mode on the power adapter", category: .performance,
            summary: "While plugged in, the fans may run faster so long renders, builds and model runs throttle less.",
            explanation: """
            While the Mac is on the power adapter, its energy mode is High Power, which allows higher fan speeds so the \
            chip can hold its clock speed through long, heavy work. Apple says it "may improve performance in very \
            intensive workloads". It does not raise clock limits: Eclectic Light found no difference in short tests, and \
            any gain is expected only in loads that last longer than 10–15 minutes, where it has not been quantified. Only \
            some Pro, Max and Ultra Macs offer it, and Keel shows it only where pmset reports it. Changing it needs an \
            administrator password, and turning this off restores the recorded mode.
            """,
            risk: .safe, impact: .low, recommended: false,
            source: ac, requireHighPower: true, target: 2, isOn: { $0 == 2 }, fallbackOff: 0,
            sources: ["https://support.apple.com/101613",
                      "https://eclecticlight.co/2025/01/06/power-modes-and-apple-silicon-gpus/",
                      "https://www.digitaltrends.com/computing/m4-pro-low-power-mode-change/"],
            confidence: .medium, audience: [.creator, .ai, .gamer],
            benefit: "Renders, exports, builds and model runs longer than 10–15 minutes may slow down less as the Mac heats up.",
            tradeoff: "Louder fans under load and slightly higher power draw. Short tasks are not faster."),

        energyModeTweak(
            id: "power-ac-not-low", name: "No Low Power Mode on the power adapter", category: .performance,
            summary: "While plugged in, the Mac uses Automatic instead of Low Power Mode, so CPU and GPU speed are not capped.",
            explanation: """
            The Mac runs at full speed while plugged in, because Low Power Mode is turned off for the power adapter. \
            System Settings > Battery (or Energy) > Low Power Mode can be set to Always or Only on power adapter, and the \
            limit is easy to forget once the Mac is back at the desk. In Eclectic Light and Digital Trends tests on M4 Pro \
            hardware, Low Power Mode cost 30–55 % of throughput, depending on the load, while drawing roughly a quarter \
            to a third of the power and keeping the fans quiet. Leave it if you chose it for a quiet desk; the battery \
            setting is not changed, and Keel asks for an administrator password to make the change.
            """,
            risk: .safe, impact: .high, recommended: false,
            source: ac, requireHighPower: false, target: 0, isOn: { $0 != 1 }, fallbackOff: 1,
            sources: ["https://support.apple.com/101613",
                      "https://eclecticlight.co/2025/01/08/power-modes-and-apple-silicon-cpus/",
                      "https://www.digitaltrends.com/computing/m4-pro-low-power-mode-change/"],
            confidence: .high, audience: [.everyone, .creator, .gamer],
            benefit: "Heavy work while plugged in runs at full speed again instead of being capped.",
            tradeoff: "More heat and fan noise under load than with Low Power Mode."),

        energyModeTweak(
            id: "power-battery-lowpower", name: "Low Power Mode on battery", category: .power,
            summary: "The Mac uses Low Power Mode whenever it is unplugged, for longer battery life and slower heavy work.",
            explanation: """
            Low Power Mode comes on whenever the Mac runs on battery, the same as System Settings > Battery > Low Power \
            Mode > Only on battery. macOS lowers CPU and GPU clock speeds and reduces background activity (pmset \
            powermode 1, or lowpowermode 1 on Macs without High Power Mode); Keel needs an administrator password to set \
            it. Browsing and writing feel about the same. In Eclectic Light's M4 Pro tests, heavy CPU and GPU loads kept \
            roughly half to two-thirds of their throughput while drawing a quarter to a third of the power.
            """,
            risk: .low, impact: .medium, recommended: false,
            source: battery, requireHighPower: false, target: 1, isOn: { $0 == 1 }, fallbackOff: 0,
            sources: ["https://support.apple.com/101613",
                      "https://eclecticlight.co/2025/01/16/how-low-power-mode-controls-cpu-cores/",
                      "https://eclecticlight.co/2025/01/22/m4-pro-full-on-when-cpu-and-gpu-draw-over-50-w-and-how-low-power-mode-changes-that/"],
            confidence: .high, audience: [.laptop],
            benefit: "The battery lasts longer, most of all during heavy work, and the Mac runs cooler and quieter unplugged.",
            tradeoff: "Builds, exports and games run much slower on battery."),

        // MARK: Sleep and wake

        Tweak(id: "sleep-blockers-check", name: "Nothing is keeping the Mac awake", category: .power,
              summary: "Lists apps that are stopping the Mac from sleeping right now, such as a forgotten call or video tab.",
              explanation: """
              Keel lists the apps that are currently preventing the Mac or its display from sleeping on their own. Apps \
              do this with a power assertion: video players, calls, downloads and `caffeinate` hold one on purpose, but a browser \
              tab or chat app can keep one for hours and drain the battery or keep a desktop awake all night. Keel reads \
              `pmset -g assertions` without admin rights, skips the short-lived assertions of macOS's own services, and \
              lists every other app with how long it has held its assertion. Nothing is changed.
              """,
              risk: .safe, impact: .medium, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: { await sleepBlockersDetection() },
                settingsURL: "file:///System/Applications/Utilities/Activity%20Monitor.app",
                instructions: "Quit the listed app, or close the tab, call or download that keeps the Mac awake. Activity Monitor > Energy > Preventing Sleep shows the same.")),
              sources: ["man pmset (-g assertions)", "https://developer.apple.com/documentation/iokit/iopmlib_h",
                        "Local check: pmset -g assertions on macOS 27.0.1"],
              confidence: .high,
              expectedBenefit: "You see why the Mac did not sleep or why the battery drained overnight, and which app to quit.",
              tradeoff: "Nothing. Keel only reads the current state.", audience: [.everyone, .laptop]),

        Tweak(id: "battery-idle-sleep", name: "Sleep when idle on battery", category: .power,
              summary: "On battery, the Mac and its display go to sleep when idle instead of staying on indefinitely.",
              explanation: """
              A laptop left open and idle on battery goes to sleep instead of running until the battery is empty. pmset \
              stores "never" as 0 for the system (sleep) and display (displaysleep) timers, and some tutorials recommend \
              `pmset -a sleep 0`, which drains a laptop that sits open and idle. Keel changes only the battery values that \
              are 0, setting displaysleep to 10 minutes and sleep to 1 as System Settings does, and asks for an \
              administrator password. Apps that need to keep running, such as downloads, calls and `caffeinate`, still \
              hold the Mac awake.
              """,
              risk: .safe, impact: .medium, recommended: true,
              mechanism: .custom(batteryIdleSleepMechanism()),
              sources: ["https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac",
                        "man pmset"],
              requires: [.laptop], confidence: .high,
              expectedBenefit: "An open, unused Mac on battery goes to sleep instead of running flat.",
              tradeoff: "Unattended work that does not ask macOS to stay awake pauses when the Mac sleeps on battery.", audience: [.laptop]),

        Tweak(id: "ac-no-idle-sleep", name: "Stay awake on the power adapter", category: .power,
              summary: "While plugged in, the display still turns off but the Mac keeps running jobs, servers and downloads.",
              explanation: """
              The Mac keeps running while plugged in, even after the display has turned off and nobody is using it. This \
              is System Settings > Battery > Options > "Prevent automatic sleeping on power adapter when the display is \
              off" (on desktops, "Prevent automatic sleeping when the display is off"), stored as pmset sleep 0 for the \
              power adapter; changing it needs an administrator password. It suits a Mac that serves files, runs a local \
              model server or finishes long jobs overnight. Closing a laptop's lid still puts it to sleep unless an \
              external display is connected.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .custom(acNoIdleSleepMechanism()),
              sources: ["https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac",
                        "man pmset"],
              requires: [.custom({ await pmsetMissing("sleep", source: ac) })], confidence: .high,
              expectedBenefit: "Long jobs, servers and downloads keep running overnight while the Mac is plugged in.",
              tradeoff: "The Mac uses more power when idle on the power adapter, because it never sleeps on its own.", audience: [.developer, .ai, .creator]),

        Tweak(id: "powernap-battery-off", name: "Power Nap off on battery", category: .power,
              summary: "The Mac no longer wakes briefly while asleep on battery to fetch Mail and sync iCloud.",
              explanation: """
              A sleeping Mac on battery no longer wakes briefly to check Mail, sync iCloud and run maintenance. pmset \
              calls this powernap (stored as DarkWakeBackgroundTasks), and each of these "dark wakes" is short. \
              With it off on battery, Mail and iCloud refresh after you open the lid; on the power adapter nothing \
              changes, so Time Machine and updates still run overnight. The saving has not been measured in a published \
              test and is likely small; `pmset -g stats` shows how many dark wakes happened since startup.
              """,
              risk: .low, impact: .low, recommended: false,
              mechanism: .pmset([PmsetSetting(key: "powernap", on: "0", off: "1", scope: .battery)]),
              sources: ["https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLibPrivate.h",
                        "https://support.apple.com/guide/mac-help/mh40773/11.0/mac"],
              requires: [.laptop, .custom({ await pmsetMissing("powernap", source: battery) })], confidence: .medium,
              expectedBenefit: "Slightly less battery used overnight while the lid is closed.",
              tradeoff: "Mail, Calendar and iCloud are not refreshed while the Mac sleeps on battery.", audience: [.laptop]),

        Tweak(id: "tcpkeepalive-battery-off", name: "TCP keep-alive off on battery", category: .power,
              summary: "Fewer wakes while asleep on battery, but no push notifications or Find My location during sleep.",
              explanation: """
              The Mac stops keeping its network connections open while it sleeps on battery. pmset tcpkeepalive keeps \
              the connections used by push notifications, Messages, FaceTime and Find My alive during sleep, which needs \
              periodic wakes. pmset warns that Find My Mac may not work while asleep with this off, and System Settings \
              shows a warning next to network access. The power-adapter setting is not changed.
              """,
              risk: .low, impact: .low, recommended: false,
              mechanism: .pmset([PmsetSetting(key: "tcpkeepalive", on: "0", off: "1", scope: .battery)]),
              sources: ["man pmset"],
              requires: [.laptop, .custom({ await pmsetMissing("tcpkeepalive", source: battery) })], confidence: .medium,
              expectedBenefit: "Slightly less battery used while the Mac sleeps on battery.",
              tradeoff: "No notifications, Messages or Find My location while the Mac sleeps on battery.", audience: [.laptop]),

        Tweak(id: "womp-off", name: "Wake for network access off", category: .power,
              summary: "Other devices can no longer wake this Mac over the network for file sharing or Screen Sharing.",
              explanation: """
              Other devices on the network can no longer wake this Mac from sleep. This is System Settings > Battery (or \
              Energy) > Options > Wake for network access > Never, stored as pmset womp 0 for every power source. File \
              sharing, Screen Sharing and SSH can no longer reach the Mac while it sleeps, so leave it on for a Mac used as \
              a home server. Users report that Wake on LAN is unreliable on Apple silicon in any case.
              """,
              risk: .low, impact: .low, recommended: false,
              mechanism: .pmset([PmsetSetting(key: "womp", on: "0", off: "1", scope: .all)]),
              sources: ["man pmset", "https://talk.tidbits.com/t/wake-on-lan-with-apple-silicon/33183"],
              requires: [.custom({ await pmsetMissing("womp") })], confidence: .high,
              expectedBenefit: "The Mac stays asleep instead of waking for network traffic.",
              tradeoff: "Remote access to the sleeping Mac (file sharing, Screen Sharing, SSH) stops working.", audience: [.everyone, .privacy]),

        Tweak(id: "womp-battery-off", name: "Network wake only on the power adapter", category: .power,
              summary: "Keeps remote wake while plugged in, but network requests no longer wake the Mac on battery.",
              explanation: """
              Network requests no longer wake the Mac while it is on battery, but still can when it is on the power \
              adapter. This is Wake for network access > Only on Power Adapter in System Settings > Battery > Options, \
              stored as pmset womp 0 for the battery source. It suits a laptop you reach remotely at the desk but not in \
              a bag.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .pmset([PmsetSetting(key: "womp", on: "0", off: "1", scope: .battery)]),
              sources: ["man pmset", "https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac"],
              requires: [.laptop, .custom({ await pmsetMissing("womp", source: battery) })], confidence: .high,
              expectedBenefit: "A sleeping Mac on battery is no longer woken by network requests.",
              tradeoff: "On battery, you cannot reach the sleeping Mac remotely.", audience: [.laptop]),

        Tweak(id: "lessbright-battery", name: "Slightly dim the display on battery", category: .power,
              summary: "The display dims slightly on battery and returns to its normal brightness when plugged in.",
              explanation: """
              The display dims slightly whenever the Mac runs on battery. This is the "Slightly dim the display on \
              battery" switch in System Settings > Battery > Options, stored as pmset lessbright 1 for the battery source. \
              The backlight is one of the larger power draws during light use, so the saving is real but small.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .pmset([PmsetSetting(key: "lessbright", on: "1", off: "0", scope: .battery)]),
              sources: ["man pmset"],
              requires: [.laptop, .custom({ await pmsetMissing("lessbright", source: battery) })], confidence: .high,
              expectedBenefit: "A little more battery time during light use.",
              tradeoff: "The screen is a little darker when unplugged.", audience: [.laptop]),

        Tweak(id: "video-streaming-sdr-battery", name: "Optimize video streaming on battery", category: .power,
              summary: "On battery, streamed HDR video plays in standard range to save energy. Only System Settings can set it.",
              explanation: """
              Streamed HDR video plays in standard dynamic range (SDR) while the Mac is on battery, because HDR drives the \
              display much brighter. Apple: the Mac "saves energy by playing HDR video in standard dynamic range (SDR) \
              while on battery power", and HDR returns when you plug in. The switch is in System Settings > Battery > \
              Options (its text is present in PowerPreferences.appex on macOS 27), but it has no command-line interface \
              and Keel cannot read its state, so Keel opens the page.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: { Detection(state: .unknown, values: [("setting", "not readable outside System Settings")]) },
                settingsURL: "x-apple.systempreferences:com.apple.Battery-Settings.extension",
                instructions: "System Settings > Battery > Options > Optimize video streaming while on battery")),
              sources: ["https://support.apple.com/102205",
                        "Local check: string \"Optimize video streaming while on battery\" in PowerPreferences.appex, macOS 27.0.1"],
              requires: [.laptop], confidence: .medium,
              expectedBenefit: "Longer battery life while watching HDR shows and videos unplugged.",
              tradeoff: "HDR video looks less vivid on battery.", audience: [.laptop]),

        Tweak(id: "sleep-hibernate-defaults", name: "Safe sleep settings (Apple defaults)", category: .power,
              summary: "The Mac keeps saving a copy of open work to disk when it sleeps, as Apple ships it.",
              explanation: """
              The Mac writes a copy of memory to disk when it sleeps, so open work survives if the battery runs completely \
              flat. Laptops ship with hibernatemode 3 (memory stays powered and a safety image is written) and standby 1; \
              older speed-up guides set hibernatemode 0 or standby 0, which on Apple silicon does not make sleep or wake \
              faster. Keel restores 3 and 1 wherever they differ, records the previous values, and asks for an \
              administrator password. \
              hibernatemode 25 is a deliberate security setting that asks for the FileVault password on every wake; if \
              you chose it, leave this off.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .custom(sleepDefaultsMechanism()),
              sources: ["man pmset"],
              requires: [.laptop], confidence: .high,
              expectedBenefit: "Open work survives a completely drained battery, and long sleeps use less battery.",
              tradeoff: "Nothing noticeable on the defaults. It undoes hibernatemode 25 if you set that for security.", audience: [.laptop]),

        Tweak(id: "autorestart-power-failure", name: "Start up after a power failure", category: .power,
              summary: "A desktop Mac starts up again on its own when power returns after an outage.",
              explanation: """
              A desktop Mac turns itself back on when power returns after an outage. This is System Settings > \
              Energy > "Start up automatically after a power failure", stored as pmset autorestart 1. It suits a Mac mini \
              or Mac Studio that runs servers, backups or remote access, and it does not affect speed.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .pmset([PmsetSetting(key: "autorestart", on: "1", off: "0", scope: .all)]),
              sources: ["man pmset", "https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac"],
              requires: [.desktop, .custom({ await pmsetMissing("autorestart", source: ac) })], confidence: .high,
              expectedBenefit: "After an outage the Mac comes back online without anyone pressing the power button.",
              tradeoff: "The Mac also starts up when power returns at times you wanted it to stay off.", audience: [.everyone, .developer, .ai]),

        // MARK: Scheduling

        Tweak(id: "cancel-weekly-restart", name: "Remove the repeating power schedule", category: .power,
              summary: "Removes a weekly scheduled restart, shutdown, sleep or wake, after recording it so it can be put back.",
              explanation: """
              The Mac no longer restarts, shuts down, sleeps or wakes on a fixed weekly schedule. Such \
              schedules are set with `pmset repeat`, and System Settings no longer shows them, so they are easy to forget. \
              A scheduled restart gives macOS no benefit and interrupts overnight jobs, downloads and builds. Keel reads \
              the exact event from the power manager's store, records it, and runs `pmset repeat cancel` with administrator \
              rights; turning this off re-creates the same schedule.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .custom(repeatScheduleMechanism()),
              sources: ["man pmset", "https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/RepeatingAutoWake.c"],
              confidence: .high,
              expectedBenefit: "Overnight work is no longer cut off by a scheduled restart or shutdown.",
              tradeoff: "The scheduled event no longer happens.", audience: [.everyone, .developer, .ai]),

        // MARK: Battery health

        Tweak(id: "battery-health-check", name: "Battery health", category: .power,
              summary: "Shows the battery's cycle count and remaining capacity compared with when it was new.",
              explanation: """
              Keel shows how worn the battery is: its charge cycles and how much charge it holds compared with when it was \
              new. Keel reads the AppleSmartBattery values in the I/O Registry without admin rights; the capacity figure \
              is an estimate from the full-charge and design capacities and can differ from System Settings by a point or \
              two. Apple rates Mac laptop batteries for 1,000 cycles; this check reads as off below 80 % capacity or past \
              the rated count, which is when System Settings may recommend service. Nothing is changed.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: { batteryHealthDetection() },
                settingsURL: "x-apple.systempreferences:com.apple.Battery-Settings.extension",
                instructions: "System Settings > Battery > Battery Health (i) shows Apple's own assessment.")),
              sources: ["https://support.apple.com/102888",
                        "Local check: ioreg -r -c AppleSmartBattery on macOS 27.0.1"],
              requires: [.laptop], confidence: .medium,
              expectedBenefit: "You know whether a short battery life comes from a worn battery rather than from settings.",
              tradeoff: "Nothing. Keel only reads the current state.", audience: [.laptop]),

        Tweak(id: "charge-limit-80", name: "Battery charge limit", category: .power,
              summary: "Holds the battery below 100 % on a Mac that is mostly plugged in. Only System Settings can set it.",
              explanation: """
              The battery stops charging at a limit you choose between 80 and 100 %, which slows its \
              aging on a Mac that stays plugged in most of the day. It is in System Settings > Battery > Charging > Charge \
              Limit on macOS 26.4 and later. Optimized Battery Charging, on by default, holds at 80 % on its own when it \
              can predict your routine, and both still charge to 100 % occasionally to recalibrate. The limit has no \
              command-line interface and no public reader, so Keel shows battery health and opens the page.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: {
                    var d = Detection(state: .unknown, values: batteryHealthValues())
                    d.note = "The charge limit is not readable outside System Settings. Set one if this Mac is plugged in most of the time."
                    return d
                },
                settingsURL: "x-apple.systempreferences:com.apple.Battery-Settings.extension",
                instructions: "System Settings > Battery > Charging (i) > Charge Limit")),
              sources: ["https://support.apple.com/102338"],
              requires: [.laptop, .custom({
                  let m = await Machine.profile()
                  return m.osMajor > 26 || (m.osMajor == 26 && m.osMinor >= 4) ? nil : "Needs macOS 26.4 or later (Optimized Battery Charging is available instead)"
              })],
              confidence: .high,
              expectedBenefit: "The battery keeps more of its capacity over the years if the Mac is mostly plugged in.",
              tradeoff: "Less charge is available when you unplug unexpectedly.", audience: [.laptop]),

        // MARK: Performance checks and gaming

        Tweak(id: "thermal-check", name: "Not slowed down by heat", category: .performance,
              summary: "Checks whether macOS is currently lowering speed because the Mac is too hot.",
              explanation: """
              Keel checks whether macOS is currently reducing speed to cool the Mac down. macOS publishes a thermal state \
              (nominal, fair, serious or critical) and lowers CPU and GPU speed at serious and critical; `pmset -g therm` \
              also lists any recorded thermal or performance warning. Common causes are blocked vents, a hot room or a \
              runaway process, which Activity Monitor's CPU tab shows. Nothing is changed.
              """,
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(
                detect: { await thermalDetection() },
                settingsURL: "file:///System/Applications/Utilities/Activity%20Monitor.app",
                instructions: "Keep the vents clear on a hard surface and check Activity Monitor > CPU for a process using a lot of CPU.")),
              sources: ["https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum", "man pmset (-g therm)"],
              confidence: .high,
              expectedBenefit: "You learn whether heat is why the Mac feels slow.",
              tradeoff: "Nothing. Keel only reads the current state.", audience: [.everyone, .gamer, .creator]),

        Tweak(id: "metal-hud", name: "Metal Performance HUD in all apps", category: .performance,
              summary: "Shows Apple's frame-rate and GPU overlay in every Metal app and game you open next.",
              explanation: """
              Apple's Metal Performance HUD, an overlay with frame rate, frame time, GPU time and memory use, appears in \
              every app and game that draws with Metal, Apple's graphics interface. Apple documents the MetalForceHudEnabled user default and says \
              that on macOS a global value shows the HUD for all Metal apps; the key is present in macOS 27's Metal \
              framework. It applies to apps launched after the change. It measures performance and does not change it.
              """,
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "MetalForceHudEnabled", type: .bool, on: "1", off: nil)],
                                   post: .relaunchApp),
              sources: ["https://developer.apple.com/videos/play/tech-talks/110339",
                        "https://developer.apple.com/documentation/xcode/gaining-performance-insights-with-metal-performance-hud",
                        "Local check: string MetalForceHudEnabled in the dyld shared cache, macOS 27.0.1"],
              confidence: .high,
              expectedBenefit: "Games and 3D apps show live frame rate and GPU timing in a corner overlay.",
              tradeoff: "The overlay covers part of the window in every Metal app until you turn it off.", audience: [.gamer, .creator, .developer]),

        Tweak(id: "game-mode-force", name: "Force Game Mode on (experimental)", category: .performance,
              summary: "Keeps Game Mode on all the time instead of only while a full-screen game runs. Needs Xcode.",
              explanation: """
              macOS Game Mode stays on all the time instead of only while a game is in full screen. Game Mode gives the \
              game top priority for CPU and GPU, reduces background work and doubles the Bluetooth sampling rate for \
              controllers and AirPods (Apple support 105118); it is not a system-wide speed increase, and no test shows \
              other apps running faster. The switch is `gamepolicyctl`, which ships with Xcode and needs no admin rights. \
              Keel records the current policy and restores it when you turn this off.
              """,
              risk: .low, impact: .low, recommended: false,
              mechanism: .custom(gameModeMechanism()),
              sources: ["https://support.apple.com/105118", "https://eclecticlight.co/2023/10/17/what-does-game-mode-do/",
                        "Local check: xcrun gamepolicyctl game-mode status, Xcode 27.0 on macOS 27.0.1"],
              requires: [.xcode, .custom({ await gamePolicyTool() == nil ? "gamepolicyctl is not in this Xcode" : nil })],
              confidence: .low,
              expectedBenefit: "Windowed games may get Game Mode's priority and lower controller and AirPods latency. Other work is not faster.",
              tradeoff: "Background apps get lower priority while it is forced on.", audience: [.gamer]),
    ]
}

// MARK: - Private helpers

private extension TweakCatalog {
    static let battery = "Battery Power"
    static let ac = "AC Power"

    static func sourceLabel(_ src: String) -> String { src == battery ? "battery" : "power adapter" }
    static func scopeFlag(_ src: String) -> String { src == battery ? "-b" : "-c" }

    /// nil when this Mac offers the pmset `key` (listed by `pmset -g cap` or present in `pmset -g custom` for
    /// `source`, or for any source); otherwise the N/A reason.
    static func pmsetMissing(_ key: String, source: String? = nil) async -> String? {
        let m = await Machine.profile()
        if m.pmsetCapabilities.contains(key) { return nil }
        let table = await Pmset.current()
        let present = source.map { table[$0]?[key] != nil } ?? table.values.contains { $0[key] != nil }
        return present ? nil : "This Mac does not offer the pmset setting \(key)"
    }

    // MARK: Energy mode

    /// pmset shows a tri-state `powermode` when the source supports High Power Mode, otherwise `lowpowermode` 0/1.
    static func modeKey(_ table: [String: [String: String]], _ src: String) -> String? {
        if table[src]?["powermode"] != nil { return "powermode" }
        if table[src]?["lowpowermode"] != nil { return "lowpowermode" }
        return nil
    }

    static func modeName(_ v: Int?, key: String) -> String {
        guard let v else { return "(absent)" }
        switch (key, v) {
        case (_, 0): return "0 (Automatic)"
        case (_, 1): return "1 (Low Power)"
        case ("powermode", 2): return "2 (High Power)"
        default: return String(v)
        }
    }

    static func energyModeTweak(id: String, name: String, category: TweakCategory, summary: String, explanation: String,
                                risk: Risk, impact: Impact, recommended: Bool, source: String, requireHighPower: Bool,
                                target: Int, isOn: @escaping @Sendable (Int) -> Bool, fallbackOff: Int,
                                sources: [String], confidence: Confidence, audience: Set<Audience>, benefit: String, tradeoff: String) -> Tweak {
        let label = sourceLabel(source)
        let requirement: Requirement = .custom({
            // `pmset -g cap` names the features of this model; `pmset -g custom` shows which source offers them.
            let m = await Machine.profile()
            let table = await Pmset.current()
            guard m.powerSources.contains(source) else { return "This Mac has no \(label) power source" }
            if requireHighPower {
                guard m.pmsetCapabilities.contains("highpowermode") else { return "This Mac does not offer High Power Mode" }
                return table[source]?["powermode"] != nil ? nil : "This Mac does not offer High Power Mode on the \(label)"
            }
            guard m.pmsetCapabilities.contains("lowpowermode") || m.pmsetCapabilities.contains("highpowermode") else {
                return "This Mac does not offer Low Power Mode"
            }
            return modeKey(table, source) != nil ? nil : "This Mac does not offer Low Power Mode on the \(label)"
        })
        let mech = CustomMechanism(
            detect: {
                let table = await Pmset.current()
                guard let key = modeKey(table, source) else { return .na("Energy mode not reported for the \(label)") }
                let v = table[source]?[key].flatMap { Int($0) }
                var values: [(String, String)] = [("\(key) (\(label))", modeName(v, key: key))]
                if let other = [battery, ac].first(where: { $0 != source && table[$0] != nil }), let ok = modeKey(table, other) {
                    values.append(("\(ok) (\(sourceLabel(other)))", modeName(table[other]?[ok].flatMap { Int($0) }, key: ok)))
                }
                values.append(("Low Power Mode active now", ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no"))
                guard let v else { return Detection(state: .unknown, values: values) }
                return Detection(state: isOn(v) ? .on : .off, values: values)
            },
            apply: { ctx in
                let table = await Pmset.current(fresh: true)
                guard let key = modeKey(table, source) else { throw TweakEngine.EngineError(message: "pmset reports no energy mode for the \(label)") }
                let prev = table[source]?[key] ?? ""
                ctx.privileged(.pmset(scope: scopeFlag(source), key: key, value: String(target)))
                return ["source": source, "key": key, "previous": prev]
            },
            revert: { ctx, orig in
                let table = await Pmset.current(fresh: true)
                let key = orig["key"] ?? modeKey(table, source) ?? "powermode"
                // Records made by the older pmset mechanism use "<source>.<key>".
                let recorded = orig["previous"] ?? orig["\(source).\(key)"] ?? orig["\(source).powermode"] ?? ""
                let value = Int(recorded) ?? fallbackOff
                ctx.privileged(.pmset(scope: scopeFlag(source), key: key, value: String(value)))
            },
            applyCommands: ["sudo pmset \(scopeFlag(source)) powermode \(target)   # lowpowermode on Macs without High Power Mode"],
            revertCommands: ["sudo pmset \(scopeFlag(source)) powermode <recorded original>"],
            needsAdmin: true)
        return Tweak(id: id, name: name, category: category, summary: summary, explanation: explanation, risk: risk,
                     impact: impact, recommended: recommended, mechanism: .custom(mech), sources: sources,
                     requires: (source == battery ? [.laptop] : []) + [requirement], confidence: confidence,
                     expectedBenefit: benefit, tradeoff: tradeoff, audience: audience)
    }

    // MARK: Stay awake on AC

    static func acNoIdleSleepMechanism() -> CustomMechanism {
        CustomMechanism(
            detect: {
                guard let v = await Pmset.current()[ac]?["sleep"] else { return .na("pmset reports no system sleep timer for the power adapter") }
                var values = [("sleep (power adapter)", v == "0" ? "0 (never)" : "\(v) min")]
                if let d = await Pmset.current()[ac]?["displaysleep"] { values.append(("displaysleep (power adapter)", d == "0" ? "0 (never)" : "\(d) min")) }
                return Detection(state: v == "0" ? .on : .off, values: values)
            },
            apply: { ctx in
                let prev = await Pmset.current(fresh: true)[ac]?["sleep"] ?? ""
                ctx.privileged(.pmset(scope: "-c", key: "sleep", value: "0"))
                return ["\(ac).sleep": prev]
            },
            revert: { ctx, orig in
                let v = orig["\(ac).sleep"].flatMap { Int($0) } ?? 1
                ctx.privileged(.pmset(scope: "-c", key: "sleep", value: String(v)))
            },
            applyCommands: ["sudo pmset -c sleep 0"],
            revertCommands: ["sudo pmset -c sleep <recorded original>"],
            needsAdmin: true)
    }

    // MARK: Sleep blockers (pmset -g assertions)

    static let sleepBlockingTypes: Set<String> = ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep",
                                                  "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Executable path of a pid (nil when the process is gone or not visible).
    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func sleepBlockersDetection() async -> Detection {
        guard let r = await Shell.probe("/usr/bin/pmset", ["-g", "assertions"]), r.ok else { return .unknown }
        // "   pid 1240(Slack): [0x…] 00:37:08 NoIdleSleepAssertion named: "Electron""
        let rx = try! NSRegularExpression(pattern: #"^\s*pid (\d+)\((.*?)\): \[0x[0-9a-fA-F]+\] (\d+:\d+:\d+) (\w+) named: "(.*)""#)
        var values: [(String, String)] = []
        var seen = Set<String>()
        for raw in r.stdout.split(separator: "\n") {
            let line = String(raw)
            guard let m = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), m.numberOfRanges == 6,
                  let pidR = Range(m.range(at: 1), in: line), let nameR = Range(m.range(at: 2), in: line),
                  let ageR = Range(m.range(at: 3), in: line), let typeR = Range(m.range(at: 4), in: line),
                  let whyR = Range(m.range(at: 5), in: line) else { continue }
            let type = String(line[typeR])
            guard sleepBlockingTypes.contains(type), let pid = Int32(line[pidR]) else { continue }
            let name = String(line[nameR])
            // macOS's own daemons (powerd's "display is on" assertion, bluetoothd, coreaudiod while audio plays) are not reported.
            let path = executablePath(pid) ?? ""
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") || path.hasPrefix("/Library/Apple/") {
                if name != "caffeinate" { continue }
            }
            let what = type.contains("Display") ? "keeps the display on" : "keeps the Mac awake"
            let key = "\(name)|\(what)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            values.append((name, "\(what) for \(line[ageR]) (\(line[whyR]))"))
        }
        if values.isEmpty { return Detection(state: .on, values: [("apps preventing sleep", "none")]) }
        return Detection(state: .off, values: values,
                         note: "These apps are stopping idle sleep right now. That is expected during a call, video or download; otherwise quit them.")
    }

    // MARK: Thermal state

    static func thermalDetection() async -> Detection {
        let state = ProcessInfo.processInfo.thermalState
        let name: String
        switch state {
        case .nominal: name = "nominal"
        case .fair: name = "fair"
        case .serious: name = "serious (speed reduced)"
        case .critical: name = "critical (speed reduced)"
        @unknown default: name = "unknown"
        }
        var values: [(String, String)] = [("thermal state", name)]
        var warned = false
        if let r = await Shell.probe("/usr/bin/pmset", ["-g", "therm"]) {
            let lines = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.allSatisfy({ $0.lowercased().contains("no ") }) { values.append(("pmset -g therm", "no warnings recorded")) }
            for l in lines {
                if !l.lowercased().contains("no ") { values.append(("pmset -g therm", l)) }
                let lower = l.lowercased()
                if !lower.contains("no ") && lower.contains("level") { warned = true }
                if lower.contains("speed_limit"), let v = Int(l.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""), v < 100 { warned = true }
            }
        }
        let hot = state == .serious || state == .critical
        var d = Detection(state: hot || warned ? .off : .on, values: values)
        if hot { d.note = "macOS is reducing speed to cool the Mac." }
        else if warned { d.note = "pmset has recorded a thermal or performance warning." }
        return d
    }

    // MARK: Idle sleep on battery

    static func batteryIdleSleepMechanism() -> CustomMechanism {
        // key → value written when the current value is 0 ("never").
        let fixes: [(String, String)] = [("displaysleep", "10"), ("sleep", "1")]
        return CustomMechanism(
            detect: {
                let t = await Pmset.current()[battery] ?? [:]
                guard t["sleep"] != nil || t["displaysleep"] != nil else { return .na("pmset reports no battery sleep settings") }
                let values = fixes.map { ("\($0.0) (battery)", t[$0.0].map { $0 == "0" ? "0 (never)" : "\($0) min" } ?? "(absent)") }
                let never = fixes.filter { t[$0.0] == "0" }.map(\.0)
                var d = Detection(state: never.isEmpty ? .on : .off, values: values)
                if !never.isEmpty { d.note = "Set to never on battery: \(never.joined(separator: ", "))" }
                return d
            },
            apply: { ctx in
                let t = await Pmset.current(fresh: true)[battery] ?? [:]
                var rec: [String: String] = [:]
                for (key, value) in fixes where t[key] == "0" {
                    rec["\(battery).\(key)"] = "0"
                    ctx.privileged(.pmset(scope: "-b", key: key, value: value))
                }
                if rec.isEmpty { throw TweakEngine.EngineError(message: "Nothing is set to never on battery") }
                return rec
            },
            revert: { ctx, orig in
                for (key, _) in fixes {
                    if let v = orig["\(battery).\(key)"], !v.isEmpty { ctx.privileged(.pmset(scope: "-b", key: key, value: v)) }
                }
            },
            applyCommands: ["sudo pmset -b displaysleep 10   # only if it is 0", "sudo pmset -b sleep 1   # only if it is 0"],
            revertCommands: ["sudo pmset -b <key> <recorded original>"],
            needsAdmin: true)
    }

    // MARK: hibernatemode / standby

    static func sleepDefaultsMechanism() -> CustomMechanism {
        let wanted: [(String, String)] = [("hibernatemode", "3"), ("standby", "1")]
        return CustomMechanism(
            detect: {
                let table = await Pmset.current()
                var values: [(String, String)] = []
                var off: [String] = []
                for src in [battery, ac] {
                    guard let t = table[src] else { continue }
                    for (key, want) in wanted {
                        guard let v = t[key] else { continue }
                        values.append(("\(key) (\(sourceLabel(src)))", v))
                        if v != want { off.append("\(key) \(v) on \(sourceLabel(src))") }
                    }
                }
                if values.isEmpty { return .na("pmset reports no hibernation settings") }
                var d = Detection(state: off.isEmpty ? .on : .off, values: values)
                if !off.isEmpty {
                    d.note = "Not Apple's default: " + off.joined(separator: ", ")
                        + (off.contains { $0.hasPrefix("hibernatemode 0") } ? ". With hibernatemode 0 a drained battery loses open work." : "")
                }
                return d
            },
            apply: { ctx in
                let table = await Pmset.current(fresh: true)
                var rec: [String: String] = [:]
                for src in [battery, ac] {
                    guard let t = table[src] else { continue }
                    for (key, want) in wanted {
                        guard let v = t[key], v != want else { continue }
                        rec["\(src).\(key)"] = v
                        ctx.privileged(.pmset(scope: scopeFlag(src), key: key, value: want))
                    }
                }
                if rec.isEmpty { throw TweakEngine.EngineError(message: "Already at Apple's defaults") }
                return rec
            },
            revert: { ctx, orig in
                for src in [battery, ac] {
                    for (key, _) in wanted {
                        if let v = orig["\(src).\(key)"], Int(v) != nil { ctx.privileged(.pmset(scope: scopeFlag(src), key: key, value: v)) }
                    }
                }
            },
            applyCommands: ["sudo pmset -b|-c hibernatemode 3   # only where it differs", "sudo pmset -b|-c standby 1   # only where it differs"],
            revertCommands: ["sudo pmset -b|-c <key> <recorded original>"],
            needsAdmin: true)
    }

    // MARK: Repeating schedule (pmset repeat)

    struct RepeatEvent: Sendable {
        let slot: String      // "on" or "off"
        let type: String      // pmset repeat token: restart, shutdown, sleep, wake, poweron, wakeorpoweron
        let days: String      // MTWRFSU letters
        let minutes: Int      // after midnight
        var time: String { String(format: "%02d:%02d:00", minutes / 60, minutes % 60) }
        var display: String { "\(type) \(days) \(String(format: "%02d:%02d", minutes / 60, minutes % 60))" }
    }

    static let dayLetters = Array("MTWRFSU")  // bit 0 = Monday … bit 6 = Sunday (RepeatingAutoWake.c)

    static func repeatEvent(_ d: [String: Any], slot: String) -> RepeatEvent? {
        guard let rawType = d["eventtype"] as? String,
              let minutes = (d["time"] as? NSNumber)?.intValue,
              let mask = (d["weekdays"] as? NSNumber)?.intValue, mask & 0x7F != 0 else { return nil }
        let type = rawType == "wakepoweron" ? "wakeorpoweron" : rawType
        let days = String((0..<7).filter { mask & (1 << $0) != 0 }.map { dayLetters[$0] })
        return RepeatEvent(slot: slot, type: type, days: days, minutes: minutes)
    }

    struct RepeatSchedule: Sendable {
        var events: [RepeatEvent]      // exact, from powerd's store
        var textLines: [String]        // what `pmset -g sched` prints under "Repeating power events:"
        /// pmset reports repeating events that the store did not yield exactly (do not touch them).
        var inexact: Bool { events.isEmpty && !textLines.isEmpty }
    }

    /// Repeating events from powerd's store (root-owned, world-readable; the repeating-event API is private),
    /// cross-checked against `pmset -g sched`.
    static func repeatingSchedule(fresh: Bool = false) async -> RepeatSchedule? {
        let file = "/Library/Preferences/SystemConfiguration/com.apple.AutoWake.plist"
        var dict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file) {
            guard let f = NSDictionary(contentsOfFile: file) as? [String: Any] else { return nil }
            dict = f
        }
        var events: [RepeatEvent] = []
        if let on = dict["RepeatingPowerOn"] as? [String: Any], let e = repeatEvent(on, slot: "on") { events.append(e) }
        if let off = dict["RepeatingPowerOff"] as? [String: Any], let e = repeatEvent(off, slot: "off") { events.append(e) }
        if fresh { await ProbeCache.shared.invalidate() }
        var lines: [String] = []
        if let r = await Shell.probe("/usr/bin/pmset", ["-g", "sched"]), let rg = r.stdout.range(of: "Repeating power events:") {
            for l in r.stdout[rg.upperBound...].split(separator: "\n") {
                guard l.hasPrefix(" "), l.contains(" at ") else { break }
                lines.append(l.trimmingCharacters(in: .whitespaces))
            }
        }
        return RepeatSchedule(events: events, textLines: lines)
    }

    /// Parses a schedule line recorded by older Keel versions, e.g. "restart at 3:00AM Wednesday".
    static func parseLegacySchedule(_ line: String) -> (type: String, days: String, time: String)? {
        let words = line.lowercased().split(separator: " ").map(String.init)
        guard words.count >= 3, words[1] == "at" else { return nil }
        let type = words[0] == "wakepoweron" ? "wakeorpoweron" : words[0]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mma"
        guard let date = f.date(from: words[2].uppercased()) else { return nil }
        let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: date)
        let names = ["monday": "M", "tuesday": "T", "wednesday": "W", "thursday": "R", "friday": "F", "saturday": "S", "sunday": "U"]
        let rest = words.dropFirst(3).joined(separator: " ")
        var days = ""
        if rest.contains("every day") { days = "MTWRFSU" }
        else if rest.contains("weekdays") { days = "MTWRF" }
        else if rest.contains("weekends") { days = "SU" }
        else { for l in dayLetters where names.contains(where: { rest.contains($0.key) && $0.value == String(l) }) { days.append(l) } }
        guard !days.isEmpty else { return nil }
        return (type, days, String(format: "%02d:%02d:00", c.hour ?? 0, c.minute ?? 0))
    }

    static func repeatScheduleMechanism() -> CustomMechanism {
        CustomMechanism(
            detect: {
                guard let s = await repeatingSchedule() else { return Detection(state: .unknown, values: [("schedule", "could not be read")]) }
                if s.inexact { return Detection(state: .off, values: s.textLines.map { ("pmset -g sched", $0) }) }
                if s.events.isEmpty { return Detection(state: .on, values: [("repeating power events", "none")], note: "No repeating power schedule is set.") }
                return Detection(state: .off, values: s.events.map { ("repeating \($0.slot == "on" ? "power-on" : "power-off") event", $0.display) }
                                 + s.textLines.map { ("pmset -g sched", $0) })
            },
            apply: { ctx in
                guard let s = await repeatingSchedule(fresh: true), !s.inexact else { throw TweakEngine.EngineError(message: "Could not read the exact repeating schedule, so Keel leaves it alone") }
                let events = s.events
                guard !events.isEmpty else { throw TweakEngine.EngineError(message: "No repeating power schedule is set") }
                // `pmset repeat <event>` replaces both slots, so the helper can restore one event per call only.
                guard events.count == 1, let e = events.first else {
                    throw TweakEngine.EngineError(message: "Two repeating events are scheduled (\(events.map(\.display).joined(separator: "; "))). Keel can restore only one, so it leaves them alone; remove them with `sudo pmset repeat cancel` if you want.")
                }
                ctx.privileged(.pmsetRepeatCancel)
                return ["type": e.type, "days": e.days, "time": e.time, "display": e.display]
            },
            revert: { ctx, orig in
                if let type = orig["type"], let days = orig["days"], let time = orig["time"] {
                    ctx.privileged(.pmsetRepeat(type: type, days: days, time: time))
                } else if let line = orig["schedule"], let p = parseLegacySchedule(line) {
                    ctx.privileged(.pmsetRepeat(type: p.type, days: p.days, time: p.time))
                }
                // Nothing recorded: the default is no schedule, so there is nothing to restore.
            },
            applyCommands: ["sudo pmset repeat cancel"],
            revertCommands: ["sudo pmset repeat <recorded type> <recorded days> <recorded HH:MM:SS>"],
            needsAdmin: true)
    }

    // MARK: Battery health (IOKit, no root)

    /// Cycle count, design cycle count and approximate capacity percentage, or nil when unreadable.
    static func batteryHealthNumbers() -> (cycles: Int?, rated: Int?, percent: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any] else { return (nil, nil, nil) }
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        let data = p["BatteryData"] as? [String: Any] ?? [:]
        let full = int(p["AppleRawMaxCapacity"]) ?? int(data["FullChargeCapacity"])
        let design = int(p["DesignCapacity"]) ?? int(data["DesignCapacity"])
        let pct = (full != nil && design != nil && design! > 0) ? full! * 100 / design! : nil
        return (int(p["CycleCount"]), int(p["DesignCycleCount9C"]), pct)
    }

    static func batteryHealthDetection() -> Detection {
        let h = batteryHealthNumbers()
        let values = batteryHealthValues()
        guard let pct = h.percent else { return Detection(state: .unknown, values: values) }
        let rated = h.rated ?? 1000
        let worn = pct < 80 || (h.cycles ?? 0) >= rated
        var d = Detection(state: worn ? .off : .on, values: values)
        if worn { d.note = "The battery is below 80 % of its original capacity or past its rated cycle count. System Settings > Battery > Battery Health shows whether service is recommended." }
        return d
    }

    static func batteryHealthValues() -> [(String, String)] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [("battery", "not found")] }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any] else { return [("battery", "not readable")] }
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        let data = p["BatteryData"] as? [String: Any] ?? [:]
        var out: [(String, String)] = []
        if let c = int(p["CycleCount"]) {
            out.append(("cycle count", int(p["DesignCycleCount9C"]).map { "\(c) of \($0) rated" } ?? String(c)))
        }
        // MaxCapacity is a percentage on Apple silicon; use mAh values for health.
        let full = int(p["AppleRawMaxCapacity"]) ?? int(data["FullChargeCapacity"])
        let design = int(p["DesignCapacity"]) ?? int(data["DesignCapacity"])
        if let full, let design, design > 0 {
            out.append(("capacity vs new (approx.)", "\(full * 100 / design) %  (\(full) of \(design) mAh)"))
        }
        if let cur = int(p["CurrentCapacity"]) { out.append(("charge now", "\(cur) %")) }
        if let ext = p["ExternalConnected"] as? Bool { out.append(("power adapter", ext ? "connected" : "not connected")) }
        return out
    }

    // MARK: Game Mode

    /// Path of gamepolicyctl from the selected Xcode, or nil.
    static func gamePolicyTool() async -> String? {
        guard let r = await Shell.probe("/usr/bin/xcrun", ["-f", "gamepolicyctl"], ttl: 300), r.ok else { return nil }
        let path = r.output
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// (status line, policy: auto | on | off)
    static func gameModeStatus(fresh: Bool = false) async -> (String, String)? {
        guard let tool = await gamePolicyTool() else { return nil }
        let r: ShellResult?
        if fresh { r = try? await Shell.run(tool, ["game-mode", "status"], timeout: 15) } else { r = await Shell.probe(tool, ["game-mode", "status"]) }
        guard let r else { return nil }
        let clean = r.combined.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let first = clean.split(separator: "\n").first.map(String.init) ?? clean
        return (first, parseGamePolicy(clean))
    }

    /// "auto", "on", "off" or "unknown". After `set on`, macOS 27 prints "…policy is currently disabled. Game mode
    /// is forced always on." There "disabled" refers to the automatic policy, so the forced state decides.
    static func parseGamePolicy(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.range(of: "forced (always )?on", options: .regularExpression) != nil { return "on" }
        if lower.range(of: "forced (always )?off", options: .regularExpression) != nil { return "off" }
        if let rg = lower.range(of: "policy is currently [a-z]+", options: .regularExpression) {
            switch lower[rg].split(separator: " ").last.map(String.init) ?? "" {
            case "automatic", "auto": return "auto"
            case "on", "enabled": return "on"
            case "off": return "off"
            default: break
            }
        }
        return "unknown"
    }

    static func gameModeMechanism() -> CustomMechanism {
        CustomMechanism(
            detect: {
                guard let (line, policy) = await gameModeStatus() else { return .na("gamepolicyctl did not respond") }
                let state: TweakState = policy == "on" ? .on : (policy == "unknown" ? .unknown : .off)
                let names = ["auto": "automatic", "on": "forced on", "off": "forced off", "unknown": "unknown"]
                return Detection(state: state, values: [("game mode", line), ("enablement policy", names[policy] ?? policy)])
            },
            apply: { _ in
                guard let tool = await gamePolicyTool() else { throw TweakEngine.EngineError(message: "gamepolicyctl not found") }
                // Record the policy (automatic or forced off) so revert puts back exactly that.
                let previous = await gameModeStatus(fresh: true)?.1 ?? "auto"
                let r = try await Shell.run(tool, ["game-mode", "set", "on"], timeout: 15)
                ActivityLog.post(.command, "xcrun gamepolicyctl game-mode set on", detail: r.combined.isEmpty ? nil : r.combined)
                guard r.ok else { throw TweakEngine.EngineError(message: "gamepolicyctl failed: \(r.combined)") }
                return ["previous": previous == "off" ? "off" : "auto"]
            },
            revert: { _, orig in
                guard let tool = await gamePolicyTool() else { throw TweakEngine.EngineError(message: "gamepolicyctl not found") }
                let policy = ["auto", "off"].contains(orig["previous"] ?? "") ? orig["previous"]! : "auto"
                let r = try await Shell.run(tool, ["game-mode", "set", policy], timeout: 15)
                ActivityLog.post(.command, "xcrun gamepolicyctl game-mode set \(policy)", detail: r.combined.isEmpty ? nil : r.combined)
                guard r.ok else { throw TweakEngine.EngineError(message: "gamepolicyctl failed: \(r.combined)") }
            },
            applyCommands: ["xcrun gamepolicyctl game-mode set on"],
            revertCommands: ["xcrun gamepolicyctl game-mode set <recorded policy: auto or off>"],
            needsAdmin: false)
    }
}
