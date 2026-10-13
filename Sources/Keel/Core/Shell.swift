import Foundation

struct ShellResult: Sendable {
    let command: String
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
    var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    var combined: String { (stdout + (stderr.isEmpty ? "" : "\n" + stderr)).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum ShellError: Error, LocalizedError {
    case timeout(String)
    case launch(String, String)
    var errorDescription: String? {
        switch self {
        case .timeout(let c): return "Timed out: \(c)"
        case .launch(let c, let e): return "Could not launch \(c): \(e)"
        }
    }
}

/// Unprivileged process runner. Never blocks a thread (readability and termination handlers), so many
/// concurrent detections cannot starve the cooperative pool.
enum Shell {
    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data()
        var finished = false
        var outClosed = false, errClosed = false, exited = false
        var status: Int32 = 0
    }

    @discardableResult
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 60, env: [String: String]? = nil) async throws -> ShellResult {
        let display = ([path] + args).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            if let env { for (k, v) in env { environment[k] = v } }
            p.environment = environment
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let c = Collector()
            let timer = DispatchSource.makeTimerSource(queue: .global())

            func finishIfDone() {
                c.lock.lock()
                guard !c.finished, c.exited, c.outClosed, c.errClosed else { c.lock.unlock(); return }
                c.finished = true
                let r = ShellResult(command: display, status: c.status, stdout: String(decoding: c.out, as: UTF8.self), stderr: String(decoding: c.err, as: UTF8.self))
                c.lock.unlock()
                timer.cancel()
                cont.resume(returning: r)
            }
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                c.lock.lock()
                if d.isEmpty { c.outClosed = true; h.readabilityHandler = nil } else { c.out.append(d) }
                c.lock.unlock()
                if d.isEmpty { finishIfDone() }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                c.lock.lock()
                if d.isEmpty { c.errClosed = true; h.readabilityHandler = nil } else { c.err.append(d) }
                c.lock.unlock()
                if d.isEmpty { finishIfDone() }
            }
            p.terminationHandler = { proc in
                c.lock.lock(); c.exited = true; c.status = proc.terminationStatus; c.lock.unlock()
                finishIfDone()
            }
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                c.lock.lock()
                let already = c.finished
                if !already { c.finished = true }
                c.lock.unlock()
                if already { return }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if p.isRunning { p.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } } }
                cont.resume(throwing: ShellError.timeout(display))
            }
            timer.resume()
            do { try p.run() } catch {
                c.lock.lock(); let already = c.finished; c.finished = true; c.lock.unlock()
                timer.cancel()
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if !already { cont.resume(throwing: ShellError.launch(display, error.localizedDescription)) }
            }
        }
    }

    /// Runs through /bin/zsh -c. Use for pipelines only.
    @discardableResult
    static func zsh(_ script: String, timeout: TimeInterval = 60) async throws -> ShellResult {
        let r = try await run("/bin/zsh", ["-c", script], timeout: timeout)
        return ShellResult(command: script, status: r.status, stdout: r.stdout, stderr: r.stderr)
    }

    /// nil when the key is not set.
    static func defaultsRead(_ domain: String, _ key: String, currentHost: Bool = false) async -> String? {
        var args = currentHost ? ["-currentHost"] : []
        args += ["read", domain, key]
        guard let r = try? await run("/usr/bin/defaults", args, timeout: 20), r.ok else { return nil }
        return r.output
    }

    static func sysctl(_ name: String) async -> String? {
        guard let r = try? await run("/usr/sbin/sysctl", ["-n", name], timeout: 10), r.ok else { return nil }
        return r.output
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) }
    static func home() -> String { NSHomeDirectory() }
    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
}

func shq(_ s: String) -> String {
    if s.isEmpty { return "''" }
    if s.range(of: "^[A-Za-z0-9_./:=+@%,-]+$", options: .regularExpression) != nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
