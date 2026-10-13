import Foundation
import Darwin

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func int64(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == 8 { var v: Int64 = 0; guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }; return v }
        if size == 4 { var v: Int32 = 0; guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }; return Int64(v) }
        return nil
    }
    static func int(_ name: String) -> Int? { int64(name).map(Int.init) }
}

enum NetIf {
    /// True when the interface exists and has IFF_UP set.
    static func isUp(_ name: String) -> Bool? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: Bool? = nil
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            if String(cString: a.pointee.ifa_name) == name { found = (Int32(a.pointee.ifa_flags) & IFF_UP) != 0; break }
            p = a.pointee.ifa_next
        }
        return found
    }
}

/// Briefly caches read-only commands so a detection pass runs each distinct command once.
actor ProbeCache {
    static let shared = ProbeCache()
    private var done: [String: (Date, ShellResult)] = [:]
    private var inflight: [String: Task<ShellResult?, Never>] = [:]

    func result(_ path: String, _ args: [String], ttl: TimeInterval) async -> ShellResult? {
        let key = ([path] + args).joined(separator: "\u{1}")
        if let (t, r) = done[key], Date().timeIntervalSince(t) < ttl { return r }
        if let task = inflight[key] { return await task.value }
        let task = Task<ShellResult?, Never> { try? await Shell.run(path, args, timeout: 30) }
        inflight[key] = task
        let r = await task.value
        inflight[key] = nil
        if let r { done[key] = (Date(), r) }
        return r
    }

    func invalidate() { done.removeAll() }
}

extension Shell {
    static func probe(_ path: String, _ args: [String] = [], ttl: TimeInterval = 4) async -> ShellResult? {
        await ProbeCache.shared.result(path, args, ttl: ttl)
    }
}
