import Foundation

/// Shared cancel flag polled by compute loops running on their own threads.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag || Task.isCancelled }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

struct BenchCancelled: Error {}

/// Monotonic nanoseconds.
@inline(__always) func nowNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// CPU-bound work on dedicated threads, so the cooperative pool and main thread never block. QoS is the only
/// control over core placement: user-interactive can use P-cores, background stays on E-cores.
enum BenchThreads {
    private final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        var values: [T?]
        var starts: [UInt64]
        var ends: [UInt64]
        init(_ n: Int) { values = Array(repeating: nil, count: n); starts = Array(repeating: 0, count: n); ends = Array(repeating: 0, count: n) }
    }

    /// Start barrier: every thread waits until all have been created, so the timed window covers real parallel work.
    private final class Barrier: @unchecked Sendable {
        let cond = NSCondition()
        var waiting = 0
        let count: Int
        init(_ n: Int) { count = n }
        func wait() {
            cond.lock()
            waiting += 1
            if waiting >= count { cond.broadcast() } else { while waiting < count { cond.wait() } }
            cond.unlock()
        }
    }

    /// Runs `body(i)` on `n` threads. Returns the results in index order and the wall time from the
    /// first thread passing the start barrier to the last one finishing.
    static func run<T>(_ n: Int, qos: QualityOfService = .userInteractive, stackMB: Int = 8, _ body: @escaping @Sendable (Int) -> T) async -> (values: [T], seconds: Double) {
        let box = Box<T>(n)
        let barrier = Barrier(n)
        return await withCheckedContinuation { cont in
            let group = DispatchGroup()
            for i in 0..<n {
                group.enter()
                let t = Thread {
                    barrier.wait()
                    let s = nowNS()
                    let v = body(i)
                    let e = nowNS()
                    box.lock.lock(); box.values[i] = v; box.starts[i] = s; box.ends[i] = e; box.lock.unlock()
                    group.leave()
                }
                t.qualityOfService = qos
                t.stackSize = stackMB << 20
                t.name = "keel.bench.\(i)"
                t.start()
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                let secs = Double((box.ends.max() ?? 0) - (box.starts.min() ?? 0)) / 1e9
                cont.resume(returning: (box.values.map { $0! }, max(secs, 1e-9)))
            }
        }
    }

    static func one<T>(qos: QualityOfService = .userInteractive, _ body: @escaping @Sendable () -> T) async -> T {
        await run(1, qos: qos) { _ in body() }.values[0]
    }
}

/// Process runner with cancellation (kills the child) and per-line output, used for ping and networkQuality.
enum BenchProcess {
    struct Output: Sendable { let status: Int32; let stdout: String; let stderr: String; let timedOut: Bool }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data()
        var outClosed = false, errClosed = false, exited = false, finished = false, timedOut = false
        var status: Int32 = 0
        var process: Process?
        var cont: CheckedContinuation<Output?, Never>?
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> Output? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let st = State()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Output?, Never>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                st.lock.lock(); st.process = p; st.cont = cont; st.lock.unlock()

                func finishIfDone(force: Bool = false) {
                    st.lock.lock()
                    guard !st.finished, force || (st.exited && st.outClosed && st.errClosed) else { st.lock.unlock(); return }
                    st.finished = true
                    let r = Output(status: st.status, stdout: String(decoding: st.out, as: UTF8.self), stderr: String(decoding: st.err, as: UTF8.self), timedOut: st.timedOut)
                    let c = st.cont; st.cont = nil
                    st.lock.unlock()
                    c?.resume(returning: r)
                }
                out.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    st.lock.lock(); if d.isEmpty { st.outClosed = true; h.readabilityHandler = nil } else { st.out.append(d) }; st.lock.unlock()
                    if d.isEmpty { finishIfDone() }
                }
                err.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    st.lock.lock(); if d.isEmpty { st.errClosed = true; h.readabilityHandler = nil } else { st.err.append(d) }; st.lock.unlock()
                    if d.isEmpty { finishIfDone() }
                }
                p.terminationHandler = { proc in
                    st.lock.lock(); st.exited = true; st.status = proc.terminationStatus; st.lock.unlock()
                    finishIfDone()
                    // Pipes normally close right after exit; never wait on them for long.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finishIfDone(force: true) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    st.lock.lock(); let running = !st.finished && (st.process?.isRunning ?? false); if running { st.timedOut = true }; st.lock.unlock()
                    if running { p.terminate() }
                }
                if Task.isCancelled {
                    st.lock.lock(); st.finished = true; st.cont = nil; st.lock.unlock()
                    out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: nil)
                    return
                }
                do { try p.run() } catch {
                    st.lock.lock(); let already = st.finished; st.finished = true; let c = st.cont; st.cont = nil; st.lock.unlock()
                    out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
                    if !already { c?.resume(returning: nil) }
                }
            }
        } onCancel: {
            st.lock.lock(); let p = st.process; st.lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }
}
