import Foundation
import Darwin

/// Reading inside protected app-data folders (containers; on macOS 27 any folder marked `com.apple.macl`)
/// raises a privacy prompt, so detection checks metadata first and reads only unprotected folders or with FDA.
enum Permissions {
    nonisolated(unsafe) private static var fdaCache: (Date, Bool)? = nil
    private static let lock = NSLock()

    /// Forgets the cached Full Disk Access answer, so the next check probes again.
    static func recheckFullDiskAccess() { lock.lock(); fdaCache = nil; lock.unlock() }

    /// Full Disk Access, probed by listing a TCC-protected folder (EPERM without FDA; never prompts). Cached 10 s.
    static var hasFullDiskAccess: Bool {
        lock.lock(); defer { lock.unlock() }
        if let (t, v) = fdaCache, Date().timeIntervalSince(t) < 10 { return v }
        let probes = ["\(NSHomeDirectory())/Library/Safari", "\(NSHomeDirectory())/Library/Mail", "/Library/Application Support/com.apple.TCC"]
        var v = false
        for p in probes where FileManager.default.fileExists(atPath: p) {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil { v = true; break }
        }
        fdaCache = (Date(), v)
        return v
    }

    /// True when `path` (or a parent folder inside ~/Library) carries an app-data protection marker
    /// or has extended attributes Keel is not allowed to read.
    static func isProtected(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let lib = home + "/Library/"
        guard path.hasPrefix(lib) else { return false }
        if path.hasPrefix(home + "/Library/Containers/") { return !path.contains("/Keel") }
        var p = (path as NSString).deletingLastPathComponent
        while p.count > lib.count {
            if hasBlockingXattr(p) { return true }
            p = (p as NSString).deletingLastPathComponent
        }
        return FileManager.default.fileExists(atPath: path) && hasBlockingXattr(path)
    }

    static func canRead(_ path: String) -> Bool { hasFullDiskAccess || !isProtected(path) }

    private static func hasBlockingXattr(_ path: String) -> Bool {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if size < 0 { return errno == EPERM || errno == EACCES }
        guard size > 0 else { return false }
        var buf = [CChar](repeating: 0, count: size)
        let n = listxattr(path, &buf, size, XATTR_NOFOLLOW)
        guard n > 0 else { return false }
        let names = buf.split(separator: 0).map { String(cString: Array($0) + [0]) }
        // A protection marker this process cannot read means the folder is closed to Keel.
        for name in names {
            if getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) < 0 && (errno == EPERM || errno == EACCES) { return true }
        }
        return false
    }
}
