import Foundation
import Darwin
import IOKit
import IOKit.ps
import CoreWLAN
import SystemConfiguration
import Observation
import AppKit

// MARK: - Facts

struct HardwareFacts: Sendable, Equatable {
    var model = "", modelID = "", chip = "", cores = "", gpuCores = 0, memoryGB = 0.0, osVersion = "", build = ""
    var bootDate = Date(timeIntervalSince1970: 0)
    var uptime: String {
        guard bootDate.timeIntervalSince1970 > 0 else { return "—" }
        let up = Int(Date().timeIntervalSince(bootDate))
        let d = up / 86400, h = (up % 86400) / 3600, m = (up % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
    }
}

enum MemoryPressure: String, Sendable, Equatable {
    case normal, warning, critical
    var label: String { rawValue.uppercased() }
}

struct MemoryFacts: Sendable, Equatable {
    var totalBytes: UInt64 = 0
    /// Activity Monitor's "Memory Used": app + wired + compressed.
    var usedBytes: UInt64 = 0
    var appBytes: UInt64 = 0, wiredBytes: UInt64 = 0, compressedBytes: UInt64 = 0, cachedBytes: UInt64 = 0, freeBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0, swapTotalBytes: UInt64 = 0
    var pressure: MemoryPressure = .normal
    /// kern.memorystatus_level: what `memory_pressure` prints as "free percentage".
    var freePercent = 0
    var gpuWiredLimitMB = 0
    var usedFraction: Double { totalBytes == 0 ? 0 : min(1, Double(usedBytes) / Double(totalBytes)) }
    var pressureLevel: String { pressure.rawValue }
}

struct CPUFacts: Sendable, Equatable {
    /// 0…1 across all cores, sampled over the last interval.
    var usage: Double = 0
    var user: Double = 0, system: Double = 0
    var history: [Double] = []
    var load1 = 0.0, load5 = 0.0, load15 = 0.0
    var thermal: ProcessInfo.ThermalState = .nominal
    var thermalLabel: String {
        switch thermal {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

struct StorageFacts: Sendable, Equatable {
    var containerBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    /// Includes purgeable space (Finder's "available").
    var importantAvailableBytes: UInt64 = 0
    var purgeableBytes: UInt64 = 0
    var localSnapshots: [String] = []
    var fileVaultOn: Bool? = nil
    var freePercent: Double { containerBytes == 0 ? 0 : Double(freeBytes) / Double(containerBytes) * 100 }
    var availablePercent: Double { containerBytes == 0 ? 0 : Double(max(freeBytes, importantAvailableBytes)) / Double(containerBytes) * 100 }
    var usedFraction: Double { containerBytes == 0 ? 0 : 1 - Double(freeBytes) / Double(containerBytes) }
}

struct BatteryFacts: Sendable, Equatable {
    var present = false, percent = 0, charging = false, onAC = false, cycleCount = 0, designCycles = 0, healthPercent = 0, condition = ""
    var minutesToEmpty: Int? = nil, minutesToFull: Int? = nil
    var lowPowerMode = false
    /// pmset powermode values ("0" Automatic, "1" Low Power, "2" High Power) per power source.
    var powerMode = "", powerModeBattery = "", powerModeAC = ""
}

struct WiFiFacts: Sendable, Equatable {
    var interface = "", powerOn = false, connected = false
    var ssid: String? = nil
    var channel = "", band = "", width = "", rssi = 0, noise = 0, txRate = 0, phy = ""
    var ssidKnown: Bool { ssid != nil }
    var snr: Int { rssi - noise }
    var dns: [String] = [], gateway = "", awdlActive = false, ipv4 = ""
}

enum LinkKind: String, Sendable, Equatable { case wifi = "Wi-Fi", ethernet = "Ethernet", other = "Other", none = "Offline" }

struct NetworkFacts: Sendable, Equatable {
    var primaryInterface = ""
    var kind: LinkKind = .none
    var displayName = ""
    var linkSpeedMbps = 0
    var ipv4 = "", gateway = ""
    var dns: [String] = []
    var rxBytesPerSec: Double = 0, txBytesPerSec: Double = 0
    var awdlUp = false
    var wifi = WiFiFacts()
}

struct ProcessFacts: Sendable, Identifiable, Equatable {
    var id: String { name }
    let pid: Int32
    let name: String
    let cpu: Double
    /// Physical footprint (what Activity Monitor shows as Memory), summed per app.
    let rssBytes: UInt64
    var count: Int = 1
}

// MARK: - Live model

/// Live system facts, sampled only while a view shows them. All in-process except tmutil, fdesetup
/// and pmset, which run at most once a minute.
@MainActor @Observable
final class SystemInfo {
    static let shared = SystemInfo()

    private(set) var hardware = HardwareFacts()
    private(set) var memory = MemoryFacts()
    private(set) var cpu = CPUFacts()
    private(set) var storage = StorageFacts()
    private(set) var battery = BatteryFacts()
    private(set) var network = NetworkFacts()
    private(set) var topCPU: [ProcessFacts] = []
    private(set) var topMemory: [ProcessFacts] = []
    private(set) var bootedSimulators: [String] = []
    private(set) var simulatorProcesses = 0
    private(set) var hasFullDiskAccess: Bool? = nil
    private(set) var lastRefresh: Date? = nil
    private(set) var refreshing = false

    var wifi: WiFiFacts { network.wifi }

    @ObservationIgnored private var subscribers: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>? = nil
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var lastSlow: Date = .distantPast
    @ObservationIgnored private var lastStorage: Date = .distantPast

    /// Call `stopLive` with the same token on disappear.
    func startLive(_ token: String) {
        subscribers.insert(token)
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.anyWindowVisible() { await self.sample() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopLive(_ token: String) {
        subscribers.remove(token)
        if subscribers.isEmpty { loop?.cancel(); loop = nil }
    }

    private func anyWindowVisible() -> Bool {
        NSApp == nil || NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// Every 2 s: CPU, memory, network. Every third step: processes, battery, Wi-Fi. Storage every 30 s;
    /// snapshots, power modes and simulators every minute.
    private func sample() async {
        tick += 1
        let medium = tick % 3 == 1
        let storageDue = Date().timeIntervalSince(lastStorage) > 30
        let slowDue = Date().timeIntervalSince(lastSlow) > 60
        let snap = await Task.detached(priority: .utility) { () -> Sample in
            var s = Sample()
            s.cpu = Samplers.cpu.sample()
            s.memory = Samplers.readMemory()
            s.rates = Samplers.net.sample()
            if medium {
                s.procs = Samplers.procs.sample()
                s.network = Samplers.readNetwork()
                s.battery = Samplers.readPowerSources()
            }
            if storageDue { s.storage = Samplers.readVolume() }
            return s
        }.value
        apply(snap)
        if storageDue { lastStorage = Date() }
        if slowDue { lastSlow = Date(); await slowTier() }
        lastRefresh = Date()
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let m = await Machine.profile()
        set(\.hardware, await Task.detached(priority: .userInitiated) { Samplers.readHardware(m) }.value)
        let snap = await Task.detached(priority: .userInitiated) { () -> Sample in
            var s = Sample()
            s.cpu = Samplers.cpu.sample()
            s.memory = Samplers.readMemory()
            s.rates = Samplers.net.sample()
            s.procs = Samplers.procs.sample()
            s.network = Samplers.readNetwork()
            s.battery = Samplers.readPowerSources()
            s.storage = Samplers.readVolume()
            return s
        }.value
        apply(snap)
        lastStorage = Date()
        lastSlow = Date()
        await slowTier()
        lastRefresh = Date()
    }

    /// Memory, CPU and free space only, for the menu bar.
    func refreshLight() async {
        let snap = await Task.detached(priority: .userInitiated) { () -> Sample in
            var s = Sample()
            s.cpu = Samplers.cpu.sample()
            s.memory = Samplers.readMemory()
            s.storage = Samplers.readVolume()
            s.procs = Samplers.procs.sample()
            return s
        }.value
        apply(snap)
    }

    private func slowTier() async {
        let hasBattery = Machine.current.hasBattery
        let fileVaultKnown = storage.fileVaultOn != nil
        let simCount = simulatorProcesses
        async let snaps = Samplers.localSnapshots()
        async let fv: Bool? = fileVaultKnown ? nil : Samplers.fileVault()
        async let modes = Pmset.current()
        async let sims: [String] = simCount > 0 ? Samplers.bootedSimulatorNames() : []
        async let fda = Task.detached(priority: .utility) { FullDiskAccess.has() }.value
        async let reg = Task.detached(priority: .utility) { hasBattery ? Samplers.readBatteryRegistry() : nil }.value

        var st = storage
        st.localSnapshots = await snaps
        if let v = await fv { st.fileVaultOn = v }
        set(\.storage, st)

        var b = battery
        let table = await modes
        b.powerModeBattery = table["Battery Power"]?["powermode"] ?? ""
        b.powerModeAC = table["AC Power"]?["powermode"] ?? ""
        b.powerMode = (b.onAC || !b.present) ? b.powerModeAC : b.powerModeBattery
        if let r = await reg { b.cycleCount = r.cycles; b.healthPercent = r.health; b.designCycles = r.designCycles }
        set(\.battery, b)

        set(\.bootedSimulators, await sims)
        let granted: Bool? = await fda
        set(\.hasFullDiskAccess, granted)
    }

    private func apply(_ s: Sample) {
        if var c = s.cpu {
            var h = cpu.history
            h.append(c.usage)
            if h.count > 60 { h.removeFirst(h.count - 60) }
            c.history = h
            set(\.cpu, c)
        }
        if let m = s.memory { set(\.memory, m) }
        if let st = s.storage {
            var merged = st
            merged.localSnapshots = storage.localSnapshots
            merged.fileVaultOn = storage.fileVaultOn
            set(\.storage, merged)
        }
        if var b = s.battery {
            b.cycleCount = battery.cycleCount; b.healthPercent = battery.healthPercent; b.designCycles = battery.designCycles
            b.powerModeAC = battery.powerModeAC; b.powerModeBattery = battery.powerModeBattery
            b.powerMode = (b.onAC || !b.present) ? b.powerModeAC : b.powerModeBattery
            set(\.battery, b)
        }
        var net = s.network ?? network
        if let r = s.rates, let iface = net.primaryInterface.nilIfEmpty, let rate = r[iface] {
            net.rxBytesPerSec = rate.rx; net.txBytesPerSec = rate.tx
            if net.kind != .wifi, rate.baud > 0 { net.linkSpeedMbps = Int(rate.baud / 1_000_000) }
        }
        set(\.network, net)
        if let p = s.procs {
            set(\.topCPU, p.topCPU)
            set(\.topMemory, p.topMemory)
            set(\.simulatorProcesses, p.simulatorRoots)
            if p.simulatorRoots == 0, !bootedSimulators.isEmpty { set(\.bootedSimulators, []) }
        }
    }

    /// Assigns only on change so observing views are not invalidated.
    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<SystemInfo, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    // MARK: Used by Benchmark

    nonisolated static func readBattery() async -> BatteryFacts {
        var b = Samplers.readPowerSources()
        let table = await Pmset.current()
        b.powerModeBattery = table["Battery Power"]?["powermode"] ?? ""
        b.powerModeAC = table["AC Power"]?["powermode"] ?? ""
        b.powerMode = (b.onAC || !b.present) ? b.powerModeAC : b.powerModeBattery
        return b
    }

    nonisolated static func readWiFi() async -> WiFiFacts {
        let n = Samplers.readNetwork()
        var w = n.wifi
        w.dns = n.dns; w.gateway = n.gateway
        return w
    }
}

/// Built off the main thread.
struct Sample: Sendable {
    var cpu: CPUFacts? = nil
    var memory: MemoryFacts? = nil
    var storage: StorageFacts? = nil
    var battery: BatteryFacts? = nil
    var network: NetworkFacts? = nil
    var rates: [String: InterfaceRate]? = nil
    var procs: ProcessSample? = nil
}

struct InterfaceRate: Sendable { var rx: Double; var tx: Double; var baud: UInt64 }

struct ProcessSample: Sendable {
    var topCPU: [ProcessFacts]
    var topMemory: [ProcessFacts]
    /// launchd_sim processes: one per booted simulator device.
    var simulatorRoots: Int
}

// MARK: - Samplers (nonisolated, in-process)

enum Samplers {
    static let cpu = CPUSampler()
    static let net = NetSampler()
    static let procs = ProcSampler()
    static let host = mach_host_self()

    static func readHardware(_ m: MachineProfile) -> HardwareFacts {
        var h = HardwareFacts()
        h.model = m.modelName
        h.modelID = m.modelID
        h.chip = m.chip
        h.cores = m.perfCores > 0 ? "\(m.totalCores) (\(m.perfCores)P + \(m.effCores)E)" : "\(m.totalCores)"
        h.memoryGB = Double(m.memoryBytes) / 1_073_741_824
        h.osVersion = m.osString
        h.build = m.osBuild
        h.gpuCores = m.gpuCores > 0 ? m.gpuCores : gpuCoreCount()
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 { h.bootDate = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)) }
        return h
    }

    /// GPU core count from the AGX accelerator's registry entry.
    static func gpuCoreCount() -> Int {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard svc != 0 else { return 0 }
        defer { IOObjectRelease(svc) }
        if let n = IORegistryEntryCreateCFProperty(svc, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int { return n }
        return 0
    }

    static func readMemory() -> MemoryFacts {
        var m = MemoryFacts()
        m.totalBytes = UInt64(Sysctl.int64("hw.memsize") ?? 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            let internalPages = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
            m.appBytes = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wiredBytes = UInt64(stats.wire_count) * page
            m.compressedBytes = UInt64(stats.compressor_page_count) * page
            m.cachedBytes = (UInt64(stats.external_page_count) + purgeable) * page
            m.freeBytes = (UInt64(stats.free_count) > UInt64(stats.speculative_count) ? UInt64(stats.free_count) - UInt64(stats.speculative_count) : 0) * page
            m.usedBytes = min(m.totalBytes, m.appBytes + m.wiredBytes + m.compressedBytes)
        }
        var xsw = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 { m.swapUsedBytes = xsw.xsu_used; m.swapTotalBytes = xsw.xsu_total }
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 2: m.pressure = .warning
        case 4: m.pressure = .critical
        default: m.pressure = .normal
        }
        m.freePercent = Sysctl.int("kern.memorystatus_level") ?? 0
        m.gpuWiredLimitMB = Sysctl.int("iogpu.wired_limit_mb") ?? 0
        return m
    }

    static func readVolume() -> StorageFacts {
        var s = StorageFacts()
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            s.containerBytes = UInt64(max(0, v.volumeTotalCapacity ?? 0))
            s.freeBytes = UInt64(max(0, v.volumeAvailableCapacity ?? 0))
            s.importantAvailableBytes = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0))
            if s.importantAvailableBytes > s.freeBytes { s.purgeableBytes = s.importantAvailableBytes - s.freeBytes }
        }
        return s
    }

    static func localSnapshots() async -> [String] {
        guard let r = try? await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 20) else { return [] }
        return r.stdout.split(separator: "\n").map(String.init).filter { $0.contains("com.apple.") }
    }

    static func fileVault() async -> Bool? {
        guard let r = try? await Shell.run("/usr/bin/fdesetup", ["status"], timeout: 10) else { return nil }
        return r.stdout.contains("FileVault is On")
    }

    /// From IOPowerSources; no process or registry walk.
    static func readPowerSources() -> BatteryFacts {
        var b = BatteryFacts()
        b.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { b.onAC = true; return b }
        let src = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        b.onAC = src != kIOPSBatteryPowerValue
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                b.present = true
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                b.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
                b.charging = d[kIOPSIsChargingKey] as? Bool ?? false
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0, !b.onAC { b.minutesToEmpty = t }
                if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0, b.charging { b.minutesToFull = t }
                if let h = d[kIOPSBatteryHealthConditionKey] as? String { b.condition = h }
                else if let h = d[kIOPSBatteryHealthKey] as? String { b.condition = h }
            }
        }
        return b
    }

    struct BatteryRegistry: Sendable { var cycles: Int; var health: Int; var designCycles: Int }

    /// Cycle count and capacity from the AppleSmartBattery registry entry (laptops only).
    static func readBatteryRegistry() -> BatteryRegistry? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? { (d[k] as? Int) ?? (data[k] as? Int) }
        let design = int("DesignCapacity") ?? 0
        let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        let health = design > 0 && full > 0 ? min(100, Int((Double(full) / Double(design) * 100).rounded())) : 0
        return BatteryRegistry(cycles: int("CycleCount") ?? 0, health: health, designCycles: int("DesignCycleCount9C") ?? 0)
    }

    /// SCDynamicStore plus CoreWLAN. SSID is nil without Location access; RSSI, noise, channel and rate are not.
    static func readNetwork() -> NetworkFacts {
        var n = NetworkFacts()
        if let store = SCDynamicStoreCreate(nil, "Keel" as CFString, nil, nil) {
            if let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
                n.primaryInterface = v4["PrimaryInterface"] as? String ?? ""
                n.gateway = v4["Router"] as? String ?? ""
            }
            if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
                n.dns = Array((dns["ServerAddresses"] as? [String] ?? []).prefix(4))
            }
        }
        n.awdlUp = NetIf.isUp("awdl0") ?? false
        let wifiIface = CWWiFiClient.shared().interface()
        var w = WiFiFacts()
        if let i = wifiIface {
            w.interface = i.interfaceName ?? ""
            w.powerOn = i.powerOn()
            w.ssid = i.ssid()
            let rssi = i.rssiValue()
            w.connected = w.powerOn && rssi != 0
            if w.connected {
                w.rssi = rssi
                w.noise = i.noiseMeasurement()
                w.txRate = Int(i.transmitRate())
                if let ch = i.wlanChannel() {
                    w.channel = "\(ch.channelNumber)"
                    switch ch.channelBand {
                    case .band2GHz: w.band = "2.4 GHz"
                    case .band5GHz: w.band = "5 GHz"
                    case .band6GHz: w.band = "6 GHz"
                    default: w.band = ""
                    }
                    switch ch.channelWidth {
                    case .width20MHz: w.width = "20 MHz"
                    case .width40MHz: w.width = "40 MHz"
                    case .width80MHz: w.width = "80 MHz"
                    case .width160MHz: w.width = "160 MHz"
                    default: w.width = ""
                    }
                }
                switch i.activePHYMode() {
                case .mode11a: w.phy = "802.11a"
                case .mode11b: w.phy = "802.11b"
                case .mode11g: w.phy = "802.11g"
                case .mode11n: w.phy = "Wi-Fi 4"
                case .mode11ac: w.phy = "Wi-Fi 5"
                case .mode11ax: w.phy = "Wi-Fi 6"
                default: w.phy = (i.activePHYMode().rawValue == 7) ? "Wi-Fi 7" : ""
                }
            }
        }
        w.awdlActive = n.awdlUp
        w.dns = n.dns
        w.gateway = n.gateway
        if n.primaryInterface.isEmpty {
            n.kind = .none
        } else if n.primaryInterface == w.interface {
            n.kind = .wifi
            n.displayName = "Wi-Fi"
            n.linkSpeedMbps = w.txRate
        } else {
            let (kind, name) = InterfaceNames.lookup(n.primaryInterface)
            n.kind = kind
            n.displayName = name
        }
        n.ipv4 = ipv4Address(n.primaryInterface)
        w.ipv4 = w.interface == n.primaryInterface ? n.ipv4 : ipv4Address(w.interface)
        n.wifi = w
        return n
    }

    static func ipv4Address(_ name: String) -> String {
        guard !name.isEmpty else { return "" }
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "" }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            if String(cString: a.pointee.ifa_name) == name, let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
            }
            p = a.pointee.ifa_next
        }
        return ""
    }

    static func bootedSimulatorNames() async -> [String] {
        guard Machine.current.hasXcode,
              let r = try? await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"], timeout: 20),
              let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devs = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        return devs.values.flatMap { $0 }.compactMap { $0["name"] as? String }.sorted()
    }
}

/// Display names and kinds of network interfaces, cached (the SystemConfiguration walk is not free).
enum InterfaceNames {
    nonisolated(unsafe) private static var cache: [String: (LinkKind, String)] = [:]
    private static let lock = NSLock()
    static func lookup(_ bsd: String) -> (LinkKind, String) {
        lock.lock(); if let c = cache[bsd] { lock.unlock(); return c }; lock.unlock()
        var result: (LinkKind, String) = (.other, bsd)
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all where (SCNetworkInterfaceGetBSDName(i) as String?) == bsd {
                let type = SCNetworkInterfaceGetInterfaceType(i) as String? ?? ""
                let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd
                let kind: LinkKind = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi : (type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : .other)
                result = (kind, name)
            }
        }
        if result.0 == .other, bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") { result = (.other, "VPN (\(bsd))") }
        lock.lock(); cache[bsd] = result; lock.unlock()
        return result
    }
}

/// Whole-machine CPU load from per-core tick counters (host_processor_info), as a delta between calls.
final class CPUSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

    func sample() -> CPUFacts {
        lock.lock(); defer { lock.unlock() }
        var f = CPUFacts()
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(Samplers.host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return f }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var now: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            now.append((UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                        UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                        UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                        UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))))
        }
        if previous.count == now.count {
            var user = 0.0, sys = 0.0, total = 0.0
            for (a, b) in zip(previous, now) {
                let du = Double(b.user &- a.user) + Double(b.nice &- a.nice), ds = Double(b.system &- a.system), di = Double(b.idle &- a.idle)
                user += du; sys += ds; total += du + ds + di
            }
            if total > 0 { f.user = user / total; f.system = sys / total; f.usage = min(1, (user + sys) / total) }
        }
        previous = now
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { f.load1 = loads[0]; f.load5 = loads[1]; f.load15 = loads[2] }
        f.thermal = ProcessInfo.processInfo.thermalState
        return f
    }
}

/// Bytes in/out per interface (getifaddrs AF_LINK counters), as a rate between calls.
final class NetSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var previousDate = Date()

    func sample() -> [String: InterfaceRate] {
        lock.lock(); defer { lock.unlock() }
        var now: [String: (rx: UInt64, tx: UInt64, baud: UInt64)] = [:]
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [:] }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            if let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let raw = a.pointee.ifa_data {
                let d = raw.assumingMemoryBound(to: if_data.self).pointee
                now[String(cString: a.pointee.ifa_name)] = (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes), UInt64(d.ifi_baudrate))
            }
            p = a.pointee.ifa_next
        }
        let dt = max(0.5, Date().timeIntervalSince(previousDate))
        var out: [String: InterfaceRate] = [:]
        for (k, v) in now {
            var r = InterfaceRate(rx: 0, tx: 0, baud: v.baud)
            if let old = previous[k], v.rx >= old.rx, v.tx >= old.tx {
                r.rx = Double(v.rx - old.rx) / dt; r.tx = Double(v.tx - old.tx) / dt
            }
            out[k] = r
        }
        previous = now.mapValues { ($0.rx, $0.tx) }
        previousDate = Date()
        return out
    }
}

/// Per-app memory footprint and CPU from libproc. Current user only; other users' processes need root.
final class ProcSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastDate = Date.distantPast
    private var names: [pid_t: String] = [:]
    private let timebase: Double = {
        var tb = mach_timebase_info(); mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    func sample() -> ProcessSample {
        lock.lock(); defer { lock.unlock() }
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return ProcessSample(topCPU: [], topMemory: [], simulatorRoots: 0) }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = Date()
        let wallNs = lastDate == .distantPast ? 0 : now.timeIntervalSince(lastDate) * 1e9
        var cpuNow: [pid_t: UInt64] = [:]
        var mem: [String: (UInt64, Int, pid_t)] = [:]
        var cpu: [String: Double] = [:]
        var simRoots = 0
        let me = getpid()
        for pid in pids.prefix(max(0, got)) where pid > 0 && pid != me {
            var ri = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &ri) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard r == 0 else { continue }
            let name = names[pid] ?? appName(pid)
            names[pid] = name
            if name == "launchd_sim" { simRoots += 1 }
            let group = name.hasPrefix("sim:") ? "Simulator devices" : name
            let e = mem[group] ?? (0, 0, pid)
            mem[group] = (e.0 + ri.ri_phys_footprint, e.1 + 1, e.2)
            let t = ri.ri_user_time + ri.ri_system_time
            cpuNow[pid] = t
            if wallNs > 0, let old = lastCPU[pid], t >= old {
                cpu[group, default: 0] += Double(t - old) * timebase / wallNs * 100
            }
        }
        names = names.filter { cpuNow[$0.key] != nil }
        lastCPU = cpuNow
        lastDate = now
        let topMem = mem.sorted { $0.value.0 > $1.value.0 }.prefix(8).map {
            ProcessFacts(pid: $0.value.2, name: $0.key, cpu: cpu[$0.key] ?? 0, rssBytes: $0.value.0, count: $0.value.1)
        }
        let topCPU = cpu.filter { $0.value >= 0.1 }.sorted { $0.value > $1.value }.prefix(8).map {
            ProcessFacts(pid: mem[$0.key]?.2 ?? 0, name: $0.key, cpu: $0.value, rssBytes: mem[$0.key]?.0 ?? 0, count: mem[$0.key]?.1 ?? 1)
        }
        return ProcessSample(topCPU: Array(topCPU), topMemory: Array(topMem), simulatorRoots: simRoots)
    }

    /// Outermost app bundle ("Google Chrome" for its helpers), "sim:…" inside a simulator, else the executable.
    private func appName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else {
            var nameBuf = [CChar](repeating: 0, count: 64)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            return String(cString: nameBuf)
        }
        let path = String(cString: buf)
        let exe = (path as NSString).lastPathComponent
        if exe == "launchd_sim" { return exe }
        if path.contains(".simruntime/") || path.contains("/CoreSimulator/Devices/") { return "sim:\(exe)" }
        if let r = path.range(of: ".app/") {
            let bundle = path[..<r.lowerBound]
            return (String(bundle) as NSString).lastPathComponent
        }
        return exe
    }
}

enum FullDiskAccess {
    /// EPERM on a TCC-protected folder means no Full Disk Access (no prompt is triggered). Call off the main thread.
    static func has() -> Bool {
        let probes = ["\(NSHomeDirectory())/Library/Safari", "\(NSHomeDirectory())/Library/Mail", "/Library/Application Support/com.apple.TCC"]
        for probe in probes {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: probe, isDirectory: &isDir), isDir.boolValue else { continue }
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }
        return false
    }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

enum PowerMode {
    /// pmset powermode: 0 Automatic, 1 Low Power, 2 High Power.
    static func name(_ v: String) -> String {
        switch v { case "0": return "Automatic"; case "1": return "Low Power"; case "2": return "High Power"; default: return v.isEmpty ? "—" : v }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension UInt64 {
    var gb: String { String(format: "%.1f GB", Double(self) / 1_073_741_824) }
    var humanBytes: String {
        let d = Double(self)
        if d >= 1_099_511_627_776 { return String(format: "%.2f TB", d / 1_099_511_627_776) }
        if d >= 1_073_741_824 { return String(format: "%.1f GB", d / 1_073_741_824) }
        if d >= 1_048_576 { return String(format: "%.0f MB", d / 1_048_576) }
        if d >= 1024 { return String(format: "%.0f KB", d / 1024) }
        return "\(self) B"
    }
}

extension Double {
    /// Bytes per second as "1.2 MB/s".
    var rateString: String {
        if self >= 1_048_576 { return String(format: "%.1f MB/s", self / 1_048_576) }
        if self >= 1024 { return String(format: "%.0f KB/s", self / 1024) }
        return String(format: "%.0f B/s", self)
    }
}
