import Foundation

enum BenchEvent: Sendable {
    case status(BenchmarkTest, TestStatus)
    case sub(Double)                 // progress inside the current job, 0…1
}

/// Runs tests off the main actor: noise-sensitive local tests first (CPU, GPU, memory, SSD), then network
/// (pings in parallel, DNS, link-saturating networkQuality last), then Ollama, which heats the Mac most.
struct BenchmarkEngine: Sendable {
    let tests: [BenchmarkTest]
    let cancel: CancelFlag
    let report: @Sendable (BenchEvent) async -> Void

    private func has(_ t: BenchmarkTest) -> Bool { tests.contains(t) }

    func execute() async -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        let jobs: [[BenchmarkTest]] = [
            [.cpuSingle], [.cpuMulti], [.gpuCompute, .gpuBandwidth], [.memBandwidth], [.memLatency],
            [.ssdSeqWrite, .ssdSeqRead, .ssdBigWrite, .ssdBigRead, .ssd4kRead, .ssd4kWrite],
            [.pingGateway, .ping1111, .ping8888, .pingAWS], [.dns], [.responsiveness], [.ollama],
        ]
        for job in jobs {
            let mine = job.filter(has)
            guard !mine.isEmpty else { continue }
            if cancel.isCancelled { break }
            for t in mine { await report(.status(t, .running)) }
            await report(.sub(0))
            do {
                let r = try await run(job[0], previous: results)
                if cancel.isCancelled { break }
                results += r
                for t in mine {
                    if let x = r.first(where: { $0.testID == t.rawValue }) {
                        await report(.status(t, x.skipped.map { .skipped($0) } ?? .done("\(fmtValue(x.value)) \(x.unit)")))
                    } else { await report(.status(t, .skipped("not measured"))) }
                }
            } catch is BenchCancelled {
                break
            } catch {
                if cancel.isCancelled { break }
                let msg = error.localizedDescription
                for t in mine {
                    results.append(skippedResult(t, msg))
                    await report(.status(t, .failed(msg)))
                }
            }
        }
        return results
    }

    private func run(_ first: BenchmarkTest, previous: [BenchmarkResult]) async throws -> [BenchmarkResult] {
        switch first {
        case .cpuSingle: return try await cpuSingle()
        case .cpuMulti: return try await cpuMulti(single: previous.first { $0.testID == BenchmarkTest.cpuSingle.rawValue })
        case .gpuCompute: return try await gpu()
        case .memBandwidth: return try await memBandwidth()
        case .memLatency: return try await memLatency()
        case .ssdSeqWrite: return try await ssd()
        case .pingGateway: return await pings()
        case .dns: return await dns()
        case .responsiveness: return await responsiveness()
        case .ollama: return try await ollama()
        default: return []
        }
    }

    // MARK: Helpers

    private func skippedResult(_ t: BenchmarkTest, _ why: String) -> BenchmarkResult {
        BenchmarkResult(testID: t.rawValue, name: t.rawValue, value: 0, unit: t.unit, higherIsBetter: t.higherIsBetter, detail: why, skipped: why)
    }

    private func sub(_ x: Double) async { await report(.sub(x)) }
    private func check() throws { if cancel.isCancelled { throw BenchCancelled() } }

    /// Throughput result: best sample is the headline (least disturbed run), median kept for context.
    private func best(_ t: BenchmarkTest, _ s: [Double], detail: String, metrics: [BenchmarkMetric]? = nil) -> BenchmarkResult {
        let v = t.higherIsBetter ? (s.max() ?? 0) : (s.min() ?? 0)
        return BenchmarkResult(testID: t.rawValue, name: t.rawValue, value: v, unit: t.unit, higherIsBetter: t.higherIsBetter,
                               detail: detail, samples: s, median: Stats.median(s), metrics: metrics)
    }

    private func spread(_ s: [Double]) -> String {
        guard let h = Stats.halfRangePercent(s) else { return "" }
        return String(format: ", spread ±%.1f%%", h)
    }

    // MARK: CPU

    private func cpuSingle() async throws -> [BenchmarkResult] {
        let reps = await CPUBench.calibrate()
        var s: [Double] = []
        for i in 0..<3 { try check(); s.append(try await CPUBench.throughput(threads: 1, reps: reps, cancel: cancel)); await sub(Double(i + 1) / 3) }
        return [best(.cpuSingle, s, detail: "1 thread at user-interactive QoS, \(reps) kernel runs per sample; best of 3, median \(f1(Stats.median(s)))\(spread(s))")]
    }

    private func cpuMulti(single: BenchmarkResult?) async throws -> [BenchmarkResult] {
        let n = ProcessInfo.processInfo.activeProcessorCount
        let p = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        let reps = await CPUBench.calibrate()
        var all: [Double] = []
        for i in 0..<3 { try check(); all.append(try await CPUBench.throughput(threads: n, reps: reps, cancel: cancel)); await sub(Double(i + 1) / 5) }
        var metrics: [BenchmarkMetric] = []
        var pBest: Double? = nil
        if p > 0, p < n {
            var ps: [Double] = []
            for i in 0..<2 { try check(); ps.append(try await CPUBench.throughput(threads: p, reps: reps, cancel: cancel)); await sub(Double(4 + i) / 5) }
            pBest = ps.max()
        }
        var one = single.flatMap { $0.isValid ? $0.value : nil }
        if one == nil { try check(); one = try await CPUBench.throughput(threads: 1, reps: max(2, reps / 2), cancel: cancel) }
        let allBest = all.max() ?? 0
        if let one { metrics.append(BenchmarkMetric(key: "threads.1", label: "1 thread", value: one, unit: "Mops/s", higherIsBetter: true)) }
        if let pBest { metrics.append(BenchmarkMetric(key: "threads.p", label: "\(p) threads (P-cores)", value: pBest, unit: "Mops/s", higherIsBetter: true)) }
        metrics.append(BenchmarkMetric(key: "threads.all", label: "\(n) threads (all cores)", value: allBest, unit: "Mops/s", higherIsBetter: true, samples: all))
        var detail = "\(n) threads sharing one work queue, best of 3, median \(f1(Stats.median(all)))\(spread(all))"
        if let one, one > 0 {
            let x = allBest / one
            metrics.append(BenchmarkMetric(key: "scaling", label: "Scaling over 1 thread", value: x, unit: "×", higherIsBetter: true))
            detail += String(format: "; scaling ×%.1f over one thread", x)
            if let pBest { detail += String(format: " (×%.1f with %d P-core threads)", pBest / one, p) }
        }
        return [best(.cpuMulti, all, detail: detail, metrics: metrics)]
    }

    // MARK: GPU

    private func gpu() async throws -> [BenchmarkResult] {
        let r = try await GPUBench.run(wantCompute: has(.gpuCompute), wantBandwidth: has(.gpuBandwidth), cancel: cancel)
        try check()
        var out: [BenchmarkResult] = []
        if has(.gpuCompute), !r.gflops.isEmpty {
            out.append(best(.gpuCompute, r.gflops, detail: "\(r.device): 1M threads × \(r.iters) iterations × 8 float4 FMA chains, GPU timestamps; best of 3, median \(f1(Stats.median(r.gflops)))\(spread(r.gflops))"))
        }
        if has(.gpuBandwidth), !r.bandwidth.isEmpty {
            out.append(best(.gpuBandwidth, r.bandwidth, detail: "\(r.device): float4 copy of \(r.bufferMiB) MiB private buffers ×4, read + write counted; best of 3, median \(f1(Stats.median(r.bandwidth)))\(spread(r.bandwidth))"))
        }
        return out
    }

    // MARK: Memory

    private func memBandwidth() async throws -> [BenchmarkResult] {
        let bytes = MemoryBench.bufferBytes()
        let buf = MemoryBench.Buffers(bytes: bytes)
        await buf.touch()
        try check()
        let n = ProcessInfo.processInfo.activeProcessorCount
        var multi: [Double] = [], single: [Double] = []
        for i in 0..<3 { try check(); multi.append(try await MemoryBench.copyBandwidth(buf, threads: n, passes: 16, cancel: cancel)); await sub(Double(i + 1) / 6) }
        for i in 0..<3 { try check(); single.append(try await MemoryBench.copyBandwidth(buf, threads: 1, passes: 6, cancel: cancel)); await sub(Double(i + 4) / 6) }
        let metrics = [
            BenchmarkMetric(key: "threads.all", label: "\(n) threads", value: multi.max() ?? 0, unit: "GB/s", higherIsBetter: true, samples: multi),
            BenchmarkMetric(key: "threads.1", label: "1 thread", value: single.max() ?? 0, unit: "GB/s", higherIsBetter: true, samples: single),
        ]
        return [best(.memBandwidth, multi, detail: "memcpy across \(n) threads over 2 × \(bytes >> 20) MiB, read + write counted; best of 3\(spread(multi)); 1 thread \(f1(single.max() ?? 0)) GB/s", metrics: metrics)]
    }

    private func memLatency() async throws -> [BenchmarkResult] {
        let big = min(512 << 20, Int(ProcessInfo.processInfo.physicalMemory) / 16)
        let sizes: [(Int, String)] = [(256 << 10, "256 KiB"), (8 << 20, "8 MiB"), (64 << 20, "64 MiB"), (big, "\(big >> 20) MiB")]
        var metrics: [BenchmarkMetric] = []
        var headline: [Double] = []
        for (i, (bytes, label)) in sizes.enumerated() {
            try check()
            let s = await MemoryBench.chaseLatency(bytes: bytes, samples: 3, cancel: cancel)
            try check()
            guard let mn = s.min() else { continue }
            metrics.append(BenchmarkMetric(key: "size.\(bytes >> 10)k", label: label, value: mn, unit: "ns", higherIsBetter: false, samples: s))
            if i == sizes.count - 1 { headline = s }
            await sub(Double(i + 1) / Double(sizes.count))
        }
        guard !headline.isEmpty else { return [skippedResult(.memLatency, "no samples")] }
        let ladder = metrics.map { "\($0.label) \(String(format: "%.1f", $0.value))" }.joined(separator: " · ")
        return [best(.memLatency, headline, detail: "Random pointer chase, 128 B lines, 1 thread; best of 3. ns per load: \(ladder)", metrics: metrics)]
    }

    // MARK: SSD

    private func ssd() async throws -> [BenchmarkResult] {
        let opts = SSDBench.Options(seqQD1: has(.ssdSeqWrite) || has(.ssdSeqRead), big: has(.ssdBigWrite) || has(.ssdBigRead), rand4k: has(.ssd4kRead) || has(.ssd4kWrite))
        let report = self.report
        let r = try await SSDBench.run(opts, cancel: cancel) { p in Task { await report(.sub(p)) } }
        try check()
        let file = "\(r.fileMiB) MiB file"
        var out: [BenchmarkResult] = []
        if has(.ssdSeqWrite), !r.seqWrite.isEmpty { out.append(best(.ssdSeqWrite, r.seqWrite, detail: "\(file), 1 MiB blocks, 1 in flight, F_NOCACHE + F_FULLFSYNC; best of 3\(spread(r.seqWrite))")) }
        if has(.ssdSeqRead), !r.seqRead.isEmpty { out.append(best(.ssdSeqRead, r.seqRead, detail: "\(file), 1 MiB blocks, 1 in flight, F_NOCACHE; best of 3\(spread(r.seqRead))")) }
        if has(.ssdBigWrite), !r.bigWrite.isEmpty { out.append(best(.ssdBigWrite, r.bigWrite, detail: "\(file), 8 MiB blocks, 4 in flight, F_NOCACHE + F_FULLFSYNC; best of 3\(spread(r.bigWrite))")) }
        if has(.ssdBigRead), !r.bigRead.isEmpty { out.append(best(.ssdBigRead, r.bigRead, detail: "\(file), 8 MiB blocks, 4 in flight, F_NOCACHE; best of 3\(spread(r.bigRead))")) }
        func rand(_ t: BenchmarkTest, _ iops: Double, _ lat: [Double], _ what: String) -> BenchmarkResult {
            let metrics = [
                BenchmarkMetric(key: "mbps", label: "Throughput", value: iops * 4096 / 1e6, unit: "MB/s", higherIsBetter: true),
                BenchmarkMetric(key: "lat.p50", label: "Latency p50", value: lat.first ?? 0, unit: "µs", higherIsBetter: false),
                BenchmarkMetric(key: "lat.p99", label: "Latency p99", value: lat.last ?? 0, unit: "µs", higherIsBetter: false),
            ]
            return BenchmarkResult(testID: t.rawValue, name: t.rawValue, value: iops, unit: "IOPS", higherIsBetter: true,
                                   detail: String(format: "4 KiB %@, 1 in flight, 3 s, F_NOCACHE; latency p50 %.0f µs, p99 %.0f µs", what, lat.first ?? 0, lat.last ?? 0),
                                   samples: [iops], median: iops, metrics: metrics)
        }
        if has(.ssd4kRead), r.randRead > 0 { out.append(rand(.ssd4kRead, r.randRead, r.randReadLatUS, "random reads")) }
        if has(.ssd4kWrite), r.randWrite > 0 { out.append(rand(.ssd4kWrite, r.randWrite, r.randWriteLatUS, "random writes, no per-write flush")) }
        return out
    }

    // MARK: Network

    private func pingResult(_ t: BenchmarkTest, _ s: NetworkBench.PingStats, label: String, extra: [BenchmarkMetric] = []) -> BenchmarkResult {
        let metrics: [BenchmarkMetric] = [
            BenchmarkMetric(key: "min", label: "Min", value: s.min, unit: "ms", higherIsBetter: false),
            BenchmarkMetric(key: "p95", label: "p95", value: s.p95, unit: "ms", higherIsBetter: false),
            BenchmarkMetric(key: "max", label: "Max", value: s.max, unit: "ms", higherIsBetter: false),
            BenchmarkMetric(key: "jitter", label: "Jitter", value: s.jitter, unit: "ms", higherIsBetter: false),
            BenchmarkMetric(key: "loss", label: "Loss", value: s.loss, unit: "%", higherIsBetter: false),
            BenchmarkMetric(key: "spikes", label: "Replies > 50 ms", value: Double(s.spikes), unit: "", higherIsBetter: false),
        ] + extra
        let d = String(format: "%@: median %.1f, p95 %.1f, min %.1f, max %.1f ms; jitter %.1f ms; loss %.0f%%; %d over 50 ms (%d pings)",
                       label, s.median, s.p95, s.min, s.max, s.jitter, s.loss, s.spikes, s.sent)
        return BenchmarkResult(testID: t.rawValue, name: t.rawValue, value: s.median, unit: "ms", higherIsBetter: false,
                               detail: d, samples: s.times, median: s.median, p95: s.p95, metrics: metrics)
    }

    private func pings() async -> [BenchmarkResult] {
        var out: [BenchmarkResult] = []
        var targets: [(BenchmarkTest, String, String)] = []
        if has(.pingGateway) {
            if let g = await NetworkBench.gateway() { targets.append((.pingGateway, g, "gateway \(g)")) }
            else { out.append(skippedResult(.pingGateway, "No IPv4 default gateway (offline or IPv6-only)")) }
        }
        if has(.ping1111) { targets.append((.ping1111, "1.1.1.1", "1.1.1.1")) }
        if has(.ping8888) { targets.append((.ping8888, "8.8.8.8", "8.8.8.8")) }
        var ranks: [NetworkBench.RegionTime] = []
        if has(.pingAWS) {
            ranks = await NetworkBench.rankAWS()
            if let w = ranks.first { targets.append((.pingAWS, "dynamodb.\(w.region).amazonaws.com", w.region)) }
            else { out.append(skippedResult(.pingAWS, "No AWS region answered on TCP 443 (offline or blocked)")) }
        }
        await sub(0.2)
        if cancel.isCancelled { return out }
        let stats = await withTaskGroup(of: (BenchmarkTest, NetworkBench.PingStats?).self) { g in
            for (t, host, _) in targets { g.addTask { (t, await NetworkBench.ping(host)) } }
            var all: [BenchmarkTest: NetworkBench.PingStats?] = [:]
            for await (t, s) in g { all[t] = s }
            return all
        }
        for (t, host, label) in targets {
            let s = stats[t] ?? nil
            var extra: [BenchmarkMetric] = []
            var lbl = label
            if t == .pingAWS, let w = ranks.first {
                extra.append(BenchmarkMetric(key: "tcp.connect", label: "TCP connect (\(w.region))", value: w.minMS, unit: "ms", higherIsBetter: false))
                let top = ranks.prefix(3).map { "\($0.region) \(f1($0.minMS))" }.joined(separator: ", ")
                lbl = "\(w.region) (TCP connect ms: \(top))"
            }
            if let s, s.received > 0 {
                out.append(pingResult(t, s, label: lbl, extra: extra))
            } else if t == .pingAWS, let w = ranks.first {
                out.append(BenchmarkResult(testID: t.rawValue, name: t.rawValue, value: w.minMS, unit: "ms", higherIsBetter: false,
                                           detail: "\(lbl): ICMP blocked on this network, TCP connect time used", samples: [w.minMS], median: w.medianMS, metrics: extra))
            } else {
                out.append(skippedResult(t, "No ICMP replies from \(host) (blocked or offline)"))
            }
        }
        return out
    }

    private func dns() async -> [BenchmarkResult] {
        var servers: [(String, String)] = []
        if let s = NetworkBench.systemResolvers().first { servers.append(("system \(s)", s)) }
        for pub in ["1.1.1.1", "8.8.8.8", "9.9.9.9"] where !servers.contains(where: { $0.1 == pub }) { servers.append((pub, pub)) }
        var metrics: [BenchmarkMetric] = []
        var lines: [String] = []
        var headline: NetworkBench.ResolverStats? = nil
        for (i, (label, server)) in servers.enumerated() {
            if cancel.isCancelled { break }
            let s = await NetworkBench.measureResolver(label: label, server: server, cancel: cancel)
            let key = i == 0 && label.hasPrefix("system") ? "system" : server
            if !s.cached.isEmpty {
                metrics.append(BenchmarkMetric(key: "\(key).cached.median", label: "\(label) cached median", value: Stats.median(s.cached), unit: "ms", higherIsBetter: false, samples: s.cached))
                metrics.append(BenchmarkMetric(key: "\(key).cached.p95", label: "\(label) cached p95", value: Stats.percentile(s.cached, 95), unit: "ms", higherIsBetter: false))
            }
            if !s.uncached.isEmpty {
                metrics.append(BenchmarkMetric(key: "\(key).uncached.median", label: "\(label) uncached median", value: Stats.median(s.uncached), unit: "ms", higherIsBetter: false, samples: s.uncached))
                metrics.append(BenchmarkMetric(key: "\(key).uncached.p95", label: "\(label) uncached p95", value: Stats.percentile(s.uncached, 95), unit: "ms", higherIsBetter: false))
            }
            if s.cached.isEmpty && s.uncached.isEmpty { lines.append("\(label): no reply") }
            else {
                lines.append(String(format: "%@: cached %.1f (p95 %.1f) ms, uncached %.1f (p95 %.1f) ms, %d/%d failed", label,
                                    Stats.median(s.cached), Stats.percentile(s.cached, 95), Stats.median(s.uncached), Stats.percentile(s.uncached, 95), s.failures, s.total))
                if headline == nil, !s.cached.isEmpty { headline = s }
            }
            await sub(Double(i + 1) / Double(servers.count))
        }
        guard let h = headline else { return [skippedResult(.dns, "No resolver answered (offline?)")] }
        return [BenchmarkResult(testID: BenchmarkTest.dns.rawValue, name: BenchmarkTest.dns.rawValue, value: Stats.median(h.cached), unit: "ms", higherIsBetter: false,
                                detail: "Headline: \(h.label), cached. " + lines.joined(separator: "\n"), samples: h.cached,
                                median: Stats.median(h.cached), p95: Stats.percentile(h.cached, 95), metrics: metrics)]
    }

    private func responsiveness() async -> [BenchmarkResult] {
        let (r, err) = await NetworkBench.networkQuality()
        guard let r, let rpm = r.dlRPM ?? r.rpm else { return [skippedResult(.responsiveness, err ?? "No result")] }
        var m: [BenchmarkMetric] = []
        if let v = r.idleLatencyMS { m.append(BenchmarkMetric(key: "idle", label: "Idle latency", value: v, unit: "ms", higherIsBetter: false)) }
        if let v = r.ulRPM { m.append(BenchmarkMetric(key: "ul.rpm", label: "Upload RPM", value: v, unit: "RPM", higherIsBetter: true)) }
        if let v = r.dlMbps { m.append(BenchmarkMetric(key: "dl.mbps", label: "Download", value: v, unit: "Mbps", higherIsBetter: true)) }
        if let v = r.ulMbps { m.append(BenchmarkMetric(key: "ul.mbps", label: "Upload", value: v, unit: "Mbps", higherIsBetter: true)) }
        let d = String(format: "networkQuality -s via %@ (%@): download RPM %.0f, upload RPM %.0f, idle latency %.0f ms, %.0f / %.0f Mbps down/up",
                       r.interface.isEmpty ? "?" : r.interface, r.endpoint.isEmpty ? "Apple CDN" : r.endpoint,
                       rpm, r.ulRPM ?? 0, r.idleLatencyMS ?? 0, r.dlMbps ?? 0, r.ulMbps ?? 0)
        return [BenchmarkResult(testID: BenchmarkTest.responsiveness.rawValue, name: BenchmarkTest.responsiveness.rawValue, value: rpm, unit: "RPM", higherIsBetter: true,
                                detail: d, samples: [rpm], median: rpm, metrics: m)]
    }

    private func ollama() async throws -> [BenchmarkResult] {
        let report = self.report
        do {
            let r = try await OllamaBench.run(cancel: cancel) { p in Task { await report(.sub(p)) } }
            var m: [BenchmarkMetric] = []
            if !r.prompt.isEmpty { m.append(BenchmarkMetric(key: "prompt", label: "Prompt processing", value: r.prompt.max() ?? 0, unit: "tok/s", higherIsBetter: true, samples: r.prompt)) }
            if let c = r.coldStartS { m.append(BenchmarkMetric(key: "cold", label: "Model load (warm-up)", value: c, unit: "s", higherIsBetter: false)) }
            let d = String(format: "%@ (%.1f GB): generation %.1f tok/s, prompt %.0f tok/s; warm-up discarded, best of 3, median %.1f%@",
                           r.model, r.sizeGB, r.generation.max() ?? 0, r.prompt.max() ?? 0, Stats.median(r.generation), spread(r.generation))
            return [best(.ollama, r.generation, detail: d, metrics: m)]
        } catch let e as OllamaBench.Unavailable {
            return [skippedResult(.ollama, e.localizedDescription)]
        }
    }
}
