import Foundation

enum CleanupGroup: String, CaseIterable, Identifiable, Sendable {
    case developer = "Xcode and simulators"
    case packages = "Package managers"
    case apps = "App caches"
    case system = "System"
    case protected = "Protected (list only)"
    case largeFiles = "Large files (list only)"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .developer: return "hammer"
        case .packages: return "shippingbox"
        case .apps: return "square.stack.3d.up"
        case .system: return "gearshape"
        case .protected: return "lock"
        case .largeFiles: return "doc"
        }
    }
    /// Nothing in these groups is ever deleted by Keel.
    var isListOnly: Bool { self == .protected || self == .largeFiles }
}

/// One process Keel runs, without a shell. Shown verbatim.
struct CleanupCommand: Sendable, Hashable {
    let executable: String
    let args: [String]
    /// Extra environment (e.g. PATH so `npm` finds the `node` next to it).
    var env: [String: String] = [:]
    var display: String { ([executable] + args).map(shq).joined(separator: " ") }
}

/// One concrete step of a cleanup. Every step is shown to the user before it runs.
enum CleanupAction: Sendable {
    case run(CleanupCommand)
    /// Delete what is inside the folder, keep the folder (apps expect it to exist). Names in `except` are kept.
    case removeContents(String, except: [String])
    case removePath(String)
    /// Move to the Trash with NSWorkspace.recycle (recoverable).
    case moveToTrash(String)
    case emptyTrashViaFinder

    var preview: String {
        switch self {
        case .run(let c): return c.display
        case .removeContents(let p, let except):
            return "rm -rf \(shq(p))/*" + (except.isEmpty ? "" : "   (keeps \(except.joined(separator: ", ")))")
        case .removePath(let p): return "rm -rf \(shq(p))"
        case .moveToTrash(let p): return "move to Trash: \(shq(p))"
        case .emptyTrashViaFinder: return "osascript -e 'tell application \"Finder\" to empty trash'"
        }
    }
}

enum CleanupKind: Sendable, Equatable {
    case clean
    /// Measured and shown; Keel never deletes it.
    case listOnly
    /// Cannot be read without Full Disk Access; the string says why it matters.
    case needsFullDiskAccess(String)
}

/// How a size was obtained. Shown in the UI so nobody mistakes an estimate for a measurement.
enum SizeKind: Sendable, Equatable {
    /// `du` of the paths (allocated blocks).
    case measured
    /// Upper bound: the tool may keep part of it (e.g. `dart pub cache gc`), or snapshots.
    case upTo
    /// Reported by the owning tool (simctl sizeBytes, brew --dry-run).
    case reported
    /// Logical file size from Spotlight (sparse files look larger than they are).
    case logical

    var prefix: String { self == .upTo ? "≤ " : "" }
}

enum Measure: Sendable {
    case du
    /// Size was set by the catalog.
    case preset
    case none
    case custom(@Sendable () async -> UInt64?)
}

/// An app (or background process) that must not be running while its cache is deleted.
struct OwningApp: Sendable, Hashable {
    let name: String
    var bundleIDs: [String] = []
    var bundlePrefixes: [String] = []
    /// `pgrep -f` pattern for processes without a bundle (Gradle daemon).
    var processPattern: String? = nil
}

struct CleanupItem: Identifiable, Sendable {
    let id: String
    var name: String
    var group: CleanupGroup
    /// One line.
    var summary: String
    /// Drawer text.
    var explanation: String
    /// Measured and shown in the drawer.
    var paths: [String] = []
    var actions: [CleanupAction] = []
    var kind: CleanupKind = .clean
    var risk: Risk = .safe
    var defaultOn: Bool = false
    /// What it costs to get back.
    var rebuildCost: String = "—"
    var sizeBytes: UInt64? = nil
    var sizeKind: SizeKind = .measured
    var measure: Measure = .du
    /// Extra identifier shown in the drawer (UUID, build).
    var detail: String? = nil
    /// Child rows (one per DeviceSupport folder, runtime, simulator, cache folder…).
    var children: [CleanupItem] = []
    var owner: OwningApp? = nil
    /// Shown in the drawer and the confirmation sheet.
    var warnings: [String] = []
    /// `du` hit permission errors: the size is a lower bound.
    var unreadable: Bool = false
    /// When set, the cleanup verifies that this simulator runtime image (UUID) is gone afterwards.
    var verifyRuntimeGone: String? = nil
    /// Runtime identifier (com.apple.CoreSimulator.SimRuntime.…) of a runtime row, remembered after deletion.
    var simRuntimeID: String? = nil
    /// Size shown came from the previous launch's cache and is being re-measured.
    var sizeFromCache: Bool = false

    var isParent: Bool { !children.isEmpty }
    var requiresAppClosed: String? { owner?.name }

    var deletable: Bool {
        if isParent { return children.contains { $0.deletable } }
        return kind == .clean && !actions.isEmpty && !group.isListOnly
    }

    var commandsPreview: [String] {
        switch kind {
        case .listOnly: return ["(list only: Keel never deletes this)"]
        case .needsFullDiskAccess(let why): return ["(needs Full Disk Access to \(why))"]
        case .clean:
            if isParent { return children.filter(\.deletable).prefix(12).flatMap(\.commandsPreview) }
            return actions.map(\.preview)
        }
    }

    /// Every leaf (self when there are no children).
    var leaves: [CleanupItem] { isParent ? children : [self] }

    var sizeLabel: String? { sizeBytes.map { sizeKind.prefix + $0.humanBytes } }
}

extension CleanupItem {
    /// Convenience for the common "delete the contents of these folders" item.
    static func folders(id: String, name: String, group: CleanupGroup, summary: String, explanation: String,
                        paths: [String], risk: Risk = .safe, defaultOn: Bool = true, rebuildCost: String,
                        owner: OwningApp? = nil, keep: [String] = []) -> CleanupItem {
        CleanupItem(id: id, name: name, group: group, summary: summary, explanation: explanation,
                    paths: paths, actions: paths.map { .removeContents($0, except: keep) },
                    risk: risk, defaultOn: defaultOn, rebuildCost: rebuildCost, owner: owner)
    }

    /// A measured, never-deleted row.
    static func listOnly(id: String, name: String, group: CleanupGroup = .protected, summary: String, explanation: String,
                         paths: [String], risk: Risk = .medium, rebuildCost: String = "Cannot be recreated by Keel") -> CleanupItem {
        CleanupItem(id: id, name: name, group: group, summary: summary, explanation: explanation,
                    paths: paths, kind: .listOnly, risk: risk, defaultOn: false, rebuildCost: rebuildCost)
    }
}

/// Free space as macOS reports it, split into what is really free and what is only purgeable.
struct VolumeSpace: Sendable, Equatable {
    /// Unconditionally free blocks (`df`, `volumeAvailableCapacityKey`).
    var free: UInt64 = 0
    /// Free + purgeable (Finder's "available", `volumeAvailableCapacityForImportantUsageKey`).
    var important: UInt64 = 0
    var total: UInt64 = 0
    var purgeable: UInt64 { important > free ? important - free : 0 }
}

struct LocalSnapshot: Sendable, Hashable, Identifiable {
    let name: String
    var id: String { name }
    /// `YYYY-MM-DD-HHMMSS` for Time Machine snapshots (what `tmutil deletelocalsnapshots` takes).
    var tmDate: String? {
        guard name.hasPrefix("com.apple.TimeMachine.") else { return nil }
        let d = name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: "")
        return d.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$", options: .regularExpression) != nil ? d : nil
    }
    var isTimeMachine: Bool { tmDate != nil }
    var isSystemUpdate: Bool { name.hasPrefix("com.apple.os.update") }
}

/// Per-item progress while cleaning.
enum CleanStepState: Sendable, Equatable {
    case pending
    case running
    /// Bytes measured gone (before − after), plus whether that was measured or reported by the tool.
    case done(UInt64, measured: Bool)
    case skipped(String)
    case failed(String)
}

struct CleanStep: Identifiable, Sendable {
    let id: String
    let name: String
    var state: CleanStepState = .pending
    var note: String? = nil
}

/// What a cleanup run actually achieved. Deleted bytes and free-space change are reported separately
/// because local snapshots can keep deleted blocks allocated.
struct CleanSummary: Sendable {
    var date = Date()
    var steps: [CleanStep] = []
    var deletedMeasured: UInt64 = 0
    var deletedReported: UInt64 = 0
    /// Moved to the Trash: space returns only when the Trash is emptied.
    var movedToTrash: UInt64 = 0
    var before = VolumeSpace()
    var after = VolumeSpace()
    var snapshotCount = 0
    var deleted: UInt64 { deletedMeasured + deletedReported }
    var freeDelta: Int64 { Int64(after.free) - Int64(before.free) }
    var importantDelta: Int64 { Int64(after.important) - Int64(before.important) }
    /// Deleted bytes that did not show up as free space: almost always held by snapshots.
    var heldBack: UInt64 { deleted > UInt64(max(0, freeDelta)) ? deleted - UInt64(max(0, freeDelta)) : 0 }
}

extension Int64 {
    var signedHumanBytes: String { (self < 0 ? "−" : "+") + UInt64(abs(self)).humanBytes }
}
