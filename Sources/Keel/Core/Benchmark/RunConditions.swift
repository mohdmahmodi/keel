import Foundation
import IOKit
import IOKit.ps

/// Everything that changes benchmark numbers without the Mac changing: power source, energy mode,
/// heat, memory pressure, background load, time since boot. Read in-process where possible.
struct Conditions: Sendable {
    var onAC = true
    var hasBattery = false
    var powerMode = ""             // pmset powermode for the active source: 0 Automatic, 1 Low, 2 High
    var lowPowerMode = false
    var thermal = "nominal"
    var pressure = 1               // 1 normal, 2 warn, 4 critical
    var loadAvg1 = 0.0
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var minutesSinceBoot = 9999
    var fans: [Double]? = nil      // rpm per fan; [] = fanless
    var socTemp: Double? = nil     // hottest die sensor, °C

    var freshBoot: Bool { minutesSinceBoot <= 15 }
    var busy: Bool { loadAvg1 > Double(cores) / 2 }

    /// Plain warnings for the pre-flight card.
    var warnings: [String] {
        var w: [String] = []
        if hasBattery && !onAC { w.append("On battery: plug in, or compare only with other battery runs.") }
        if powerMode == "1" || lowPowerMode { w.append("Low Power Mode caps CPU and GPU clocks.") }
        if thermal == "serious" || thermal == "critical" { w.append("The Mac is hot (thermal state \(thermal)); let it cool first.") }
        else if thermal == "fair" { w.append("Thermal state is fair: sustained tests may throttle.") }
        if pressure >= 2 { w.append("Memory pressure is \(pressure >= 4 ? "critical" : "elevated"): quit large apps first.") }
        if busy { w.append(String(format: "Load average %.1f on %d cores: other apps are busy.", loadAvg1, cores)) }
        return w
    }
}

enum RunConditions {
    static func thermalName(_ s: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func minutesSinceBoot() -> Int {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return 9999 }
        return max(0, Int(Date().timeIntervalSince1970 - Double(tv.tv_sec)) / 60)
    }

    static func loadAverage() -> Double {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) > 0 ? l[0] : 0
    }

    /// AC vs battery from IOKit power sources (no process spawn).
    static func power() -> (onAC: Bool, hasBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, false) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var battery = false
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType { battery = true }
            }
        }
        return (providing != kIOPMBatteryPowerKey, battery)
    }

    /// pmset powermode for the active source. Some Macs list `lowpowermode` instead of `powermode`.
    static func powerMode(onAC: Bool) async -> String {
        let table = await Pmset.current(fresh: true)
        let section = table[onAC ? "AC Power" : "Battery Power"] ?? table.values.first ?? [:]
        if let m = section["powermode"] { return m }
        if let l = section["lowpowermode"] { return l == "1" ? "1" : "0" }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? "1" : ""
    }

    static func capture(includeSensors: Bool = true) async -> Conditions {
        var c = Conditions()
        (c.onAC, c.hasBattery) = power()
        c.powerMode = await powerMode(onAC: c.onAC)
        c.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        c.thermal = thermalName()
        c.pressure = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        c.loadAvg1 = loadAverage()
        c.minutesSinceBoot = minutesSinceBoot()
        if includeSensors {
            let s = await Task.detached(priority: .utility) { SMC.snapshot() }.value
            c.fans = s.fans; c.socTemp = s.socTemp
        }
        return c
    }

    static var keelVersion: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "dev"
        if let b = i?["CFBundleVersion"] as? String, b != v { return "\(v) (\(b))" }
        return v
    }

    static var buildConfig: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// GPU core count from the accelerator's IORegistry entry.
    static func gpuCores() -> Int? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        return (IORegistryEntryCreateCFProperty(svc, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }

    static func metadata(before: Conditions, after: Conditions?, duration: Double?) async -> RunMetadata {
        let m = await Machine.profile()
        return RunMetadata(
            osVersion: m.osString, osBuild: m.osBuild, keelVersion: keelVersion, buildConfig: buildConfig,
            chip: m.chip, modelID: m.modelID, modelName: m.modelName,
            perfCores: m.perfCores, effCores: m.effCores, gpuCores: gpuCores(), memoryGB: m.memoryGB,
            powerSource: before.hasBattery ? (before.onAC ? "AC" : "Battery") : "AC",
            lowPowerMode: before.lowPowerMode,
            thermalBefore: before.thermal, thermalAfter: after?.thermal,
            pressureBefore: before.pressure, pressureAfter: after?.pressure,
            loadAvgBefore: before.loadAvg1,
            fanRPMBefore: before.fans, fanRPMAfter: after?.fans,
            socTempBefore: before.socTemp, socTempAfter: after?.socTemp,
            durationSeconds: duration)
    }
}

/// Read-only AppleSMC access (fans, die temperatures); no root needed on Apple silicon. Uses the 80-byte
/// `SMCKeyData_t`: key @0, keyInfo.dataSize @28, keyInfo.dataType @32, result @40, data8 (command) @42,
/// data32 @44, bytes[32] @48. Key names are undocumented and vary by SoC, so values are range-checked.
enum SMC {
    struct Snapshot: Sendable { var fans: [Double]?; var socTemp: Double? }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off] = UInt8(v & 0xff); b[off + 1] = UInt8(v >> 8 & 0xff); b[off + 2] = UInt8(v >> 16 & 0xff); b[off + 3] = UInt8(v >> 24 & 0xff)
    }
    private static func get32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }

    private final class Connection {
        var conn: io_connect_t = 0
        init?() {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard svc != 0 else { return nil }
            defer { IOObjectRelease(svc) }
            guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        }
        deinit { if conn != 0 { IOServiceClose(conn) } }

        private func call(_ input: [UInt8]) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: 80)
            var size = 80
            let r = input.withUnsafeBytes { i in out.withUnsafeMutableBytes { o in
                IOConnectCallStructMethod(conn, 2, i.baseAddress, 80, o.baseAddress, &size) } }
            guard r == kIOReturnSuccess, size == 80, out[40] == 0 else { return nil }
            return out
        }

        /// Raw bytes and 4-char type of a key, or nil if it does not exist.
        func read(_ key: String) -> (type: String, bytes: [UInt8])? {
            var info = [UInt8](repeating: 0, count: 80)
            SMC.put32(&info, 0, SMC.fourCC(key)); info[42] = 9              // kSMCGetKeyInfo
            guard let i = call(info) else { return nil }
            let size = SMC.get32(i, 28), type = SMC.get32(i, 32)
            guard size > 0, size <= 32 else { return nil }
            var req = [UInt8](repeating: 0, count: 80)
            SMC.put32(&req, 0, SMC.fourCC(key)); SMC.put32(&req, 28, size); req[42] = 5   // kSMCReadKey
            guard let o = call(req) else { return nil }
            let t = String(bytes: [UInt8(type >> 24 & 0xff), UInt8(type >> 16 & 0xff), UInt8(type >> 8 & 0xff), UInt8(type & 0xff)], encoding: .ascii) ?? ""
            return (t, Array(o[48..<(48 + Int(size))]))
        }

        func number(_ key: String) -> Double? {
            guard let (t, b) = read(key) else { return nil }
            switch t {
            case "flt " where b.count == 4:
                let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                return Double(Float(bitPattern: bits))
            case "ui8 " where b.count >= 1: return Double(b[0])
            case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
            case "fpe2" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
            case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
            default: return nil
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tempKeys: [String]? = nil

    static func snapshot() -> Snapshot {
        guard let c = Connection() else { return Snapshot(fans: nil, socTemp: nil) }
        var snap = Snapshot(fans: nil, socTemp: nil)
        if let n = c.number("FNum"), n >= 0, n <= 4 {
            var f: [Double] = []
            for i in 0..<Int(n) { if let v = c.number("F\(i)Ac"), v >= 0, v < 20_000 { f.append(v) } }
            snap.fans = f
        }
        // Discover die sensors once: CPU (Tp*, Te*) and GPU (Tg*) keys with float readings.
        lock.lock(); var keys = tempKeys; lock.unlock()
        if keys == nil {
            var found: [String] = []
            let chars = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            for p in ["Tp0", "Tp1", "Te0", "Tg0"] {
                for ch in chars {
                    let k = p + String(ch)
                    if let (t, _) = c.read(k), t == "flt " { found.append(k) }
                }
            }
            keys = found
            lock.lock(); tempKeys = found; lock.unlock()
        }
        let temps = (keys ?? []).compactMap { c.number($0) }.filter { $0 > 5 && $0 < 130 }
        snap.socTemp = temps.max()
        return snap
    }
}
