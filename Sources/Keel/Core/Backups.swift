import Foundation

/// A tweak's state before Keel changed it. Revert restores this, never a guessed default.
struct BackupRecord: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case defaults, pmset, sysctl, file, plistMoved, text }
    var id: String { "\(tweakID)-\(date.timeIntervalSince1970)" }
    let tweakID: String
    let date: Date
    let kind: Kind
    /// Key/value pairs describing the original (domain, key, existed, value, path…).
    let original: [String: String]
    /// Backup file names inside the backups directory, comma separated.
    let fileName: String?
}

/// In-memory index of recorded originals, persisted on a background queue.
enum BackupStore {
    private static let queue = DispatchQueue(label: "keel.backups")
    nonisolated(unsafe) private static var cache: [BackupRecord]? = nil
    private static let lock = NSLock()
    private static var indexURL: URL { AppPaths.backups.appendingPathComponent("index.json") }

    static func all() -> [BackupRecord] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let list = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([BackupRecord].self, from: $0) } ?? []
        cache = list
        return list
    }

    static func latest(for tweakID: String) -> BackupRecord? {
        all().filter { $0.tweakID == tweakID }.max { $0.date < $1.date }
    }

    /// Replaces older records for the same tweak; the newest original is the one to restore.
    static func save(_ r: BackupRecord) { mutate { list in list.removeAll { $0.tweakID == r.tweakID }; list.append(r) } }
    static func remove(_ r: BackupRecord) { mutate { $0.removeAll { $0.id == r.id } } }

    private static func mutate(_ f: (inout [BackupRecord]) -> Void) {
        var list = all()
        f(&list)
        lock.lock(); cache = list; lock.unlock()
        let url = indexURL
        queue.async {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(list) { try? data.write(to: url, options: .atomic) }
        }
    }

    static func copyFile(at path: String, tag: String) throws -> String {
        let name = backupName(for: path, tag: tag)
        try FileManager.default.copyItem(atPath: path, toPath: fileURL(name).path)
        return name
    }
    static func backupName(for path: String, tag: String) -> String {
        "\(tag)-\(Int(Date().timeIntervalSince1970))-\((path as NSString).lastPathComponent)"
    }
    static func fileURL(_ name: String) -> URL { AppPaths.backups.appendingPathComponent(name) }
}
