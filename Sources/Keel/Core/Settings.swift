import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var keepInMenuBar: Bool { didSet { d.set(keepInMenuBar, forKey: "keepInMenuBar") } }
    var snapshotBeforeFirstChange: Bool { didSet { d.set(snapshotBeforeFirstChange, forKey: "snapshotBeforeFirstChange") } }
    var snapshotTaken: Bool { didSet { d.set(snapshotTaken, forKey: "snapshotTaken") } }
    var confirmChanges: Bool { didSet { d.set(confirmChanges, forKey: "confirmChanges") } }
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    /// Refreshed from the system, never assumed.
    private(set) var login = LoginItem.Status(state: .off, mechanism: LoginItem.preferredMechanism)
    private(set) var loginBusy = false

    var startAtLogin: Bool { login.state != .off }

    init() {
        keepInMenuBar = d.object(forKey: "keepInMenuBar") as? Bool ?? true
        snapshotBeforeFirstChange = d.object(forKey: "snapshotBeforeFirstChange") as? Bool ?? true
        snapshotTaken = d.bool(forKey: "snapshotTaken")
        confirmChanges = d.object(forKey: "confirmChanges") as? Bool ?? true
        onboardingDone = d.bool(forKey: "onboardingDone")
    }

    func refreshLogin() async {
        let s = await Task.detached(priority: .utility) { LoginItem.status() }.value
        if s != login { login = s }
    }

    func setStartAtLogin(_ on: Bool) {
        guard !loginBusy else { return }
        loginBusy = true
        Task {
            await LoginItem.set(on)
            await refreshLogin()
            loginBusy = false
        }
    }
}

/// Start at login: `SMAppService.mainApp` for a signed app in /Applications, otherwise a user LaunchAgent.
enum LoginItem {
    static let label = "com.keel.app"
    static var plistPath: String { "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist" }

    enum Mechanism: String, Sendable { case appService = "Login Items (SMAppService)", launchAgent = "LaunchAgent" }
    enum State: String, Sendable { case on = "ON", needsApproval = "NEEDS APPROVAL", off = "OFF" }
    struct Status: Equatable, Sendable { var state: State; var mechanism: Mechanism }

    static var appPath: String { Bundle.main.bundlePath }
    static var isAppBundle: Bool { appPath.hasSuffix(".app") }
    static var inApplications: Bool { appPath.hasPrefix("/Applications/") }

    /// SMAppService needs a real, signed bundle in a stable location.
    static var preferredMechanism: Mechanism {
        isAppBundle && inApplications && isSigned ? .appService : .launchAgent
    }

    static var isSigned: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    static func status() -> Status {
        let agent = FileManager.default.fileExists(atPath: plistPath)
        if isAppBundle {
            switch SMAppService.mainApp.status {
            case .enabled: return Status(state: .on, mechanism: .appService)
            case .requiresApproval: return Status(state: .needsApproval, mechanism: .appService)
            default: break
            }
        }
        if agent { return Status(state: .on, mechanism: .launchAgent) }
        return Status(state: .off, mechanism: preferredMechanism)
    }

    @MainActor static func set(_ on: Bool) async {
        let log = ActivityLog.shared
        if on {
            if preferredMechanism == .appService {
                do {
                    try SMAppService.mainApp.register()
                    removeAgent()
                    log.success("Start at login enabled", detail: "SMAppService.mainApp registered for \(appPath)")
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    return
                } catch {
                    log.warning("Login Items registration failed, using a LaunchAgent instead", detail: error.localizedDescription)
                }
            }
            await installAgent()
        } else {
            if isAppBundle, SMAppService.mainApp.status != .notRegistered {
                do { try await SMAppService.mainApp.unregister() } catch { log.warning("Could not remove the login item", detail: error.localizedDescription) }
            }
            if FileManager.default.fileExists(atPath: plistPath) {
                _ = try? await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
                removeAgent()
            }
            log.success("Start at login disabled")
        }
    }

    private static func removeAgent() { try? FileManager.default.removeItem(atPath: plistPath) }

    @MainActor private static func installAgent() async {
        let log = ActivityLog.shared
        let target = isAppBundle ? appPath : (Bundle.main.executablePath ?? appPath)
        let args = isAppBundle ? ["/usr/bin/open", "-g", "-a", target] : [target]
        let plist: [String: Any] = ["Label": label, "ProgramArguments": args, "RunAtLoad": true, "LimitLoadToSessionType": "Aqua"]
        do {
            try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } catch {
            log.error("Could not write \(plistPath)", detail: error.localizedDescription)
            return
        }
        log.success("Start at login enabled", detail: "LaunchAgent \(plistPath)")
    }
}
