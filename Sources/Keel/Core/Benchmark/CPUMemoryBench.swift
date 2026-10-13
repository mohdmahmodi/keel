import Foundation

/// CPU throughput. Do not change the kernel: saved runs must stay comparable. Samples are ~1 s on dedicated
/// user-interactive threads with a shared work queue, so fast and slow cores stay busy until the end.
enum CPUBench {
    /// Mixed integer + floating workload: mandelbrot escape iterations, prime sieve, small matmul.
    /// Returns the number of operations performed.
    static func kernel() -> Double {
        var ops = 0.0
        // Mandelbrot 300x300, 200 iterations
        let n = 300, maxIt = 200
        for py in 0..<n {
            let y0 = Double(py) / Double(n) * 2.0 - 1.0
            for px in 0..<n {
                let x0 = Double(px) / Double(n) * 3.0 - 2.0
                var x = 0.0, y = 0.0, it = 0
                while x*x + y*y <= 4 && it < maxIt { let xt = x*x - y*y + x0; y = 2*x*y + y0; x = xt; it += 1 }
                ops += Double(it) * 6
            }
        }
        // Sieve to 3M
        let limit = 3_000_000
        var sieve = [Bool](repeating: true, count: limit + 1)
        var i = 2
        while i * i <= limit { if sieve[i] { var j = i * i; while j <= limit { sieve[j] = false; j += i; ops += 1 } }; i += 1 }
        // 160x160 matmul
        let m = 160
        var a = [Double](repeating: 0, count: m*m), b = [Double](repeating: 0, count: m*m), c = [Double](repeating: 0, count: m*m)
        for k in 0..<(m*m) { a[k] = Double(k % 7) * 0.5; b[k] = Double(k % 5) * 0.25 }
        for r in 0..<m { for k in 0..<m { let av = a[r*m+k]; for col in 0..<m { c[r*m+col] += av * b[k*m+col] } } }
        ops += Double(m*m*m) * 2
        blackHole(c[0] + (sieve[limit] ? 1 : 0))
        return ops
    }
    @inline(never) static func blackHole(_ x: Double) { if x == -12345.678 { print(x) } }

    /// Kernel repetitions so that one thread works for about `target` seconds.
    static func calibrate(target: Double = 0.8) async -> Int {
        _ = await BenchThreads.one { kernel() }                       // warm caches, page in code
        let (_, secs) = await BenchThreads.run(1) { _ in kernel() }
        return max(2, min(400, Int((target / secs).rounded())))
    }

    private final class WorkQueue: @unchecked Sendable {
        let lock = NSLock(); var remaining: Int
        init(_ n: Int) { remaining = n }
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if remaining > 0 { remaining -= 1; return true }; return false }
    }

    /// Million operations per second with `threads` threads sharing `threads × reps` kernel runs.
    static func throughput(threads: Int, reps: Int, cancel: CancelFlag) async throws -> Double {
        if cancel.isCancelled { throw BenchCancelled() }
        let q = WorkQueue(threads * reps)
        let (ops, secs) = await BenchThreads.run(threads) { _ in
            var o = 0.0
            while !cancel.isCancelled, q.take() { o += kernel() }
            return o
        }
        if cancel.isCancelled { throw BenchCancelled() }
        return ops.reduce(0, +) / secs / 1e6
    }
}

/// Memory bandwidth (memcpy) and latency (pointer chase).
enum MemoryBench {
    /// Two page-aligned buffers, pre-touched so first-touch page faults are not timed.
    final class Buffers: @unchecked Sendable {
        let src: UnsafeMutableRawPointer, dst: UnsafeMutableRawPointer, bytes: Int
        init(bytes: Int) {
            self.bytes = bytes
            src = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16384)
            dst = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16384)
        }
        func touch() async {
            let n = 8, slice = bytes / n
            _ = await BenchThreads.run(n, qos: .userInitiated) { [self] i in
                memset(src + i * slice, 0x5A, slice); memset(dst + i * slice, 0xA5, slice)
            }
        }
        deinit { src.deallocate(); dst.deallocate() }
    }

    /// Buffer size per side: 1 GiB, or 1/16 of RAM on smaller Macs (512 MiB on 8 GB).
    static func bufferBytes() -> Int {
        let mem = Int(ProcessInfo.processInfo.physicalMemory)
        let b = min(1 << 30, mem / 16)
        return b - b % (1 << 20)
    }

    /// GB/s for `threads` threads each copying its own slice `passes` times (read + write counted).
    static func copyBandwidth(_ buf: Buffers, threads: Int, passes: Int, cancel: CancelFlag) async throws -> Double {
        if cancel.isCancelled { throw BenchCancelled() }
        let slice = (buf.bytes / threads) & ~0x3FFF
        let (_, secs) = await BenchThreads.run(threads) { i in
            let s = buf.src + i * slice, d = buf.dst + i * slice
            for p in 0..<passes { if p % 2 == 0 { memcpy(d, s, slice) } else { memcpy(s, d, slice) } }
        }
        if cancel.isCancelled { throw BenchCancelled() }
        return Double(slice * threads * passes * 2) / secs / 1e9
    }

    /// ns per dependent load when chasing a random cycle through `bytes` of memory in 128-byte lines.
    /// The chain is built once; each of `samples` timings covers ~0.1–0.4 s of loads.
    static func chaseLatency(bytes: Int, samples: Int, cancel: CancelFlag) async -> [Double] {
        await BenchThreads.one {
            let line = 128, stride = line / MemoryLayout<Int>.stride
            let lines = max(bytes / line, 16)
            let p = UnsafeMutablePointer<Int>.allocate(capacity: lines * stride)
            defer { p.deallocate() }
            p.initialize(repeating: 0, count: lines * stride)
            // Sattolo's algorithm: a single random cycle visiting every line, which defeats the prefetchers.
            var order = [Int](0..<lines)
            var rng: UInt64 = 0x2545F4914F6CDD1D
            var k = lines - 1
            while k > 0 {
                rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                order.swapAt(k, Int(rng % UInt64(k)))
                k -= 1
            }
            for idx in 0..<lines { p[order[idx] * stride] = order[(idx + 1) % lines] * stride }
            order = []
            if cancel.isCancelled { return [] }
            // One untimed pass to warm caches and TLB as far as they go.
            var cur = 0
            for _ in 0..<min(lines, 1 << 20) { cur = p[cur] }
            let loads = bytes >= 32 << 20 ? 3_000_000 : 12_000_000
            var out: [Double] = []
            for _ in 0..<samples {
                if cancel.isCancelled { break }
                let t0 = nowNS()
                var n = 0
                while n < loads {
                    cur = p[cur]; cur = p[cur]; cur = p[cur]; cur = p[cur]
                    cur = p[cur]; cur = p[cur]; cur = p[cur]; cur = p[cur]
                    n += 8
                }
                out.append(Double(nowNS() - t0) / Double(loads))
            }
            CPUBench.blackHole(Double(cur))
            return out
        }
    }
}
