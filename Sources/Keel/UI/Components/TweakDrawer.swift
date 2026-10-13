import SwiftUI

/// Side panel for one tweak: what it does, who it is for, current state, undo, commands and sources.
struct TweakDrawer: View {
    @Bindable var item: TweakItem
    @Bindable var intent: CardIntent
    let close: () -> Void
    @State private var record: BackupRecord? = nil
    @State private var showCommands = false
    @State private var showSources = false
    @State private var showMore = false

    var body: some View {
        let t = item.tweak
        VStack(spacing: 0) {
            topBar(t)
            HLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(t)
                    notices(t)
                    whatItDoes(t)
                    if !t.expectedBenefit.isEmpty || !t.tradeoff.isEmpty { effects(t) }
                    guide("Is it for you?", symbol: "person.crop.circle.badge.questionmark") {
                        VStack(alignment: .leading, spacing: 6) {
                            FlowLayout(spacing: 5) {
                                ForEach(Audience.allCases.filter { t.audiences.contains($0) }) { a in
                                    Chip(text: a.rawValue.uppercased(), symbol: a == .everyone ? "person.2" : "person")
                                }
                            }
                            .padding(.bottom, 2)
                            ForEach(Array(TweakGuide.fit(t, state: item.state, note: item.detection?.note).enumerated()), id: \.offset) { _, line in
                                Bullet(text: line)
                            }
                        }
                    }
                    rightNow(t)
                    undo(t)
                    Disclosure(title: "Exact commands", symbol: "terminal", expanded: $showCommands) {
                        let m = Machine.current
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                SectionTitle(text: t.isManual ? "How to change it" : "Turning on runs")
                                CommandBlock(lines: t.applyCommands(m))
                            }
                            if !t.isManual {
                                VStack(alignment: .leading, spacing: 5) {
                                    SectionTitle(text: "Turning off runs")
                                    CommandBlock(lines: t.revertCommands(m))
                                }
                            }
                        }
                    }
                    if !t.sources.isEmpty {
                        Disclosure(title: "Sources (\(t.sources.count))", symbol: "books.vertical", expanded: $showSources) {
                            VStack(alignment: .leading, spacing: 7) { ForEach(t.sources, id: \.self) { SourceLine(source: $0) } }
                        }
                    }
                    Text(t.id).font(Theme.monoSmall).foregroundStyle(.tertiary)
                }
                .padding(16)
            }
        }
        .background(Theme.raisedBG)
        .task(id: "\(item.id)-\(item.phase == .idle)") {
            let id = item.id
            record = await Task.detached(priority: .userInitiated) { BackupStore.latest(for: id) }.value
        }
        .onChange(of: item.id) { _, _ in showMore = false }
    }

    private func topBar(_ t: Tweak) -> some View {
        HStack(spacing: 6) {
            Image(systemName: t.category.symbol).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(t.category.rawValue).font(Theme.small).foregroundStyle(.secondary)
            Spacer()
            IconButton(symbol: "xmark", label: "Close details", size: 11, action: close)
                .keyboardShortcut(ChangeCenter.shared.pending == nil ? .cancelAction : nil)
        }
        .padding(.horizontal, 14).frame(height: 40)
    }

    private func header(_ t: Tweak) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(t.name).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                CardControl(item: item, intent: intent).padding(.top, 1)
            }
            FlowLayout(spacing: 5) {
                statusChip
                if item.failed { Chip(text: "FAILED", color: Theme.fail, filled: true) }
                RiskChip(risk: t.risk)
                ImpactChip(impact: t.impact)
                if t.isHiddenGem { Chip(text: "HIDDEN GEM").help("A little-known setting with an effect you can see or measure") }
                if t.oneShot { Chip(text: "ONE-TIME ACTION").help("Runs once; there is nothing to turn off afterwards") }
                Chip(text: t.recommended ? "RECOMMENDED" : "OPT-IN")
                if t.needsAdmin { Chip(text: "ADMIN", symbol: "lock") }
                if t.postAction != .none { Chip(text: TweakGuide.postChip(t.postAction), color: [.logout, .restart].contains(t.postAction) ? Theme.warn : Theme.neutral) }
            }
            if let msg = item.message {
                Text(msg).font(Theme.small).foregroundStyle(item.failed ? Theme.fail : .secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var statusChip: some View {
        if item.isBusy { Chip(text: item.phase == .reverting ? "TURNING OFF" : "TURNING ON", color: Theme.warn) }
        else if intent.target != nil { Chip(text: "PENDING", color: Theme.warn) }
        else { StateChip(state: item.state, checking: item.detection == nil) }
    }

    @ViewBuilder private func notices(_ t: Tweak) -> some View {
        let post = TweakGuide.postNotice(t.postAction)
        if t.needsAdmin || post != nil || t.isManual {
            VStack(alignment: .leading, spacing: 6) {
                if t.isManual {
                    Callout(symbol: "hand.point.up.left", text: "Only you can change this, in System Settings. Keel checks it and opens the right pane.")
                }
                if t.needsAdmin {
                    Callout(symbol: "lock", text: HelperManager.shared.isReady
                            ? "Needs administrator rights. Keel's helper runs it without a password prompt."
                            : "Needs administrator rights. macOS asks for your password once per batch.")
                }
                if let post { Callout(symbol: "arrow.clockwise", text: post, color: Theme.warn) }
            }
        }
    }

    private func whatItDoes(_ t: Tweak) -> some View {
        let (lead, rest) = TweakGuide.split(t.explanation)
        return guide("What it does", symbol: "text.alignleft") {
            VStack(alignment: .leading, spacing: 8) {
                Text(lead.isEmpty ? t.summary : lead).font(.system(size: 13)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !rest.isEmpty {
                    if showMore {
                        Text(rest).font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(showMore ? "Less" : "More detail") { withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() } }
                        .buttonStyle(KeelButtonStyle(kind: .ghost, small: true))
                        .padding(.leading, -8)
                }
            }
        }
    }

    private func effects(_ t: Tweak) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !t.expectedBenefit.isEmpty {
                EffectCard(title: "What you'll notice", symbol: "checkmark.circle", text: t.expectedBenefit, tint: Theme.on)
            }
            if !t.tradeoff.isEmpty {
                EffectCard(title: "What you give up", symbol: "minus.circle", text: t.tradeoff, tint: Theme.warn)
            }
        }
    }

    private func rightNow(_ t: Tweak) -> some View {
        guide("Right now on this Mac", symbol: "desktopcomputer") {
            VStack(alignment: .leading, spacing: 8) {
                Text(TweakGuide.stateSentence(item.detection == nil ? .unknown : item.state, isManual: t.isManual, note: item.detection?.note))
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                if let d = item.detection, !d.values.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(d.values.enumerated()), id: \.offset) { _, kv in KV(k: kv.0, v: kv.1) }
                    }
                    .card(padding: 10)
                }
            }
        }
    }

    private func undo(_ t: Tweak) -> some View {
        guide("How to undo", symbol: "arrow.uturn.backward") {
            VStack(alignment: .leading, spacing: 8) {
                Text(TweakGuide.undoSentence(t, state: item.state, recorded: record?.date))
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                if let b = record, !b.original.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionTitle(text: "Recorded original")
                        ForEach(b.original.keys.sorted(), id: \.self) { k in KV(k: k, v: b.original[k] ?? "") }
                    }
                    .card(padding: 10)
                }
            }
        }
    }

    private func guide<C: View>(_ title: String, symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14).accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

// MARK: - Guide text

enum TweakGuide {
    /// First sentence and the rest.
    static func split(_ text: String) -> (String, String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var idx = s.startIndex
        while let r = s.range(of: ". ", range: idx..<s.endIndex) {
            // Skip abbreviations like "e.g. ".
            let before = s[s.startIndex..<r.lowerBound]
            if before.hasSuffix("e.g") || before.hasSuffix("i.e") || before.hasSuffix("approx") || before.hasSuffix("vs") { idx = r.upperBound; continue }
            return (String(s[..<r.lowerBound]) + ".", String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return (s, "")
    }

    static func fit(_ t: Tweak, state: TweakState, note: String?) -> [String] {
        var out: [String] = []
        if state == .notApplicable {
            out.append("Not for this Mac: \(note ?? "a requirement is not met").")
        } else if t.recommended {
            out.append(t.risk == .safe ? "Recommended for most Macs. Safe and fully reversible."
                                       : "Recommended for most Macs. \(t.risk == .low ? "Low" : "Some") risk, and Keel can undo it.")
        } else {
            switch t.risk {
            case .medium: out.append("Opt-in. Read “What you give up” first; it has real side effects for some setups.")
            default: out.append("Opt-in. Turn it on if the benefit matters to you; otherwise leave it.")
            }
        }
        switch t.impact {
        case .high: out.append("High impact: you should notice the difference.")
        case .medium: out.append("Medium impact: noticeable in the situations described above.")
        case .low: out.append("Low impact: a small improvement, not a speed-up.")
        case .cosmetic: out.append("Cosmetic: changes how things look or feel, not how fast the Mac is.")
        }
        let aud = t.audiences.subtracting([.everyone])
        if aud.isEmpty { out.append("Useful on any Mac, whatever you use it for.") }
        if t.oneShot { out.append("A one-time action: it runs once and there is nothing to turn off afterwards.") }
        let reqs = t.requires.compactMap(requirementText)
        if !reqs.isEmpty { out.append("Applies to: " + reqs.joined(separator: ", ") + ".") }
        if t.confidence == .low { out.append("The effect is not well measured yet.") }
        return out
    }

    static func requirementText(_ r: Requirement) -> String? {
        switch r {
        case .laptop: return "Macs with a battery"
        case .desktop: return "desktop Macs"
        case .xcode: return "Macs with Xcode"
        case .homebrew: return "Macs with Homebrew"
        case .minMemoryGB(let g): return "\(g) GB of memory or more"
        case .minMacOS(let v): return "macOS \(v) or later"
        case .maxMacOS(let v): return "macOS \(v) or earlier"
        case .pmsetCapability(let c): return "Macs that support \(c)"
        case .app(_, let name): return "Macs with \(name)"
        case .anyPath(_, let name): return "Macs with \(name)"
        case .custom: return nil
        }
    }

    static func stateSentence(_ s: TweakState, isManual: Bool, note: String?) -> String {
        switch s {
        case .on: return "This is on."
        case .off: return isManual ? "This is not set the way Keel suggests." : "This is off. The Mac is using its current (usually default) setting."
        case .partlyOn: return "This is partly on: some of its settings match and some do not. Turning it on sets the rest."
        case .notApplicable: return note.map { "Does not apply here: \($0)." } ?? "Does not apply to this Mac."
        case .unknown: return "Checking…"
        }
    }

    static func undoSentence(_ t: Tweak, state: TweakState, recorded: Date?) -> String {
        if t.isManual { return "Change it back in the same System Settings pane." }
        if let d = recorded {
            return "Keel recorded your original value on \(d.formatted(date: .abbreviated, time: .shortened)). Turning it off restores it exactly."
        }
        switch state {
        case .on, .partlyOn:
            return "Keel has no recorded original (it was already like this, or set outside Keel). Turning it off restores the documented macOS default."
        default:
            return "Nothing to undo yet. When you turn it on, Keel records the current value first, so turning it off later restores it exactly."
        }
    }

    static func postNotice(_ p: PostAction) -> String? {
        switch p {
        case .none: return nil
        case .killDock: return "The Dock restarts for a moment when this changes."
        case .killFinder: return "Finder restarts for a moment when this changes."
        case .killSharingd: return "The sharing service restarts when this changes."
        case .killSystemUIServer: return "The menu bar restarts for a moment when this changes."
        case .killControlCenter: return "Control Center restarts for a moment when this changes."
        case .logout: return "Takes full effect after you log out and back in."
        case .restart: return "Takes full effect after a restart."
        case .relaunchApp: return "Takes effect after the affected app is relaunched."
        }
    }

    static func postChip(_ p: PostAction) -> String {
        switch p {
        case .none: return ""
        case .killDock: return "DOCK RESTARTS"
        case .killFinder: return "FINDER RESTARTS"
        case .killSharingd: return "SHARING RESTARTS"
        case .killSystemUIServer: return "MENU BAR RESTARTS"
        case .killControlCenter: return "CONTROL CENTER RESTARTS"
        case .logout: return "NEEDS LOGOUT"
        case .restart: return "NEEDS RESTART"
        case .relaunchApp: return "RELAUNCH APP"
        }
    }

    /// "macos-defaults.com · dock/autohide" or "Keel research · 10 visual responsiveness, VR-03".
    static func sourceTitle(_ s: String) -> String {
        if let u = URL(string: s), let host = u.host, s.hasPrefix("http") {
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let path = u.path.split(separator: "/").suffix(2).joined(separator: "/")
                .replacingOccurrences(of: ".html", with: "").replacingOccurrences(of: ".md", with: "")
            return path.isEmpty ? h : "\(h) · \(path)"
        }
        if s.hasPrefix("research/") {
            let rest = s.dropFirst("research/".count)
            let parts = rest.split(separator: " ", maxSplits: 1)
            let file = (parts.first.map(String.init) ?? "").replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "-", with: " ")
            return "Keel research · \(file)\(parts.count > 1 ? ", \(parts[1])" : "")"
        }
        return s
    }
}

// MARK: - Small pieces

struct Bullet: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(Color.secondary).frame(width: 3.5, height: 3.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3.5 }.accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Callout: View {
    let symbol: String
    let text: String
    var color: Color = .secondary
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(color).frame(width: 14).padding(.top, 1).accessibilityHidden(true)
            Text(text).font(Theme.small).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct EffectCard: View {
    let title: String
    let symbol: String
    let text: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            Text(text).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 11)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(tint.opacity(0.7)).frame(width: 2).padding(.vertical, 10)
        }
    }
}

/// Collapsible section without the system accent colour.
struct Disclosure<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14).accessibilityHidden(true)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(hover ? Theme.hover : Theme.fill.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded { content.transition(.opacity) }
        }
    }
}

/// A source: links open in the browser with a readable title; repository references are plain text.
struct SourceLine: View {
    let source: String
    @State private var hover = false
    var body: some View {
        if let u = URL(string: source), source.hasPrefix("http") {
            Button { NSWorkspace.shared.open(u) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10)).accessibilityHidden(true)
                    Text(TweakGuide.sourceTitle(source)).font(Theme.small).lineLimit(1).truncationMode(.middle).underline(hover)
                }
                .foregroundStyle(hover ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain).onHover { hover = $0 }.help(source)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 10)).accessibilityHidden(true)
                Text(TweakGuide.sourceTitle(source)).font(Theme.small).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary).help(source)
        }
    }
}
