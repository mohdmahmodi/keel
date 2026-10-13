import Foundation
import ServiceManagement
import Observation
import KeelShared

/// The only path to root: XPC to the helper daemon when it is approved, otherwise the same helper run once
/// through the administrator prompt (one prompt per batch). Either way only allow-listed `PrivOp`s run.
enum Privileged {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var helperBinary: String? {
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [exe?.appendingPathComponent("KeelHelper").path].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns one result per op, in order. Throws if the user cancels.
    static func run(_ ops: [PrivOp], reason: String, helperOnly: Bool = false) async throws -> [OpResult] {
        guard !ops.isEmpty else { return [] }
        let request = PrivRequest(ops: ops, uid: getuid())
        let data = try JSONEncoder().encode(request)
        if await HelperManager.shared.isReady {
            do {
                let results = try await viaXPC(data)
                if results.count == ops.count { return results }
                if helperOnly { throw Failure(message: "The helper returned \(results.count) results for \(ops.count) operations") }
            } catch {
                if helperOnly { throw error }
                ActivityLog.post(.warning, "Helper unavailable (\(error.localizedDescription)); using the administrator prompt instead")
            }
        } else if helperOnly {
            throw Failure(message: "The helper is not enabled")
        }
        return try await viaPrompt(data, reason: reason, count: ops.count)
    }

    private static func viaXPC(_ data: Data) async throws -> [OpResult] {
        try await withCheckedThrowingContinuation { cont in
            let conn = NSXPCConnection(machServiceName: KeelConstants.helperMachService, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: KeelHelperXPC.self)
            if let team = HelperManager.teamIdentifier {
                conn.setCodeSigningRequirement("anchor apple generic and identifier \"\(KeelConstants.helperMachService)\" and certificate leaf[subject.OU] = \"\(team)\"")
            }
            let once = OnceFlag()
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { err in
                if once.fire() { conn.invalidate(); cont.resume(throwing: err) }
            } as? KeelHelperXPC
            proxy?.run(data) { reply in
                guard once.fire() else { return }
                conn.invalidate()
                if let r = try? JSONDecoder().decode([OpResult].self, from: reply) { cont.resume(returning: r) }
                else { cont.resume(throwing: Failure(message: "Bad reply from helper")) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if once.fire() { conn.invalidate(); cont.resume(throwing: Failure(message: "Helper timed out")) } }
        }
    }

    private static func viaPrompt(_ data: Data, reason: String, count: Int) async throws -> [OpResult] {
        guard let helper = helperBinary else { throw Failure(message: "KeelHelper is missing from the app bundle") }
        let b64 = data.base64EncodedString()
        // The base64 alphabet and an app-bundle path are the only things interpolated.
        let cmd = "'\(helper.replacingOccurrences(of: "'", with: "'\\''"))' run \(b64)"
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = "Keel needs administrator access to \(reason)".replacingOccurrences(of: "\"", with: "'")
        let script = "do shell script \"\(esc)\" with administrator privileges with prompt \"\(prompt)\""
        await MainActor.run { ActivityLog.shared.info("Waiting for administrator approval: \(reason)") ; AppState.shared.waitingForAdmin = true }
        defer { Task { @MainActor in AppState.shared.waitingForAdmin = false } }
        let r = try await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 600)
        if !r.ok {
            if r.stderr.contains("-128") { throw Failure(message: "Cancelled at the administrator prompt") }
            throw Failure(message: r.stderr.isEmpty ? "Privileged step failed (status \(r.status))" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let out = r.stdout.data(using: .utf8), let results = try? JSONDecoder().decode([OpResult].self, from: out) else {
            throw Failure(message: "Unexpected helper output: \(r.stdout.prefix(200))")
        }
        return results
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

/// The optional SMAppService helper daemon. Requires a Developer ID signed build.
@MainActor @Observable
final class HelperManager {
    static let shared = HelperManager()
    enum State: String { case unavailable = "Not available in this build", notInstalled = "Not installed", needsApproval = "Waiting for approval in System Settings", enabled = "Enabled", outdated = "Needs update" }
    var state: State = .notInstalled
    var detail = ""

    nonisolated static let teamIdentifier: String? = readTeamIdentifier()
    nonisolated private static func readTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var s: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &s) == errSecSuccess, let s else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(s, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any], let t = d[kSecCodeInfoTeamIdentifier as String] as? String, !t.isEmpty else { return nil }
        return t
    }

    var service: SMAppService { SMAppService.daemon(plistName: KeelConstants.helperPlistName) }

    /// Reads the live service status, never a cached one.
    var isReady: Bool { bundleHasDaemon && Self.teamIdentifier != nil && service.status == .enabled }

    var bundleHasDaemon: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(KeelConstants.helperPlistName)").path)
    }

    func refresh() {
        guard bundleHasDaemon, Self.teamIdentifier != nil else { state = .unavailable; detail = "Signed release builds can install a helper so privileged changes need no password."; return }
        Task.detached(priority: .utility) {
            let status = SMAppService.daemon(plistName: KeelConstants.helperPlistName).status
            await MainActor.run { HelperManager.shared.apply(status) }
        }
    }

    private func apply(_ status: SMAppService.Status) {
        switch status {
        case .enabled: state = .enabled; detail = "Privileged changes run without a password prompt."
        case .requiresApproval: state = .needsApproval; detail = "Turn on Keel in System Settings > General > Login Items & Extensions."
        case .notRegistered, .notFound: state = .notInstalled; detail = "Each batch of privileged changes asks for your password once."
        @unknown default: state = .notInstalled
        }
    }

    func install() {
        do {
            try service.register()
            ActivityLog.shared.success("Helper registered")
        } catch {
            ActivityLog.shared.warning("Helper registration: \(error.localizedDescription)")
        }
        refresh()
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() {
        do { try service.unregister(); ActivityLog.shared.success("Helper removed") }
        catch { ActivityLog.shared.error("Could not remove helper: \(error.localizedDescription)") }
        refresh()
    }
}

/// Transient state shown in the activity strip.
@MainActor @Observable
final class AppState {
    static let shared = AppState()
    var waitingForAdmin = false
    var busyMessage: String? = nil
}
