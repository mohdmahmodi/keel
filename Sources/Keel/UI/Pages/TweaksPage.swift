import SwiftUI

/// Tweaks grouped by category, with section headers.
struct TweaksPage: View {
    @State private var nav = Navigator.shared
    @FocusState private var searchFocused: Bool
    private var digest: TweakDigest { TweakDigest.shared }
    private var store: TweakStore { TweakStore.shared }
    private var center: ChangeCenter { ChangeCenter.shared }
    static let columns = [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 10, alignment: .top)]

    var body: some View {
        let sections = TweakSections.build(states: digest.states, busy: digest.busy, filter: nav.filter, category: nav.category,
                                           audience: nav.audience, search: nav.search)
        let selected = nav.selectedTweak
        VStack(spacing: 0) {
            header
            toolbar
            HLine()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                    // One lazy grid with section headers. Nesting a LazyVGrid per category inside a
                    // LazyVStack made SwiftUI measure every card of every section on each change.
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                        ForEach(sections) { s in
                            Section {
                                ForEach(s.ids, id: \.self) { id in
                                    if let item = store.item(id) {
                                        TweakCard(item: item, intent: center.intent(id), selected: selected == id)
                                            .equatable()
                                            .id(id)
                                    }
                                }
                            } header: {
                                SectionHeader(category: s.category).equatable()
                                    .padding(.top, s.id == sections.first?.id ? 0 : 12)
                            }
                        }
                    }
                    if sections.isEmpty {
                            EmptyNote(symbol: store.items.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                                      text: store.items.isEmpty ? "No tweaks in this build." : (store.detecting && digest.detectedCount == 0 ? "Checking this Mac…" : "No tweaks match these filters."))
                            if !store.items.isEmpty && !(store.detecting && digest.detectedCount == 0) {
                                Button("Show all") { nav.showTweaks(.all) }.buttonStyle(.keel).frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .onAppear { if let id = nav.selectedTweak { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: nav.selectedTweak) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
        }
        .onChange(of: nav.searchFocusRequest) { _, _ in searchFocused = true }
        .onAppear { if nav.searchFocusRequest > 0 && nav.page == .tweaks { searchFocused = true } }
    }

    private var header: some View {
        let pending = digest.recommendedPending.count
        return PageHeader(title: "Tweaks", subtitle: "\(digest.applicableCount) apply to this Mac · \(digest.onCount) on · \(pending) recommended off") {
            if store.detecting { ProgressView().controlSize(.small).accessibilityLabel("Checking") }
            ViewThatFits(in: .horizontal) {
                headerButtons(pending: pending, compact: false)
                headerButtons(pending: pending, compact: true)
            }
        }
    }

    private func headerButtons(pending: Int, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { AppStartup.redetect() } label: {
                if compact { Image(systemName: "arrow.clockwise") } else { Label("Re-detect", systemImage: "arrow.clockwise") }
            }
            .disabled(store.detecting || store.running > 0)
            .help("Check every tweak again (⌘R)")
            .accessibilityLabel("Re-detect")
            Button(compact ? "Recommended (\(pending))" : "Turn on recommended (\(pending))") {
                center.requestBatch(digest.recommendedPendingTweaks, on: true, title: "Turn on \(pending) recommended change\(pending == 1 ? "" : "s")")
            }
            .buttonStyle(.keelPrimary)
            .disabled(pending == 0 || store.running > 0)
            .help("Turn on the recommended changes that are off. Shows the list and the exact commands first.")
        }
        .fixedSize()
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TweakFilter.allCases, id: \.self) { f in
                            ChipButton(text: f.rawValue, selected: nav.filter == f, count: digest.filterCounts[f] ?? 0) { nav.filter = f }
                        }
                    }
                }
                CategoryMenu(nav: nav)
            }
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("For").font(Theme.small).foregroundStyle(.secondary).padding(.trailing, 2)
                        ChipButton(text: "Any", selected: nav.audience == nil) { nav.audience = nil }
                        ForEach(Audience.allCases) { a in
                            if let n = digest.audienceCounts[a], n > 0 {
                                ChipButton(text: a.rawValue, selected: nav.audience == a, count: n) {
                                    nav.audience = nav.audience == a ? nil : a
                                }
                            }
                        }
                    }
                }
                SearchField(text: $nav.search, prompt: "Search tweaks", focus: $searchFocused)
                    .frame(width: 190)
                    .help("Search names, summaries and categories (⌘F)")
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }
}

/// Category picker as a compact menu; the sections already show categories as headers.
private struct CategoryMenu: View {
    @Bindable var nav: Navigator
    private var digest: TweakDigest { TweakDigest.shared }
    var body: some View {
        Menu {
            Button("All categories") { nav.category = nil }
            Divider()
            ForEach(TweakCategory.allCases) { c in
                if let stat = digest.categories[c], stat.total > 0 {
                    Button { nav.category = c } label: {
                        Label("\(c.rawValue)  (\(stat.applicable))", systemImage: nav.category == c ? "checkmark" : c.symbol)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: nav.category?.symbol ?? "square.grid.2x2").font(.system(size: 10.5))
                Text(nav.category?.rawValue ?? "All categories").font(.system(size: 11.5, weight: nav.category == nil ? .regular : .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).frame(height: 24)
            .foregroundStyle(nav.category == nil ? Color.secondary : Color.primary)
            .background(nav.category == nil ? Color.clear : Theme.selection, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show one category")
        .accessibilityLabel("Category: \(nav.category?.rawValue ?? "all")")
    }
}

/// Visible tweaks of one category. Built from the digest's coalesced states, not the live items.
struct TweakSection: Identifiable, Equatable {
    let category: TweakCategory
    let ids: [String]
    var id: String { category.rawValue }
}

enum TweakSections {
    @MainActor private static var haystacks: [String: String] = [:]

    @MainActor static func build(states: [String: TweakState], busy: Set<String>, filter: TweakFilter, category: TweakCategory?,
                                 audience: Audience?, search: String) -> [TweakSection] {
        let store = TweakStore.shared
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let words = q.split(separator: " ")
        var by: [TweakCategory: [Tweak]] = [:]
        for item in store.items {
            let t = item.tweak
            if let category, t.category != category { continue }
            if let audience, !TweakAudiences.of(t.id).contains(audience) { continue }
            let st = states[t.id] ?? .unknown
            guard busy.contains(t.id) || TweakFilters.matches(t, state: st, filter: filter) else { continue }
            if !words.isEmpty {
                let hay = haystacks[t.id] ?? {
                    let h = ([t.name, t.summary, t.category.rawValue, t.id] + TweakAudiences.of(t.id).map(\.rawValue)).joined(separator: " ").lowercased()
                    haystacks[t.id] = h
                    return h
                }()
                guard words.allSatisfy({ hay.contains($0) }) else { continue }
            }
            by[t.category, default: []].append(t)
        }
        return TweakCategory.allCases.compactMap { c in
            guard let list = by[c], !list.isEmpty else { return nil }
            let sorted = list.sorted { a, b in
                let sa = states[a.id] ?? .unknown, sb = states[b.id] ?? .unknown
                if (sa == .notApplicable) != (sb == .notApplicable) { return sb == .notApplicable }
                if a.recommended != b.recommended { return a.recommended }
                if a.impact != b.impact { return a.impact < b.impact }
                return a.name < b.name
            }
            return TweakSection(category: c, ids: sorted.map(\.id))
        }
    }
}

/// Audiences per tweak, computed once (the catalog is static).
@MainActor
enum TweakAudiences {
    private static var cache: [String: Set<Audience>] = [:]
    static func of(_ id: String) -> Set<Audience> {
        if let c = cache[id] { return c }
        let a = TweakStore.shared.tweak(id)?.audiences ?? [.everyone]
        cache[id] = a
        return a
    }
}

/// Category header inside the grid: name, how many are on, and "turn on the recommended ones here".
private struct SectionHeader: View, Equatable {
    let category: TweakCategory
    private var digest: TweakDigest { TweakDigest.shared }
    nonisolated static func == (a: SectionHeader, b: SectionHeader) -> Bool { a.category == b.category }

    var body: some View {
        let c = category
        let stat = digest.categories[c] ?? .init()
        let recs = stat.recommendedPending
        HStack(spacing: 8) {
            Image(systemName: c.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            Text(c.rawValue).font(.system(size: 13.5, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text("\(stat.on) of \(stat.applicable) on").font(Theme.monoSmall).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !recs.isEmpty {
                Button("Turn on \(recs.count) recommended") {
                    let tweaks = recs.compactMap { TweakStore.shared.tweak($0) }
                    ChangeCenter.shared.requestBatch(tweaks, on: true, title: "Turn on \(tweaks.count) recommended in \(c.rawValue)")
                }
                .buttonStyle(KeelButtonStyle(small: true))
                .disabled(TweakStore.shared.running > 0)
                .help("Lists exactly what it will do before anything changes")
            }
        }
        .frame(height: 26)
        .padding(.bottom, 2)
    }
}
