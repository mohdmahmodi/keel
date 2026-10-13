import Foundation

/// Runs selected items one by one. Deleted bytes (`du` before and after) and the free-space change are
/// reported separately, because local snapshots can keep deleted blocks allocated.
@MainActor
enum CleanupRunner {
    struct Hooks {
        var isBlocked: (OwningApp) async -> Bool
        var readSpace: () -> VolumeSpace
        var snapshotCount: () async -> Int
        /// APFS releases blocks asynchronously; wait this long before reading free space again.
        var settleNanoseconds: UInt64
        /// Simulator runtime checks need Xcode; the self-test turns them off.
        var verifyRuntimes: Bool

        static let live = Hooks(isBlocked: { await AppControl.isRunning($0) },
                                readSpace: { DiskSpace.read() },
                                snapshotCount: { await DiskSpace.localSnapshots().count },
                                settleNanoseconds: 1_000_000_000, verifyRuntimes: true)
    }

    static func run(_ targets: [CleanupItem], hooks: Hooks, update: (Int, CleanStep) -> Void) async -> CleanSummary {
        var s = CleanSummary()
        var steps = targets.map { CleanStep(id: $0.id, name: $0.name) }
        s.before = hooks.readSpace()
        s.snapshotCount = await hooks.snapshotCount()

        for (i, t) in targets.enumerated() {
            steps[i].state = .running
            update(i, steps[i])
            if let o = t.owner, await hooks.isBlocked(o) {
                steps[i].state = .skipped("Quit \(o.name) first")
                update(i, steps[i])
                ActivityLog.shared.warning("Skipped “\(t.name)” because \(o.name) is open")
                continue
            }
            let before: CleanupScanner.DUResult? = isDuMeasured(t) ? await CleanupScanner.du(t.paths) : nil
            do {
                try await CleanupScanner.clean(t)
                var bytes: UInt64, measured: Bool
                if let b = before, !b.unreadable {
                    let after: CleanupScanner.DUResult = await CleanupScanner.du(t.paths)
                    bytes = b.bytes > after.bytes ? b.bytes - after.bytes : 0
                    measured = true
                } else {
                    bytes = t.sizeBytes ?? 0
                    measured = false
                }
                if movesToTrash(t) { s.movedToTrash += bytes }
                else if measured { s.deletedMeasured += bytes } else { s.deletedReported += bytes }
                if let rt = t.simRuntimeID { DeletedRuntimes.record(rt) }
                if hooks.verifyRuntimes, let rid = t.verifyRuntimeGone, let inv = await SimInventory.load(), inv.images.contains(where: { $0.identifier == rid }) {
                    steps[i].note = "simctl still lists this runtime. Delete it in Xcode › Settings › Components."
                    ActivityLog.shared.warning("“\(t.name)” is still listed after simctl runtime delete",
                                               detail: "Xcode can leave the runtime's asset behind. Delete it in Xcode › Settings › Components.")
                }
                steps[i].state = .done(bytes, measured: measured)
                let how = movesToTrash(t) ? "moved to the Trash" : (measured ? "measured" : "as reported by the tool")
                ActivityLog.shared.success("Cleaned “\(t.name)”: \(bytes.humanBytes) \(how)")
            } catch {
                steps[i].state = .failed(error.localizedDescription)
                ActivityLog.shared.error("Could not clean “\(t.name)”", detail: error.localizedDescription)
            }
            update(i, steps[i])
        }

        if hooks.settleNanoseconds > 0 { try? await Task.sleep(nanoseconds: hooks.settleNanoseconds) }
        s.after = hooks.readSpace()
        s.steps = steps
        return s
    }

    static func logLine(_ s: CleanSummary) -> String {
        var line = "Cleanup finished: deleted \(s.deleted.humanBytes)"
        if s.deletedReported > 0 { line += " (\(s.deletedMeasured.humanBytes) measured, \(s.deletedReported.humanBytes) reported by tools)" }
        if s.movedToTrash > 0 { line += ", moved \(s.movedToTrash.humanBytes) to the Trash" }
        line += ". Free space \(s.before.free.humanBytes) → \(s.after.free.humanBytes) (\(s.freeDelta.signedHumanBytes))."
        if s.heldBack > 268_435_456 {
            line += s.snapshotCount > 0
                ? " \(s.heldBack.humanBytes) is still held by \(s.snapshotCount) local snapshot\(s.snapshotCount == 1 ? "" : "s") and returns when they are deleted."
                : " \(s.heldBack.humanBytes) has not shown up as free space yet (purgeable now \(s.after.purgeable.humanBytes))."
        }
        return line
    }

    static func isDuMeasured(_ t: CleanupItem) -> Bool {
        guard !t.paths.isEmpty, t.sizeKind != .reported, t.sizeKind != .logical else { return false }
        if case .du = t.measure { return true }
        return false
    }

    static func movesToTrash(_ t: CleanupItem) -> Bool {
        t.actions.contains { if case .moveToTrash = $0 { return true }; return false }
    }
}
