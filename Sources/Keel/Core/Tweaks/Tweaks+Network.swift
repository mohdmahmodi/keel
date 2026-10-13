import Foundation
import KeelShared

// Nothing assumes Wi-Fi or en0: devices come from MachineProfile, and the DNS tweak reads the default route
// live so it acts on the service that carries traffic now.

extension TweakCatalog {
    static let network: [Tweak] = [
        netAirDropOff, netHandoffOff, netAirPlayReceiverOff, netAWDLSessionDown,
        netDNSCloudflare, netContentCaching, netBonjourAdvertisingOff, netThunderboltBridgeOff, netPrivateRelayCheck,
    ]
}

// MARK: - Catalog entries

private extension TweakCatalog {

    static let netAirDropOff = Tweak(
        id: "airdrop-off", name: "AirDrop receiving: No One", category: .network,
        summary: "Other people's devices can no longer find this Mac in AirDrop. You can still send files.",
        explanation: """
        Other people's iPhones and Macs no longer see this Mac in AirDrop, so they stop asking its Wi-Fi radio to listen for them. AirDrop discovery runs over AWDL (Apple Wireless Direct Link, the peer-to-peer Wi-Fi link between Apple devices), which briefly moves the Wi-Fi radio to another channel and can delay ordinary Wi-Fi traffic by 50–90 ms at a time. On the MacBook Pro Keel was developed on (macOS 26.6.2), pings to the router had a median of 3.9 ms but a 95th percentile of 72 ms, the pattern AWDL produces; the cause was inferred, not isolated. Keel sets com.apple.sharingd DiscoverableMode to "Off" and restarts sharingd, the process behind AirDrop; the values Off, Contacts Only and Everyone are in /usr/libexec/sharingd on macOS 26.6.2 and 27.0.1. Turning this off restores the recorded value, or Contacts Only when nothing was recorded.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .defaults([DefaultsSetting(domain: "com.apple.sharingd", key: "DiscoverableMode", type: .string, on: "Off", off: "Contacts Only")], post: .killSharingd),
        sources: ["https://arxiv.org/abs/1808.03156",
                  "Local check: strings /usr/libexec/sharingd on macOS 27.0.1 lists Off, Contacts Only, Everyone"],
        confidence: .medium,
        expectedBenefit: "Fewer AWDL wake-ups from nearby devices, one of the causes of short lag spikes on Wi-Fi. Strangers cannot send you AirDrop requests.",
        tradeoff: "Nobody can AirDrop to this Mac until you choose Contacts Only or Everyone in Control Center.", audience: [.everyone, .gamer, .privacy])

    static let netHandoffOff = Tweak(
        id: "handoff-off", name: "Handoff and Universal Clipboard off", category: .network,
        summary: "This Mac stops sharing open activities and the clipboard with your iPhone and iPad.",
        explanation: """
        This Mac stops passing what you are doing (open documents, web pages, copied text) to your iPhone and iPad, and stops picking up theirs. Keel sets ActivityAdvertisingAllowed and ActivityReceivingAllowed to false in the per-host domain com.apple.coreservices.useractivityd, which is what System Settings > General > AirDrop & Handoff writes; both key names are in the settings extension and in useractivityd on macOS 27.0.1. It then restarts useractivityd and sharingd so the change applies without logging out. Managed Macs get the same result from the MDM restriction allowActivityContinuation = false (DISA STIG for macOS 26, V-277172).
        """,
        risk: .low, impact: .low, recommended: false,
        mechanism: .custom(CustomMechanism(
            detect: {
                let a = Prefs.string(handoffDomain, "ActivityAdvertisingAllowed", currentHost: true)
                let r = Prefs.string(handoffDomain, "ActivityReceivingAllowed", currentHost: true)
                let off = [a, r].filter { $0 == "0" }.count
                return Detection(state: off == 2 ? .on : (off == 0 ? .off : .partlyOn),
                                 values: [("[host] ActivityAdvertisingAllowed", a ?? "(not set: on)"), ("[host] ActivityReceivingAllowed", r ?? "(not set: on)")])
            },
            apply: { ctx in
                var rec: [String: String] = [:]
                for k in handoffKeys {
                    rec[k] = Prefs.value(handoffDomain, k, currentHost: true).map(Prefs.render) ?? ""
                    guard Prefs.write(handoffDomain, k, "false", type: .bool, currentHost: true) else {
                        throw TweakEngine.EngineError(message: "Could not write \(handoffDomain) \(k)")
                    }
                }
                _ = try? await Shell.run("/usr/bin/killall", ["useractivityd"], timeout: 10)
                ctx.post(.killSharingd)
                return rec
            },
            revert: { ctx, rec in
                for (i, k) in handoffKeys.enumerated() {
                    // Older builds recorded this as a defaults tweak: "0.existed" / "0.value".
                    let legacy = rec["\(i).existed"] == "1" ? rec["\(i).value"] : nil
                    let v = rec[k] ?? legacy ?? ""
                    if v.isEmpty { Prefs.delete(handoffDomain, k, currentHost: true) } else { Prefs.write(handoffDomain, k, v, type: .bool, currentHost: true) }
                }
                _ = try? await Shell.run("/usr/bin/killall", ["useractivityd"], timeout: 10)
                ctx.post(.killSharingd)
            },
            applyCommands: ["defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false",
                            "defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false",
                            "killall useractivityd sharingd"],
            revertCommands: ["defaults -currentHost write com.apple.coreservices.useractivityd … <recorded value>  # or delete when it was unset", "killall useractivityd sharingd"],
            needsAdmin: false)),
        sources: ["https://www.stigviewer.com/stigs/apple_macos_26_tahoe/2026-02-11/finding/V-277172",
                  "Local check: strings AirDropHandoffExtension.appex and useractivityd on macOS 27.0.1"],
        confidence: .medium,
        expectedBenefit: "The Handoff icon no longer appears in the Dock for activities from your phone, and sharingd stops advertising this Mac's activity.",
        tradeoff: "No Handoff between devices and no copy on iPhone, paste on Mac.", audience: [.everyone, .privacy])

    static let netAirPlayReceiverOff = Tweak(
        id: "airplay-receiver-off", name: "AirPlay Receiver off", category: .network,
        summary: "Other devices can no longer cast to this Mac, and it stops listening on ports 5000 and 7000.",
        explanation: """
        Other devices can no longer send video or audio to this Mac's screen and speakers. AirPlay Receiver is on by default; the ControlCenter process then listens on TCP ports 5000 and 7000, and the Mac announces itself over Bonjour (local network discovery) and AWDL. The key published by CIS (com.apple.controlcenter AirplayRecieverEnabled) no longer exists in macOS 27.0.1, and the settings pane now uses a private AirPlay interface, so Keel only detects the state and opens the pane. It counts the receiver as off when no ControlCenter process is listening on TCP port 7000.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let r = await Shell.probe("/usr/sbin/lsof", ["-nP", "-iTCP:7000", "-sTCP:LISTEN"]) else { return .unknown }
                let listening = r.stdout.split(separator: "\n").contains { $0.hasPrefix("ControlCe") }
                return Detection(state: listening ? .off : .on,
                                 values: [("ControlCenter listening on TCP 7000", listening ? "yes (receiver on)" : "no (receiver off)")])
            },
            settingsURL: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension",
            instructions: "System Settings > General > AirDrop & Handoff > AirPlay Receiver: off")),
        sources: ["https://arxiv.org/abs/1808.03156",
                  "Local check: AirplayRecieverEnabled absent from ControlCenter and the dyld shared cache on macOS 27.0.1"],
        confidence: .high,
        expectedBenefit: "This Mac disappears from other devices' AirPlay menus and has two fewer open network ports.",
        tradeoff: "You cannot mirror an iPhone or another Mac to this screen.", audience: [.everyone, .privacy])

    static let netAWDLSessionDown = Tweak(
        id: "awdl-session-down", name: "AWDL off for this session", category: .network,
        summary: "Turns off the device-to-device Wi-Fi link until the Mac sleeps, removing its lag spikes.",
        explanation: """
        The direct Wi-Fi link Apple devices use to talk to each other (AWDL, interface awdl0) stays off until the Mac next sleeps. While AWDL is active the radio spends short slots on other channels, which adds 50–90 ms to some packets on Wi-Fi; a published test on macOS 15 measured the worst local-network ping falling from 93 to 12 ms with awdl0 down. Keel runs `ifconfig awdl0 down` with administrator rights and never installs a watchdog or LaunchDaemon. macOS brings awdl0 back after sleep, after Wi-Fi is turned off and on, or when AirDrop, AirPlay, Sidecar, Universal Control, Continuity Camera or Auto Unlock with Apple Watch needs it. It does nothing for traffic over Ethernet, and users report no gain on 6 GHz networks.
        """,
        risk: .medium, impact: .medium, recommended: false,
        mechanism: .custom(CustomMechanism(
            detect: {
                guard let up = NetIf.isUp("awdl0") else { return .na("This Mac has no awdl0 interface") }
                let route = await netLiveRoute()
                return Detection(state: up ? .off : .on,
                                 values: [("awdl0", up ? "UP" : "DOWN"), ("traffic goes over", route.label)],
                                 note: up ? nil : "Comes back on its own after sleep, a Wi-Fi toggle, or when AirDrop/AirPlay/Sidecar needs it.")
            },
            apply: { ctx in
                ctx.privileged(.interface(name: "awdl0", up: false))
                return ["awdl0": "up"]
            },
            revert: { ctx, _ in ctx.privileged(.interface(name: "awdl0", up: true)) },
            applyCommands: ["sudo ifconfig awdl0 down"], revertCommands: ["sudo ifconfig awdl0 up"], needsAdmin: true)),
        sources: ["https://adamlovattdevops.github.io/awdl-latency-killer/",
                  "https://gyorgy.sh/blog/macos-awdl-network-jitter", "https://developer.apple.com/forums/thread/819926"],
        requires: [.custom({
            let m = await Machine.profile()
            guard let wifi = m.wifiDevice else { return "This Mac has no Wi-Fi interface" }
            guard let primary = m.primaryDevice, primary != wifi, !primary.hasPrefix("utun"), !primary.hasPrefix("ipsec") else { return nil }
            let name = m.primaryService.map { "\($0) (\(primary))" } ?? primary
            return "Traffic goes over \(name), not Wi-Fi (\(wifi)); AWDL only delays Wi-Fi traffic"
        })],
        confidence: .medium,
        expectedBenefit: "Steadier ping on Wi-Fi in games, calls and remote desktop until the Mac next sleeps.",
        tradeoff: "AirDrop, AirPlay, Sidecar, Universal Control, Continuity Camera and Auto Unlock with Apple Watch stop working until awdl0 is back up.", audience: [.everyone, .gamer])

    static let netDNSCloudflare = Tweak(
        id: "dns-cloudflare", name: "DNS: Cloudflare, current resolver as fallback", category: .network,
        summary: "The active network service looks up names with 1.1.1.1. Run the Benchmark DNS test first.",
        explanation: """
        The Mac looks up website names with Cloudflare's public DNS (1.1.1.1 and 1.0.0.1) instead of your router or provider. Keel sets this on the network service that carries traffic now (usually Wi-Fi on a laptop, Ethernet on a desktop), keeps your current resolvers after Cloudflare in case it is unreachable, records the exact previous list and flushes the DNS cache; this needs an administrator password. On the home connection where it was tested, the median uncached lookup fell from 59 ms to 28 ms, while cached lookups were faster through the router, so measure your own network first. macOS moves to the next server only after a timeout, so names only your router knows (printer.lan) may stop resolving; Bonjour .local names keep working. The setting follows the service to every network it joins, including office networks with internal names and hotel sign-in pages, and Safari with iCloud Private Relay bypasses it.
        """,
        risk: .medium, impact: .low, recommended: false,
        mechanism: .custom(CustomMechanism(
            detect: {
                guard let svc = await netDNSTargetService() else { return .na("No active network service") }
                let servers = await netDNSServers(svc)
                let effective = await netEffectiveResolvers()
                return Detection(state: servers.first == "1.1.1.1" ? .on : .off,
                                 values: [("service", svc),
                                          ("networksetup -getdnsservers", servers.isEmpty ? "(none set: DHCP)" : servers.joined(separator: ", ")),
                                          ("in use (scutil --dns)", effective.isEmpty ? "(none)" : effective.joined(separator: ", "))])
            },
            apply: { ctx in
                guard let svc = await netDNSTargetService() else { throw TweakEngine.EngineError(message: "No active network service") }
                let previous = await netDNSServers(svc)
                var fallback = previous.filter { !["1.1.1.1", "1.0.0.1"].contains($0) }
                if fallback.isEmpty { fallback = await netEffectiveResolvers().filter { !["1.1.1.1", "1.0.0.1"].contains($0) } }
                if fallback.isEmpty, let gw = await netLiveRoute().gateway { fallback = [gw] }
                let list = Array((["1.1.1.1", "1.0.0.1"] + fallback.filter(netValidIP)).prefix(5))
                ctx.privileged([.setDNS(service: svc, servers: list), .flushDNS])
                return ["service": svc, "previous": previous.isEmpty ? "Empty" : previous.joined(separator: " ")]
            },
            revert: { ctx, rec in
                var svc = rec["service"]
                if svc == nil { svc = await netDNSTargetService() }
                guard let svc else { throw TweakEngine.EngineError(message: "No network service recorded") }
                let prev = (rec["previous"] ?? "Empty").split(separator: " ").map(String.init).filter { $0 == "Empty" || netValidIP($0) }
                ctx.privileged([.setDNS(service: svc, servers: prev.isEmpty ? ["Empty"] : prev), .flushDNS])
            },
            applyCommands: ["sudo networksetup -setdnsservers <active service> 1.1.1.1 1.0.0.1 <current resolvers or router>",
                            "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"],
            revertCommands: ["sudo networksetup -setdnsservers <recorded service> <recorded list, or Empty for DHCP>",
                             "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"],
            needsAdmin: true)),
        sources: ["man networksetup (-setdnsservers … Empty)",
                  "https://developer.apple.com/support/prepare-your-network-for-icloud-private-relay/"],
        confidence: .medium,
        expectedBenefit: "Pages on sites you have not visited recently can start loading a little sooner, about 30 ms per lookup on the network where it was measured.",
        tradeoff: "Names only your router knows may stop resolving, and office or hotel networks that rely on their own DNS can misbehave on this service.", audience: [.everyone, .gamer])

    static let netContentCaching = Tweak(
        id: "content-caching", name: "Content Caching for your other Apple devices", category: .network,
        summary: "This Mac keeps local copies of Apple updates and apps for the other Apple devices on your network.",
        explanation: """
        Content Caching makes this Mac a local download cache for Apple software. When one iPhone, iPad or Mac downloads a system update or App Store app, the others on the same network get it from this Mac at local-network speed instead of downloading it again; iCloud content can be cached too. Devices find the cache on their own, and Apple notes they find it sooner after a restart. Keel reads `AssetCacheManagerUtil status`, which needs no administrator rights on macOS 27.0.1, and opens System Settings > General > Sharing so you can choose what to cache. It suits a Mac that stays on and wired; with a single Apple device it does nothing.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let r = await Shell.probe("/usr/bin/AssetCacheManagerUtil", ["status"]) else { return .unknown }
                var fields: [String: String] = [:]
                for line in r.combined.split(separator: "\n") {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, ["Activated", "Active", "CacheUsed", "CacheLimit"].contains(parts[0]) { fields[parts[0]] = parts[1] }
                }
                guard let activated = fields["Activated"] else { return .unknown }
                return Detection(state: activated == "true" ? .on : .off,
                                 values: ["Activated", "Active", "CacheUsed", "CacheLimit"].compactMap { k in fields[k].map { (k, $0) } })
            },
            settingsURL: "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
            instructions: "System Settings > General > Sharing > Content Caching: on, then the (i) button to choose what to cache")),
        sources: ["https://support.apple.com/guide/mac-help/mchl3b6c3720/mac", "https://support.apple.com/guide/deployment/depe9b5c1aab/web",
                  "Local check: AssetCacheManagerUtil status on macOS 27.0.1 runs without admin"],
        requires: [.desktop],
        confidence: .high,
        expectedBenefit: "Updates and app downloads on your other Apple devices finish at home-network speed and come over the internet once.",
        tradeoff: "Uses disk space on this Mac (you can set a limit) and only serves devices while this Mac is awake.", audience: [.everyone])

    static let netBonjourAdvertisingOff = Tweak(
        id: "bonjour-advertising-off", name: "Bonjour advertising off", category: .network,
        summary: "This Mac stops announcing its name and services on the local network. Applies after a restart.",
        explanation: """
        This Mac stops announcing its name and shared services to other devices on the local network through Bonjour, Apple's local discovery protocol. Keel sets NoMulticastAdvertisements to true in /Library/Preferences/com.apple.mDNSResponder.plist, which needs an administrator password; this is the CIS benchmark remediation (item 4.1, Level 2). mDNSResponder on macOS 27.0.1 still contains the key and reads it when it starts, so it applies after a restart. This Mac can still find printers, speakers and servers, but other devices can no longer find it. It is a privacy setting for shared and public networks, not a speed setting.
        """,
        risk: .medium, impact: .low, recommended: false,
        mechanism: .custom(CustomMechanism(
            detect: {
                let v = Prefs.value(mdnsPrefs, "NoMulticastAdvertisements").map(Prefs.render)
                return Detection(state: v == "1" ? .on : .off,
                                 values: [("NoMulticastAdvertisements", v ?? "(not set: advertising on)")],
                                 note: v == "1" ? "mDNSResponder reads this at startup; restart the Mac if you changed it recently." : nil)
            },
            apply: { ctx in
                let prev = Prefs.value(mdnsPrefs, "NoMulticastAdvertisements").map(Prefs.render) ?? ""
                ctx.privileged(.rootDefaults(domain: mdnsPrefs, key: "NoMulticastAdvertisements", value: true))
                return ["previous": prev]
            },
            revert: { ctx, rec in
                let prev = rec["previous"] ?? ""
                ctx.privileged(.rootDefaults(domain: mdnsPrefs, key: "NoMulticastAdvertisements", value: prev.isEmpty ? nil : prev == "1"))
            },
            applyCommands: ["sudo defaults write /Library/Preferences/com.apple.mDNSResponder NoMulticastAdvertisements -bool true", "Restart the Mac"],
            revertCommands: ["sudo defaults delete /Library/Preferences/com.apple.mDNSResponder NoMulticastAdvertisements  # or the recorded value", "Restart the Mac"],
            needsAdmin: true)),
        sources: ["https://www.tenable.com/audits/items/CIS_Apple_macOS_26_Tahoe_v1.1.0_L2.audit:aa2209fe7d18b879e4cd5ea9e62d3ba1",
                  "Local check: strings /usr/sbin/mDNSResponder on macOS 27.0.1 contains NoMulticastAdvertisements"],
        confidence: .medium,
        expectedBenefit: "After a restart, this Mac's name and services no longer appear to other people on the same network.",
        tradeoff: "Nobody can AirDrop to it over the local network, AirPlay to it, or find its shared folders, screen or printers by name.", audience: [.privacy])

    static let netThunderboltBridgeOff = Tweak(
        id: "thunderbolt-bridge-off", name: "Thunderbolt Bridge service off", category: .network,
        summary: "Turns off the unused Mac-to-Mac Thunderbolt network service. Tidier, not faster.",
        explanation: """
        The network connection Macs use to talk to each other over a Thunderbolt cable (service Thunderbolt Bridge, interface bridge0) is turned off. That removes one entry from the Network list and one service for configd, the process that tracks network state, to evaluate. Claims that this speeds up network changes have not been measured anywhere credible, so it is listed as cosmetic; hardening guides such as the DISA STIG turn off unused network services to reduce what can be attacked. Keel needs an administrator password, refuses while bridge0 has an active link, and leaves USB and dock Ethernet adapters alone.
        """,
        risk: .low, impact: .cosmetic, recommended: false,
        mechanism: .custom(CustomMechanism(
            detect: {
                guard let s = await netServices().first(where: { $0.port == "Thunderbolt Bridge" }) else { return .na("This Mac has no Thunderbolt Bridge service") }
                return Detection(state: s.enabled ? .off : .on, values: [("service", s.name), ("device", s.device), ("enabled", s.enabled ? "yes" : "no")])
            },
            apply: { ctx in
                guard let s = await netServices().first(where: { $0.port == "Thunderbolt Bridge" }) else { throw TweakEngine.EngineError(message: "This Mac has no Thunderbolt Bridge service") }
                if let r = await Shell.probe("/sbin/ifconfig", [s.device]), r.stdout.contains("status: active") {
                    throw TweakEngine.EngineError(message: "\(s.name) is connected right now; disconnect the Thunderbolt cable first")
                }
                ctx.privileged(.networkServiceEnabled(service: s.name, on: false))
                return ["service": s.name]
            },
            revert: { ctx, rec in
                var name = rec["service"]
                if name == nil { name = await netServices().first(where: { $0.port == "Thunderbolt Bridge" })?.name }
                guard let name else { throw TweakEngine.EngineError(message: "This Mac has no Thunderbolt Bridge service") }
                ctx.privileged(.networkServiceEnabled(service: name, on: true))
            },
            applyCommands: ["sudo networksetup -setnetworkserviceenabled 'Thunderbolt Bridge' off"],
            revertCommands: ["sudo networksetup -setnetworkserviceenabled 'Thunderbolt Bridge' on"],
            needsAdmin: true)),
        sources: ["https://stigviewer.com/stig/apple_os_x_10.13/2021-03-29/finding/V-214917"],
        confidence: .low,
        expectedBenefit: "One fewer entry in Network settings. No measurable speed change.",
        tradeoff: "Migration Assistant over a cable, Share Disk and Mac-to-Mac clustering need it turned back on.", audience: [.everyone])

    static let netPrivateRelayCheck = Tweak(
        id: "private-relay-check", name: "iCloud Private Relay", category: .network,
        summary: "Shows a hint of the relay's state and opens its setting. macOS has no supported way to read it.",
        explanation: """
        iCloud Private Relay hides your IP address from websites by sending Safari and Mail traffic through two relays. Measurements disagree on its cost: Howard Oakley (2023) saw responsiveness under load fall from 86 to 5 RPM (round trips per minute, the score from the networkQuality command) on one Mac and stay unchanged on another, and a PAM 2023 study found throughput mostly unaffected with occasional large drops. Keel can only show the undocumented status code stored in com.apple.networkserviceproxy and does not map that code to on or off. Decide per network with Limit IP address tracking in the network's Details, or for the account under System Settings > Apple Account > iCloud.
        """,
        risk: .safe, impact: .low, recommended: false,
        mechanism: .manual(ManualMechanism(
            detect: {
                guard let blob = Prefs.value("com.apple.networkserviceproxy", "NSPServiceStatusManagerInfo") as? Data else {
                    return Detection(state: .unknown, values: [("com.apple.networkserviceproxy", "no relay status stored")], note: "Check System Settings > Apple Account > iCloud > Private Relay.")
                }
                let code = netRelayStatusCode(blob).map { "status code \($0) (undocumented)" } ?? "present, not readable"
                return Detection(state: .unknown, values: [("relay status", code)], note: "Check System Settings > Apple Account > iCloud > Private Relay.")
            },
            settingsURL: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
            instructions: "System Settings > Apple Account > iCloud > Private Relay; per network: Network > (service) > Details > Limit IP address tracking")),
        sources: ["https://eclecticlight.co/2023/12/11/does-icloud-private-relay-reduce-network-responsiveness/",
                  "https://support.apple.com/en-us/102022"],
        confidence: .low,
        expectedBenefit: "You can compare networkQuality with and without the relay and decide per network.",
        tradeoff: "With the relay off, websites and trackers in Safari and Mail see your IP address.", audience: [.privacy, .everyone])
}

// MARK: - Helpers

/// IPv4 or IPv6 literal without a scope suffix (what `networksetup -setdnsservers` and the helper accept).
private func netValidIP(_ s: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
}

private struct NetRoute: Sendable {
    var device: String?
    var gateway: String?
    var service: String?
    var label: String { device.map { d in service.map { "\($0) (\(d))" } ?? d } ?? "no default route" }
}

private struct NetService: Sendable {
    let name: String
    let port: String
    let device: String
    let enabled: Bool
}

private extension TweakCatalog {
    static let handoffDomain = "com.apple.coreservices.useractivityd"
    static let handoffKeys = ["ActivityAdvertisingAllowed", "ActivityReceivingAllowed"]
    static let mdnsPrefs = "/Library/Preferences/com.apple.mDNSResponder"

    /// `networksetup -listnetworkserviceorder`, parsed. "(*)" marks a disabled service.
    static func netServices() async -> [NetService] {
        guard let r = await Shell.probe("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else { return [] }
        var out: [NetService] = []
        var pending: (name: String, enabled: Bool)?
        for line in r.stdout.split(separator: "\n").map(String.init) {
            if let rg = line.range(of: "^\\(([0-9]+|\\*)\\) ", options: .regularExpression) {
                pending = (String(line[rg.upperBound...]), !line.hasPrefix("(*)"))
            } else if let p = pending, line.hasPrefix("(Hardware Port: ") {
                let body = line.dropFirst("(Hardware Port: ".count).dropLast()   // "Wi-Fi, Device: en0"
                let parts = body.components(separatedBy: ", Device: ")
                out.append(NetService(name: p.name, port: parts.first ?? "", device: parts.count > 1 ? parts[1] : "", enabled: p.enabled))
                pending = nil
            }
        }
        return out
    }

    /// The interface and gateway that carry traffic right now (live, not the launch-time profile).
    static func netLiveRoute() async -> NetRoute {
        var route = NetRoute()
        if let r = await Shell.probe("/sbin/route", ["-n", "get", "default"]), r.ok {
            for line in r.stdout.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("interface: ") { route.device = String(t.dropFirst(11)) }
                if t.hasPrefix("gateway: ") { route.gateway = String(t.dropFirst(9)) }
            }
        }
        if let dev = route.device { route.service = await netServices().first { $0.device == dev }?.name }
        if route.device == nil { let m = await Machine.profile(); route.device = m.primaryDevice; route.service = m.primaryService }
        if let gw = route.gateway, !netValidIP(gw) { route.gateway = nil }
        return route
    }

    /// The service the DNS tweak acts on: the one recorded when it was applied, else the live primary service.
    static func netDNSTargetService() async -> String? {
        let services = await netServices()
        if let rec = BackupStore.latest(for: "dns-cloudflare")?.original["service"], services.contains(where: { $0.name == rec }) { return rec }
        if let live = await netLiveRoute().service { return live }
        let m = await Machine.profile()
        return m.primaryService ?? m.wifiService ?? services.first(where: \.enabled)?.name
    }

    /// Manually set DNS servers for a service; [] means none set (DHCP).
    static func netDNSServers(_ service: String) async -> [String] {
        guard let r = await Shell.probe("/usr/sbin/networksetup", ["-getdnsservers", service]), r.ok else { return [] }
        return r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(netValidIP)
    }

    /// Nameservers of the default resolver (#1) in `scutil --dns`, skipping scoped link-local addresses.
    static func netEffectiveResolvers() async -> [String] {
        guard let r = await Shell.probe("/usr/sbin/scutil", ["--dns"]) else { return [] }
        var inFirst = false
        var out: [String] = []
        for line in r.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("resolver #") { if inFirst { break }; inFirst = t == "resolver #1"; continue }
            if inFirst, t.hasPrefix("nameserver["), let v = t.components(separatedBy: " : ").last, netValidIP(v), !out.contains(v) { out.append(v) }
        }
        return out
    }

    /// PrivacyProxyServiceStatus from the NSKeyedArchiver blob, if present (meaning undocumented).
    static func netRelayStatusCode(_ data: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        for o in objects { if let d = o as? [String: Any], let n = d["PrivacyProxyServiceStatus"] as? Int { return n } }
        return nil
    }
}
