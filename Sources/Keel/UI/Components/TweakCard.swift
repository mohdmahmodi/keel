import SwiftUI

/// One tweak as a card. Observes only its own `TweakItem` and `CardIntent`, so a change re-renders one card.
struct TweakCard: View, Equatable {
    @Bindable var item: TweakItem
    @Bindable var intent: CardIntent
    var selected = false
    @State private var hover = false
    private func onOpen() { Navigator.shared.selectedTweak = item.id }
    /// Lets SwiftUI skip cards whose inputs did not change (their own state changes still re-render them).
    nonisolated static func == (a: TweakCard, b: TweakCard) -> Bool {
        a.item === b.item && a.intent === b.intent && a.selected == b.selected
    }

    var body: some View {
        let t = item.tweak
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.name).font(Theme.bodyStrong).lineLimit(1).truncationMode(.tail).help(t.name)
                        .foregroundStyle(item.state == .notApplicable ? Color.secondary : Color.primary)
                    Text(subtitle)
                        .font(Theme.small).foregroundStyle(item.failed ? Theme.fail : .secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                CardControl(item: item, intent: intent)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                chips
                Spacer(minLength: 4)
                if t.needsAdmin {
                    Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
                        .help("Needs administrator approval").accessibilityLabel("Needs administrator approval")
                }
                IconButton(symbol: "sidebar.right", label: "Details for \(t.name)", size: 11) { onOpen() }
            }
        }
        .frame(height: 80, alignment: .top)
        .padding(12)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(selected ? Theme.borderStrong : (hover ? Theme.borderStrong.opacity(0.45) : Theme.border), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onHover { hover = $0 }
        .onChange(of: item.isBusy) { _, busy in
            if busy { intent.started = true } else if intent.started { intent.clear() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(t.name), \(item.state.rawValue)")
        .accessibilityAction(named: "Details") { onOpen() }
    }

    private var subtitle: String {
        if item.failed, let m = item.message { return m }
        if item.state == .notApplicable, let n = item.detection?.note { return n }
        return item.tweak.summary
    }

    @ViewBuilder private var statusChip: some View {
        if item.isBusy {
            Chip(text: item.phase == .reverting ? "TURNING OFF" : "TURNING ON", color: Theme.warn)
        } else if intent.target != nil {
            Chip(text: "PENDING", color: Theme.warn)
        } else if item.failed {
            Chip(text: "FAILED", color: Theme.fail, filled: true)
        } else {
            StateChip(state: item.state, checking: item.detection == nil)
        }
    }

    /// One fixed chip row (no ViewThatFits: measuring alternatives for every card was a layout hot spot).
    private var chips: some View {
        HStack(spacing: 5) {
            statusChip
            RiskChip(risk: item.tweak.risk)
            ImpactChip(impact: item.tweak.impact, compact: true)
            if item.tweak.recommended { Chip(text: "REC").help("Recommended: safe for almost every Mac") }
            if item.tweak.isHiddenGem { Chip(text: "GEM").help("Hidden gem: a little-known setting with an effect you can see or measure") }
        }
        .lineLimit(1)
        .clipped()
    }
}

/// The switch (or Open button) shared by the card and the drawer.
struct CardControl: View {
    @Bindable var item: TweakItem
    @Bindable var intent: CardIntent
    private func onToggle(_ t: Tweak, _ on: Bool) { ChangeCenter.shared.request(t, on: on) }

    var body: some View {
        let t = item.tweak
        HStack(spacing: 6) {
            if item.isBusy { ProgressView().controlSize(.mini).accessibilityLabel("Working") }
            if t.oneShot {
                Button(item.state == .on ? "Run again" : "Run") { onToggle(t, true) }
                    .buttonStyle(KeelButtonStyle(small: true))
                    .disabled(item.detection == nil || item.state == .notApplicable || item.isBusy || intent.target != nil)
                    .help("A one-time action: runs once, nothing to turn off afterwards")
                    .accessibilityLabel("Run \(t.name)")
            } else if t.isManual {
                Button("Open") { onToggle(t, true) }
                    .buttonStyle(KeelButtonStyle(small: true))
                    .disabled(item.state == .notApplicable)
                    .help("Open the System Settings pane for this")
                    .accessibilityLabel("Open System Settings for \(t.name)")
            } else {
                Toggle(t.name, isOn: Binding(get: { intent.target ?? (item.state == .on) },
                                             set: { onToggle(t, $0) }))
                    .toggleStyle(FlatToggleStyle())
                    .disabled(item.detection == nil || item.state == .notApplicable || item.state == .unknown || item.isBusy || intent.target != nil)
                    .opacity(item.detection == nil ? 0.4 : 1)
            }
        }
        .frame(minHeight: 22)
    }
}

/// Lists exactly what will run. Apply closes it at once; progress shows on the cards.
struct ConfirmSheet: View {
    let change: PendingChange
    let onConfirm: (_ selected: [Tweak], _ snapshotFirst: Bool) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String>
    @State private var expanded: Set<String>
    @State private var snapshot: Bool
    @State private var listHeight: CGFloat = 0

    init(change: PendingChange, onConfirm: @escaping ([Tweak], Bool) -> Void, onCancel: @escaping () -> Void) {
        self.change = change; self.onConfirm = onConfirm; self.onCancel = onCancel
        _selected = State(initialValue: Set(change.tweaks.map(\.id)))
        _expanded = State(initialValue: change.tweaks.count == 1 ? [change.tweaks[0].id] : [])
        _snapshot = State(initialValue: AppSettings.shared.snapshotBeforeFirstChange && !AppSettings.shared.snapshotTaken)
        // Close estimate of the list height (about 63 pt per row) so the first layout is final for long lists.
        _listHeight = State(initialValue: CGFloat(change.tweaks.count) * 63 + (change.tweaks.count > 1 ? 30 : 0) + 24)
    }

    private var chosen: [Tweak] { change.tweaks.filter { selected.contains($0.id) } }
    private var isBatch: Bool { change.tweaks.count > 1 }

    var body: some View {
        let m = Machine.current
        let chosen = self.chosen
        let admin = chosen.filter(\.needsAdmin).count
        let posts = Set(chosen.map(\.postAction)).subtracting([.none])
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(change.title).font(.system(size: 15, weight: .semibold))
                Text(change.on ? "Keel records each original value first, verifies every change, and restores anything that does not stick."
                               : "Keel puts back the original values it recorded.")
                    .font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 5) {
                    Chip(text: "\(chosen.count) CHANGE\(chosen.count == 1 ? "" : "S")")
                    if admin > 0 { Chip(text: HelperManager.shared.isReady ? "ADMIN VIA HELPER" : "ONE PASSWORD PROMPT", color: Theme.warn, symbol: "lock") }
                    ForEach(Array(posts).sorted { $0.rawValue < $1.rawValue }, id: \.self) { p in Chip(text: TweakGuide.postChip(p), color: [.logout, .restart].contains(p) ? Theme.warn : Theme.neutral) }
                }
                .padding(.top, 2)
            }
            .padding(18)
            HLine()
            // Hug the list when it is short; scroll only past 400 pt.
            ScrollView {
                list(m).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if abs(h - listHeight) > 0.5 { listHeight = h }
                }
            }
            .frame(height: min(max(listHeight, 80), 400))
            HLine()
            HStack(spacing: 10) {
                if change.on && !AppSettings.shared.snapshotTaken {
                    Toggle(isOn: $snapshot) { Text("Take a safety snapshot first (removed automatically after 24 hours)").font(Theme.small) }
                        .toggleStyle(KeelCheckboxStyle())
                        .help("Runs tmutil localsnapshot once before the first change")
                }
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.keel).keyboardShortcut(.cancelAction)
                Button(change.on ? (chosen.count > 1 ? "Apply \(chosen.count) changes" : "Apply") : (chosen.count > 1 ? "Restore \(chosen.count)" : "Restore")) {
                    onConfirm(chosen, change.on && snapshot && !AppSettings.shared.snapshotTaken)
                }
                .buttonStyle(.keelPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 600)
        .background(Theme.raisedBG)
    }

    private func list(_ m: MachineProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isBatch {
                HStack {
                    Button(selected.count == change.tweaks.count ? "Select none" : "Select all") {
                        selected = selected.count == change.tweaks.count ? [] : Set(change.tweaks.map(\.id))
                    }.buttonStyle(KeelButtonStyle(kind: .ghost, small: true))
                    Spacer()
                    Button(expanded.isEmpty ? "Show all commands" : "Hide commands") {
                        expanded = expanded.isEmpty ? Set(change.tweaks.map(\.id)) : []
                    }.buttonStyle(KeelButtonStyle(kind: .ghost, small: true))
                }
            }
            ForEach(change.tweaks) { t in row(t, m) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func row(_ t: Tweak, _ m: MachineProfile) -> some View {
        let on = selected.contains(t.id)
        let open = expanded.contains(t.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isBatch {
                    Toggle(t.name, isOn: Binding(get: { on }, set: { v in if v { selected.insert(t.id) } else { selected.remove(t.id) } }))
                        .toggleStyle(KeelCheckboxStyle(labelHidden: true))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(t.category.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                RiskChip(risk: t.risk)
                ImpactChip(impact: t.impact, compact: true)
                if t.needsAdmin { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityLabel("Needs administrator approval") }
                IconButton(symbol: open ? "chevron.up" : "chevron.down", label: open ? "Hide commands" : "Show commands", size: 10) {
                    if open { expanded.remove(t.id) } else { expanded.insert(t.id) }
                }
            }
            if open {
                CommandBlock(lines: change.on ? t.applyCommands(m) : t.revertCommands(m))
                if !t.tradeoff.isEmpty && change.on {
                    Text("Trade-off: \(t.tradeoff)").font(Theme.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .opacity(isBatch && !on ? 0.55 : 1)
    }
}
