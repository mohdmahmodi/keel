import Foundation

/// Storage tests on a temp file on the boot volume. F_NOCACHE bypasses the buffer cache (otherwise reads
/// come from RAM at 20+ GB/s); buffers hold pseudo-random bytes because SSD controllers compress zeros.
enum SSDBench {
    struct Options: Sendable { var seqQD1 = true, big = true, rand4k = true }
    struct Result: Sendable {
        var seqWrite: [Double] = [], seqRead: [Double] = []          // MB/s
        var bigWrite: [Double] = [], bigRead: [Double] = []          // MB/s
        var randRead: Double = 0, randWrite: Double = 0              // IOPS
        var randReadLatUS: [Double] = [], randWriteLatUS: [Double] = []  // p50, p99 µs
        var fileMiB = 0
        var freeGB = 0.0
    }

    static let fileSize = 1 << 30
    static var tempPath: String { NSTemporaryDirectory() + "keel-bench-\(getpid()).bin" }

    /// Free space on the volume holding the temp file, in bytes.
    static func freeBytes() -> Int64? {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
        if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    enum SSDError: Error, LocalizedError {
        case lowSpace(Double), open(String), io(String)
        var errorDescription: String? {
            switch self {
            case .lowSpace(let gb): return String(format: "Needs 10 GB free on the startup disk (%.1f GB free)", gb)
            case .open(let s): return "Could not create the temporary file: \(s)"
            case .io(let s): return "I/O error: \(s)"
            }
        }
    }

    /// Removes temp files left by a Keel process that was killed mid-test (its pid no longer exists).
    static func removeStaleFiles() {
        let dir = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("keel-bench-") && name.hasSuffix(".bin") {
            let pidText = name.dropFirst("keel-bench-".count).dropLast(4)
            if let pid = Int32(pidText), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH { unlink(dir + name) }
        }
    }

    static func run(_ opts: Options, cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        removeStaleFiles()
        let free = freeBytes() ?? 0
        let freeGB = Double(free) / 1e9
        guard free >= 10_000_000_000 else { throw SSDError.lowSpace(freeGB) }
        let r: Result = try await withCheckedThrowingContinuation { cont in
            let t = Thread {
                do { cont.resume(returning: try runSync(opts, cancel: cancel, progress: progress)) } catch { cont.resume(throwing: error) }
            }
            t.qualityOfService = .userInitiated
            t.stackSize = 4 << 20
            t.start()
        }
        var out = r; out.freeGB = freeGB
        return out
    }

    private static func fill(_ p: UnsafeMutableRawPointer, _ n: Int, seed: UInt64) {
        var s = seed
        p.withMemoryRebound(to: UInt64.self, capacity: n / 8) { q in
            for i in 0..<(n / 8) { s = s &* 6364136223846793005 &+ 1442695040888963407; q[i] = s }
        }
    }

    private static func runSync(_ opts: Options, cancel: CancelFlag, progress: @Sendable (Double) -> Void) throws -> Result {
        let path = tempPath
        defer { unlink(path) }
        let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        guard fd >= 0 else { throw SSDError.open(String(cString: strerror(errno))) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var res = Result(); res.fileMiB = fileSize >> 20

        let small = 1 << 20, big = 8 << 20, lanes = 4
        // One random buffer per lane for the 8 MiB mode; lane 0's buffer doubles as the 1 MiB / 4 KiB buffer.
        let bufs = (0..<lanes).map { i -> UnsafeMutableRawPointer in
            let b = UnsafeMutableRawPointer.allocate(byteCount: big, alignment: 16384)
            fill(b, big, seed: 0x9E3779B97F4A7C15 &+ UInt64(i)); return b
        }
        defer { bufs.forEach { $0.deallocate() } }
        func check() throws { if cancel.isCancelled { throw BenchCancelled() } }
        func secs(_ t0: UInt64) -> Double { max(Double(nowNS() - t0) / 1e9, 1e-9) }

        // QD1 sequential, 1 MiB.
        func seqWrite() throws -> Double {
            let t0 = nowNS(); var off = 0
            while off < fileSize {
                let n = pwrite(fd, bufs[0], small, off_t(off)); if n <= 0 { throw SSDError.io(String(cString: strerror(errno))) }
                off += n
                if off % (64 << 20) == 0 { try check() }
            }
            _ = fcntl(fd, F_FULLFSYNC)
            return Double(off) / secs(t0) / 1e6
        }
        func seqRead() throws -> Double {
            let t0 = nowNS(); var off = 0
            while off < fileSize {
                let n = pread(fd, bufs[0], small, off_t(off)); if n <= 0 { throw SSDError.io(String(cString: strerror(errno))) }
                off += n
                if off % (64 << 20) == 0 { try check() }
            }
            return Double(off) / secs(t0) / 1e6
        }
        // 8 MiB requests, four in flight (one per thread, interleaved blocks), like Blackmagic.
        func bigIO(write: Bool) throws -> Double {
            let blocks = fileSize / big
            let failed = UnsafeMutablePointer<Int32>.allocate(capacity: 1); failed.pointee = 0
            defer { failed.deallocate() }
            let t0 = nowNS()
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                var b = lane
                while b < blocks {
                    let off = off_t(b * big)
                    let n = write ? pwrite(fd, bufs[lane], big, off) : pread(fd, bufs[lane], big, off)
                    if n != big { failed.pointee = 1; return }
                    if cancel.isCancelled { return }
                    b += lanes
                }
            }
            if write { _ = fcntl(fd, F_FULLFSYNC) }
            try check()
            if failed.pointee != 0 { throw SSDError.io("short \(write ? "write" : "read")") }
            return Double(fileSize) / secs(t0) / 1e6
        }
        func random4k(write: Bool) throws -> (Double, [Double]) {
            let blocks = fileSize / 4096
            var rng: UInt64 = write ? 0xD1B54A32D192ED03 : 0x8CB92BA72F3D8DD7
            var lat: [Double] = []; lat.reserveCapacity(80_000)
            let t0 = nowNS()
            while Double(nowNS() - t0) < 3e9 {
                rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                let off = off_t(Int(rng % UInt64(blocks)) * 4096)
                let s = nowNS()
                let n = write ? pwrite(fd, bufs[1], 4096, off) : pread(fd, bufs[1], 4096, off)
                if n == 4096 { lat.append(Double(nowNS() - s) / 1000) }
                if lat.count % 2048 == 0 { try check() }
            }
            let iops = Double(lat.count) / secs(t0)
            return (iops, [Stats.median(lat), Stats.percentile(lat, 99)])
        }

        // The file must exist at full size before any read test; the first QD1 write creates it.
        let steps = Double((opts.seqQD1 ? 6 : 0) + (opts.big ? 6 : 0) + (opts.rand4k ? 2 : 0) + 1)
        var done = 0.0
        func tick() { done += 1; progress(min(1, done / steps)) }

        let first = try seqWrite(); tick()
        if opts.seqQD1 {
            res.seqWrite.append(first)
            for _ in 0..<2 { try check(); res.seqWrite.append(try seqWrite()); tick() }
            for _ in 0..<3 { try check(); res.seqRead.append(try seqRead()); tick() }
        }
        if opts.big {
            for _ in 0..<3 { try check(); res.bigWrite.append(try bigIO(write: true)); tick() }
            for _ in 0..<3 { try check(); res.bigRead.append(try bigIO(write: false)); tick() }
        }
        if opts.rand4k {
            try check(); (res.randRead, res.randReadLatUS) = try random4k(write: false); tick()
            try check(); (res.randWrite, res.randWriteLatUS) = try random4k(write: true); _ = fcntl(fd, F_FULLFSYNC); tick()
        }
        return res
    }
}
