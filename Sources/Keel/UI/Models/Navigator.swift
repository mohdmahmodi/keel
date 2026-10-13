import SwiftUI
import Observation

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", tweaks = "Tweaks", cleanup = "Cleanup", benchmark = "Benchmark", activity = "Activity", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .tweaks: return "slider.horizontal.3"
        case .cleanup: return "trash"
        case .benchmark: return "stopwatch"
        case .activity: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\((Page.allCases.firstIndex(of: self) ?? 0) + 1)")) }
}

enum TweakFilter: String, CaseIterable {
    case all = "All", off = "Off", on = "On", recommended = "Recommended", optIn = "Opt-in", notApplicable = "Not on this Mac"
}

/// Where the user is: page, open drawer, Tweaks filters. Shared by the window, the menu bar and the menu commands.
@MainActor @Observable
final class Navigator {
    static let shared = Navigator()
    var page: Page = .overview
    var selectedTweak: String? = nil
    var filter: TweakFilter = .all
    var category: TweakCategory? = nil
    var audience: Audience? = nil
    var search = ""
    /// Bumped to ask the Tweaks page to focus its search field.
    var searchFocusRequest = 0
    var showOnboarding = false

    func open(_ p: Page) {
        page = p
        if p != .tweaks && p != .overview { selectedTweak = nil }
    }

    /// Shows a tweak's drawer on the Tweaks page, widening the filters if they would hide it.
    func openTweak(_ id: String) {
        guard let item = TweakStore.shared.item(id) else { return }
        page = .tweaks
        if let c = category, c != item.tweak.category { category = nil }
        if let a = audience, !item.tweak.audiences.contains(a) { audience = nil }
        if !search.isEmpty { search = "" }
        if !TweakFilters.matches(item.tweak, state: item.state, filter: filter) {
            filter = item.state == .notApplicable ? .notApplicable : .all
        }
        selectedTweak = id
    }

    func showTweaks(_ f: TweakFilter) {
        filter = f; category = nil; audience = nil; search = ""; page = .tweaks
    }

    func focusSearch() { page = .tweaks; searchFocusRequest += 1 }

    func perform(_ a: AttentionAction) {
        switch a {
        case .tweak(let id): openTweak(id)
        case .page(let p): open(p)
        case .tweaks(let f): showTweaks(f)
        case .url(let u): NSWorkspace.shared.open(u)
        case .app(let path): NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case .installHelper: HelperManager.shared.install()
        }
    }
}

enum TweakFilters {
    static func matches(_ t: Tweak, state: TweakState, filter: TweakFilter) -> Bool {
        switch filter {
        case .all: return state != .notApplicable
        case .off: return state == .off || state == .partlyOn
        case .on: return state == .on
        case .recommended: return t.recommended && state != .notApplicable
        case .optIn: return !t.recommended && state != .notApplicable
        case .notApplicable: return state == .notApplicable
        }
    }
}

/// What a "Needs attention" or "Only you can do these" row opens.
enum AttentionAction: Equatable {
    case tweak(String)
    case page(Page)
    case tweaks(TweakFilter)
    case url(URL)
    case app(String)
    case installHelper
}
