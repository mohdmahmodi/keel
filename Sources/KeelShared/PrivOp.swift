import Foundation
import Darwin

/// Everything Keel can do as root. The helper runs only these, each checked against an allow-list.
public enum PrivOp: Codable, Sendable, Equatable, CustomStringConvertible {
    case pmset(scope: String, key: String, value: String)          // scope: -a | -b | -c
    case pmsetRepeatCancel
    case pmsetRepeat(type: String, days: String, time: String)      // e.g. restart W 03:00:00
    case sysctl(name: String, value: Int)
    case installSysctlDaemon(name: String, value: Int)              // re-applies a sysctl at boot
    case removeSysctlDaemon(name: String)
    case launchctl(verb: String, domain: String, target: String)    // bootout|bootstrap|enable|disable
    case moveFile(from: String, to: String)
    case copyFile(from: String, to: String)                         // into /Library/Launch*: root:wheel 0644
    case removeFile(path: String)
    case setDNS(service: String, servers: [String])                 // ["Empty"] restores DHCP
    case flushDNS
    case firewall(globalOn: Bool?, stealthOn: Bool?)
    case tmExclusion(path: String, add: Bool)                       // fixed-path (-p) exclusion
    case crashReporter(autoSubmit: Bool?, thirdParty: Bool?)
    case interface(name: String, up: Bool)
    case powermetrics(samplers: String, ms: Int)
    case mdutil(volume: String, on: Bool)
    case networkServiceEnabled(service: String, on: Bool)
    /// Root-owned preference files, allow-listed per key (nil deletes the key).
    case rootDefaults(domain: String, key: String, value: Bool?)
    /// systemsetup switches, allow-listed.
    case systemsetup(flag: String, on: Bool)
    /// Allow-listed NVRAM variables (nil value deletes the variable).
    case nvram(name: String, value: String?)

    /// The command line this op corresponds to, for the confirmation sheet and the log.
    public var description: String {
        switch self {
        case .pmset(let s, let k, let v): return "sudo pmset \(s) \(k) \(v)"
        case .pmsetRepeatCancel: return "sudo pmset repeat cancel"
        case .pmsetRepeat(let t, let d, let h): return "sudo pmset repeat \(t) \(d) \(h)"
        case .sysctl(let n, let v): return "sudo sysctl -w \(n)=\(v)"
        case .installSysctlDaemon(let n, let v): return "sudo install /Library/LaunchDaemons/\(KeelConstants.sysctlDaemonLabel(n)).plist  # runs sysctl -w \(n)=\(v) at boot"
        case .removeSysctlDaemon(let n): return "sudo launchctl bootout system/\(KeelConstants.sysctlDaemonLabel(n)); sudo rm /Library/LaunchDaemons/\(KeelConstants.sysctlDaemonLabel(n)).plist"
        case .launchctl(let verb, let dom, let t): return verb == "bootstrap" ? "sudo launchctl bootstrap \(dom) \(t)" : "sudo launchctl \(verb) \(dom)/\(t)"
        case .moveFile(let f, let t): return "sudo mv '\(f)' '\(t)'"
        case .copyFile(let f, let t): return "sudo cp '\(f)' '\(t)'"
        case .removeFile(let p): return "sudo rm '\(p)'"
        case .setDNS(let s, let ips): return "sudo networksetup -setdnsservers '\(s)' \(ips.joined(separator: " "))"
        case .flushDNS: return "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
        case .firewall(let g, let s):
            var parts: [String] = []
            if let g { parts.append("--setglobalstate \(g ? "on" : "off")") }
            if let s { parts.append("--setstealthmode \(s ? "on" : "off")") }
            return "sudo socketfilterfw " + parts.joined(separator: " ")
        case .tmExclusion(let p, let add): return "sudo tmutil \(add ? "addexclusion" : "removeexclusion") -p '\(p)'"
        case .crashReporter(let a, let t):
            var parts: [String] = []
            if let a { parts.append("AutoSubmit=\(a)") }
            if let t { parts.append("ThirdPartyDataSubmit=\(t)") }
            return "sudo defaults write /Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist " + parts.joined(separator: " ")
        case .interface(let n, let up): return "sudo ifconfig \(n) \(up ? "up" : "down")"
        case .powermetrics(let s, let ms): return "sudo powermetrics --samplers \(s) -i \(ms) -n 1"
        case .mdutil(let v, let on): return "sudo mdutil -i \(on ? "on" : "off") '\(v)'"
        case .networkServiceEnabled(let s, let on): return "sudo networksetup -setnetworkserviceenabled '\(s)' \(on ? "on" : "off")"
        case .rootDefaults(let d, let k, let v): return v == nil ? "sudo defaults delete \(d) \(k)" : "sudo defaults write \(d) \(k) -bool \(v! ? "true" : "false")"
        case .systemsetup(let f, let on): return "sudo systemsetup \(f) \(on ? "on" : "off")"
        case .nvram(let n, let v): return v == nil ? "sudo nvram -d \(n)" : "sudo nvram \(n)=\(v!)"
        }
    }
}

public struct OpResult: Codable, Sendable {
    public let ok: Bool
    public let output: String
    public init(ok: Bool, output: String) { self.ok = ok; self.output = output }
}

public struct PrivRequest: Codable, Sendable {
    public let ops: [PrivOp]
    public let uid: UInt32
    public init(ops: [PrivOp], uid: UInt32) { self.ops = ops; self.uid = uid }
}

public enum KeelConstants {
    public static let appBundleID = "com.mohdmahmodi.keel"
    public static let helperMachService = "com.mohdmahmodi.keel.helper"
    public static let helperPlistName = "com.mohdmahmodi.keel.helper.plist"
    public static let helperVersion = "2"
    public static func sysctlDaemonLabel(_ name: String) -> String { "com.keel.sysctl." + name.replacingOccurrences(of: ".", with: "-") }
    public static let allowedSysctls: Set<String> = ["iogpu.wired_limit_mb", "debug.lowpri_throttle_enabled"]
    public static let allowedPmsetKeys: Set<String> = ["powermode", "lowpowermode", "highpowermode", "powernap", "tcpkeepalive", "womp", "lessbright", "halfdim",
                                                       "displaysleep", "sleep", "disksleep", "standby", "standbydelaylow", "standbydelayhigh", "highstandbythreshold",
                                                       "autopoweroff", "autopoweroffdelay", "ttyskeepawake", "networkoversleep", "hibernatemode",
                                                       "autorestart", "proximitywake", "lidwake", "acwake"]
    public static let launchDirs = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]
    public static let allowedRootDefaults: [String: Set<String>] = [
        "/Library/Preferences/com.apple.SoftwareUpdate": ["AutomaticCheckEnabled", "AutomaticDownload", "AutomaticallyInstallMacOSUpdates", "ConfigDataInstall", "CriticalUpdateInstall"],
        "/Library/Preferences/com.apple.commerce": ["AutoUpdate"],
        "/Library/Preferences/com.apple.loginwindow": ["GuestEnabled", "SHOWFULLNAME", "RetriesUntilHint"],
        "/Library/Preferences/com.apple.mDNSResponder": ["NoMulticastAdvertisements"],
    ]
    /// NVRAM variables Keel may set, with their allowed values. StartupMute: %01 silences the startup chime.
    public static let allowedNvram: [String: Set<String>] = ["StartupMute": ["%00", "%01"]]
    public static let allowedSystemsetupFlags: Set<String> = ["-setremotelogin", "-setremoteappleevents", "-setrestartfreeze", "-setrestartpowerfailure", "-setwakeonnetworkaccess"]
}

@objc public protocol KeelHelperXPC {
    func run(_ request: Data, reply: @escaping (Data) -> Void)
    func version(reply: @escaping (String) -> Void)
}

public enum PrivValidationError: Error, CustomStringConvertible {
    case rejected(String)
    public var description: String { if case .rejected(let s) = self { return s }; return "rejected" }
}

extension PrivOp {
    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    /// Canonical path with symlinks in the parent resolved; nil if the parent does not exist.
    static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/.."), !path.contains("\n") else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(parent, &buf) != nil else { return nil }
        return (String(cString: buf) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    static func inLaunchDir(_ p: String) -> Bool {
        KeelConstants.launchDirs.contains { (p as NSString).deletingLastPathComponent == $0 } && p.hasSuffix(".plist")
    }

    static func backupsDir(home: String) -> String { "\(home)/Library/Application Support/Keel/backups" }

    static func inBackups(_ p: String, home: String) -> Bool {
        guard let real = canonical(backupsDir(home: home) + "/x") else { return false }
        let dir = (real as NSString).deletingLastPathComponent
        return (p as NSString).deletingLastPathComponent == dir && p.hasSuffix(".plist")
    }

    static func validIP(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// Throws unless the op is on the allow-list with safe arguments. `home` is the requesting user's home.
    public func validate(home: String, memoryMB: Int) throws {
        func reject(_ why: String) -> PrivValidationError { .rejected("\(description): \(why)") }
        switch self {
        case .pmset(let scope, let key, let value):
            guard ["-a", "-b", "-c"].contains(scope) else { throw reject("bad scope") }
            guard KeelConstants.allowedPmsetKeys.contains(key) else { throw reject("key not allowed") }
            guard Self.matches(value, "^[0-9]{1,4}$") else { throw reject("bad value") }
        case .pmsetRepeatCancel: break
        case .pmsetRepeat(let type, let days, let time):
            guard ["restart", "shutdown", "sleep", "wake", "poweron", "wakeorpoweron"].contains(type) else { throw reject("bad type") }
            guard Self.matches(days, "^[MTWRFSU]{1,7}$"), Self.matches(time, "^[0-2][0-9]:[0-5][0-9]:[0-5][0-9]$") else { throw reject("bad schedule") }
        case .sysctl(let name, let value), .installSysctlDaemon(let name, let value):
            guard KeelConstants.allowedSysctls.contains(name) else { throw reject("sysctl not allowed") }
            if name == "iogpu.wired_limit_mb" {
                guard value == 0 || (value >= 2048 && value <= memoryMB - 2048) else { throw reject("value out of range") }
            } else if name == "debug.lowpri_throttle_enabled" {
                guard value == 0 || value == 1 else { throw reject("value must be 0 or 1") }
            }
        case .removeSysctlDaemon(let name):
            guard KeelConstants.allowedSysctls.contains(name) else { throw reject("sysctl not allowed") }
        case .launchctl(let verb, let domain, let target):
            guard ["bootout", "bootstrap", "enable", "disable"].contains(verb) else { throw reject("verb not allowed") }
            guard domain == "system" || Self.matches(domain, "^gui/[0-9]{1,6}$") else { throw reject("domain not allowed") }
            if verb == "bootstrap" {
                guard let c = Self.canonical(target), Self.inLaunchDir(c) else { throw reject("plist must be in /Library/LaunchAgents or /Library/LaunchDaemons") }
            } else {
                guard Self.matches(target, "^[A-Za-z0-9._-]{1,200}$") else { throw reject("bad label") }
            }
        case .moveFile(let from, let to), .copyFile(let from, let to):
            guard let f = Self.canonical(from), let t = Self.canonical(to) else { throw reject("bad path") }
            let fromLaunch = Self.inLaunchDir(f), toLaunch = Self.inLaunchDir(t)
            let fromBackup = Self.inBackups(f, home: home), toBackup = Self.inBackups(t, home: home)
            guard (fromLaunch && toBackup) || (fromBackup && toLaunch) else { throw reject("only launchd plists between /Library/Launch* and Keel's backups") }
            var st = stat()
            guard lstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw reject("source must be a regular file") }
        case .removeFile(let path):
            guard let c = Self.canonical(path), Self.inLaunchDir(c) else { throw reject("only plists in /Library/Launch*") }
        case .setDNS(let service, let servers):
            guard !service.isEmpty, service.count < 128, !service.contains("\n") else { throw reject("bad service") }
            guard servers == ["Empty"] || (!servers.isEmpty && servers.count <= 6 && servers.allSatisfy(Self.validIP)) else { throw reject("bad server list") }
        case .flushDNS, .firewall, .crashReporter: break
        case .tmExclusion(let path, _):
            guard let c = Self.canonical(path), c.hasPrefix(home + "/") || c.hasPrefix("/Users/") else { throw reject("path must be in a home folder") }
        case .interface(let name, _):
            guard ["awdl0", "llw0"].contains(name) else { throw reject("interface not allowed") }
        case .powermetrics(let samplers, let ms):
            guard Self.matches(samplers, "^[a-z_,]{1,120}$"), (100...5000).contains(ms) else { throw reject("bad sampler request") }
        case .mdutil(let volume, _):
            guard volume.hasPrefix("/Volumes/"), Self.canonical(volume) != nil else { throw reject("only external volumes") }
        case .networkServiceEnabled(let service, _):
            guard !service.isEmpty, service.count < 128, !service.contains("\n") else { throw reject("bad service") }
        case .rootDefaults(let domain, let key, _):
            guard KeelConstants.allowedRootDefaults[domain]?.contains(key) == true else { throw reject("preference not allowed") }
        case .systemsetup(let flag, _):
            guard KeelConstants.allowedSystemsetupFlags.contains(flag) else { throw reject("systemsetup flag not allowed") }
        case .nvram(let name, let value):
            guard KeelConstants.allowedNvram[name].map({ allowed in value == nil || allowed.contains(value!) }) == true else { throw reject("NVRAM variable or value not allowed") }
        }
    }
}
