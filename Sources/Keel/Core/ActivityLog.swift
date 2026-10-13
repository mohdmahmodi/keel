import Foundation
import Observation

enum LogLevel: String, Codable, CaseIterable, Sendable {
    case info, success, warning, error, command
    var label: String {
        switch self {
        case .info: return "INFO"
        case .success: return "OK"
        case .warning: return "WARN"
        case .error: return "FAIL"
        case .command: return "CMD"
        }
    }
}

struct LogEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let message: String
    let detail: String?
    init(level: LogLevel, message: String, detail: String? = nil) {
        id = UUID(); date = Date(); self.level = level; self.message = message; self.detail = detail
    }
}

/// Append-only activity log, stored as JSON lines.
@MainActor @Observable
final class ActivityLog {
    static let shared = ActivityLog()
    private(set) var entries: [LogEntry] = []
    private let url: URL
    private static let writer = DispatchQueue(label: "keel.activitylog", qos: .utility)
    /// Sandboxed self-tests must not write to the real log.
    nonisolated static let isTestRun = ProcessInfo.processInfo.environment["KEEL_CLEANUP_TEST_HOME"] != nil

    init() {
        url = AppPaths.support.appendingPathComponent("activity.jsonl")
        let url = self.url
        Self.writer.async {
            let old = Self.readTail(url)
            Task { @MainActor in ActivityLog.shared.entries = old + ActivityLog.shared.entries }
        }
    }

    func log(_ level: LogLevel, _ message: String, detail: String? = nil) {
        let e = LogEntry(level: level, message: message, detail: detail)
        entries.append(e)
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
        let url = self.url
        if Self.isTestRun { return }
        Self.writer.async {
            guard let data = try? JSONEncoder().encode(e), let line = String(data: data, encoding: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close()
            } else {
                try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        if CommandLine.arguments.contains("--verbose") { FileHandle.standardError.write("[\(level.label)] \(message)\n".data(using: .utf8)!) }
    }
    func info(_ m: String, detail: String? = nil) { log(.info, m, detail: detail) }
    func success(_ m: String, detail: String? = nil) { log(.success, m, detail: detail) }
    func warning(_ m: String, detail: String? = nil) { log(.warning, m, detail: detail) }
    func error(_ m: String, detail: String? = nil) { log(.error, m, detail: detail) }
    func command(_ m: String, detail: String? = nil) { log(.command, m, detail: detail) }

    var last: LogEntry? { entries.last }

    func clear() {
        entries.removeAll()
        let url = self.url
        Self.writer.async { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated static func post(_ level: LogLevel, _ message: String, detail: String? = nil) {
        Task { @MainActor in ActivityLog.shared.log(level, message, detail: detail) }
    }

    /// Reads the last ~500 KB of the log (off the main thread); trims the file when it passes 2 MB.
    nonisolated private static func readTail(_ url: URL) -> [LogEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 512_000 ? size - 512_000 : 0
        try? h.seek(toOffset: start)
        let data = h.readDataToEndOfFile(); try? h.close()
        if size > 2_000_000 { try? data.write(to: url, options: .atomic) }
        let dec = JSONDecoder()
        return Array(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? dec.decode(LogEntry.self, from: Data($0.utf8)) }.suffix(2000))
    }
}

enum AppPaths {
    static let appName = "Keel"
    static let support: URL = make(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(appName))
    static let backups: URL = make(support.appendingPathComponent("backups"))
    static let benchmarks: URL = make(support.appendingPathComponent("benchmarks"))
    private static func make(_ u: URL) -> URL { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }
}
