import Foundation
import KeelShared

// Keys checked on macOS 27.0.1 in the dyld shared cache. The HID system reads input defaults at login,
// so most of these need a logout to take full effect.

extension TweakCatalog {
    static let input: [Tweak] = [
        // MARK: Keyboard

        Tweak(id: "key-repeat-fast", name: "Faster key repeat", category: .input,
              summary: "Held keys start repeating sooner and repeat faster, at the fastest slider positions.",
              explanation: "A held key starts repeating sooner and repeats faster. Keel sets KeyRepeat to 2 and InitialKeyRepeat to 15 in the global domain, the fastest positions of the Key repeat rate and Delay until repeat sliders in System Settings > Keyboard. Both count in steps of 15 ms, so the defaults of 6 and 25 mean about 90 ms between repeats and 375 ms before the first. Faster values set elsewhere also count as on. You need to log out for it to apply; both keys are present in the macOS 27.0.1 dyld shared cache.",
              risk: .low, impact: .medium, recommended: false,
              mechanism: .defaults([
                DefaultsSetting(domain: "NSGlobalDomain", key: "KeyRepeat", type: .int, on: "2", off: nil, onAliases: ["1"]),
                DefaultsSetting(domain: "NSGlobalDomain", key: "InitialKeyRepeat", type: .int, on: "15", off: nil, onAliases: ["10", "11", "12", "13", "14"])
              ], post: .logout),
              sources: ["https://github.com/mathiasbynens/dotfiles/blob/main/.macos", "Local check (macOS 27.0): KeyRepeat and InitialKeyRepeat read by the keyboard settings"],
              expectedBenefit: "Moving the cursor or deleting with a held key is about three times quicker.",
              tradeoff: "A key held slightly too long types twice until you get used to it.",
              audience: [.developer, .everyone]),

        Tweak(id: "press-and-hold-off", name: "Holding a key repeats it", category: .input,
              summary: "Held letter keys repeat instead of opening the accented-character menu.",
              explanation: "A held letter key repeats instead of opening the small menu of accented characters such as é or ü. Editors with Vim-style keys expect this. The key is ApplePressAndHoldEnabled in the global domain, set to false; some Electron apps, such as VS Code, keep their own copy of it. Apps pick it up after they are reopened, and logging out applies it everywhere.",
              risk: .low, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "ApplePressAndHoldEnabled", type: .bool, on: "0", off: nil)], post: .logout),
              sources: ["https://macos-defaults.com/keyboard/applepressandholdenabled.html"],
              expectedBenefit: "Holding h, j, k, l or any other letter repeats it like the arrow keys do.",
              tradeoff: "No accent menu; type accents with Option key combinations or the Character Viewer.",
              audience: [.developer]),

        Tweak(id: "fn-keys-standard", name: "F1–F12 work as standard function keys", category: .input,
              summary: "The top row sends F1–F12 directly; hold Fn (Globe) for brightness and volume.",
              explanation: "The top row of an Apple keyboard sends F1 to F12 without holding the Fn (Globe) key. By default those keys control brightness, volume and media, so apps that use F-keys, such as IDEs, games and audio software, need Fn held. Keel sets com.apple.keyboard.fnState to true in the global domain, the same as “Use F1, F2, etc. keys as standard function keys” in System Settings > Keyboard. The key is present in the macOS 27.0.1 HID preference table; it takes full effect after you log out.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "com.apple.keyboard.fnState", type: .bool, on: "1", off: nil)], post: .logout),
              sources: ["https://support.apple.com/en-us/102439", "Local check: string present in the macOS 27.0.1 dyld shared cache"],
              confidence: .medium,
              expectedBenefit: "Keyboard shortcuts that use F-keys work with one press.",
              tradeoff: "Brightness, volume and media keys need Fn (Globe) held.",
              audience: [.developer, .gamer, .creator]),

        Tweak(id: "keyboard-navigation", name: "Keyboard navigation between all controls", category: .input,
              summary: "Tab moves through every button and control in dialogs, not only text fields.",
              explanation: "The Tab key moves focus to every control in windows and dialogs, so buttons, checkboxes and pop-up menus can be used without the pointer; Space activates the focused control. The setting is AppleKeyboardUIMode in the global domain, set to 2, which is the “Keyboard navigation” switch in System Settings > Keyboard; the older value 3 also counts as on. Apps pick it up after they are reopened. The key is present in the Keyboard settings extension and AppKit on macOS 27.0.1.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "AppleKeyboardUIMode", type: .int, on: "2", off: nil, onAliases: ["3"])], post: .relaunchApp),
              sources: ["https://support.apple.com/guide/mac-help/use-your-keyboard-like-a-mouse-mchlp1399/mac", "https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: AppleKeyboardUIMode present in KeyboardSettings.appex on macOS 27.0.1"],
              confidence: .medium,
              expectedBenefit: "Dialogs such as “Don't Save / Cancel / Save” can be answered from the keyboard.",
              tradeoff: "A focus ring appears on buttons, which some find distracting.",
              audience: [.everyone]),

        Tweak(id: "autocorrect-off", name: "Automatic spelling correction: off", category: .input,
              summary: "macOS stops replacing words as you type; misspellings are still underlined.",
              explanation: "macOS stops changing words it thinks are misspelled while you type, a correction that often alters names, technical terms and words in a second language. Keel sets NSAutomaticSpellingCorrectionEnabled and WebAutomaticSpellingCorrectionEnabled to false in the global domain, the same as turning off “Correct spelling automatically” in System Settings > Keyboard > Text Input. Spell checking still underlines mistakes. Apps that keep their own setting are unaffected; others pick it up after they are reopened.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([
                DefaultsSetting(domain: "NSGlobalDomain", key: "NSAutomaticSpellingCorrectionEnabled", type: .bool, on: "0", off: nil),
                DefaultsSetting(domain: "NSGlobalDomain", key: "WebAutomaticSpellingCorrectionEnabled", type: .bool, on: "0", off: nil)
              ], post: .relaunchApp),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: both strings present in the macOS 27.0.1 dyld shared cache"],
              expectedBenefit: "What you type stays exactly as typed.",
              tradeoff: "Real typos are no longer fixed for you; you correct them from the underline.",
              audience: [.everyone, .developer]),

        Tweak(id: "auto-capitalization-off", name: "Automatic capitalization: off", category: .input,
              summary: "macOS stops capitalizing the first letter of sentences for you.",
              explanation: "The first word of each sentence stays as you typed it. Automatic capitals get in the way when writing code, commands, usernames or lower-case notes. Keel sets NSAutomaticCapitalizationEnabled to false in the global domain, the same as turning off “Capitalize words automatically” in System Settings > Keyboard > Text Input. Apps pick it up after they are reopened.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSAutomaticCapitalizationEnabled", type: .bool, on: "0", off: nil)], post: .relaunchApp),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the macOS 27.0.1 dyld shared cache"],
              expectedBenefit: "Lower-case text stays lower-case.",
              tradeoff: "You type sentence capitals yourself.",
              audience: [.developer, .everyone]),

        Tweak(id: "double-space-period-off", name: "Double-space inserts period: off", category: .input,
              summary: "Typing two spaces no longer turns into a period and a space.",
              explanation: "Two spaces typed in a row stay two spaces instead of becoming a period and a space. The shortcut comes from the iPhone and breaks code indentation and Markdown line breaks. Keel sets NSAutomaticPeriodSubstitutionEnabled to false in the global domain, the same as turning off “Add period with double-space” in System Settings > Keyboard > Text Input. Apps pick it up after they are reopened.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "NSAutomaticPeriodSubstitutionEnabled", type: .bool, on: "0", off: nil)], post: .relaunchApp),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: string present in the macOS 27.0.1 dyld shared cache"],
              expectedBenefit: "Two spaces stay two spaces.",
              tradeoff: "You type the period at the end of a sentence yourself.",
              audience: [.developer, .everyone]),

        // MARK: Trackpad and mouse

        Tweak(id: "trackpad-tap-to-click", name: "Tap to click", category: .input,
              summary: "A light tap on the trackpad counts as a click, without pressing it down.",
              explanation: "A one-finger tap on the trackpad acts as a click. Keel sets Clicking to true for the built-in trackpad (com.apple.AppleMultitouchTrackpad) and Apple's Bluetooth trackpad (com.apple.driver.AppleBluetoothMultitouch.trackpad), and com.apple.mouse.tapBehavior to 1 for the current host, which is also what the login window reads. These are the keys the switch in System Settings > Trackpad maintains; the tapBehavior key is present in the Trackpad settings extension on macOS 27.0.1. It takes full effect after you log out.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([
                DefaultsSetting(domain: "com.apple.AppleMultitouchTrackpad", key: "Clicking", type: .bool, on: "1", off: nil),
                DefaultsSetting(domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad", key: "Clicking", type: .bool, on: "1", off: nil),
                DefaultsSetting(domain: "NSGlobalDomain", key: "com.apple.mouse.tapBehavior", type: .int, on: "1", off: nil, currentHost: true)
              ], post: .logout),
              sources: ["https://support.apple.com/guide/mac-help/change-trackpad-settings-mchlp1226/mac", "https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: com.apple.mouse.tapBehavior present in TrackpadExtension.appex and the dyld shared cache on macOS 27.0.1"],
              requires: [.custom({ InputSupport.hasTrackpad() ? nil : "No trackpad found (built-in or Bluetooth)" })],
              confidence: .medium,
              expectedBenefit: "Clicking takes less pressure and is silent.",
              tradeoff: "Resting a finger on the trackpad can cause accidental clicks while typing.",
              audience: [.laptop, .everyone]),

        Tweak(id: "trackpad-three-finger-drag", name: "Three-finger drag", category: .input,
              summary: "Move windows and select text by sliding three fingers, without holding the trackpad down.",
              explanation: "With three-finger drag, you move windows, files and text selections by sliding three fingers on the trackpad instead of pressing and holding. The setting lives in System Settings > Accessibility > Pointer Control > Trackpad Options. Turning it on there also moves three-finger swipe gestures to four fingers, which a plain preference write does not do, so Keel only reads TrackpadThreeFingerDrag from both trackpad domains and opens the Accessibility pane. The key is present in the macOS 27.0.1 dyld shared cache.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let a = InputSupport.bool("com.apple.AppleMultitouchTrackpad", "TrackpadThreeFingerDrag")
                  let b = InputSupport.bool("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadThreeFingerDrag")
                  let on = a == true || b == true
                  return Detection(state: on ? .on : .off, values: [
                    ("built-in trackpad", a.map { $0 ? "on" : "off" } ?? "(not set)"),
                    ("Bluetooth trackpad", b.map { $0 ? "on" : "off" } ?? "(not set)")])
              }, settingsURL: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?PointerControl",
                 instructions: "System Settings > Accessibility > Pointer Control > Trackpad Options > Use trackpad for dragging > Three Finger Drag")),
              sources: ["https://support.apple.com/en-us/102341", "Local check: TrackpadThreeFingerDrag present in the macOS 27.0.1 dyld shared cache; PointerControl and trackpad dragging controls present in AccessibilitySettingsExtension.appex"],
              requires: [.custom({ InputSupport.hasTrackpad() ? nil : "No trackpad found (built-in or Bluetooth)" })],
              confidence: .medium,
              expectedBenefit: "Dragging needs no pressure, which is easier on the hand for long selections.",
              tradeoff: "Three-finger swipes between Spaces and apps move to four fingers.",
              audience: [.laptop]),

        Tweak(id: "mouse-acceleration-off", name: "Pointer acceleration: off (mouse)", category: .input,
              summary: "Mouse pointer movement becomes proportional to hand movement, regardless of speed.",
              explanation: "The pointer moves the same distance for the same mouse movement, however fast you move the mouse. With acceleration on (the default), fast movements travel further, which helps on large screens but makes aiming inconsistent in games and design work. macOS 14 added a “Pointer acceleration” switch in System Settings > Mouse > Advanced; Keel writes com.apple.mouse.linear to true in the global domain, a key that sits next to com.apple.mouse.scaling in the macOS 27.0.1 HID preference table. That this is the key behind the switch is inferred from the binary, not documented. It affects mice only, not trackpads, and needs a logout.",
              risk: .safe, impact: .low, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "com.apple.mouse.linear", type: .bool, on: "1", off: nil)], post: .logout),
              sources: ["https://github.com/apsun/NoMouseAccel", "https://tomsguide.com/how-to/how-to-disable-mouse-acceleration-macos", "Local check: com.apple.mouse.linear in the HID key table of the macOS 27.0.1 dyld shared cache"],
              requires: [.minMacOS(14)],
              confidence: .medium,
              expectedBenefit: "Pointer movement is consistent, which helps aiming in games and precise design work.",
              tradeoff: "Crossing a large screen takes more hand movement; raise Tracking speed to compensate.",
              audience: [.gamer, .creator]),

        Tweak(id: "natural-scrolling-status", name: "Natural scrolling status", category: .input,
              summary: "Shows whether content follows your fingers (natural) or the scroll bar. Keel only reads it.",
              explanation: "Keel shows which scroll direction is set. With natural scrolling, content moves in the direction of your fingers, as on an iPhone; without it, content follows the scroll bar, as on most Windows PCs. A single setting, com.apple.swipescrolldirection in the global domain, applies to both trackpad and mouse. Keel reads it and opens System Settings > Trackpad; neither direction is faster, so this is a preference only.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let v = InputSupport.bool("NSGlobalDomain", "com.apple.swipescrolldirection")
                  let natural = v ?? true
                  return Detection(state: natural ? .on : .off, values: [("com.apple.swipescrolldirection", v.map { $0 ? "1 (natural)" : "0 (scroll bar direction)" } ?? "(not set: natural)")])
              }, settingsURL: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
                 instructions: "System Settings > Trackpad > Scroll & Zoom > Natural scrolling (also in Mouse settings)")),
              sources: ["https://raw.githubusercontent.com/mathiasbynens/dotfiles/main/.macos", "Local check: com.apple.swipescrolldirection present in TrackpadExtension.appex on macOS 27.0.1"],
              expectedBenefit: "You can see which scroll direction is set without opening Settings.",
              tradeoff: "Nothing; Keel only reads it.",
              audience: [.everyone]),

        // MARK: Sound

        Tweak(id: "startup-chime-off", name: "Startup sound: off", category: .input,
              summary: "The Mac starts up silently instead of playing the chime.",
              explanation: "The Mac no longer plays a chime when it starts up. The setting is stored in NVRAM, the small settings memory the firmware reads before macOS loads, as the variable StartupMute; when it is absent the chime plays. On macOS 27.0.1 this is the variable that the “Play sound on startup” switch in System Settings > Sound reads. Keel sets StartupMute to %01, which asks for your administrator password, and records the previous value; revert deletes the variable or restores the old value.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .custom(CustomMechanism(
                detect: { await InputSupport.startupMuteDetection() },
                apply: { ctx in
                    let prev = await InputSupport.startupMuteValue()
                    ctx.privileged(.nvram(name: "StartupMute", value: "%01"))
                    return ["previous": prev ?? ""]
                },
                revert: { ctx, orig in
                    let prev = orig["previous"] ?? ""
                    ctx.privileged(.nvram(name: "StartupMute", value: ["%00", "%01"].contains(prev) ? prev : nil))
                },
                applyCommands: ["sudo nvram StartupMute=%01"],
                revertCommands: ["sudo nvram -d StartupMute  # or restore the recorded value"],
                needsAdmin: true)),
              sources: ["https://eclecticlight.co/2022/01/22/explainer-non-volatile-ram-nvram/", "https://tidbits.com/2020/02/24/tipbits-enable-the-startup-chime-on-new-macs/", "Local check: Sound.appex on macOS 27.0.1 reads 40A0DDD2-77F8-4392-B4A3-1E7304206516:StartupMute (“property exists and is not 0”)"],
              confidence: .medium,
              expectedBenefit: "Starting or restarting the Mac makes no sound, for example in a meeting or library.",
              tradeoff: "No audible sign that the Mac has powered on and passed its startup checks.",
              audience: [.everyone]),

        Tweak(id: "ui-sound-effects-status", name: "User interface sound effects", category: .input,
              summary: "Shows whether system sounds play for actions like emptying the Trash. Keel opens the setting.",
              explanation: "Keel shows whether macOS plays sound effects for actions such as emptying the Trash, moving files or taking a screenshot. The switch “Play user interface sound effects” in System Settings > Sound stores com.apple.sound.uiaudio.enabled, which the macOS 27.0.1 AudioToolbox code reads. Reports disagree on which preference domain holds it, so Keel reads both candidates and opens Sound settings rather than writing it. Alert sounds are controlled separately.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .manual(ManualMechanism(detect: {
                  let g = InputSupport.int("NSGlobalDomain", "com.apple.sound.uiaudio.enabled")
                  let s = InputSupport.int("com.apple.systemsound", "com.apple.sound.uiaudio.enabled")
                  let on = (g ?? s ?? 1) != 0
                  return Detection(state: on ? .off : .on, values: [("com.apple.sound.uiaudio.enabled", (g ?? s).map(String.init) ?? "(not set: sounds on)")])
              }, settingsURL: "x-apple.systempreferences:com.apple.Sound-Settings.extension",
                 instructions: "System Settings > Sound > Play user interface sound effects")),
              sources: ["https://www.howtogeek.com/260683/how-to-disable-the-trash-and-screenshot-sound-effects-on-a-mac/", "Local check: com.apple.sound.uiaudio.enabled present in AudioToolbox (AudioServices.cpp) in the macOS 27.0.1 dyld shared cache"],
              confidence: .medium,
              expectedBenefit: "No sound effects for Finder and screenshot actions once turned off.",
              tradeoff: "No audible confirmation that a file action or screenshot happened.",
              audience: [.everyone]),

        Tweak(id: "volume-feedback-off", name: "Volume change sound: off", category: .input,
              summary: "Pressing the volume keys no longer plays a test sound.",
              explanation: "Pressing the volume keys no longer plays a short test sound. Keel sets com.apple.sound.beep.feedback to 0 in the global domain, the key behind “Play feedback when volume is changed” in System Settings > Sound; the key is present in the Sound settings extension on macOS 27.0.1. It takes full effect after you log out.",
              risk: .safe, impact: .cosmetic, recommended: false,
              mechanism: .defaults([DefaultsSetting(domain: "NSGlobalDomain", key: "com.apple.sound.beep.feedback", type: .int, on: "0", off: nil)], post: .logout),
              sources: ["https://mynixos.com/nix-darwin/option/system.defaults.NSGlobalDomain.%22com.apple.sound.beep.feedback%22", "Local check: string present in Sound.appex on macOS 27.0.1"],
              confidence: .medium,
              expectedBenefit: "Adjusting volume during calls or music is silent.",
              tradeoff: "No audible check of the new volume level.",
              audience: [.everyone]),
    ]
}

// MARK: - Helpers (file-private)

private enum InputSupport {
    static func bool(_ domain: String, _ key: String) -> Bool? {
        guard let v = Prefs.value(domain, key) else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return nil
    }

    static func int(_ domain: String, _ key: String) -> Int? {
        guard let v = Prefs.value(domain, key) else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// A built-in trackpad (every Mac laptop) or an Apple Bluetooth trackpad that has been set up on this account.
    static func hasTrackpad() -> Bool {
        if Machine.current.hasBattery { return true }
        let keys = CFPreferencesCopyKeyList("com.apple.driver.AppleBluetoothMultitouch.trackpad" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return !(keys ?? []).isEmpty
    }

    /// Raw StartupMute value (e.g. "%01"), nil when the variable is absent.
    static func startupMuteValue() async -> String? {
        for name in ["StartupMute", "40A0DDD2-77F8-4392-B4A3-1E7304206516:StartupMute"] {
            if let r = await Shell.probe("/usr/sbin/nvram", [name]), r.ok {
                let parts = r.output.split(separator: "\t", maxSplits: 1)
                if parts.count == 2 { return String(parts[1]).trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    static func startupMuteDetection() async -> Detection {
        let v = await startupMuteValue()
        let muted = v != nil && v != "%00" && v != "0"
        return Detection(state: muted ? .on : .off, values: [("nvram StartupMute", v ?? "(absent: chime plays)")])
    }
}
