import Foundation
import KeelShared

enum TweakCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case performance = "Performance"
    case memory = "Memory"
    case storage = "Storage"
    case background = "Background apps"
    case network = "Network"
    case developer = "Developer"
    case ai = "AI tools"
    case power = "Battery & Power"
    case privacy = "Privacy & Security"
    case visual = "Visual responsiveness"
    case finder = "Finder & desktop"
    case input = "Keyboard, trackpad & sound"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .performance: return "gauge.with.dots.needle.67percent"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .background: return "clock.arrow.2.circlepath"
        case .network: return "network"
        case .developer: return "hammer"
        case .ai: return "cpu"
        case .power: return "bolt"
        case .privacy: return "hand.raised"
        case .visual: return "sparkles.rectangle.stack"
        case .finder: return "folder"
        case .input: return "keyboard"
        }
    }
}

/// Who a tweak is mostly for; drives the "For" filter.
enum Audience: String, CaseIterable, Codable, Sendable, Identifiable {
    case everyone = "Everyone", laptop = "Laptop users", developer = "Developers", creator = "Creators",
         gamer = "Gamers", privacy = "Privacy", ai = "Local AI"
    var id: String { rawValue }
}

enum Risk: String, Codable, Sendable, Comparable {
    case safe = "SAFE", low = "LOW", medium = "MEDIUM"
    static func < (a: Risk, b: Risk) -> Bool { a.order < b.order }
    private var order: Int { self == .safe ? 0 : (self == .low ? 1 : 2) }
}

/// Shown so a cosmetic tweak is not mistaken for a speed-up.
enum Impact: String, Codable, Sendable, Comparable {
    case high = "HIGH IMPACT", medium = "MEDIUM IMPACT", low = "LOW IMPACT", cosmetic = "COSMETIC"
    static func < (a: Impact, b: Impact) -> Bool { a.order < b.order }
    var order: Int { switch self { case .high: return 0; case .medium: return 1; case .low: return 2; case .cosmetic: return 3 } }
}

enum TweakState: String, Codable, Sendable {
    case on = "ON", off = "OFF", partlyOn = "PARTLY ON", notApplicable = "N/A", unknown = "UNKNOWN"
}

enum PostAction: String, Codable, Sendable, Hashable {
    case none, killDock = "killall Dock", killFinder = "killall Finder", killSharingd = "killall sharingd",
         killSystemUIServer = "killall SystemUIServer", killControlCenter = "killall ControlCenter",
         logout = "Log out and back in", restart = "Restart", relaunchApp = "Relaunch the affected app"
    var processName: String? {
        switch self {
        case .killDock: return "Dock"
        case .killFinder: return "Finder"
        case .killSharingd: return "sharingd"
        case .killSystemUIServer: return "SystemUIServer"
        case .killControlCenter: return "ControlCenter"
        default: return nil
        }
    }
}

/// The detected state plus the raw values behind it.
struct Detection: Sendable {
    var state: TweakState
    /// Ordered label → value pairs shown in mono in the drawer.
    var values: [(String, String)] = []
    var note: String? = nil
    static func na(_ note: String) -> Detection { Detection(state: .notApplicable, note: note) }
    static let unknown = Detection(state: .unknown)
}

// MARK: - Mechanisms

enum DefaultsType: String, Codable, Sendable { case bool, int, float, string }

struct DefaultsSetting: Sendable {
    let domain: String
    let key: String
    let type: DefaultsType
    /// Value written when the tweak is ON.
    let on: String
    /// Documented value for OFF; nil = delete the key (system default). Used only when no original was recorded.
    let off: String?
    var currentHost: Bool = false
    /// Extra values that also count as ON when detected.
    var onAliases: [String] = []

    func isOn(_ v: String?) -> Bool {
        guard let v else { return false }
        if normalize(v) == normalize(on) { return true }
        return onAliases.contains { normalize($0) == normalize(v) }
    }
    func normalize(_ s: String) -> String {
        let l = s.lowercased().trimmingCharacters(in: .whitespaces)
        if ["1", "true", "yes"].contains(l) { return "1" }
        if ["0", "false", "no"].contains(l) { return "0" }
        if let d = Double(l) { return String(d) }
        return l
    }
    func writeCommand(_ v: String) -> String {
        let shown = type == .bool ? (["1", "true", "yes"].contains(v.lowercased()) ? "true" : "false") : v
        return "defaults \(currentHost ? "-currentHost " : "")write \(shq(domain)) \(shq(key)) -\(type.rawValue) \(shq(shown))"
    }
    var deleteCommand: String { "defaults \(currentHost ? "-currentHost " : "")delete \(shq(domain)) \(shq(key))" }
}

enum PmsetScope: String, Sendable { case all = "-a", battery = "-b", charger = "-c" }

struct PmsetSetting: Sendable {
    let key: String
    let on: String
    let off: String
    var scope: PmsetScope = .all
}

/// user: ~/Library/LaunchAgents · globalAgent: /Library/LaunchAgents · system: /Library/LaunchDaemons
enum LaunchdDomain: String, Sendable, Codable { case user, globalAgent, system }

struct LaunchdItem: Sendable {
    let label: String
    let plistPath: String
    let domain: LaunchdDomain
}

/// Collects privileged operations and post-actions while tweaks in a batch prepare themselves,
/// so the whole batch needs at most one administrator prompt and one Dock/Finder restart.
final class ApplyContext: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ops: [(tweakID: String, op: PrivOp)] = []
    private(set) var afterRoot: [(tweakID: String, step: @Sendable () async throws -> Void)] = []
    private(set) var posts: Set<PostAction> = []
    var currentTweak = ""
    let machine: MachineProfile
    init(machine: MachineProfile) { self.machine = machine }

    /// Queue root operations for this tweak; they run together after every tweak has prepared.
    func privileged(_ new: [PrivOp]) { lock.lock(); ops += new.map { (currentTweak, $0) }; lock.unlock() }
    func privileged(_ op: PrivOp) { privileged([op]) }
    /// A user-level step that must run after the root operations (e.g. bootstrapping a restored agent).
    func afterPrivileged(_ step: @escaping @Sendable () async throws -> Void) { lock.lock(); afterRoot.append((currentTweak, step)); lock.unlock() }
    func post(_ p: PostAction) { guard p != .none else { return }; lock.lock(); posts.insert(p); lock.unlock() }
}

struct CustomMechanism: Sendable {
    let detect: @Sendable () async -> Detection
    /// Records whatever is needed to undo, makes user-level changes, queues root ops on the context.
    let apply: @Sendable (ApplyContext) async throws -> [String: String]
    /// Restores from what `apply` recorded (empty when nothing was recorded).
    let revert: @Sendable (ApplyContext, [String: String]) async throws -> Void
    let applyCommands: [String]
    let revertCommands: [String]
    let needsAdmin: Bool
}

struct ManualMechanism: Sendable {
    let detect: @Sendable () async -> Detection
    /// System Settings deep link (x-apple.systempreferences:…) or empty.
    let settingsURL: String
    let instructions: String
}

enum Mechanism: Sendable {
    case defaults([DefaultsSetting], post: PostAction)
    case pmset([PmsetSetting])
    /// sysctl whose ON value is computed for this machine; optionally persisted with a LaunchDaemon.
    case sysctl(name: String, value: @Sendable (MachineProfile) -> Int, persist: Bool)
    /// Unload, disable and move launchd plists into Keel's backups (reversible).
    case launchd([LaunchdItem])
    case custom(CustomMechanism)
    /// Only the user can change it (System Settings / the app itself); Keel detects and deep-links.
    case manual(ManualMechanism)
}

enum Confidence: String, Sendable { case high, medium, low }

struct Tweak: Identifiable, Sendable {
    let id: String
    let name: String
    let category: TweakCategory
    /// One line, shown on the card.
    let summary: String
    /// Long explanation for the drawer.
    let explanation: String
    let risk: Risk
    var impact: Impact = .low
    /// Recommended (part of "Turn on recommended") vs opt-in.
    let recommended: Bool
    let mechanism: Mechanism
    var sources: [String] = []
    var requires: [Requirement] = []
    var confidence: Confidence = .high
    var expectedBenefit: String = ""
    /// What you give up when it is on.
    var tradeoff: String = ""
    /// An action that runs once (e.g. thin snapshots) rather than a setting that stays on.
    /// No original is recorded and there is nothing to turn off afterwards.
    var oneShot: Bool = false
    /// Who it is mostly for; empty means derived from the category.
    var audience: Set<Audience> = []

    var audiences: Set<Audience> {
        if !audience.isEmpty { return audience }
        switch category {
        case .developer: return [.developer]
        case .ai: return [.ai]
        case .privacy: return [.privacy]
        case .power: return requires.contains { if case .laptop = $0 { return true }; return false } ? [.laptop] : [.everyone]
        default: return [.everyone]
        }
    }

    /// Curated in `TweakCatalog.hiddenGems`.
    var isHiddenGem: Bool { TweakCatalog.hiddenGems.contains(id) }

    var needsAdmin: Bool {
        switch mechanism {
        case .defaults, .manual: return false
        case .pmset, .sysctl: return true
        case .launchd(let items): return items.contains { $0.domain != .user }
        case .custom(let c): return c.needsAdmin
        }
    }
    var isManual: Bool { if case .manual = mechanism { return true } else { return false } }
    var postAction: PostAction { if case .defaults(_, let p) = mechanism { return p } else { return .none } }

    /// Exact commands shown in the confirmation and the drawer.
    func applyCommands(_ m: MachineProfile) -> [String] {
        switch mechanism {
        case .defaults(let s, let post):
            return s.map { $0.writeCommand($0.on) } + (post.processName != nil ? [post.rawValue] : [])
        case .pmset(let s):
            return s.map { "sudo pmset \($0.scope.rawValue) \($0.key) \($0.on)" }
        case .sysctl(let n, let v, let persist):
            var c = ["sudo sysctl -w \(n)=\(v(m))"]
            if persist { c.append("sudo install /Library/LaunchDaemons/\(KeelConstants.sysctlDaemonLabel(n)).plist  # re-applies at boot") }
            return c
        case .launchd(let items):
            return items.flatMap { i -> [String] in
                let sudo = i.domain == .user ? "" : "sudo "
                let dom = i.domain == .system ? "system" : "gui/$UID"
                return ["\(i.domain == .system ? "sudo " : "")launchctl bootout \(dom)/\(i.label)",
                        "\(sudo)mv \(shq(i.plistPath)) \"~/Library/Application Support/Keel/backups/\"",
                        "\(i.domain == .system ? "sudo " : "")launchctl disable \(dom)/\(i.label)"]
            }
        case .custom(let c): return c.applyCommands
        case .manual(let m): return [m.instructions]
        }
    }
    func revertCommands(_ m: MachineProfile) -> [String] {
        switch mechanism {
        case .defaults(let s, let post):
            return s.map { "\($0.writeCommand("<recorded original>"))  # or delete if it was unset" } + (post.processName != nil ? [post.rawValue] : [])
        case .pmset(let s):
            return s.map { "sudo pmset \($0.scope.rawValue) \($0.key) <recorded original>" }
        case .sysctl(let n, _, let persist):
            var c = ["sudo sysctl -w \(n)=<recorded original>"]
            if persist { c.append("sudo launchctl bootout system/\(KeelConstants.sysctlDaemonLabel(n)); sudo rm the LaunchDaemon") }
            return c
        case .launchd(let items):
            return items.flatMap { i -> [String] in
                let sudo = i.domain == .user ? "" : "sudo "
                let dom = i.domain == .system ? "system" : "gui/$UID"
                return ["\(sudo)cp <backup copy> \(shq(i.plistPath))", "launchctl enable \(dom)/\(i.label)", "launchctl bootstrap \(dom) \(shq(i.plistPath))"]
            }
        case .custom(let c): return c.revertCommands
        case .manual: return ["Change it back in System Settings"]
        }
    }
}
