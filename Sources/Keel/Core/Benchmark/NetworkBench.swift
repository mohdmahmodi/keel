import Foundation
import Network
import SystemConfiguration

/// Latency, DNS and responsiveness tests. ICMP needs a raw socket, so ping is spawned (`/sbin/ping`)
/// and every reply line is parsed: the summary line alone cannot give jitter, p95 or spikes.
enum NetworkBench {
    // MARK: Ping

    struct PingStats: Sendable {
        var host = ""
        var sent = 0, received = 0
        var times: [Double] = []          // ms, in sequence order, received replies only
        var jitter = 0.0                  // mean |Δ| between consecutive received replies (RFC 3550 style)
        var spikes = 0                    // replies over 50 ms
        var loss: Double { sent > 0 ? Double(sent - received) / Double(sent) * 100 : 100 }
        var min: Double { times.min() ?? 0 }
        var max: Double { times.max() ?? 0 }
        var median: Double { Stats.median(times) }
        var p95: Double { Stats.percentile(times, 95) }
    }

    static let pingCount = 50

    /// Parses `ping` output: `64 bytes from …: icmp_seq=N ttl=… time=X ms` lines plus the
    /// `N packets transmitted` summary. Duplicate replies are ignored.
    static func parsePing(_ out: String, host: String, requested: Int) -> PingStats {
        var s = PingStats(host: host)
        var bySeq: [Int: Double] = [:]
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            if line.contains("DUP!") { continue }
            guard let seqR = line.range(of: "icmp_seq=([0-9]+)", options: .regularExpression),
                  let timeR = line.range(of: "time=([0-9.]+) ms", options: .regularExpression) else { continue }
            let seq = Int(line[seqR].dropFirst("icmp_seq=".count)) ?? -1
            let t = Double(line[timeR].dropFirst(5).dropLast(3)) ?? -1
            if seq >= 0, t >= 0, bySeq[seq] == nil { bySeq[seq] = t }
        }
        if let r = out.range(of: "([0-9]+) packets transmitted", options: .regularExpression) {
            s.sent = Int(out[r].split(separator: " ").first ?? "") ?? requested
        } else { s.sent = requested }
        let seqs = bySeq.keys.sorted()
        s.times = seqs.map { bySeq[$0]! }
        s.received = s.times.count
        s.sent = Swift.max(s.sent, s.received)
        var diffs: [Double] = []
        for i in 1..<Swift.max(seqs.count, 1) where seqs[i] == seqs[i - 1] + 1 {
            diffs.append(abs(bySeq[seqs[i]]! - bySeq[seqs[i - 1]]!))
        }
        s.jitter = Stats.mean(diffs)
        s.spikes = s.times.filter { $0 > 50 }.count
        return s
    }

    static func ping(_ host: String, count: Int = pingCount) async -> PingStats? {
        let interval = 0.2
        let args = ["-c", String(count), "-i", String(interval), "-t", String(Int(Double(count) * interval) + 6), "-n", host]
        guard let r = await BenchProcess.run("/sbin/ping", args, timeout: Double(count) * interval + 12) else { return nil }
        // Exit 2 = no replies; 68 = unknown host.
        if r.stdout.isEmpty && !r.stderr.isEmpty { return nil }
        return parsePing(r.stdout, host: host, requested: count)
    }

    /// Default IPv4 gateway from the routing table.
    static func gateway() async -> String? {
        guard let r = await BenchProcess.run("/sbin/route", ["-n", "get", "default"], timeout: 5),
              let rg = r.stdout.range(of: "gateway: (\\S+)", options: .regularExpression) else { return nil }
        let g = r.stdout[rg].replacingOccurrences(of: "gateway: ", with: "")
        return g.contains(":") ? nil : g
    }

    // MARK: TCP connect / AWS

    /// TCP connect time to `host:port` in ms (DNS resolution included unless already cached), or nil.
    static func tcpConnectMS(host: String, port: UInt16 = 443, timeout: TimeInterval = 3) async -> Double? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let lock = NSLock(); var done = false
            let start = nowNS()
            func finish(_ v: Double?) {
                lock.lock(); if done { lock.unlock(); return }; done = true; lock.unlock()
                conn.cancel(); cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(Double(nowNS() - start) / 1e6)
                case .failed, .cancelled: finish(nil)
                case .waiting: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    static let awsRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "sa-east-1",
        "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-north-1", "eu-south-1",
        "me-central-1", "af-south-1", "ap-south-1", "ap-southeast-1", "ap-southeast-2",
        "ap-northeast-1", "ap-northeast-2", "ap-east-1",
    ]

    struct RegionTime: Sendable { let region: String; let minMS: Double; let medianMS: Double }

    /// One warm-up connect per region (resolves DNS), then three timed connects; ranked by the minimum,
    /// because connect time only has upward noise.
    static func rankAWS() async -> [RegionTime] {
        await withTaskGroup(of: RegionTime?.self) { g in
            for r in awsRegions {
                g.addTask {
                    let host = "dynamodb.\(r).amazonaws.com"
                    guard await tcpConnectMS(host: host, timeout: 4) != nil else { return nil }
                    var s: [Double] = []
                    for _ in 0..<3 { if Task.isCancelled { return nil }; if let v = await tcpConnectMS(host: host) { s.append(v) } }
                    guard let mn = s.min() else { return nil }
                    return RegionTime(region: r, minMS: mn, medianMS: Stats.median(s))
                }
            }
            var all: [RegionTime] = []
            for await v in g { if let v { all.append(v) } }
            return all.sorted { $0.minMS < $1.minMS }
        }
    }

    // MARK: DNS

    /// The resolvers macOS is using right now (State:/Network/Global/DNS), IPv4 first.
    static func systemResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Keel" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String] else { return [] }
        return servers.filter { !$0.contains(":") } + servers.filter { $0.contains(":") }
    }

    /// One A query over UDP; ms from send to a reply with the matching ID, nil on timeout.
    static func dnsQuery(server: String, name: String, timeout: TimeInterval = 2) async -> Double? {
        let id = UInt16.random(in: 0...UInt16.max)
        var q = Data([UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q.append(contentsOf: Array(label.utf8)) }
        q.append(contentsOf: [0, 0, 1, 0, 1])
        let query = q
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
            let lock = NSLock(); var done = false
            func finish(_ v: Double?) {
                lock.lock(); if done { lock.unlock(); return }; done = true; lock.unlock()
                conn.cancel(); cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    let start = nowNS()
                    conn.send(content: query, completion: .contentProcessed { _ in })
                    conn.receiveMessage { data, _, _, _ in
                        if let data, data.count >= 4, data[data.startIndex] == UInt8(id >> 8), data[data.startIndex + 1] == UInt8(id & 0xff) {
                            finish(Double(nowNS() - start) / 1e6)
                        } else { finish(nil) }
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    static let popularNames = ["apple.com", "github.com", "google.com", "wikipedia.org", "amazon.com",
                               "microsoft.com", "youtube.com", "cloudflare.com", "npmjs.com", "pypi.org"]
    /// Parent zones for random (never-cached) names. Answers are NXDOMAIN after a real recursive lookup.
    static let uncachedZones = ["apple.com", "github.com", "wikipedia.org", "microsoft.com", "amazon.com"]

    struct ResolverStats: Sendable {
        let label: String, server: String
        var cached: [Double] = [], uncached: [Double] = []
        var failures = 0
        var total = 0
    }

    static func measureResolver(label: String, server: String, cancel: CancelFlag) async -> ResolverStats {
        var s = ResolverStats(label: label, server: server)
        for n in popularNames {
            if cancel.isCancelled { break }
            _ = await dnsQuery(server: server, name: n)                       // prime the resolver's cache
            s.total += 1
            if let t = await dnsQuery(server: server, name: n) { s.cached.append(t) } else { s.failures += 1 }
        }
        for i in 0..<10 {
            if cancel.isCancelled { break }
            let name = "k\(UInt64.random(in: 0...UInt64.max) % 1_000_000_000_000)-\(i).\(uncachedZones[i % uncachedZones.count])"
            s.total += 1
            if let t = await dnsQuery(server: server, name: name, timeout: 3) { s.uncached.append(t) } else { s.failures += 1 }
        }
        return s
    }

    // MARK: networkQuality

    struct Responsiveness: Sendable {
        var dlRPM: Double?, ulRPM: Double?, rpm: Double?
        var idleLatencyMS: Double?
        var dlMbps: Double?, ulMbps: Double?
        var interface = "", endpoint = ""
    }

    /// `networkQuality -s -c` (sequential, JSON). `-M` caps the runtime when the tool supports it.
    static func networkQuality(maxSeconds: Int = 20) async -> (Responsiveness?, String?) {
        let path = "/usr/bin/networkQuality"
        guard FileManager.default.isExecutableFile(atPath: path) else { return (nil, "networkQuality is not available on this macOS") }
        var r = await BenchProcess.run(path, ["-s", "-c", "-M", String(maxSeconds)], timeout: Double(maxSeconds) + 40)
        if let out = r, parseNQ(out.stdout) == nil, out.stderr.lowercased().contains("usage") || out.stdout.lowercased().contains("usage") {
            r = await BenchProcess.run(path, ["-s", "-c"], timeout: 90)          // older tool without -M
        }
        guard let out = r else { return (nil, "networkQuality did not run") }
        if let nq = parseNQ(out.stdout) { return (nq, nil) }
        let err = (out.stderr + out.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, err.isEmpty ? "networkQuality returned no result (offline?)" : String(err.prefix(160)))
    }

    static func parseNQ(_ s: String) -> Responsiveness? {
        guard let start = s.firstIndex(of: "{"), let data = String(s[start...]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        var r = Responsiveness()
        r.dlRPM = num("dl_responsiveness"); r.ulRPM = num("ul_responsiveness"); r.rpm = num("responsiveness")
        r.idleLatencyMS = num("base_rtt")
        r.dlMbps = num("dl_throughput").map { $0 / 1e6 }; r.ulMbps = num("ul_throughput").map { $0 / 1e6 }
        r.interface = o["interface_name"] as? String ?? ""; r.endpoint = o["test_endpoint"] as? String ?? ""
        guard r.dlRPM != nil || r.rpm != nil || r.dlMbps != nil else { return nil }
        return r
    }
}
