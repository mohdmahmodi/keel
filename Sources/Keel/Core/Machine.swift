import Foundation
import Metal
import CoreGraphics
import IOKit.ps
import AppKit
import IOKit

/// Hardware facts read once at launch. Hardware-dependent tweaks read these, never constants.
struct MachineProfile: Sendable {
    var osMajor = 0, osMinor = 0, osPatch = 0
    var osBuild = ""
    var chip = ""
    var modelID = ""            // e.g. Mac16,7
    var modelName = ""          // e.g. MacBook Pro
    var perfCores = 0, effCores = 0, totalCores = 0, gpuCores = 0
    var memoryBytes: UInt64 = 0
    var metalWorkingSetBytes: UInt64 = 0
    var hasBattery = false
    var powerSources: [String] = []        // "Battery Power", "AC Power" as pmset names them
    var pmsetCapabilities: Set<String> = []
    var wifiDevice: String? = nil          // BSD name, e.g. en0 (en1 on a Mac mini)
    var wifiService: String? = nil         // network service name, e.g. "Wi-Fi"
    var primaryDevice: String? = nil
    var primaryService: String? = nil
    var mainDisplayMaxRefresh: Double = 60
    var hasXcode = false
    var hasCommandLineTools = false
    var brewPrefix: String? = nil
    var home = NSHomeDirectory()
    var uid: uid_t = getuid()

    var memoryGB: Int { Int((Double(memoryBytes) / 1_073_741_824).rounded()) }
    var memoryMB: Int { Int(memoryBytes / 1_048_576) }
    var isLaptop: Bool { hasBattery }
    var osString: String { osPatch > 0 ? "\(osMajor).\(osMinor).\(osPatch)" : "\(osMajor).\(osMinor)" }
    var supportsHighPowerMode: Bool { pmsetCapabilities.contains("highpowermode") }
    var supportsLowPowerMode: Bool { pmsetCapabilities.contains("lowpowermode") }
    var hasProMotion: Bool { mainDisplayMaxRefresh > 61 }
    /// "MacBook Pro · M4 Pro · 24 GB"
    var shortDescription: String { [modelName, chip.replacingOccurrences(of: "Apple ", with: ""), "\(memoryGB) GB"].filter { !$0.isEmpty }.joined(separator: " · ") }
    /// Kernel default GPU working set when iogpu.wired_limit_mb is 0. When the limit has been raised,
    /// Metal reports the raised value, so this estimates the default (≈ 74 % below 36 GB, 75 % above).
    var defaultGPUWorkingSetBytes: UInt64 {
        // Read Metal live: the profile may have been captured while the limit was raised.
        if (Sysctl.int("iogpu.wired_limit_mb") ?? 0) == 0, let dev = MTLCreateSystemDefaultDevice() { return dev.recommendedMaxWorkingSetSize }
        return UInt64(Double(memoryBytes) * (memoryGB >= 36 ? 0.75 : 0.74))
    }
}

enum Machine {
    nonisolated(unsafe) private static var cached: MachineProfile?
    private static let lock = NSLock()

    /// Loaded on first use: one pmset and two networksetup calls, the rest in-process.
    static func profile() async -> MachineProfile {
        lock.lock(); if let c = cached { lock.unlock(); return c }; lock.unlock()
        let p = await load()
        lock.lock(); cached = p; lock.unlock()
        return p
    }
    /// Re-reads the default route and its network service, which change when docking or toggling Wi-Fi.
    static func refreshNetwork() async {
        var m = await profile()
        guard let r = try? await Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5) else { return }
        let dev = r.stdout.range(of: "interface: (\\S+)", options: .regularExpression).map { r.stdout[$0].replacingOccurrences(of: "interface: ", with: "") }
        guard dev != m.primaryDevice else { return }
        m.primaryDevice = dev
        m.primaryService = nil
        if let o = try? await Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: 10) {
            var last: String?
            for line in o.stdout.split(separator: "\n").map(String.init) {
                if let rg = line.range(of: "^\\([0-9*]+\\) ", options: .regularExpression) { last = String(line[rg.upperBound...]) }
                if let d = line.range(of: "Device: ([a-z0-9]+)\\)", options: .regularExpression),
                   line[d].replacingOccurrences(of: "Device: ", with: "").replacingOccurrences(of: ")", with: "") == dev { m.primaryService = last }
            }
        }
        override(m)
    }

    /// Replaces the profile (simulation and tests only).
    static func override(_ p: MachineProfile) { lock.lock(); cached = p; lock.unlock() }

    /// Valid after `profile()` has completed once.
    static var current: MachineProfile { lock.lock(); defer { lock.unlock() }; return cached ?? MachineProfile() }

    private static func load() async -> MachineProfile {
        var m = MachineProfile()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        m.osMajor = v.majorVersion; m.osMinor = v.minorVersion; m.osPatch = v.patchVersion
        m.osBuild = Sysctl.string("kern.osversion") ?? ""
        m.chip = Sysctl.string("machdep.cpu.brand_string") ?? ""
        m.modelID = Sysctl.string("hw.model") ?? ""
        m.perfCores = Sysctl.int("hw.perflevel0.physicalcpu") ?? 0
        m.effCores = Sysctl.int("hw.perflevel1.physicalcpu") ?? 0
        m.totalCores = Sysctl.int("hw.ncpu") ?? ProcessInfo.processInfo.activeProcessorCount
        m.memoryBytes = UInt64(Sysctl.int64("hw.memsize") ?? 0)
        if let dev = MTLCreateSystemDefaultDevice() {
            m.metalWorkingSetBytes = dev.recommendedMaxWorkingSetSize
        }
        m.modelName = modelName(for: m.modelID)
        // Battery: IOPowerSources lists an internal battery only on laptops.
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType { m.hasBattery = true }
            }
        }
        async let custom = Shell.run("/usr/bin/pmset", ["-g", "custom"], timeout: 10)
        async let cap = Shell.run("/usr/bin/pmset", ["-g", "cap"], timeout: 10)
        async let ports = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 10)
        async let order = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: 10)
        async let route = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5)
        if let c = try? await custom {
            m.powerSources = c.stdout.split(separator: "\n").filter { !$0.hasPrefix(" ") && $0.hasSuffix(":") }.map { String($0.dropLast()) }
        }
        if let c = try? await cap {
            m.pmsetCapabilities = Set(c.stdout.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if let p = try? await ports {
            var lastPort = ""
            for line in p.stdout.split(separator: "\n") {
                if line.hasPrefix("Hardware Port: ") { lastPort = String(line.dropFirst(15)) }
                if line.hasPrefix("Device: "), lastPort == "Wi-Fi" || lastPort == "AirPort" { m.wifiDevice = String(line.dropFirst(8)) }
            }
        }
        if let r = try? await route, let rg = r.stdout.range(of: "interface: (\\S+)", options: .regularExpression) {
            m.primaryDevice = r.stdout[rg].replacingOccurrences(of: "interface: ", with: "")
        }
        if let o = try? await order {
            // "(1) Wi-Fi" followed by "(Hardware Port: Wi-Fi, Device: en0)"
            var lastService: String?
            for line in o.stdout.split(separator: "\n").map(String.init) {
                if let rg = line.range(of: "^\\([0-9*]+\\) ", options: .regularExpression) { lastService = String(line[rg.upperBound...]) }
                if let dev = line.range(of: "Device: ([a-z0-9]+)\\)", options: .regularExpression) {
                    let d = line[dev].replacingOccurrences(of: "Device: ", with: "").replacingOccurrences(of: ")", with: "")
                    if d == m.wifiDevice { m.wifiService = lastService }
                    if d == m.primaryDevice { m.primaryService = lastService }
                }
            }
        }
        m.mainDisplayMaxRefresh = maxRefresh()
        let devDir = (try? await Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5))?.output ?? ""
        m.hasXcode = devDir.contains(".app/Contents/Developer") && FileManager.default.fileExists(atPath: devDir)
        m.hasCommandLineTools = !devDir.isEmpty && FileManager.default.fileExists(atPath: devDir)
        for prefix in ["/opt/homebrew", "/usr/local"] where FileManager.default.isExecutableFile(atPath: "\(prefix)/bin/brew") { m.brewPrefix = prefix; break }
        return m
    }

    /// Marketing name from the device tree, e.g. "MacBook Pro (16-inch, 2024)". Present on every Apple Silicon Mac.
    static func modelName(for id: String) -> String {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            if let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                if !name.isEmpty { return name }
            }
        }
        return "Mac"
    }

    /// Highest refresh rate the main display offers (120 on ProMotion panels).
    static func maxRefresh() -> Double {
        let id = CGMainDisplayID()
        var best = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        if let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] { best = max(best, modes.map(\.refreshRate).max() ?? 0) }
        return best > 0 ? best : 60
    }

    static func appURL(_ bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static func appInstalled(_ bundleID: String) -> Bool { appURL(bundleID) != nil }
}

/// Requirements a tweak needs on this Mac. The first unmet one becomes the "N/A" reason.
enum Requirement: Sendable {
    case laptop
    case desktop
    case xcode
    case homebrew
    case minMemoryGB(Int)
    case minMacOS(Int)
    case maxMacOS(Int)
    case pmsetCapability(String)
    case app(bundleID: String, name: String)
    case anyPath([String], name: String)
    case custom(@Sendable () async -> String?)

    func unmetReason(_ m: MachineProfile) async -> String? {
        switch self {
        case .laptop: return m.hasBattery ? nil : "Only applies to Macs with a battery"
        case .desktop: return m.hasBattery ? "Only applies to desktop Macs" : nil
        case .xcode: return m.hasXcode ? nil : "Xcode is not installed"
        case .homebrew: return m.brewPrefix != nil ? nil : "Homebrew is not installed"
        case .minMemoryGB(let g): return m.memoryGB >= g ? nil : "Needs at least \(g) GB of memory (this Mac has \(m.memoryGB) GB)"
        case .minMacOS(let v): return m.osMajor >= v ? nil : "Needs macOS \(v) or later"
        case .maxMacOS(let v): return m.osMajor <= v ? nil : "Not applicable after macOS \(v)"
        case .pmsetCapability(let c): return m.pmsetCapabilities.contains(c) ? nil : "This Mac does not support \(c)"
        case .app(let id, let name): return Machine.appInstalled(id) ? nil : "\(name) is not installed"
        case .anyPath(let paths, let name): return paths.contains { FileManager.default.fileExists(atPath: Shell.expand($0)) } ? nil : "\(name) not found"
        case .custom(let f): return await f()
        }
    }
}
