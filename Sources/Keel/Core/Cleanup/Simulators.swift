import Foundation

/// Read-only view of CoreSimulator through `xcrun simctl … -j`.
/// `simctl delete unavailable` also removes devices whose runtime is installed but not ready (unmounted, or
/// rebuilding its dyld cache after a macOS update), so devices are classified and deleted by UDID instead.
struct SimInventory: Sendable {
    struct Device: Sendable, Identifiable {
        let udid: String
        let name: String
        let runtimeID: String
        let state: String
        let isAvailable: Bool
        let availabilityError: String?
        let dataPath: String?
        let lastBooted: String?
        var id: String { udid }
        /// The device folder (`…/Devices/<UDID>`), which holds `data` plus the device plist.
        var folder: String? {
            guard let d = dataPath else { return nil }
            return d.hasSuffix("/data") ? String(d.dropLast(5)) : d
        }
    }

    struct Runtime: Sendable {
        let identifier: String     // UUID of the image (what `simctl runtime delete` takes)
        let runtimeID: String      // com.apple.CoreSimulator.SimRuntime.iOS-26-1
        let platform: String       // iOS, watchOS, tvOS, visionOS
        let version: String
        let build: String
        let sizeBytes: UInt64
        let lastUsed: String?      // yyyy-mm-dd
        let deletable: Bool
        let state: String
        var name: String { "\(platform) \(version)" }
    }

    enum UnavailableReason: Sendable, Equatable {
        /// The runtime is not installed any more. The device cannot boot until it is reinstalled.
        case runtimeRemoved
        /// The runtime is installed but not usable right now (not mounted, being updated, needs Xcode first launch).
        case runtimeNotReady(String)
    }

    var devices: [Device] = []
    var images: [Runtime] = []
    /// Runtime identifiers simctl knows (available or not), from `simctl list runtimes`.
    var knownRuntimes: [String: (name: String, available: Bool, error: String?)] = [:]

    var unavailable: [Device] { devices.filter { !$0.isAvailable } }
    var available: [Device] { devices.filter { $0.isAvailable } }

    func reason(_ d: Device) -> UnavailableReason {
        let imageForRuntime = images.first { $0.runtimeID == d.runtimeID }
        if let k = knownRuntimes[d.runtimeID] {
            return .runtimeNotReady(k.error ?? d.availabilityError ?? "runtime \(k.name) is installed but not available")
        }
        if let img = imageForRuntime {
            return .runtimeNotReady(d.availabilityError ?? "runtime image is \(img.state.lowercased())")
        }
        return .runtimeRemoved
    }

    func devices(onRuntime runtimeID: String) -> [Device] { devices.filter { $0.runtimeID == runtimeID } }

    static func runtimeName(_ runtimeID: String) -> String {
        // com.apple.CoreSimulator.SimRuntime.iOS-26-1 → iOS 26.1
        let tail = runtimeID.components(separatedBy: ".").last ?? runtimeID
        var parts = tail.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return tail }
        let platform = parts.removeFirst()
        return "\(platform) \(parts.joined(separator: "."))"
    }

    /// Loads everything with three read-only simctl calls. Returns nil when Xcode is not selected
    /// (calling xcrun without Xcode can trigger the Command Line Tools install prompt).
    static func load() async -> SimInventory? {
        guard await Machine.profile().hasXcode else { return nil }
        async let devs = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 40)
        async let rts = Shell.run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "-j"], timeout: 40)
        async let imgs = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 40)
        var inv = SimInventory()

        if let r = try? await devs, let o = json(r.stdout) as? [String: Any], let map = o["devices"] as? [String: [[String: Any]]] {
            for (rt, list) in map {
                for d in list {
                    guard let udid = d["udid"] as? String else { continue }
                    inv.devices.append(Device(udid: udid, name: d["name"] as? String ?? udid, runtimeID: rt,
                                              state: d["state"] as? String ?? "",
                                              isAvailable: d["isAvailable"] as? Bool ?? true,
                                              availabilityError: d["availabilityError"] as? String,
                                              dataPath: d["dataPath"] as? String,
                                              lastBooted: (d["lastBootedAt"] as? String).map { String($0.prefix(10)) }))
                }
            }
        }
        if let r = try? await rts, let o = json(r.stdout) as? [String: Any], let list = o["runtimes"] as? [[String: Any]] {
            for rt in list {
                guard let id = rt["identifier"] as? String else { continue }
                inv.knownRuntimes[id] = (rt["name"] as? String ?? runtimeName(id), rt["isAvailable"] as? Bool ?? true, rt["availabilityError"] as? String)
            }
        }
        if let r = try? await imgs, let o = json(r.stdout) as? [String: [String: Any]] {
            for (_, v) in o {
                let pid = v["platformIdentifier"] as? String ?? ""
                let platform = pid.contains("iphone") ? "iOS" : pid.contains("appletv") ? "tvOS" : pid.contains("watch") ? "watchOS" : (pid.contains("xr") || pid.contains("vision")) ? "visionOS" : (pid.isEmpty ? "Simulator" : pid)
                inv.images.append(Runtime(identifier: v["identifier"] as? String ?? "",
                                          runtimeID: v["runtimeIdentifier"] as? String ?? "",
                                          platform: platform,
                                          version: v["version"] as? String ?? "",
                                          build: v["build"] as? String ?? "",
                                          sizeBytes: (v["sizeBytes"] as? NSNumber)?.uint64Value ?? 0,
                                          lastUsed: (v["lastUsedAt"] as? String).map { String($0.prefix(10)) },
                                          deletable: v["deletable"] as? Bool ?? true,
                                          state: v["state"] as? String ?? ""))
            }
        }
        inv.images.removeAll { $0.identifier.isEmpty }
        inv.images.sort { ($0.platform, $0.version.versionKey) < ($1.platform, $1.version.versionKey) }
        return inv
    }

    private static func json(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}

extension String {
    /// "26.10.1" → zero-padded string that sorts numerically.
    var versionKey: String {
        split(separator: ".").map { String(repeating: "0", count: max(0, 6 - $0.count)) + $0 }.joined(separator: ".")
    }
}

/// Runtimes Keel deleted recently. Devices orphaned by those deletions are not pre-selected: their data
/// is intact and comes back if the runtime is reinstalled.
enum DeletedRuntimes {
    private static let key = "cleanup.deletedRuntimes"
    static func record(_ runtimeID: String) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        d[runtimeID] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: key)
    }
    /// runtimeID → date deleted, within the last `days` days.
    static func recent(days: Double = 14) -> [String: Date] {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let cutoff = Date().timeIntervalSince1970 - days * 86_400
        return d.filter { $0.value > cutoff }.mapValues { Date(timeIntervalSince1970: $0) }
    }
}
