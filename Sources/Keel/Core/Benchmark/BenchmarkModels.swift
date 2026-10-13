import Foundation

/// A secondary number inside a result (per-resolver DNS, per-thread-count CPU, p99 latency…).
/// `key` is stable so A/B comparisons can match metrics across runs.
struct BenchmarkMetric: Codable, Sendable, Hashable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let value: Double
    let unit: String
    let higherIsBetter: Bool
    var samples: [Double]? = nil
}

/// One test's outcome. Saved runs decode into this, so new fields must be optional.
struct BenchmarkResult: Codable, Identifiable, Sendable {
    var id: String { testID }
    let testID: String
    let name: String
    let value: Double      // primary metric: best sample for throughput, median for latency
    let unit: String
    let higherIsBetter: Bool
    var detail: String = ""
    var samples: [Double] = []
    var median: Double? = nil
    var p95: Double? = nil
    var metrics: [BenchmarkMetric]? = nil
    /// Why the test produced no number (Ollama not running, no gateway…). Skipped results are never compared.
    var skipped: String? = nil

    /// True when the value can be compared and charted.
    var isValid: Bool { skipped == nil && value > 0 && value.isFinite }
}

/// Conditions captured with a run (`nil` on runs saved by older builds).
struct RunMetadata: Codable, Sendable {
    var osVersion: String
    var osBuild: String
    var keelVersion: String
    var buildConfig: String          // "release" or "debug": debug builds run the Swift kernels far slower
    var chip: String
    var modelID: String
    var modelName: String
    var perfCores: Int
    var effCores: Int
    var gpuCores: Int?
    var memoryGB: Int
    var powerSource: String?         // "AC" / "Battery"
    var lowPowerMode: Bool?
    var thermalBefore: String
    var thermalAfter: String?
    var pressureBefore: Int?         // kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical
    var pressureAfter: Int?
    var loadAvgBefore: Double?
    var fanRPMBefore: [Double]?
    var fanRPMAfter: [Double]?
    var socTempBefore: Double?       // hottest AppleSMC die sensor, °C (undocumented keys)
    var socTempAfter: Double?
    var durationSeconds: Double?
}

struct BenchmarkRun: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    var label: String
    let afterReboot: Bool
    let minutesSinceBoot: Int
    let onAC: Bool
    let powerMode: String
    var results: [BenchmarkResult]
    var meta: RunMetadata? = nil

    func result(_ t: BenchmarkTest) -> BenchmarkResult? { results.first { $0.testID == t.rawValue } }
}

/// Every test. Raw values are the stable IDs stored in saved runs: never rename an existing one.
enum BenchmarkTest: String, CaseIterable, Identifiable, Sendable, Codable {
    case cpuSingle = "CPU single-core", cpuMulti = "CPU multi-core"
    case gpuCompute = "GPU FP32 compute", gpuBandwidth = "GPU memory bandwidth"
    case memBandwidth = "Memory bandwidth", memLatency = "Memory latency"
    case ssdSeqWrite = "SSD sequential write", ssdSeqRead = "SSD sequential read"
    case ssdBigWrite = "SSD write 8 MiB × 4", ssdBigRead = "SSD read 8 MiB × 4"
    case ssd4kRead = "SSD 4K random read", ssd4kWrite = "SSD 4K random write"
    case pingGateway = "Ping gateway", ping1111 = "Ping 1.1.1.1", ping8888 = "Ping 8.8.8.8", pingAWS = "Ping nearest AWS region"
    case dns = "DNS lookup", responsiveness = "Network responsiveness"
    case ollama = "Ollama tokens/s"

    var id: String { rawValue }

    static let groups = ["CPU", "GPU", "Memory", "SSD", "Network", "AI"]

    var group: String {
        switch self {
        case .cpuSingle, .cpuMulti: return "CPU"
        case .gpuCompute, .gpuBandwidth: return "GPU"
        case .memBandwidth, .memLatency: return "Memory"
        case .ssdSeqWrite, .ssdSeqRead, .ssdBigWrite, .ssdBigRead, .ssd4kRead, .ssd4kWrite: return "SSD"
        case .pingGateway, .ping1111, .ping8888, .pingAWS, .dns, .responsiveness: return "Network"
        case .ollama: return "AI"
        }
    }

    var shortName: String {
        switch self {
        case .cpuSingle: return "Single-core"
        case .cpuMulti: return "Multi-core"
        case .gpuCompute: return "FP32 compute"
        case .gpuBandwidth: return "Memory bandwidth"
        case .memBandwidth: return "Bandwidth"
        case .memLatency: return "Latency"
        case .ssdSeqWrite: return "Write 1 MiB QD1"
        case .ssdSeqRead: return "Read 1 MiB QD1"
        case .ssdBigWrite: return "Write 8 MiB × 4"
        case .ssdBigRead: return "Read 8 MiB × 4"
        case .ssd4kRead: return "4K random read"
        case .ssd4kWrite: return "4K random write"
        case .pingGateway: return "Ping gateway"
        case .ping1111: return "Ping 1.1.1.1"
        case .ping8888: return "Ping 8.8.8.8"
        case .pingAWS: return "Ping nearest AWS"
        case .dns: return "DNS resolvers"
        case .responsiveness: return "Responsiveness (RPM)"
        case .ollama: return "Ollama tokens/s"
        }
    }

    var unit: String {
        switch self {
        case .cpuSingle, .cpuMulti: return "Mops/s"
        case .gpuCompute: return "GFLOPS"
        case .gpuBandwidth, .memBandwidth: return "GB/s"
        case .memLatency: return "ns"
        case .ssdSeqWrite, .ssdSeqRead, .ssdBigWrite, .ssdBigRead: return "MB/s"
        case .ssd4kRead, .ssd4kWrite: return "IOPS"
        case .pingGateway, .ping1111, .ping8888, .pingAWS, .dns: return "ms"
        case .responsiveness: return "RPM"
        case .ollama: return "tok/s"
        }
    }

    var higherIsBetter: Bool {
        switch self {
        case .memLatency, .pingGateway, .ping1111, .ping8888, .pingAWS, .dns: return false
        default: return true
        }
    }

    /// Typical run-to-run spread on an idle Mac. A Δ inside this band is noise.
    var defaultNoiseBand: Double {
        switch self {
        case .cpuSingle, .cpuMulti, .gpuCompute, .gpuBandwidth, .memBandwidth, .memLatency: return 3
        case .ssdSeqWrite, .ssdSeqRead, .ssdBigWrite, .ssdBigRead, .ollama: return 5
        case .ssd4kRead, .ssd4kWrite, .dns: return 10
        case .pingGateway, .ping1111, .ping8888, .pingAWS, .responsiveness: return 15
        }
    }

    /// Rough share of a full run, for the progress bar.
    var weight: Double {
        switch self {
        case .cpuSingle: return 4
        case .cpuMulti: return 7
        case .gpuCompute, .gpuBandwidth: return 2
        case .memBandwidth: return 3
        case .memLatency: return 4
        case .ssdSeqWrite, .ssdSeqRead, .ssdBigWrite, .ssdBigRead: return 1.5
        case .ssd4kRead, .ssd4kWrite: return 3
        case .pingGateway, .ping1111, .ping8888, .pingAWS: return 4
        case .dns: return 5
        case .responsiveness: return 22
        case .ollama: return 25
        }
    }

    /// What it measures and how.
    var explanation: String {
        switch self {
        case .cpuSingle: return "Mandelbrot, prime sieve and matrix multiply on one thread at the highest QoS, so it runs on a performance core. Each sample lasts about a second; best of three."
        case .cpuMulti: return "The same kernel on every core at once, also timed with fewer threads to show how throughput scales from one core to the performance cluster to all cores. Best of three."
        case .gpuCompute: return "A Metal kernel of independent fused multiply-adds over about a million threads. Counts 2 FLOPs per FMA, timed on the GPU clock. Best of three."
        case .gpuBandwidth: return "A Metal kernel that copies a large private buffer; bytes read plus written per second. Best of three."
        case .memBandwidth: return "memcpy between two large buffers on every core, read plus write counted (STREAM Copy). Single-thread figure in the details. Best of three."
        case .memLatency: return "Pointer chase through a random cycle of 128-byte lines, one dependent load at a time. The headline is the largest buffer (DRAM); smaller sizes show the caches. Best of three."
        case .ssdSeqWrite: return "1 GiB written in 1 MiB blocks, one request at a time, bypassing the file cache (F_NOCACHE) and flushed with F_FULLFSYNC. Best of three."
        case .ssdSeqRead: return "The same 1 GiB file read back in 1 MiB blocks, one request at a time, F_NOCACHE. Best of three."
        case .ssdBigWrite: return "8 MiB blocks with four requests in flight, then F_FULLFSYNC. Comparable to Blackmagic Disk Speed Test. Best of three."
        case .ssdBigRead: return "8 MiB blocks with four requests in flight, F_NOCACHE. Comparable to Blackmagic Disk Speed Test. Best of three."
        case .ssd4kRead: return "4 KiB reads at random aligned offsets for 3 s, one at a time (what app launches look like). Median and p99 latency in the details."
        case .ssd4kWrite: return "4 KiB writes at random aligned offsets for 3 s, one at a time, no per-write flush."
        case .pingGateway: return "50 ICMP echoes to your router at 0.2 s intervals. Median, p95, jitter (mean difference between consecutive replies), loss and replies over 50 ms."
        case .ping1111: return "50 ICMP echoes to Cloudflare's anycast resolver: your connection to the nearest internet exchange."
        case .ping8888: return "50 ICMP echoes to Google's anycast resolver."
        case .pingAWS: return "TCP connect time to DynamoDB in 20 AWS regions picks the closest (the method cloudping.co uses), then 50 ICMP echoes to it."
        case .dns: return "Raw UDP queries to the system resolver and to 1.1.1.1, 8.8.8.8 and 9.9.9.9. Cached: popular names asked twice, second answer timed. Uncached: random names the resolver must look up. Headline is the system resolver, cached."
        case .responsiveness: return "Apple's networkQuality tool: round trips per minute while the link is saturated (download), idle latency and throughput. Higher RPM means less bufferbloat."
        case .ollama: return "Generation and prompt tokens per second from the local Ollama server with the smallest installed model. A warm-up request is discarded; best of three."
        }
    }

    /// What moves the number besides the Mac itself.
    var affectedBy: String {
        switch self {
        case .cpuSingle, .cpuMulti: return "Low Power Mode, battery power, heat, and anything else using the CPU. Debug builds of Keel run this kernel much slower."
        case .gpuCompute, .gpuBandwidth: return "Low Power Mode, other GPU work (video, games, ML), external displays."
        case .memBandwidth, .memLatency: return "Other apps streaming memory (browsers, simulators, VMs), memory pressure and swap."
        case .ssdSeqWrite, .ssdSeqRead, .ssdBigWrite, .ssdBigRead, .ssd4kRead, .ssd4kWrite: return "Free space, Spotlight indexing, Time Machine, other disk activity. Writes about 6 GiB to a temporary file that is deleted afterwards."
        case .pingGateway: return "Wi-Fi signal and channel, AirDrop/Handoff (AWDL) scans, other devices on the network."
        case .ping1111, .ping8888, .pingAWS: return "Your provider's routing and load, other traffic on the link, Wi-Fi."
        case .dns: return "The resolver's cache and distance, encrypted DNS or iCloud Private Relay (which bypass these servers in apps)."
        case .responsiveness: return "Other traffic on the link and the router's queue management. Transfers a few hundred MB."
        case .ollama: return "Model size and quantisation, the GPU memory limit, Low Power Mode, heat."
        }
    }
}

/// Status of one test during or after the current run.
enum TestStatus: Equatable, Sendable {
    case pending, running, done(String), skipped(String), failed(String), cancelled
}

/// Saved runs: one JSON file per run in ~/Library/Application Support/Keel/benchmarks.
enum BenchmarkStore {
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    static func url(_ r: BenchmarkRun) -> URL { AppPaths.benchmarks.appendingPathComponent("\(r.id.uuidString).json") }

    static func all() -> [BenchmarkRun] {
        let dir = AppPaths.benchmarks
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dec = decoder()
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(BenchmarkRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
    static func save(_ r: BenchmarkRun) {
        if let d = try? encoder().encode(r) { try? d.write(to: url(r), options: .atomic) }
    }
    static func delete(_ r: BenchmarkRun) { try? FileManager.default.removeItem(at: url(r)) }
}

/// Small statistics helpers. All take unsorted samples.
enum Stats {
    static func median(_ s: [Double]) -> Double {
        guard !s.isEmpty else { return 0 }
        let v = s.sorted(); let n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }
    /// Nearest-rank percentile, p in 0...100.
    static func percentile(_ s: [Double], _ p: Double) -> Double {
        guard !s.isEmpty else { return 0 }
        let v = s.sorted()
        let rank = Int((p / 100 * Double(v.count)).rounded(.up))
        return v[min(max(rank - 1, 0), v.count - 1)]
    }
    static func mean(_ s: [Double]) -> Double { s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count) }
    /// Half the sample range relative to the median, in percent: a simple per-run noise estimate.
    static func halfRangePercent(_ s: [Double]) -> Double? {
        guard s.count >= 2, let lo = s.min(), let hi = s.max() else { return nil }
        let m = median(s)
        guard m > 0 else { return nil }
        return (hi - lo) / 2 / m * 100
    }
}

/// Formats for display and the CLI (kept global: `App/CLI.swift` uses it).
func f1(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }

/// Grouped number for the UI: 14,807 / 224 / 3.4.
func fmtValue(_ v: Double) -> String {
    if v >= 1000 { return v.formatted(.number.precision(.fractionLength(0))) }
    if v >= 100 { return String(format: "%.0f", v) }
    if v >= 1 { return String(format: "%.1f", v) }
    return String(format: "%.2f", v)
}
