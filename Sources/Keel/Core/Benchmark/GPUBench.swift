import Foundation
import Metal

/// GPU compute through Metal. Shaders are compiled from source at run time (no metallib in the bundle),
/// and every dispatch is timed with the command buffer's GPU start/end timestamps, not the CPU clock.
enum GPUBench {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // 8 independent float4 FMA chains per thread: enough instruction-level parallelism to fill the ALUs.
    kernel void keel_fma(device float4 *out [[buffer(0)]], constant uint &iters [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
        float4 a = float4(float(gid & 1023) * 1e-4f);
        float4 b = a + 0.1f, c = a + 0.2f, d = a + 0.3f, e = a + 0.4f, f = a + 0.5f, g = a + 0.6f, h = a + 0.7f;
        const float4 m = float4(0.9999f), k = float4(0.0001f);
        for (uint i = 0; i < iters; i++) {
            a = fma(a, m, k); b = fma(b, m, k); c = fma(c, m, k); d = fma(d, m, k);
            e = fma(e, m, k); f = fma(f, m, k); g = fma(g, m, k); h = fma(h, m, k);
        }
        out[gid] = a + b + c + d + e + f + g + h;
    }

    kernel void keel_copy(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]], uint gid [[thread_position_in_grid]]) {
        dst[gid] = src[gid];
    }
    """

    struct Result: Sendable { let gflops: [Double]; let bandwidth: [Double]; let device: String; let bufferMiB: Int; let iters: Int }

    enum GPUError: Error, LocalizedError {
        case noDevice, compile(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .noDevice: return "No Metal device"
            case .compile(let s): return "Shader compile failed: \(s)"
            case .failed(let s): return s
            }
        }
    }

    /// Runs both kernels. `wantCompute`/`wantBandwidth` skip the other half.
    static func run(wantCompute: Bool, wantBandwidth: Bool, cancel: CancelFlag) async throws -> Result {
        let r: Result? = try await withCheckedThrowingContinuation { cont in
            let t = Thread {
                do { cont.resume(returning: try runSync(wantCompute: wantCompute, wantBandwidth: wantBandwidth, cancel: cancel)) }
                catch { cont.resume(throwing: error) }
            }
            t.qualityOfService = .userInitiated
            t.start()
        }
        guard let r else { throw BenchCancelled() }
        return r
    }

    private static func time(_ cb: MTLCommandBuffer) throws -> Double {
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw GPUError.failed(e.localizedDescription) }
        let s = cb.gpuEndTime - cb.gpuStartTime
        return s > 0 ? s : 1e-9
    }

    private static func runSync(wantCompute: Bool, wantBandwidth: Bool, cancel: CancelFlag) throws -> Result? {
        guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { throw GPUError.noDevice }
        let lib: MTLLibrary
        do { lib = try dev.makeLibrary(source: source, options: nil) } catch { throw GPUError.compile(error.localizedDescription) }
        guard let fmaFn = lib.makeFunction(name: "keel_fma"), let copyFn = lib.makeFunction(name: "keel_copy") else { throw GPUError.compile("missing function") }
        let fmaPSO = try dev.makeComputePipelineState(function: fmaFn)
        let copyPSO = try dev.makeComputePipelineState(function: copyFn)

        var gflops: [Double] = [], bw: [Double] = []
        var iters: UInt32 = 256
        var bufMiB = 0

        if wantCompute {
            let threads = 1 << 20
            guard let out = dev.makeBuffer(length: threads * 16, options: .storageModePrivate) else { throw GPUError.failed("buffer allocation failed") }
            func dispatch(_ n: UInt32) throws -> Double {
                guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw GPUError.failed("encoder") }
                var it = n
                enc.setComputePipelineState(fmaPSO)
                enc.setBuffer(out, offset: 0, index: 0)
                enc.setBytes(&it, length: 4, index: 1)
                let tg = min(fmaPSO.maxTotalThreadsPerThreadgroup, 256)
                enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
                enc.endEncoding()
                return try time(cb)
            }
            _ = try dispatch(iters)                                  // warm-up: pipeline + clocks
            // Calibrate to ~150 ms per dispatch (well under the GPU watchdog).
            let t = try dispatch(iters)
            iters = UInt32(max(256.0, min(65536.0, Double(iters) * 0.15 / t)))
            // Two full-length untimed dispatches so the GPU reaches its sustained clock before sampling.
            for _ in 0..<2 { if cancel.isCancelled { return nil }; _ = try dispatch(iters) }
            for _ in 0..<3 {
                if cancel.isCancelled { return nil }
                let s = try dispatch(iters)
                gflops.append(Double(threads) * Double(iters) * 64 / s / 1e9)   // 8 chains × 4 lanes × 2 FLOPs
            }
        }

        if wantBandwidth {
            // Large enough to defeat the system-level cache, small enough for an 8 GB Mac.
            let ws = Int(dev.recommendedMaxWorkingSetSize)
            var bytes = min(512 << 20, max(64 << 20, ws / 8))
            bytes -= bytes % (1 << 20)
            bufMiB = bytes >> 20
            guard let a = dev.makeBuffer(length: bytes, options: .storageModePrivate),
                  let b = dev.makeBuffer(length: bytes, options: .storageModePrivate) else { throw GPUError.failed("buffer allocation failed") }
            if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                blit.fill(buffer: a, range: 0..<bytes, value: 1); blit.fill(buffer: b, range: 0..<bytes, value: 2); blit.endEncoding()
                _ = try time(cb)
            }
            let n = bytes / 16, reps = 4
            func dispatch() throws -> Double {
                guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw GPUError.failed("encoder") }
                enc.setComputePipelineState(copyPSO)
                let tg = min(copyPSO.maxTotalThreadsPerThreadgroup, 256)
                for r in 0..<reps {
                    enc.setBuffer(r % 2 == 0 ? a : b, offset: 0, index: 0)
                    enc.setBuffer(r % 2 == 0 ? b : a, offset: 0, index: 1)
                    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
                }
                enc.endEncoding()
                return try time(cb)
            }
            _ = try dispatch()
            for _ in 0..<3 {
                if cancel.isCancelled { return nil }
                let s = try dispatch()
                bw.append(Double(bytes) * 2 * Double(reps) / s / 1e9)
            }
        }
        return Result(gflops: gflops, bandwidth: bw, device: dev.name, bufferMiB: bufMiB, iters: Int(iters))
    }
}
