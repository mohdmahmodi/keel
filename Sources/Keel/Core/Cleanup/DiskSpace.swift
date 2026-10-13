import Foundation

/// Free space and local snapshots of the Data volume. All reads are unprivileged and never prompt.
enum DiskSpace {
    static let dataVolume = "/System/Volumes/Data"

    static func read() -> VolumeSpace {
        for path in [dataVolume, "/"] {
            let url = URL(fileURLWithPath: path)
            if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
               let free = v.volumeAvailableCapacity {
                let important = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? UInt64(free)
                return VolumeSpace(free: UInt64(free), important: max(important, UInt64(free)), total: UInt64(v.volumeTotalCapacity ?? 0))
            }
        }
        return VolumeSpace()
    }

    /// Snapshots on the Data volume: `diskutil apfs listSnapshots` (all snapshots, any app) merged with
    /// `tmutil listlocalsnapshots /` (Time Machine). Both run without root.
    static func localSnapshots() async -> [LocalSnapshot] {
        async let du = Shell.run("/usr/sbin/diskutil", ["apfs", "listSnapshots", "-plist", dataVolume], timeout: 20)
        async let tm = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 20)
        var names: [String] = []
        if let r = try? await du, r.ok, let data = r.stdout.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let list = plist["Snapshots"] as? [[String: Any]] {
            names += list.compactMap { $0["SnapshotName"] as? String }
        }
        if let r = try? await tm, r.ok {
            for line in r.stdout.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("com.apple.") && !names.contains(t) { names.append(t) }
            }
        }
        return names.filter { !$0.isEmpty }.map { LocalSnapshot(name: $0) }
    }
}
