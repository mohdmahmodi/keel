import SwiftUI
import Observation

/// A change waiting for confirmation.
struct PendingChange: Identifiable {
    let id = UUID()
    let tweaks: [Tweak]
    let on: Bool
    let title: String
}

/// The switch position a card shows before the engine has finished (or while the confirmation is open).
/// One object per tweak, so setting it re-renders one card.
@MainActor @Observable
final class CardIntent {
    var target: Bool? = nil
    /// Set once the engine picked the tweak up, so the card can drop the intent when it finishes.
    var started = false
    func clear() { target = nil; started = false }
}

/// Every on/off request goes through here. Owns the confirmation sheet and closes it before work starts.
@MainActor @Observable
final class ChangeCenter {
    static let shared = ChangeCenter()
    var pending: PendingChange? = nil

    @ObservationIgnored private var intents: [String: CardIntent] = [:]
    @ObservationIgnored private var openedManual: Set<String> = []
    @ObservationIgnored private let store = TweakStore.shared

    func intent(_ id: String) -> CardIntent {
        if let i = intents[id] { return i }
        let i = CardIntent(); intents[id] = i; return i
    }

    /// A switch was flipped. The card shows the new position at once.
    func request(_ t: Tweak, on: Bool) {
        if t.isManual { openManual(t); return }
        intent(t.id).target = on
        if AppSettings.shared.confirmChanges || (on && needsSnapshotOffer) {
            pending = PendingChange(tweaks: [t], on: on, title: on ? "Turn on “\(t.name)”" : "Turn off “\(t.name)”")
        } else {
            run([t], on: on, snapshot: false)
        }
    }

    /// Several tweaks at once (recommended, a category, restore everything). Always confirmed.
    func requestBatch(_ tweaks: [Tweak], on: Bool, title: String) {
        guard !tweaks.isEmpty else { return }
        pending = PendingChange(tweaks: tweaks, on: on, title: title)
    }

    /// Apply was pressed: the sheet closes first, then the work runs in the background.
    func confirm(_ p: PendingChange, selected: [Tweak], snapshot: Bool) {
        pending = nil
        let ids = Set(selected.map(\.id))
        for t in p.tweaks where !ids.contains(t.id) { intent(t.id).clear() }
        run(selected, on: p.on, snapshot: snapshot)
    }

    func cancel() {
        if let p = pending { for t in p.tweaks { intent(t.id).clear() } }
        pending = nil
    }

    private var needsSnapshotOffer: Bool { AppSettings.shared.snapshotBeforeFirstChange && !AppSettings.shared.snapshotTaken }

    private func run(_ tweaks: [Tweak], on: Bool, snapshot: Bool) {
        guard !tweaks.isEmpty else { return }
        for t in tweaks { intent(t.id).target = on }
        Task { @MainActor in
            if snapshot, await SnapshotHelper.takeLocalSnapshot() { AppSettings.shared.snapshotTaken = true }
            if on { await store.apply(tweaks) } else { await store.revert(tweaks) }
            for t in tweaks { intent(t.id).clear() }
        }
    }

    /// Manual tweaks: open the System Settings pane and re-check when Keel comes back to the front.
    func openManual(_ t: Tweak) {
        guard case .manual(let m) = t.mechanism else { return }
        if let u = URL(string: m.settingsURL), !m.settingsURL.isEmpty { NSWorkspace.shared.open(u) }
        ActivityLog.shared.info("Opened settings for “\(t.name)”", detail: m.instructions)
        openedManual.insert(t.id)
    }

    /// Called when the app becomes active again.
    func recheckManual() {
        guard !openedManual.isEmpty else { return }
        let ids = Array(openedManual)
        openedManual.removeAll()
        Task { await store.redetect(ids) }
    }

    /// Tweaks with a recorded original, i.e. everything Keel has changed and can put back.
    func changedByKeel() async -> [Tweak] {
        let ids = await Task.detached(priority: .userInitiated) { Set(BackupStore.all().map(\.tweakID)) }.value
        return store.items.filter { ids.contains($0.id) && !$0.tweak.isManual && $0.state != .notApplicable }.map(\.tweak)
    }
}
